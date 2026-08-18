# An unsupported `<invoke type>` is never live Implementation Plan

## Overview

An `<invoke>` whose `type` this engine does not support never starts a child
session, but the core still records it as a live invocation: it appears in
`Trace.InvokePass`'s `invoke_ids` and produces an `Effect.CancelInvoke` when
its state exits. An observer therefore watches an invocation start and later be
cancelled for a child that never existed. This plan makes the core's own
liveness record - `machine_state.active_invocations` - tell the truth, which
fixes both symptoms at once and leaves `Effect.Invoke` and the session's
`error.execution` exactly as they are. Bead: st-5fbw.

## Current State Analysis

**The type check today lives only at the session boundary.**
`Statifier.Session.Effects.plan_invoke/2`
(`lib/statifier/session/effects.ex:206-217`) is the only place
`Statifier.Send.Target.supported_invoke_type?/1` is consulted:

```elixir
defp plan_invoke(invoke, effect) do
  if Target.supported_invoke_type?(invoke.type) do
    [{:start_child, invoke, effect}]
  else
    [
      {:raise, :platform, "error.execution", {:invoke, invoke.state_index, invoke.invoke_index},
       []}
    ]
  end
end
```

That is correct as far as it goes: no `{:start_child, _}` is planned, and
3.12.2's `error.execution` is raised back into the session. But by the time the
session sees the effect, the core has already committed to the invocation.

**The core records liveness unconditionally.**
`Statifier.Interpreter.invoke_one/6` (`lib/statifier/interpreter.ex:1343-1390`)
resolves `type` through `resolve_expr/2` - which handles both a static `type`
and a compiled `typeexpr` - then, on a successful `idlocation` write,
unconditionally calls `record_active_invocation/4`
(`lib/statifier/interpreter.ex:1553`) before building the `Effect.Invoke`. The
resolved `type` is in scope at that point and is simply passed into the effect
payload; nothing tests it.

**Both symptoms hang off that one record.**

- `run_invoke_pass/1` (`lib/statifier/interpreter.ex:1276-1295`) builds the
  trace's `invoke_ids` by comprehending over the *emitted effects*, not over
  what the pass recorded:

  ```elixir
  invoke_ids = for {:invoke, %Effect.Invoke{invoke_id: invoke_id}} <- effects, do: invoke_id
  ```

  So even once the record is skipped, this line would keep reporting the id.
- `ExitEntry.cancel_one_invocation/4`
  (`lib/statifier/interpreter/exit_entry.ex:304-328`) already emits
  `CancelInvoke` only for a key present in `active_invocations`, and its comment
  already names the precedent: an invocation whose arguments failed (ADR-0031)
  never reaches `active_invocations` and so produces no cancel. This symptom
  needs no code change at all once the record is skipped.
- `apply_invoke_passes_for_invocation/5`
  (`lib/statifier/interpreter.ex:616-633`) reads the same map for `<finalize>`
  matching and autoforwarding, so skipping the record also stops the engine from
  autoforwarding external events to an invocation that has no child. That is a
  third latent bug the same one-line change closes; it is not separately
  asserted here beyond the `active_invocations` assertion in Phase 1.

**What the spec says.** 6.4.1's attribute table:

> Platforms MUST support `http://www.w3.org/TR/scxml/` as a value for the
> 'type' attribute. Platforms MAY support `http://www.w3.org/TR/voicexml21/`
> ... Processors MAY define short form notations as an authoring convenience
> (e.g., "scxml" as equivalent to `http://www.w3.org/TR/scxml/`).

and 6.4 on cancellation:

> If the invoking session takes a transition out of the state containing the
> `<invoke>` before it receives the 'done.invoke. id ' event, the SCXML
> Processor MUST automatically cancel the invoked component and stop its
> processing.

There is no invoked component here, so there is nothing the MUST reaches. Both
quotes are from `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`.

**Appendix D.** `spec-cache/appendix-d.txt:137-141` is explicit that this is a
platform decision, not a pseudocode one:

```
        # Here we invoke whatever needs to be invoked. The implementation of 'invoke' is platform-specific
        for state in statesToInvoke.sort(entryOrder):
            for inv in state.invoke.sort(documentOrder):
                invoke(inv)
        statesToInvoke.clear()
```

`invoke(inv)` is declared platform-specific, so deciding inside it that an
unsupported type starts nothing is not an ADR-0002 deviation. `exitStates`
(`appendix-d.txt:272-273`) does say `for inv in s.invoke: cancelInvoke(inv)`
unconditionally; this codebase already deviates there, guarding on
`active_invocations`, with the mechanical reason recorded in
`cancel_one_invocation/4`'s own comment (ADR-0031's argument-failure case).
This plan widens the set that comment covers rather than introducing a new
deviation - see Phase 1's doc change.

### Key Discoveries:

- `lib/statifier/interpreter.ex:1353` - the unconditional
  `record_active_invocation/4` call is the single root cause of both symptoms.
- `lib/statifier/interpreter.ex:1287` - `invoke_ids` is derived from emitted
  effects, so it must be re-derived from liveness or it will not follow.
- `lib/statifier/interpreter/exit_entry.ex:305` - `Map.fetch/2` on
  `active_invocations` already makes the cancel side self-correcting.
- `lib/statifier/effect/invoke.ex:60` - `Effect.Invoke` carries both
  `state_index` and `invoke_index`, so an emitted effect can be matched back to
  its `active_invocations` key with no new accumulator.
- ADR-0047 decision 3 moved the classifier into the neutral
  `Statifier.Send.Target` precisely so the core may call it; decision 5 records
  that the supported-type set is static, with an embedder-registrable processor
  set named as the reopen trigger.
- ADR-0047 decision 4 - "The two sites apply one shared classifier (decision 3),
  so they cannot drift" - is the existing answer to the drift question, and this
  plan reuses it rather than inventing a second one.
- `test/statifier/interpreter/cancel_invoke_test.exs:150` - "an invocation whose
  arguments failed produces no cancel on exit" is the ADR-0031 precedent test
  the new cancel test is modeled on.
- `test/statifier/session/effects_test.exs:496-538` - the session-side
  unsupported-type behavior this plan must leave untouched, already covered.

## Desired End State

An `<invoke>` whose resolved `type` is not supported:

- still produces its `Effect.Invoke`, carrying the authored `type`, in the same
  position in the effect stream, with the same generated `invoke_id`, and still
  performs its `idlocation` write and emits its `:datamodel_change`;
- still causes `Statifier.Session.Effects.plan_invoke/2` to plan
  `{:raise, :platform, "error.execution", {:invoke, state_index, invoke_index}, []}`
  and no `{:start_child, _}`;
- is **absent** from `Trace.InvokePass`'s `invoke_ids`;
- is **absent** from `machine_state.active_invocations`, and so emits no
  `Effect.CancelInvoke` when its state exits, is never autoforwarded to, and
  never matches an external event's `invokeid` for `<finalize>`.

Verified by: `mix quality` green, plus the new tests in Phases 1 and 2 which
assert each bullet directly.

## What We're NOT Doing

- **Not moving the rejection into the core.** ADR-0047 gives `<send>` a
  core-side *rejection*: no effect, `error.execution` from
  `Statifier.Interpreter.Content`, 4.9 block abort. This plan deliberately does
  not do the same for `<invoke>`. The bead's acceptance criterion requires
  `Effect.Invoke` and `error.execution` behavior to be unchanged, and the
  disanalogy is real: `<send>`'s check is on a statically-known attribute at the
  point the element executes, while `<invoke type>` may come from a runtime
  `typeexpr`, and `<invoke>` is not executable content so there is no block to
  abort. Making `<invoke>` symmetric with `<send>` would relocate where
  `error.execution` originates and would be a direction-level decision needing
  its own record - it is not this bug fix.
- **Not touching effect ordering.** The bead's observation that the same run
  reordered effects (`{1,3}` -> `{1,1}`) is st-r6l9's, not this bead's.
- **Not writing a new ADR or amending ADR-0047.** See "Decision 1" below for the
  reasoning, which is recorded in the code comment rather than a record.
- **Not changing `Statifier.Send.Target`.** `supported_invoke_type?/1` is
  already public, pure, and correct; this plan only adds a second caller.
- **Not adding a changelog fragment.** Per `changelog.d/README.md`'s "While v2
  is unreleased" rule, a fragment is written when v2 differs from v1. v1
  (`../statifier`) has no `Trace.InvokePass` and no `Effect.CancelInvoke` at
  all, so there is no v1 behavior for this to differ from, and no 1.x user can
  observe the change. `changelog.d/st-5fbw.md` is deliberately not created.

## Implementation Approach

### Decision 1: the core may call `Statifier.Send.Target.supported_invoke_type?/1`, and this needs no new record

ADR-0047 decision 3 moved the classifier out of `Statifier.Session.Target` into
the neutral `Statifier.Send.Target` for exactly this reason - "`Statifier.Session.Target`'s
namespace says 'session concern', which stops being true the moment the core
calls it" - and explicitly left it open whether `supported_invoke_type?/1`
travelled with it (it did). Decision 5 settled that the supported-type set is
static ("a fixed three-way string test with no deployment state behind it"), so
the check may run in the core; the named reopen trigger is an
embedder-registrable processor-type set, which does not exist.

This plan's use is *strictly narrower* than what ADR-0047 already authorizes.
ADR-0047 lets the core use the predicate to **reject** a `<send>`. Here the
predicate does not reject anything: the `Effect.Invoke` is still built and
emitted unchanged, `error.execution` still originates at the session, and the
predicate only decides a bookkeeping question the core already owns alone -
whether `active_invocations` gains an entry. Nothing about that is a new
direction, so: **neither a new ADR nor an amendment to ADR-0047.** An
implementation comment at the call site cites ADR-0047 decisions 3 and 5 and
6.4's cancel clause, which is where a reader will look.

The `typeexpr` disanalogy the bead raises is real but does not change the
answer. It only forces *when* the check runs (invoke time, against the resolved
value, inside `invoke_one/6`) rather than *whether* the core may run it. That is
the same place `type` is already resolved, so the check adds no new evaluation
and no new ordering.

### Decision 2: `active_invocations` is the one piece of state, and `invoke_ids` is re-derived from it

`machine_state.active_invocations` is already the single source of truth for
"this invocation is live" - `cancel_one_invocation/4`,
`apply_invoke_passes_for_invocation/5`, and (mirrored, through
`{:start_child, _}`) `Statifier.Session.Invocations` all read it or track it.
So the change is to **skip `record_active_invocation/4`** for an unsupported
type. No new struct field, no new accumulator threaded through
`invoke_state/3` -> `invoke_one/6`.

`run_invoke_pass/1` then re-derives `invoke_ids` by filtering the emitted
`Effect.Invoke`s against the post-pass `active_invocations`, matching on the
effect's own `{state_index, invoke_index}` key **and** on the id value:

```elixir
invoke_ids =
  for {:invoke, %Effect.Invoke{} = invoke} <- effects,
      Map.get(machine_state.active_invocations, {invoke.state_index, invoke.invoke_index}) ==
        invoke.invoke_id,
      do: invoke.invoke_id
```

Order is preserved because it still walks `effects` in emission order (entry
order across states, document order within a state) - the property
`Trace.InvokePass`'s moduledoc states. Matching on the value as well as the key
means a hypothetical stale entry under the same key from an earlier pass cannot
resurrect an id; re-entry after exit already deletes the entry
(`exit_entry.ex:317-321`), so this is belt-and-braces, not a fix for a known
case.

Three contracts this must not break, and does not:

- **`Effect.Invoke`'s own contract** is untouched. Every field is built exactly
  as today, from the same values, in the same position in the effect list, and
  the `:datamodel_change` for `idlocation` still precedes it.
- **`plan_invoke/2`** still receives the effect and still plans the
  `{:raise, ...}`. The session boundary is unaware of the core's bookkeeping.
- **The `idlocation` write still lands.** It is sequenced before the record
  today and stays there; an author reading the invoke id out of the datamodel
  sees the same value whether or not the type was supported, which is what
  `Effect.Invoke` carrying the id already implies.

### Decision 3: what the observability docs require

`docs/observability.md:69` describes the invoke-pass row as "the states walked
and the invocations it started". That sentence is what this change makes *true*
- an invocation that starts nothing is no longer reported - so the file needs no
edit, and this plan makes none. `lib/statifier/effect.ex:28,43` name only the
producing function for the `:invoke` and `Trace.InvokePass` rows and are
likewise unaffected.

Two moduledocs do state something this change makes stale and must be updated
in Phase 1:

- `lib/statifier/effect/trace/invoke_pass.ex` documents `invoke_ids` as "every
  invocation this pass actually started" and enumerates ADR-0031's
  argument-failure case as the only non-contributor. An unsupported type is a
  second non-contributor and must be named alongside it.
- `lib/statifier/interpreter/exit_entry.ex`'s `cancel_one_invocation/4` comment
  says an invocation "never started" produces no cancel; it should name both
  ways an invocation can fail to start.

`lib/statifier/session/effects.ex`'s `<invoke> routing` moduledoc section stays
as written - the session's behavior is unchanged - and gains no claim about core
bookkeeping.

### Decision 4: drift between the two checks

The two call sites - `plan_invoke/2` and `invoke_one/6` - both call the single
pure predicate `Statifier.Send.Target.supported_invoke_type?/1`. This is
verbatim the mechanism ADR-0047 decision 4 already relies on for `<send>`'s two
sites ("The two sites apply one shared classifier (decision 3), so they cannot
drift"). They cannot disagree about *which* types are supported, because there
is one definition.

What they can still disagree about is *which value* is classified: the core
classifies the runtime-resolved `type`, the session classifies
`invoke.type` off the `Effect.Invoke` payload. Those are the same value by
construction - `invoke_one/6` puts the resolved `type` into the effect's `type`
field, which is what `plan_invoke/2` reads. Phase 2 pins that with an
end-to-end test that drives one document through a real session and asserts both
halves in the same run: the `error.execution` arrives (session half) *and* the
id is absent from `invoke_ids` with no `CancelInvoke` (core half). A change that
made the two classify different values reddens that test.

No third site is introduced and no local copy of the predicate is made.

## Phase 1: The core stops recording an unsupported-type invocation

### Overview

`invoke_one/6` skips `record_active_invocation/4` when the resolved `type` is
unsupported, and `run_invoke_pass/1` derives `invoke_ids` from
`active_invocations` instead of from the emitted effects. Both symptoms named in
the bead are fixed by the end of this phase; Phase 2 only adds boundary
coverage.

### Changes Required:

#### 1. The invoke pass

**File**: `lib/statifier/interpreter.ex`

**Changes**: add `alias Statifier.Send.Target` to the alias block at
`interpreter.ex:182-186` (no collision - `Target` is not currently bound in this
module; verify at implementation time and qualify fully if that has changed).

In `invoke_one/6`, replace the unconditional record with a guarded one, in the
same position in the `{:ok, machine_state, context, write}` branch:

```elixir
# 6.4.1 makes `http://www.w3.org/TR/scxml/` (and its "scxml" short form)
# the only `type` this platform supports; a `type`/`typeexpr` naming
# anything else starts no child - `Statifier.Session.Effects.plan_invoke/2`
# raises 3.12.2's `error.execution` for it instead. The `Effect.Invoke` is
# still emitted (the session needs it to raise against), but the invocation
# is never live, so it is not recorded: 6.4's "MUST automatically cancel
# the invoked component" has no invoked component to reach, and a trace
# consumer must not see an invocation start that never did. Same channel
# ADR-0031's failed-argument case already uses - absent from
# `active_invocations` - reached for a different reason. Calling
# `Statifier.Send.Target` from the core is ADR-0047 decisions 3 and 5:
# the classifier lives in a neutral module for this, and the supported set
# is static. Unlike `<send>`, this is not a rejection - nothing about the
# emitted effect or the raised error changes.
machine_state =
  if Target.supported_invoke_type?(type) do
    record_active_invocation(machine_state, state_index, invoke_index, invoke_id)
  else
    machine_state
  end
```

In `run_invoke_pass/1`, replace the `invoke_ids` comprehension with the
liveness-filtered form from Decision 2, with a comment stating that it reads
liveness rather than emission and why.

Update `invoke_one/6`'s own leading comment (currently "Otherwise the invocation
is recorded in `active_invocations` and one `{:invoke, %Effect.Invoke{}}` is
emitted") to say that the record is conditional on a supported `type` while the
effect is not.

#### 2. Trace payload documentation

**File**: `lib/statifier/effect/trace/invoke_pass.ex`

**Changes**: extend the `invoke_ids` paragraph so the exclusion clause names
both cases - an invocation whose arguments raised `error.execution` (ADR-0031)
and one whose `type` is unsupported (6.4.1) - and restate the field as "every
invocation this pass actually started", i.e. every invocation now live in
`active_invocations`.

#### 3. Cancel-side comment

**File**: `lib/statifier/interpreter/exit_entry.ex`

**Changes**: extend `cancel_one_invocation/4`'s "or leave `ms`/`effects`
untouched when it never started" comment to name the two ways an invocation can
fail to start (failed arguments, ADR-0031; unsupported `type`, 6.4.1), so the
Appendix-D deviation this guard represents stays fully justified in place.

#### 4. Core tests

**File**: `test/statifier/interpreter/invoke_pass_test.exs`

**Changes**: add a fixture whose state carries one unsupported-type `<invoke>`
and one supported sibling, e.g.

```elixir
#  0 scxml (root)
#  1   s0      (invoke type="http://example.com/not-scxml"; invoke id="ok" type="scxml")
@unsupported_type_document """
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
    <state id="s0">
        <invoke id="bad" type="http://example.com/not-scxml"/>
        <invoke id="ok" type="scxml"/>
    </state>
</scxml>
"""
```

and tests asserting:

- both `Effect.Invoke`s are still emitted, in document order, the unsupported
  one still carrying `type: "http://example.com/not-scxml"` and
  `invoke_id: "bad"` (this is the "unchanged `Effect.Invoke`" half of the bead's
  acceptance criterion);
- `trace.invoke_ids == ["ok"]`;
- `result.active_invocations` has an entry for the supported invocation's
  `{state_index, invoke_index}` and none for the unsupported one.

Add a second fixture that reaches the same answer through a runtime-resolved
`typeexpr` rather than a static `type` - the same structure as
`@unsupported_type_document` above (one unsupported invocation, one supported
sibling, same ids, same assertions), with the bad type string held in a
root-level `<datamodel>` and read back by `typeexpr`:

```elixir
#  0 scxml (root)
#  1   s0      (invoke typeexpr="bad_type"; invoke id="ok" type="scxml")
@unsupported_typeexpr_document """
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0"
       datamodel="predicator">
    <datamodel>
        <data id="bad_type" expr="'http://example.com/not-scxml'"/>
    </datamodel>
    <state id="s0">
        <invoke id="bad" typeexpr="bad_type"/>
        <invoke id="ok" type="scxml"/>
    </state>
</scxml>
"""
```

This is deliberately a `typeexpr` that **evaluates successfully to an
unsupported value**, which is the case this plan's guard handles. A `typeexpr`
that fails to *evaluate at all* is a different, pre-existing path: it never
reaches the guard, because `resolve_expr/2` returns `{:error, _}` out of
`invoke_one/6`'s `with` chain and `abort_invocation/4` produces no
`Effect.Invoke` and no `active_invocations` entry (ADR-0031). That path is
already covered by "a failing typeexpr raises error.execution and produces no
effect, but a sibling still does" in the same test module, and this plan changes
nothing about it.

**File**: `test/statifier/interpreter/cancel_invoke_test.exs`

**Changes**: add a test modeled on the existing "an invocation whose arguments
failed produces no cancel on exit" (line 150): a state with an unsupported-type
`<invoke>` and a supported sibling, transitioned out of; assert exactly one
`CancelInvoke` is emitted, for the supported invocation's id.

Every new test gets its `# sabotage:` line per `docs/testing.md`, e.g.
`# sabotage: invoke_one/6's supported-type guard is removed so an unsupported
type still calls record_active_invocation/4 -> "bad" reappears in invoke_ids ->
red`, confirmed red and reverted before the line is written.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality` is fully green (use `mix quality --profile loop` between
      edits; a loop or scoped run does not satisfy this phase).
- [x] `mix gate.verify` exits zero, proving the reported green was a full,
      unprofiled, unscoped, un-`--skip`ed run.
- [x] `mix test test/statifier/interpreter/invoke_pass_test.exs
      test/statifier/interpreter/cancel_invoke_test.exs` passes.
- [x] `mix test --include scion --include scxml_w3` shows no newly failing
      conformance test, and `mix test.regression` is green (the ratchet is
      unchanged - no corpus test is expected to flip, since no document in the
      corpus pairs an unsupported invoke type with a trace assertion; if one
      does flip to passing, `mix test.baseline add` it).
- [x] `mix quality --format json --report -` is available for a looped
      execution to route on.

#### Manual Verification:
- [ ] The touched functions still match the W3C Appendix D pseudocode line for
      line: `invoke(inv)` is declared platform-specific
      (`spec-cache/appendix-d.txt:137`), so the guard inside it is not a
      deviation, and `exitStates`' unconditional `cancelInvoke(inv)` deviation
      is the pre-existing one whose comment this phase widens rather than a new
      one.
- [ ] A trace consumer stepping the invoke pass for a document with a mixed pair
      of invocations sees exactly the started one named, and sees no phantom
      node appear and disappear.
- [ ] No regressions in `<finalize>` or autoforward behavior for supported
      invocations (they read the same map).

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: End-to-end coverage that the two checks agree

### Overview

Phase 1's tests are core-only. This phase pins the whole path through a live
session in one test, which is what makes Decision 4's anti-drift claim
mechanical: the same document must produce the session's `error.execution` and
the core's absent-from-liveness bookkeeping in a single run. No `lib/` change.

### Changes Required:

#### 1. Session-level integration test

**File**: `test/statifier/session/invoke_start_child_test.exs`

**Changes**: add a describe block for an unsupported invoke type, following the
module's existing subscriber-driven pattern (it already asserts on
`{:effect, {:cancel_invoke, %Effect.CancelInvoke{invoke_id: ^invoke_id}}}` at
line 160, which is the exact shape this test must show is absent). One document,
one state with an unsupported-type `<invoke>` and a transition out of it.
Assert, from one run:

- the `{:invoke, %Effect.Invoke{type: "http://example.com/not-scxml"}}` effect
  is observed, unchanged;
- an `error.execution` event is raised into the session, naming the invoke node
  (`{:invoke, state_index, invoke_index}` origin), as today;
- `Statifier.Session.Invocations` never gains an entry - no child session is
  started;
- the `Trace.InvokePass` effect's `invoke_ids` does not contain the invoke id;
- taking the transition out of the state produces **no**
  `Effect.CancelInvoke` for that id.

Use `Statifier.StreamOrder` as the module's neighbouring tests do when the
assertion depends on effect ordering. `async: false` for the same reason the
module already is.

Sabotage line, confirmed red and reverted, e.g.
`# sabotage: invoke_one/6 records an unsupported-type invocation -> the
CancelInvoke refute reddens`.

#### 2. The predicate itself: no change

**File**: `test/statifier/send/target_test.exs`

**Changes**: none. Its `describe "supported_invoke_type?/1"` block
(lines 104-139) already pins all three accepted forms (`nil`, `"scxml"`,
`scxml_invoke_type/0`), rejects `"http://example.com/BasicHTTPEventProcessor"`,
and rejects `supported_type?/1`'s own processor URI - each with its own sabotage
line. A duplicate assertion here would not be coverage. This item exists so the
implementer confirms rather than re-derives it; note the confirmation in the
commit body.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality` is fully green (loop gate between edits only).
- [ ] `mix gate.verify` exits zero.
- [ ] `mix test test/statifier/session/invoke_start_child_test.exs` passes.
- [ ] `mix test.regression` is green; the ratchet is unchanged by a test-only
      phase.

#### Manual Verification:
- [ ] The test genuinely exercises both halves in one run - reading it, a
      reviewer can see that a core-side change alone or a session-side change
      alone would redden it.
- [ ] The observed effect stream, read in order, tells a coherent story: an
      `Effect.Invoke`, an `error.execution`, no invocation in the pass trace, no
      cancel on exit.
- [ ] No regressions in the module's existing start-child tests.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Corpus/Ratchet Notes

No corpus regeneration and no expected `test/passing_tests.json` movement. The
W3C mandatory suite has no test that pairs an unsupported `<invoke type>` with
an assertion on cancellation or on the trace stream, and this change alters no
event, no configuration, and no datamodel value - only which invocations the
core considers live. `mix test.regression` is run in both phases to prove that
rather than to assume it. If a conformance test does flip to passing, add it
with `mix test.baseline add` in the same phase and say so in the commit body.

## Testing Strategy

### Unit Tests:

- `test/statifier/interpreter/invoke_pass_test.exs` - `Trace.InvokePass`'s
  `invoke_ids` excludes an unsupported-type invocation while its `Effect.Invoke`
  survives; `active_invocations` reflects only the supported one; both a static
  `type` and a runtime `typeexpr` reach the same answer.
- `test/statifier/interpreter/cancel_invoke_test.exs` - exiting the state emits
  a `CancelInvoke` for the supported sibling only.
- `test/statifier/session/invoke_start_child_test.exs` - the whole path through
  a real session, both halves in one run.

Key edge cases: a state carrying a supported and an unsupported invocation
together (proves the guard is per-invocation, not per-state); a `typeexpr` whose
runtime value is unsupported (proves the check is at invoke time, not compile
time); re-entering the state (the second pass must behave identically, and no
stale `active_invocations` key can resurrect an id).

Every new test asserting `lib/` behavior carries its `# sabotage:` line,
confirmed red and reverted, per `docs/testing.md` and this repo's CLAUDE.md.

### Manual Testing Steps:

1. Compile a document with `<invoke type="http://example.com/not-scxml"/>` on a
   state with a transition out, run it through `Statifier.Session` with an
   observer attached, and read the effect stream in order.
2. Confirm the `Effect.Invoke` appears with the authored type, the
   `error.execution` follows naming the invoke node, the `Trace.InvokePass`
   between them lists no invoke id, and taking the transition emits no
   `Effect.CancelInvoke`.
3. Repeat with `type="scxml"` and confirm the id is present in `invoke_ids` and
   the `CancelInvoke` is emitted on exit - the supported path is untouched.

## References

- Bead: `st-5fbw` (mirrors `sui-t36.1`)
- Related ADRs: `docs/adr/0047-send-static-target-type-invalidity-rejects-in-the-core.md`
  (decisions 3, 4, 5 - the classifier's neutral home, the shared-classifier
  anti-drift argument, and the static supported-type set),
  `docs/adr/0031-invoke-argument-failure-aborts-the-invocation.md` (the
  precedent: an invocation that never starts is never in `active_invocations`),
  `docs/adr/0012-debuggability-designed-into-the-core.md` (the trace seams),
  `docs/adr/0002` (Appendix D fidelity), `docs/adr/0003-pure-core-with-effects.md`
- Root cause: `lib/statifier/interpreter.ex:1353` (the unconditional record),
  `lib/statifier/interpreter.ex:1287` (the emission-derived `invoke_ids`)
- Session boundary left unchanged: `lib/statifier/session/effects.ex:206-217`
- Shared classifier: `lib/statifier/send/target.ex` `supported_invoke_type?/1`
- Self-correcting cancel side: `lib/statifier/interpreter/exit_entry.ex:304-328`
- Precedent test: `test/statifier/interpreter/cancel_invoke_test.exs:150`
- Spec: `spec-cache/scxml-rec.html` 6.4/6.4.1;
  `spec-cache/appendix-d.txt:137-141, 272-273`
- Upstream research: `docs/research/260816-sui-t36.1-trace-coverage-spike.md`
  (in the statifier-ui repo, not this one)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The touched functions still match the W3C Appendix D pseudocode line for
      line: `invoke(inv)` is declared platform-specific
      (`spec-cache/appendix-d.txt:137`), so the guard inside it is not a
      deviation, and `exitStates`' unconditional `cancelInvoke(inv)` deviation
      is the pre-existing one whose comment this phase widens rather than a new
      one.
- [ ] A trace consumer stepping the invoke pass for a document with a mixed pair
      of invocations sees exactly the started one named, and sees no phantom
      node appear and disappear.
- [ ] No regressions in `<finalize>` or autoforward behavior for supported
      invocations (they read the same map).

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
