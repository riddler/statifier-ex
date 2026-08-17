# Static `<send>` Target/Type Validity in the Core Implementation Plan

## Overview

ADR-0047 decides that spec 6.2.4's invalid-`target` and 6.2.5's
unsupported-`type` checks are made **inside the pure core**, in
`Statifier.Machine.Content.Send.execute/2`, and that rejection travels
ADR-0036's existing channel: no `Effect.Send`/`Effect.SendDelayed` is
produced, and `Statifier.Interpreter.Content`'s fold supplies both the
`error.execution` and spec 4.9's block abort. This plan implements that
decision. Bead: st-yizi.

The observable result is test159 going green (the sibling `<assign>` in the
same `<onentry>` block no longer runs) and entering the regression ratchet,
with test332 - already ratcheted - as the guard that the send id is still
minted and `idlocation` still written *before* the rejection, so the raised
`error.execution` still carries `sendid`.

## Current State Analysis

**Where the check lives today.** `Statifier.Session.Effects.plan_send/3`
(`lib/statifier/session/effects.ex:155-177`) and `plan_send_delayed/3`
(`:183-204`) gate every `<send>` effect on
`Statifier.Session.Target.supported_type?/1` and
`Statifier.Session.Target.parse/1`, planning `execution_error/1`
(`:227-231`) - a `{:raise, :platform, "error.execution", {:content, c_index,
owner}, sendid: send_id}` instruction - for `{:invalid, _}` or an
unsupported type. That is session-side, and per ADR-0003 the session only
sees the effect list *after* `Statifier.Interpreter.handle_event/2` has run
the whole macrostep to quiescence. The research document
(`docs/research/260817-st-yizi-send-target-validity-block-abort-and-order.md`)
establishes the mechanics; the consequence is that test159's sibling
`<assign>` has already run by the time the invalid target is noticed.

**Where the check must move.** `Send.execute/2`
(`lib/statifier/machine/content/send.ex:111-150`) resolves every argument in
one `with`, then mints the send id (`generate_send_id/2`, `:253-261`), writes
`idlocation` (`maybe_write_idlocation/4`, `:269-281`), and builds the effect
(`build_effect/6`, `:325-372`). Its `@spec` today admits only
`{:ok, context, effects} | {:error, term()}`.

**The channel that already does the work.** `Statifier.Interpreter.Content`
is the sole errors-are-events conversion site: `run_nodes/2`
(`lib/statifier/interpreter/content.ex:171-190`) halts the fold on the first
`{:error, reason}` **or** `{:error, new_context, reason}` from a node, and
`raise_execution_error/4` (`:232-236`) calls
`MachineState.raise_platform(machine_state, "error.execution", {:content,
c_index, owner}, data: reason)`. `Statifier.Event.platform/3`
(`lib/statifier/event.ex:140-150`) already reads `:sendid` from its opts, so
carrying a sendid through this site is an opts addition, not a new event
shape.

**Why the naive fix regresses test332.** test332
(`test/scxml_tests/mandatory/system_variables/test332_test.exs`, in
`test/passing_tests.json:266`) sends to the same invalid target `"baz"` with
`idlocation="Var1"` and asserts `Var1===_event.sendid`. An early
`{:error, reason}` in `execute/2`'s `with` chain would discard both the
advanced `send_counter` and the `idlocation` write, and the raised event
would carry no `sendid`. ADR-0047 forces the ordering: mint, write, *then*
reject, returning the composite `{:error, context, reason}` form so the
`machine_state` carrying both survives the halt.

**The classifier's home.** `Statifier.Session.Target`
(`lib/statifier/session/target.ex`) is one pure module - no process, no
registry, no liveness - but its namespace says "session concern", which stops
being true the moment the core calls it. ADR-0047 decision 3 moves it to
`Statifier.Send.Target`, mirroring `Statifier.Invoke.Source` (ADR-0038,
`lib/statifier/invoke/source.ex`). Callers today:

| Site | Kind |
|---|---|
| `lib/statifier/session/effects.ex:84` (`alias`), `:159`, `:160`, `:186`, `:187`, `:210` | code |
| `lib/statifier/session.ex:295` (`alias`), `:147` (moduledoc) | code + prose |
| `lib/statifier/session/effects.ex:19`, `:22`, `:46` | moduledoc prose |
| `lib/statifier/validator/checks/send.ex:213` | comment |
| `test/statifier/session/target_test.exs` | the module's own test file |
| `test/statifier/session_test.exs:1072`, `test/statifier/session/send_cancel_test.exs:196`, `test/statifier/session/invoke_parent_routing_test.exs:120` | comments/sabotage notes |

**Existing tests whose mechanism moves** (behavior-level, so they matter):

- `test/statifier/session/send_cancel_test.exs:207-228` - "an unparseable
  target raises error.execution on the internal queue" asserts a
  `{:send, %Effect.Send{event: "e", target: "whatever"}}` reaches the
  subscriber. **After this change no such effect is ever produced**, so this
  assertion must be inverted, and its sabotage note (which names
  `plan_send/3`'s `{:invalid, _target}` clause) re-pointed at the core.
- `test/statifier/session_test.exs:996-1026` - the unsupported-`type` delayed
  send. Its three assertions (reaches `b`, `pending_timers == 0`,
  `_event.sendid == "send1"`) all still hold, and the third is a direct
  guard on the sendid-bearing conversion; only its sabotage note names a
  function that no longer decides the outcome.
- `test/statifier/session_test.exs:1113-1140` - `Session.interpret/2` with a
  hand-built `%Effect.Send{target: "not a recognized target"}` on a halted
  session. This is exactly the ADR-0029 boundary path decision 4 preserves;
  it is unchanged and becomes the planner arms' coverage.

**Mechanical constraints discovered:**

1. `content_acceptance_test.exs:162-175` (AC3) greps every
   `lib/statifier/machine/content/*.ex` for `"error.execution"` and for
   `~r/Event(?!Data)/`. New code and comments in `send.ex` must contain
   neither - in particular, the phrase "Event I/O Processor" from 6.2.5
   cannot be written with a capital E in that file.
2. `Mix.Statifier.AdrGuard` (`lib/mix/statifier/adr_guard.ex:318-334`) flags
   bead ids appearing in `lib/` or `test/` doc context. Cite ADR-0047, never
   `st-yizi`, in code comments.
3. `Statifier.ExecutableContent`'s contract prose
   (`lib/statifier/executable_content.ex:34-45`) currently reads "A leaf node
   returns the two-element form; a *composite* node ... returns this one".
   `<send>` is a leaf that must now return the three-element form, so that
   sentence is amended by ADR-0047 (the `@type result` at `:69-73` already
   admits both and needs no change).
4. `Statifier.Effect.DatamodelChange`'s moduledoc
   (`lib/statifier/effect/datamodel_change.ex:5-8`) says a change is
   "Emitted for every successful write `write_location/4` performs". The
   rejection path performs a successful write and emits nothing (the
   composite error return has no effects slot), which ADR-0047 names as a
   known observability consequence. That sentence gains its exception.

## Desired End State

A `<send>` whose resolved `target` classifies as `{:invalid, _}`, or whose
resolved `type` is unsupported, fails inside `Send.execute/2` after its send
id has been minted and its `idlocation` written. The block runner halts the
block at that node (4.9), raises one `error.execution` carrying
`sendid: <the minted id>` and the origin `{:content, c_index, owner}`, and
produces no `Effect.Send`/`Effect.SendDelayed` and no timer. The classifier
lives at `Statifier.Send.Target`; `Statifier.Session.Effects` calls the same
module for its `interpret/2` boundary arms, which stay.

Verified by: test159 green and in `test/passing_tests.json`; test332 still
green through `mix test.regression`; the `mix quality` full gate green; and
no other member of the ratchet moving.

### Key Discoveries:

- `Event.platform/3` already reads `:sendid` from opts
  (`lib/statifier/event.ex:149`), so the "widening of the runner's error
  model" ADR-0047 authorizes is one extra `raise_execution_error/4` clause,
  not a new event field.
- `run_nodes/2` already accepts the composite `{:error, context, reason}`
  form on the fatal arm (`lib/statifier/interpreter/content.ex:181-183`) and
  keeps the node's context - no fold change is needed to preserve the
  counter and the datamodel write.
- ADR-0047 decision 1 says explicitly to use the **fatal** arm, not
  `context.pending_errors`: the drain is 5.9.1's non-fatal channel and does
  not abort the block, which is the whole point of test159.
- ADR-0036's discard already produces exactly the outcome wanted for the
  *argument* half; this change reuses its mechanism for the neighboring
  clause (6.2.4/6.2.5 beside 6.2.2) rather than rewriting it.
- ADR-0035's send-counter semantics are unchanged: an invalid-target
  `<send>` still consumes a generated id, which is what test332 observes.

## What We're NOT Doing

- **test496 and reachability of `#_scxml_foo`.** ADR-0047 decision 6 defers
  the liveness half to its own bead and its own record, which must settle
  shape C versus D, replay recording, ADR-0027's self-addressing carve-out,
  snapshot staleness, and whether `error.communication` aborts the block.
  test496 stays red and outside the ratchet. The orchestrator files that
  bead; this plan does not.
- **Removing the session planner's `{:invalid, _}` / unsupported-type
  arms.** ADR-0047 decision 4: `Session.interpret/2` is public (ADR-0029)
  and an embedder can hand in effects the core never produced. The arms are
  a boundary check, not dead code.
- **Giving ADR-0036's argument failures a `sendid`.** ADR-0047's
  consequences name this as a known 5.10.1 gap that belongs to a record
  arguing it against 6.2.2's discard semantics, not to this bead in passing.
- **Making `supported_type?/1` deployment state.** Decision 5 keeps the
  supported-type set static; the reopen trigger is an
  embedder-registrable processor-type set, which does not exist.
- **Editing ADR-0047, ADR-0039, or `docs/adr/README.md`.** Those edits are
  already made and sit uncommitted in this branch's working tree alongside
  the research document; they are part of this branch's change set and are
  left exactly as they are.
- **Emitting a `{:datamodel_change, _}` effect on the rejection path.**
  ADR-0047 accepts its absence explicitly (the composite error return has no
  effects slot; the write is in the datamodel, where test332 reads it, and
  live and replay agree because both derive from the core). This plan
  records the consequence in prose rather than engineering around it.

## Implementation Approach

Three phases, ordered so that each is independently committable with a green
full gate and none leaves an intermediate state that only the next phase
makes coherent.

Phase 1 is a pure move: the classifier changes namespace with no behavior
change at all, so the whole suite is its own proof. Phase 2 is the behavior
change, and it is one phase on purpose - the core check without the
sendid-bearing conversion regresses test332, and the conversion without the
check is dead code, so neither half is separately gate-verifiable. Phase 3 is
the ratchet and the changelog, which move no code and are verified by
`mix test.regression`.

The Appendix D rule: none of this touches an Appendix D procedure. `<send>`
is executable content, whose pseudocode contribution is `executeContent`'s
"execute the content of the block" - already ported literally in
`Interpreter.Content.execute_block/3`. No deviation from Appendix D is
introduced or required; the clauses in play are 4.9, 6.2.2-6.2.5, and
5.10.1, all normative prose rather than pseudocode. Read them from the local
cache (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`),
not from memory.

---

## Phase 1: Move the classifier to `Statifier.Send.Target`

### Overview

ADR-0047 decision 3, in isolation: `Statifier.Session.Target` becomes
`Statifier.Send.Target`, one pure module with the same functions, mirroring
`Statifier.Invoke.Source`. No caller's behavior changes.

### Changes Required:

#### 1. The module

**File**: `lib/statifier/session/target.ex` -> `lib/statifier/send/target.ex`
**Changes**: `git mv` the file, rename the module to `Statifier.Send.Target`,
and reframe the moduledoc's first paragraph: it currently says the parse
result is "a route `Statifier.Session.Effects` plans against", which is no
longer the only consumer. Say instead that it is a pure classifier with two
consumers - the core's `<send>` node, which rejects a `{:invalid, _}` target
or an unsupported `type` under ADR-0047, and `Statifier.Session.Effects`,
which applies the same classification at `Statifier.Session.interpret/2`'s
boundary (ADR-0029). Keep the existing second paragraph verbatim: resolving
a route into a delivery is still the session's job, and this module still
never says whether a destination exists.

`supported_invoke_type?/1` and `scxml_invoke_type/0` travel with the module
unchanged. ADR-0047 calls this implementation detail; keeping one module is
the reading that matches its own sentence "The module stays one pure module
with the same functions", and splitting it would create a second module for
two functions with no caller that wants them apart. Add one sentence to
`supported_invoke_type?/1`'s `@doc` noting that `<invoke>`'s type predicate
lives here because it shares 6.4.2/6.2.5's short-form reasoning with its
`<send>` sibling, not because `<invoke>` is a send.

#### 2. Code callers

**File**: `lib/statifier/session/effects.ex`
**Changes**: `alias Statifier.Session.Target` (`:84`) becomes
`alias Statifier.Send.Target`; the moduledoc's three prose references
(`:19`, `:22`, `:46`) name the new module. Call sites need no other edit -
the local alias name is unchanged.

**File**: `lib/statifier/session.ex`
**Changes**: `alias Statifier.Session.Target` (`:295`) and the moduledoc
sentence at `:147` name the new module.

**File**: `lib/statifier/validator/checks/send.ex`
**Changes**: the comment at `:213` names the new module.

#### 3. Tests

**File**: `test/statifier/session/target_test.exs` ->
`test/statifier/send/target_test.exs`
**Changes**: `git mv`, rename the test module to
`Statifier.Send.TargetTest`, update its `alias`. Assertions are unchanged -
this file is the classifier's own coverage and stays exhaustive over the
route vocabulary.

**Files**: `test/statifier/session_test.exs:1072`,
`test/statifier/session/send_cancel_test.exs:196`,
`test/statifier/session/invoke_parent_routing_test.exs:120`
**Changes**: comment/sabotage-note text only - the module name in prose.

No new tests are warranted: this phase adds no `lib/` behavior, so the
sabotage rule has nothing to apply to. The existing suite passing unchanged
is the proof that the move is a move.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` is green (use `mix quality --profile loop` between
      edits; a loop or `--quick` run never satisfies this phase).
- [x] `mix gate.verify` confirms the run was a full, unscoped gate.
- [x] `grep -rn "Session.Target" lib test` returns nothing.
- [x] `mix test.regression` is green - no ratcheted conformance test moves.
- [x] `test/statifier/send/target_test.exs` exists and
      `test/statifier/session/target_test.exs` does not.

#### Manual Verification:

- [ ] The moved moduledoc still disclaims liveness in its own words - the
      module says what kind of destination a string names and never whether
      that destination exists (ADR-0047 decision 2's scoping depends on this
      staying true).
- [ ] The diff is a rename plus prose: no `parse/1` or `supported_type?/1`
      clause changed, added, or reordered.
- [ ] Appendix D conformance, per `.claude/wurk/plan.md`: satisfied
      vacuously here. This phase touches `lib/statifier/` but no Appendix D
      procedure - `Statifier.Send.Target` is a pure string classifier the
      pseudocode never names, and the other three files change only an alias
      and prose. Confirm that is still true of the diff as landed rather
      than assuming it from this sentence.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause
here for confirmation before Phase 2. In looped (`--loop`) execution, the
Automated Verification list gates advancement and the Manual items are
deferred to the end.

---

## Phase 2: Reject invalid target/type inside `Send.execute/2`

### Overview

The behavior change. `Send.execute/2` classifies the resolved `target` and
`type` after minting the send id and writing `idlocation`, and rejects with
the composite `{:error, context, reason}` form carrying a sendid-bearing
reason. `Interpreter.Content.raise_execution_error/4` gains one clause that
destructures that reason into `data:` plus `sendid:`. Block abort and the
correctly-positioned `error.execution` fall out of the existing fold.

### Changes Required:

#### 1. The core check

**File**: `lib/statifier/machine/content/send.ex`
**Changes**: add `alias Statifier.Send.Target`; widen the `@spec` for
`execute/2` to admit `{:error, Context.t(), term()}`; insert the validity
check in the `{:ok, machine_state, datamodel_context, write}` branch, after
the id is minted and the write has landed, before `build_effect/6`.

```elixir
case maybe_write_idlocation(machine_state, datamodel_context, node.idlocation, send_id) do
  {:ok, machine_state, datamodel_context, write} ->
    new_context = %{
      context
      | machine_state: machine_state,
        datamodel_context: datamodel_context
    }

    case reject_reason(target, type) do
      nil ->
        # ... existing fields/effect/return, threading new_context ...

      reason ->
        # ADR-0047: 6.2.4's invalid target and 6.2.5's unsupported type are
        # rejected here, in the core, so 4.9's block abort is honored. The
        # id was minted and idlocation written first (5.10.1's unconditional
        # MUST), and the composite error form is what keeps both: the
        # advanced send_counter and the datamodel write are in new_context's
        # machine_state, which the block runner keeps on its fatal arm.
        {:error, new_context, {:send_rejected, send_id, reason}}
    end

  {:error, reason} ->
    {:error, reason}
end
```

with

```elixir
# 6.2.5's type check runs ahead of 6.2.4's target check, matching the order
# Statifier.Session.Effects applies at its own boundary. `nil` means the
# send is well-formed and dispatches.
@spec reject_reason(target :: term(), type :: term()) ::
        {:unsupported_type, term()} | {:invalid_target, term()} | nil
defp reject_reason(target, type) do
  cond do
    not Target.supported_type?(type) -> {:unsupported_type, type}
    match?({:invalid, _}, Target.parse(target)) -> {:invalid_target, target}
    true -> nil
  end
end
```

Constraints on this file, both mechanical (AC3,
`test/statifier/interpreter/content_acceptance_test.exs:162-175`): the new
code and its comments must not contain the string `error.execution`, and
must not contain `Event` with a capital E followed by anything but `Data` -
write "the SCXML event I/O processor" in lower case when paraphrasing 6.2.5.
Cite ADR-0047 by number; never write the bead id (AdrGuard,
`lib/mix/statifier/adr_guard.ex:318-334`).

Amend the block comment above `execute/2` (`:87-102`) in the same pass. It
currently asserts "`<send>` is a leaf, so a failure returns the two-element
`{:error, reason}` form", which stops being true here: argument failures
still return the two-element form (ADR-0036), and the ADR-0047 rejection
returns the three-element one because it has already minted an id and
written `idlocation`. State both, so the sentence beside the code says what
the code does - this is the same amendment `executable_content.ex`'s
contract bullet gets below, applied to its local copy.

`Target.supported_type?/1` and `Target.parse/1` take the *resolved* values,
so a `targetexpr` that fails to evaluate remains ADR-0036's case (the `with`
never reaches here) and one that evaluates to `"baz"` is this record's. Both
`<send>` and `<send delay=...>` flow through this one function, which is
what makes 6.2.3's "evaluate arguments when the element is evaluated"
hold for delayed sends without a second site.

#### 2. The sendid-bearing conversion

**File**: `lib/statifier/interpreter/content.ex`
**Changes**: add a clause above the existing `raise_execution_error/4`:

```elixir
# ADR-0047's widening of the runner's error model: a node may name the send
# id its failure belongs to, and 5.10.1's MUST ("in the case of error events
# triggered by a failed attempt to send an event, the Processor MUST set this
# field to the send id of the triggering <send> element") is unconditional,
# so the id travels as an event field rather than only inside `data`. The
# inner reason is still what `data` carries, so a consumer reading `data`
# sees the same shape it would for any other content failure.
defp raise_execution_error(machine_state, owner, c_index, {:send_rejected, send_id, reason}) do
  MachineState.raise_platform(machine_state, "error.execution", {:content, c_index, owner},
    data: reason,
    sendid: send_id
  )
end
```

Add a `## A node may name a send id` subsection to the moduledoc under
"Errors-are-events, once", stating the widening and citing ADR-0047. Note
there that this clause is reachable from the fatal arm only: 5.9.1's
`pending_errors` drain is the non-fatal channel and no node puts a
`{:send_rejected, _, _}` reason there, which is deliberate - a drained error
does not abort the block, and 4.9's abort is the point.

#### 3. The contract prose that the change amends

**File**: `lib/statifier/executable_content.ex`
**Changes**: the `{:error, context, reason}` bullet (`:40-45`) currently
reads "A leaf node returns the two-element form; a *composite* node - one
that runs child content - returns this one". Restate the rule by what it is
for rather than by node kind: a node returns the three-element form when it
has already produced state that must not be discarded with the failure -
which is every composite node, and (ADR-0047) `<send>`, a leaf that has
minted a send id and written `idlocation` before rejecting an invalid target.

**File**: `lib/statifier/effect/datamodel_change.ex`
**Changes**: the moduledoc sentence "Emitted for every successful write
`write_location/4` performs (decision 2)" gains its one exception: the
`idlocation` write of a `<send>` rejected under ADR-0047 emits no effect,
because the composite error return carries no effects slot. The write is in
the datamodel regardless (test332 reads it back through `_event.sendid`),
and live and replay agree because both derive from the core.

**File**: `lib/statifier/session/effects.ex`
**Changes**: prose only. The moduledoc's numbered `<send>` routing list
(`:16-30`) presents steps 1 and 2 as the place validity is decided; reframe
them as the boundary check ADR-0047 decision 4 keeps for effects arriving
through `Statifier.Session.interpret/2` (ADR-0029), noting that
core-produced effects never reach these arms because the core already
rejected them. Add the same note to `execution_error/1`'s comment
(`:221-231`), which ADR-0047's consequences call for by name.

#### 4. Tests

**File**: `test/statifier/machine/content/send_test.exs`
**Changes**: a new `describe "execute/2 - static target/type rejection
(ADR-0047)"` block, driving the protocol directly the way the existing
describes do (`context/2`, `send_node/2`, `machine_state/2` helpers at
`:88-104`). Cases:

1. An invalid `target` returns `{:error, context, {:send_rejected, send_id,
   {:invalid_target, "baz"}}}` and no effect.
2. The returned context's `machine_state.send_counter` has advanced - the
   generated id was consumed (ADR-0035 unchanged).
3. With `idlocation`, the returned context's `machine_state.datamodel` holds
   the minted id at that location, and the `send_id` in the reason equals it.
4. An unsupported `type` rejects with `{:unsupported_type, _}`, and does so
   in preference to a simultaneously-invalid target (the check order).
5. A `delay`-bearing `<send>` with an invalid target rejects identically -
   no `Effect.SendDelayed` is produced (6.2.3).
6. A valid target (`nil`, `#_internal`, `#_scxml_x`, `#_someinvoke`) still
   produces its effect - the check rejects nothing it should not.

**File**: `test/statifier/interpreter/content_test.exs`
**Changes**: a test that a block whose first node is a rejecting `<send>`
and whose second node is an `<assign>` runs only the first: the `<assign>`'s
datamodel write is absent, one `error.execution` is on the internal queue,
its `sendid` equals the minted id, and `Trace.ContentExecuted`'s
`c_indexes` is the one-node prefix. This is test159's mechanism at the unit
level and is the phase's real proof.

**File**: `test/statifier/session/send_cancel_test.exs:194-228`
**Changes**: the `assert_receive {:statifier, ^session_id, {:effect, {:send,
%Effect.Send{event: "e", target: "whatever"}}}}` becomes a `refute_receive`
of any `{:send, %Effect.Send{}}` (ADR-0036's discard, now reached for an
invalid target too), with the configuration assertion on `caught` unchanged.
Re-point the describe comment and the sabotage note at
`Send.execute/2`'s `reject_reason/2`.

**File**: `test/statifier/session_test.exs:996-1026`
**Changes**: assertions unchanged - they are the end-to-end guard that an
unsupported type still schedules no timer and still yields
`_event.sendid == "send1"` - but the sabotage note must name the core clause
that now decides it rather than `plan_send_delayed/3`.

Every new test asserting `lib/` behavior carries the project's sabotage
note: break the code it covers, confirm red, revert, and record the mutation
in one line above the test (`docs/testing.md`). Concretely: for the
`send_test.exs` cases, invert `reject_reason/2`'s `cond` so it returns `nil`
unconditionally; for the `content_test.exs` block-abort test, change
`Send.execute/2`'s rejection arm to the two-element `{:error, reason}` form
and confirm the sendid assertion reddens, then to `{:ok, ...}` and confirm
the block-abort assertion reddens. The two corpus files are exempt
(`gate.sabotage.exempt_prefixes` in `.claude/wurk.json`).

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` is green (`mix quality --profile loop` while
      iterating; loop/`--quick`/scoped runs never satisfy this phase).
- [x] `mix gate.verify` confirms the run was full and unscoped.
- [x] `mix test test/scxml_tests/mandatory/evaluationof_executable_content/test159_test.exs --include scxml_w3`
      passes - test159 is green.
- [x] `mix test test/scxml_tests/mandatory/system_variables/test332_test.exs --include scxml_w3`
      passes - the mint-before-reject ordering holds.
- [x] `mix test.regression` is green - no ratcheted test moves.
- [x] `mix test --include scion --include scxml_w3` shows no test that
      passed before this phase failing after it (compare against a run taken
      on the phase's base commit; the ratchet only covers registered files,
      so this is the wider check).
- [x] `mix test test/statifier/interpreter/content_acceptance_test.exs`
      passes - AC3's grep still finds no `error.execution` or `Event` in
      `lib/statifier/machine/content/`.

#### Manual Verification:

- [ ] The touched functions still match the W3C clauses line for line: 4.9's
      "MUST NOT process the remaining elements of the block", 6.2.4's
      target rule, 6.2.5's type rule, and 5.10.1's unconditional `sendid`
      MUST, each read from the local spec cache rather than from memory. No
      Appendix D pseudocode is touched, so no deviation comment is owed.
- [ ] The rejection happens strictly after the mint and the `idlocation`
      write in `execute/2`'s source order, so a future reader cannot
      reorder it without noticing test332.
- [ ] `Statifier.Session.Effects`' boundary arms are still reachable and
      still correct for effects handed in through `Session.interpret/2` -
      `test/statifier/session_test.exs:1113-1140` exercises that path and
      still passes.
- [ ] No regression in delayed sends: a valid delayed send still schedules,
      and the unsupported-type delayed send still schedules nothing.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In interactive execution, pause
here for confirmation before Phase 3. In looped (`--loop`) execution, the
Automated Verification list gates advancement and the Manual items are
deferred to the end.

---

## Phase 3: Ratchet test159 and record the change

### Overview

test159 joins the regression ratchet, and the user-visible behavior change
gets its changelog fragment. No `lib/` code changes.

### Changes Required:

#### 1. The ratchet

**File**: `test/passing_tests.json`
**Changes**: written by
`mix test.baseline add test/scxml_tests/mandatory/evaluationof_executable_content/test159_test.exs`,
never by hand - the task verifies the file passes before it writes the
entry. This is purely additive (test159 is not in the registry today), so
`mix gate.check`'s shrink guard has nothing to say and no
`docs/quality-gate-changes.md` entry is owed. Do not add test496: ADR-0047
decision 6 leaves it red and outside the ratchet.

#### 2. Changelog fragment

**File**: `changelog.d/st-yizi.md`
**Changes**: warranted. `changelog.d/README.md`'s rewrite-era rule is "write
a fragment when v2 differs from v1", and its general list names "a change in
observable behavior" and "a bug fix a user could have noticed" - both apply:
a `<send>` with an unsupported `type` or an unroutable, non-`#_`-prefixed
`target` now aborts the rest of its executable-content block, where before
the block ran to completion and the error arrived afterwards. Anyone driving
the public `Statifier.Session` API over such a document sees a different
datamodel and a different event order. One `### Fixed` entry, phrased for a
library user rather than as a transcript of the refactor, mentioning that
the raised `error.execution` carries the failing send's `sendid`.

### Success Criteria:

#### Automated Verification:

- [ ] Full `mix quality` is green.
- [ ] `mix gate.verify` confirms the run was full and unscoped.
- [ ] `mix test.regression` is green *with test159 now in the registry*.
- [ ] `grep test159 test/passing_tests.json` finds the entry, and
      `grep test496 test/passing_tests.json` finds nothing.
- [ ] `mix gate.check` passes with no ledger entry - proof the
      `test/passing_tests.json` change was additive.
- [ ] `changelog.d/st-yizi.md` exists.

#### Manual Verification:

- [ ] The fragment reads as something a 1.x user upgrading would want to
      know, not as a description of where a check moved in the tree.
- [ ] `test/passing_tests.json`'s diff adds exactly one line.
- [ ] Appendix D conformance, per `.claude/wurk/plan.md`: not applicable -
      this phase touches no file under `lib/statifier/`.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
the full `mix quality` as the phase gate. In looped (`--loop`) execution,
the Automated Verification list gates advancement and the Manual items are
deferred to the end.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/machine/content/send_test.exs` - the classifier's decision
  at the protocol boundary: reason shape, counter advance, `idlocation`
  write survival, check order, delayed sends, and the negative cases (every
  valid route still dispatches).
- `test/statifier/interpreter/content_test.exs` - the block-level
  consequence: abort at the failing node, one `error.execution` with the
  right `sendid` and origin, `Trace.ContentExecuted` carrying the executed
  prefix.
- `test/statifier/send/target_test.exs` - unchanged coverage of the
  classifier itself, at its new module name.
- `test/statifier/session_test.exs`, `test/statifier/session/send_cancel_test.exs` -
  the end-to-end session view: no `Effect.Send` produced, no timer
  scheduled, `_event.sendid` populated, and the `Session.interpret/2`
  boundary arm still exercised.
- Edge cases worth naming: an author-written `id` (no counter advance, the
  author's id in `sendid`); `idlocation` pointing at a deep path; a
  `targetexpr` that fails to evaluate (ADR-0036's path, two-element error,
  no sendid - unchanged by this work); an invalid target on the *second*
  node of a block (the first node's effects survive, the third never runs).

### Manual Testing Steps:

1. Compile test159's document and drive it through `Statifier.start_session/2`;
   confirm the final configuration is `pass` and that `Var1` is `0`, not `1`.
2. Do the same for test332 and confirm `Var1 === Var2` at `pass` - the
   minted id reached both the datamodel and `_event.sendid`.
3. Drive a document with `<send target="baz"/>` followed by two more
   `<assign>`s and confirm exactly one `error.execution` is raised, that
   neither assign ran, and that a second `<onentry>` block on the same state
   still runs in full (4.9's "execution of other blocks is not affected").
4. Confirm test496 is still red and still absent from the ratchet - this
   plan does not touch it.

## Corpus/Ratchet Notes

One conformance result moves: test159 goes from red to green and enters
`test/passing_tests.json` in Phase 3 via `mix test.baseline add`. The
addition is purely additive, so `mix gate.check`'s shrink guard is not
triggered and `docs/quality-gate-changes.md` gains no entry.

No corpus regeneration is needed - `mise run corpus` is not part of this
work, and no generated corpus file is edited by hand.

test496 stays red and unratcheted by ADR-0047 decision 6. If any *other*
corpus test moves in either direction during Phase 2, that is a defect in the
change and not a ratchet update to record: the change should be visible only
to documents whose `<send>` names an invalid target or an unsupported type.

## Open Questions

Recorded rather than resolved. No human was available during planning; each
item below has a default the plan follows, and none blocks implementation.

1. **Does `supported_invoke_type?/1` belong in `Statifier.Send.Target`?**
   ADR-0047 decision 3 calls it implementation detail. **Default taken: it
   moves with the module**, on the record's own "one pure module with the
   same functions" phrasing. The alternative - leaving an
   `Statifier.Invoke.Target` behind for two functions - creates a second
   module no caller wants separately. Revisiting it later is a rename, not a
   design change.
2. **Is `{:send_rejected, send_id, reason}` the right encoding for the
   sendid-bearing channel?** ADR-0047 leaves the concrete encoding open (a
   structured reason the conversion site destructures, or an opts
   extension). **Default taken: the structured reason**, because it keeps
   the protocol's `result()` type unchanged and confines the widening to one
   clause in one private function. An opts extension would mean changing the
   protocol's return shape, which is a wider change than the record asks for.
   The contract the record actually fixes - the raised event's `sendid`
   equals the minted id - holds under either.
3. **Should the `error.execution` raised on rejection carry the failing
   target/type inside `data`?** **Default taken: yes**, as
   `{:invalid_target, target}` / `{:unsupported_type, type}`, matching how
   every other content failure carries its reason in `data`. No spec clause
   or corpus document constrains `data` here, so this is a debuggability
   choice; if a later record wants `data` blank for send rejections, it is a
   one-line change.

## References

- Source document: `docs/adr/0047-send-static-target-type-invalidity-rejects-in-the-core.md`
  (the specification for this plan)
- Research: `docs/research/260817-st-yizi-send-target-validity-block-abort-and-order.md`
- Related ADRs:
  `docs/adr/0003-pure-core-with-effects.md`,
  `docs/adr/0027-embedder-placed-session-runtime.md` (registry stays
  outside the core - untouched here),
  `docs/adr/0029-session-interpret-stays-public.md` (why the planner's arms
  stay),
  `docs/adr/0035-send-id-is-a-machinestate-counter.md` (counter semantics unchanged),
  `docs/adr/0036-send-argument-failure-discards-the-message.md` (the channel
  reused),
  `docs/adr/0038-invoke-source-resolves-at-the-session-boundary.md`
  (`Statifier.Invoke.Source`, the namespace this move mirrors),
  `docs/adr/0039-session-detected-send-failures-re-enter-the-core.md`
  (amended in part by 0047, scoped to liveness)
- Constraints: `docs/architecture.md` (executable content; the error model
  is "a separate, ADR-governed thing"), `docs/observability.md`,
  `docs/testing.md` (the sabotage rule), `changelog.d/README.md`
- Similar implementation: `lib/statifier/machine/content/send.ex:111-150`
  (ADR-0036's own discard path, the mechanism reused),
  `lib/statifier/interpreter/content.ex:232-236` (the sole conversion site)
- Bead: `st-yizi`

## Deferred Manual Verification

Manual verification items are deferred during looped (`--loop`) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The moved moduledoc still disclaims liveness in its own words.
- [ ] The diff is a rename plus prose, with no classifier clause changed.
- [ ] No Appendix D procedure was touched by the rename.

### Phase 2

- [ ] The touched code matches 4.9, 6.2.4, 6.2.5, and 5.10.1 as read from
      the local spec cache, quoting the clause rather than recalling it.
- [ ] The rejection sits strictly after the mint and the `idlocation` write.
- [ ] The `Session.interpret/2` boundary arms are still reachable and
      correct.
- [ ] Delayed sends: valid ones still schedule; unsupported-type ones still
      schedule nothing.

### Phase 3

- [ ] The changelog fragment is written for a library user.
- [ ] `test/passing_tests.json` gained exactly one line.
- [ ] Phase 2's `send.ex` comment amendment landed: the sentence above
      `execute/2` no longer claims every failure returns the two-element
      error form.
