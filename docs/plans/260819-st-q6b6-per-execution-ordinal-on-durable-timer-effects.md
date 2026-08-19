# Per-Execution Ordinal on the Durable-Timer Effects Implementation Plan

## Overview

ADR-0059 is accepted and committed on this branch (`90f0930`), and its doc half
already shipped: `docs/durable-timers.md` and the amended ADR-0054/ADR-0040
status lines describe an `ordinal` field on `%Statifier.Effect.SendDelayed{}`
and `%Statifier.Effect.Cancel{}` that `lib/` does not carry. This plan closes
that gap - the record's own Consequences make the implementing change owed on
this same branch before it merges, because `docs/durable-timers.md` must not
describe a field `lib/` lacks on `origin/main`.

The work is the field on both effect structs, a session-global `timer_counter`
on `%MachineState{}` that mints it, the two stamps, `timer_counter` joining
`Statifier.Position`'s serialized shape with a `@format_version` bump `1 -> 2`,
`ordinal` joining the `:send_delayed` and `:cancel` telemetry measurements, and
the tests for all of it.

Bead: st-q6b6 (mirrors `sob-7yx` in statifier_oban's tracker - that bead retires
its foreach workaround once this ships; per ADR-0025 it is re-read and re-noted
before anyone schedules against it, which this plan does not do).

## Current State Analysis

**The two effect structs have no disambiguator.**
`%SendDelayed{}` (`lib/statifier/effect/send_delayed.ex:25-54`) enforces
`[:event, :delay_ms, :macrostep, :microstep, :round]`; `%Cancel{}`
(`lib/statifier/effect/cancel.ex:20-30`) enforces
`[:send_id, :macrostep, :microstep, :round]`. Neither carries anything that
separates two executions of the same content node in one microstep.

**`%MachineState{}` has the precedent but not the counter.**
`invoke_counter: 0` (`lib/statifier/machine_state.ex:348`) and `send_counter: 0`
(`:349`) sit in the defstruct with no `@enforce_keys` entry, are typed at
`:421-422`, are re-set to `0` explicitly in `new/2` (`:476-477`), each have a
dedicated moduledoc section (`:128-167` for `invoke_counter`, `:169-202` for
`send_counter`), and each are bumped by a direct `%{machine_state | field: ...}`
update at exactly one private call site rather than through a setter -
`generate_send_id/2` at `lib/statifier/machine/content/send.ex:386-389` and
`generate_invoke_id/3` at `lib/statifier/interpreter.ex:1535-1538`. That is the
shape `timer_counter` copies.

**The two construction sites thread `machine_state` differently, and this is
the load-bearing detail.**

- `send.ex`: `execute/2` (`:116-152`) mints the send id, builds `new_context`
  carrying the bumped `machine_state` (`:128-133`), and hands it to
  `dispatch_or_reject/8` (`:159-207`). That function re-destructures
  `machine_state` out of `new_context` (`:180`) and calls `build_effect/6`
  (`:185`). `build_effect/6` (`:453-500`) takes `machine_state` as its sixth
  argument **read-only** and returns only the effect tuple - it produces no
  updated state. A counter bump therefore cannot live inside `build_effect/6`
  without changing its signature; the natural site is `dispatch_or_reject/8`'s
  accepted arm, mirroring `generate_send_id/2`'s existing bump-then-thread
  shape.
- `cancel.ex`: `execute/2` (`:56-72`) reads `machine_state` out of `context`
  read-only to stamp the counter triple (`:65-67`) and returns the **original,
  unmodified** `context` (`:70`). Nothing in that file writes a `MachineState`
  field today. Making it advance a counter means building a `new_context` the
  way `send.ex:128-133` does - a real change to that function's threading, not
  a one-line addition.

**`Position` serializes two different ways, and only one is versioned.**

- `to_binary/1` (`lib/statifier/position.ex:101-104`) takes
  `machine_state |> Map.from_struct() |> Map.delete(:machine)` as the payload,
  so a new struct field rides along **automatically**. `from_binary/2`
  (`:137-148`) checks `check_version/1` (`:150-152`, exact-match on
  `@format_version` at `:66`) then rebuilds with
  `struct!(MachineState, Map.put(payload, :machine, machine))`.
- `export/1`/`import/2` are the string-id migration vocabulary and are
  **unversioned**: no `check_version/1` call anywhere on that path. The
  allowlist is `@required_export_keys` (`:186-190`), the field list is built in
  `build_exported/2` (`:287-307`, `invoke_counter` at `:296`, `send_counter` at
  `:297`), shapes are checked in `check_shapes/1` (`:396-419`, the two counters
  at `:404-405`), and the struct is rebuilt in `build_machine_state/2`
  (`:474-498`, the two counters at `:483-484`).

**An existing test hard-codes the next version integer.**
`test/statifier/position_test.exs:318-331` is a sabotage-verified test asserting
that a blob whose version integer is bumped returns
`{:error, {:unsupported_format_version, 2}}`. Once `@format_version` becomes
`2`, `2` is a *valid* version and that test asserts a falsehood. It must move to
`3`. This is the single most likely way the format bump lands red.

**Telemetry has one dispatch point per effect kind.**
`core_shape/2` in `lib/statifier/session/telemetry.ex` has a `%SendDelayed{}`
clause at `:488-502` (measurements `macrostep`, `microstep`, `round`,
`delay_ms`) and a `%Cancel{}` clause at `:504-512` (measurements `macrostep`,
`microstep`, `round`). The published contract table lives in the same file's
moduledoc, rows at `:142` and `:143`. `base_metadata/3` (`:471-474`) puts the
whole struct into `metadata.effect`, so `ordinal` reaches metadata for free -
decision 6 additionally requires it in *measurements*, because it is a number.

**22 hand-written literals will stop compiling.** `ordinal` in `@enforce_keys`
breaks every literal construction. There is no test/support factory for either
struct; every occurrence is written out in the test file:

- `test/statifier/session/effects_test.exs`: `%SendDelayed{}` at `:66`, `:79`,
  `:97`, `:109`, `:121`, `:133`, `:144`, `:155`, `:166`, `:521`; `%Cancel{}` at
  `:175`, `:177`, `:474`
- `test/statifier/session/telemetry_test.exs`: `%SendDelayed{}` at `:147`,
  `:452`; `%Cancel{}` at `:159` (the `@core_fixtures` list begins at `:134`)
- `test/statifier/effect_test.exs`: `%SendDelayed{}` at `:33`, `:187`, `:190`;
  `%Cancel{}` at `:34`, `:204`, `:206`

`%Cancel{}` occurrences in `lib/statifier/lowering/builders.ex:929`,
`lib/statifier/machine/content/cancel.ex:56`, and
`test/statifier/lowering/cancel_test.exs` resolve to `Statifier.Document.Cancel`
/ `Statifier.Machine.Content.Cancel` - a different struct entirely, and out of
scope.

## Desired End State

`mix quality` is green, and:

- Both durable-timer effect structs carry `ordinal :: pos_integer()` in
  `@enforce_keys`, stamped at their existing construction sites.
- `%MachineState{}` carries `timer_counter :: non_neg_integer()`, starting at
  `0`, incremented immediately before use so the first ordinal is `1`, never
  reset, no setter, written directly at its two call sites.
- Three `<send id="x" delay="1000">` executions from one `<foreach>` body -
  identical `send_id`, `c_index`, `owner`, `macrostep`, `microstep`, `round` -
  carry ordinals `1`, `2`, `3`, so the eight-component dedup key
  `{session scope, send_id, macrostep, microstep, round, c_index, owner,
  ordinal}` is genuinely per-instance. This is the property the whole record
  exists for, and a test asserts it directly.
- A send/cancel interleave inside one `<foreach>` body draws from the same
  shared sequence, so cancel#1 and cancel#2 differ.
- `Position.format_version/0` returns `2`; `to_binary/1` writes it;
  `from_binary/2` accepts both `1` and `2`, defaulting `timer_counter: 0` on a
  version-1 blob; `export/1`/`import/2` carry `timer_counter` like
  `send_counter`.
- `[:statifier, :session, :effect, :send_delayed]` and `[..., :cancel]` carry
  `ordinal` in measurements, and the moduledoc contract table says so.
- `docs/durable-timers.md` describes nothing `lib/` does not have.

### Key Discoveries

- `build_effect/6` (`lib/statifier/machine/content/send.ex:453-500`) is
  read-only in `machine_state` and returns no state - the bump must happen in
  `dispatch_or_reject/8` (`:159-207`), not inside it.
- `cancel.ex`'s `execute/2` (`lib/statifier/machine/content/cancel.ex:56-72`)
  returns `context` unchanged today; it must start returning a rebuilt context.
- `to_binary/1`'s payload is `Map.from_struct/1`, so `timer_counter` serializes
  with no code change - the format bump is required by the *shape change*, not
  by a missing write (`lib/statifier/position.ex:101-104`).
- `struct!/2` on a version-1 payload would silently fill `timer_counter` from
  the defstruct default. The plan takes an **explicit** upgrade clause instead,
  so the version-1 path is a thing a test can name rather than an accident of
  `struct!/2`'s behavior.
- `export/1`'s vocabulary is unversioned (no `check_version/1` on that path), so
  the version-1 read rule applies to `from_binary/2` only. An old *exported map*
  missing `timer_counter` correctly fails
  `{:malformed_export, {:missing_keys, [:timer_counter]}}` - ADR-0059 decision 4
  puts the key in `@required_export_keys`, and ADR-0052 decision 6 makes that
  vocabulary the host's to migrate.
- `test/statifier/position_test.exs:318-331` hard-codes `2` as the *invalid*
  version and must move to `3`.
- ADR-0059 decision 5 forbids the field on every other effect, so an immediate
  `%Send{}` must not advance the counter - the bump is conditional on
  `delay_ms` being an integer.

## What We're NOT Doing

- **Not stamping `ordinal` on any other effect.** ADR-0059 decision 5 is
  explicit: the two durable-timer effects carry it because they are the only
  durably stored ones. An immediate `%Send{}` is delivered inside the drive that
  produced it.
- **Not touching `Machine.Identity`'s format version.** The chart did not change
  shape (ADR-0059 decision 4).
- **Not touching `Session.Recording`.** A recording stores the four replay
  inputs and re-drives the core, so `timer_counter` is recomputed, not stored
  (ADR-0034, ADR-0057, ADR-0059 decision 4).
- **Not changing the cancellation key.** `{session scope, send_id}` is untouched
  - spec 6.3's cancel-them-all semantics is exactly what it exists to express
  (ADR-0059 decision 3).
- **Not re-numbering `send_counter`** or overloading it as the ordinal
  (ADR-0059 context fact 3).
- **Not editing the ADRs or `docs/durable-timers.md`'s prose.** They landed with
  `90f0930` and are the binding decision this plan implements.
- **Not re-litigating any ADR-0059 decision.** A conflict between this plan and
  the record is a defect in this plan.
- **No repo-wide `file:line` reference sweep.** Adding lines to
  `send_delayed.ex`, `cancel.ex`, and `machine_state.ex` shifts a handful of
  citations in ADRs and `docs/durable-timers.md` by a line or two. Phase 3
  spot-checks only the citations in `docs/durable-timers.md` that name the two
  effect struct files and `machine_state.ex:349`; a general renumbering pass is
  review noise, not a fix.
- **No `statifier_oban` / `sob-7yx` work.** That is a different repo's tracker.

### Judgment calls made without a human present

These were decided by this plan rather than asked, and are flagged so
`/wurk:verify` can walk them:

1. **A rejected `<send delay="...">` does not advance `timer_counter`.**
   ADR-0059 decision 2 says the counter "advances on every construction of
   either effect"; `dispatch_or_reject/8`'s reject arm (`send.ex:200-206`)
   constructs no effect, so nothing is stamped and nothing advances. Rejection
   is itself deterministic, so replay determinism is unaffected either way; the
   no-bump reading is the one that matches the record's words. Same rule for a
   `<cancel>` whose `sendid` expression fails to resolve
   (`cancel.ex:60`'s `with` short-circuit): no effect, no bump. Phase 1 asserts
   both.
2. **The bump lives in `dispatch_or_reject/8`, not in `build_effect/6`.**
   `build_effect/6` returns no state; widening its return to
   `{effect, machine_state}` would change a function that also serves the
   immediate-send clause, which must not bump. Bumping in the caller keeps the
   conditional where `delay_ms` is already matched on.
3. **`from_binary/2` gains an explicit version-1 upgrade clause** rather than
   leaning on `struct!/2`'s defstruct default. The observable result is
   identical - `timer_counter` is not enforced and defaults to `0`, so
   `struct!/2` already fills it - so this buys readability, not behavior, and
   Phase 2 says plainly that no sabotage mutation can pin it.
4. **Phase 1 and Phase 2 stay separate, and the review finding against that was
   declined.** The plan critic flagged that Phase 1's commit momentarily
   violates ADR-0052 decision 2's shape-change-implies-version-bump invariant,
   and that the mitigation is prose ("do not open a pull request with Phase 1
   alone") rather than a mechanical block. That is accurate and is kept
   deliberately: the two phases are separately gate-verifiable, the caller of
   this plan asked for the format bump to be identifiable as *the* phase
   carrying persistence risk, and this repo's authority table already requires
   an explicit human ask before any push or pull request, so nothing can publish
   Phase 1 on its own without someone asking for it. Merging the two phases
   would trade a disclosed, bounded hazard for a phase large enough that a
   red gate inside it is hard to attribute.

## Implementation Approach

Three phases, ordered by dependency. Phase 1 must land first - the other two
consume the field it introduces. Phases 2 and 3 are independent of each other.

The phase boundary is drawn where the gate can actually adjudicate. `ordinal`
in `@enforce_keys` breaks 27 test literals the moment it is added, so the field,
the counter, both stamps, and every literal fixup are one indivisible phase -
splitting them leaves an intermediate commit that does not compile.

**Intermediate-state note for Phase 1.** Phase 1's commit changes the shape of
`to_binary/1`'s payload (a new struct field rides `Map.from_struct/1`) while
`@format_version` still reads `1`. A blob written by a Phase-1 build and read by
a pre-Phase-1 build would raise from `struct!/2` on an unknown key while both
claim version 1. This is invisible outside the branch - both are unreleased dev
builds of `2.0.0-dev` on a private per-issue branch that merges as a unit, and
ADR-0059's own Consequences make the whole implementation owed before merge - but
it makes **Phase 2 a merge blocker, not an optional follow-up**. Do not open a
pull request with Phase 1 alone.

No Appendix D procedure is touched. `send.ex` and `cancel.ex` are executable-
content modules under `lib/statifier/machine/content/`, not the interpreter's
Appendix D functions, and spec 6.2/6.3 semantics are unchanged - the ordinal is
invisible to the state chart. **There is no Appendix D deviation in this plan**,
mechanical or otherwise, so no inline `# deviation:` comment is owed anywhere.

No conformance result can move: the SCXML observable behavior of a chart is
identical before and after. `mix test.regression` runs as a stage of the full
gate and is expected to stay green untouched; `mix test.baseline add` should not
be run, and a phase that finds itself wanting to run it has changed semantics by
accident and should stop.

## Phase 1: The `ordinal` field and the `timer_counter` that mints it

### Overview

Both effect structs grow `ordinal`, `%MachineState{}` grows `timer_counter`,
the two construction sites stamp it, and every existing literal is updated. This
is the phase that makes the foreach dedup key per-instance.

### Changes Required:

#### 1. The two effect structs
**Files**: `lib/statifier/effect/send_delayed.ex`,
`lib/statifier/effect/cancel.ex`
**Changes**: add `:ordinal` to `@enforce_keys` and `defstruct`, add
`ordinal: pos_integer()` to `@type t`, and add a moduledoc paragraph citing
ADR-0059.

Field placement differs between the two, and matching
`docs/durable-timers.md`'s own struct listings is what keeps Phase 3's
doc spot-check honest: in `send_delayed.ex`, `:ordinal` goes immediately
**after `:round` and before `id_from_author?`** (which is the trailing
defaulted field at `lib/statifier/effect/send_delayed.ex:38`, and is listed
after `ordinal` at `docs/durable-timers.md:47`); in `cancel.ex`, `:ordinal` is
the **last** field (`docs/durable-timers.md:63`). Struct field order carries no
semantics in Elixir, so this is a readability constraint, not a correctness
one.

```elixir
# send_delayed.ex
@enforce_keys [:event, :delay_ms, :macrostep, :microstep, :round, :ordinal]
```

Moduledoc wording to add to both (adapt per struct):

```
`ordinal` is a per-execution sequence number minted from
`Statifier.MachineState`'s session-global `timer_counter` (ADR-0059). It is
what makes a durable host's dedup key per-instance where the counter triple
and the content position cannot - two iterations of a `<foreach>` body
execute the same content node, in the same microstep, under the same
author-written id, and only `ordinal` tells them apart. It replays
identically because the counter is pure fold state.
```

#### 2. `%MachineState{}` gains `timer_counter`
**File**: `lib/statifier/machine_state.ex`
**Changes**: `timer_counter: 0` in the defstruct beside `send_counter` (`:349`),
`timer_counter: non_neg_integer()` in `@type t` (beside `:422`),
`timer_counter: 0` in `new/2`'s literal (beside `:477`), and a moduledoc section
modeled line-for-line on the existing `## send_counter is the session-global
send_ id sequence (ADR-0035)` section (`:169-202`) - including its closing
statement that the field has no setter and is written directly at its call
sites. Heading: `## timer_counter is the session-global durable-timer ordinal
(ADR-0059)`. The section states that it advances on every `%SendDelayed{}` or
`%Cancel{}` construction, author-written id or not, inside a `<foreach>` or not;
that it is never reset; and that it is *two* call sites, not one, which is the
only way this section differs from `send_counter`'s.

#### 3. Stamp the delayed-send site
**File**: `lib/statifier/machine/content/send.ex`
**Changes**: in `dispatch_or_reject/8`'s accepted arm (`:181-193`), bump
`timer_counter` when `delay_ms` is an integer, pass the bumped `machine_state`
into `build_effect/6`, and rebuild `new_context` so the advanced counter
survives the drive. `build_effect/6`'s delayed clause (`:483-500`) reads
`ordinal: ms.timer_counter` off the already-bumped state - keeping the read
inside the clause that also reads `macrostep`/`microstep`/`round` and leaving
the immediate clause (`:466-481`) untouched, which is decision 5's requirement.

```elixir
# in dispatch_or_reject/8, accepted arm
machine_state = advance_timer_counter(machine_state, delay_ms)
new_context = %{new_context | machine_state: machine_state}
effect = build_effect(node, fields, send_id, delay_ms, owner, machine_state)
...
{:ok, new_context, datamodel_change_effects(write, node, owner, machine_state) ++ [effect]}

# increment-before-read, exactly as generate_send_id/2 does at :386-389
defp advance_timer_counter(%MachineState{timer_counter: n} = ms, delay_ms)
     when is_integer(delay_ms),
     do: %{ms | timer_counter: n + 1}

defp advance_timer_counter(%MachineState{} = ms, nil), do: ms
```

Note that `datamodel_change_effects/4` must receive the same bumped
`machine_state`; it reads only the counter triple, so the value is unaffected,
but passing the stale one would be a latent divergence.

#### 4. Stamp the cancel site
**File**: `lib/statifier/machine/content/cancel.ex`
**Changes**: `execute/2` (`:56-72`) bumps `timer_counter`, stamps
`ordinal:` on the `%Effect.Cancel{}` literal, and returns a rebuilt context
carrying the advanced counter instead of the pass-through `context` it returns
today. The bump lives inside the `with` body, after `resolve_expr/2` succeeds,
so a failed `sendid` resolution constructs nothing and advances nothing.

```elixir
with {:ok, send_id} <- resolve_expr(datamodel_context, node.sendid) do
  machine_state = %{machine_state | timer_counter: machine_state.timer_counter + 1}

  effect = %Effect.Cancel{
    send_id: send_id,
    c_index: node.c_index,
    owner: owner,
    macrostep: machine_state.macrostep,
    microstep: machine_state.microstep,
    round: machine_state.round,
    ordinal: machine_state.timer_counter
  }

  {:ok, %{context | machine_state: machine_state}, [{:cancel, effect}]}
end
```

#### 5. Update every existing literal
**Files**: `test/statifier/session/effects_test.exs` (13 literals),
`test/statifier/session/telemetry_test.exs` (3),
`test/statifier/effect_test.exs` (6)
**Changes**: add `ordinal:` with a plausible `pos_integer()` to each. Where a
fixture list distinguishes fixtures from one another, give each a distinct
ordinal rather than repeating `1` - a fixture set that all reads `ordinal: 1`
cannot catch a stamp reading the wrong field.

#### 6. New tests
**Files**: `test/statifier/machine/content/send_test.exs`,
`test/statifier/machine/content/cancel_test.exs`,
`test/statifier/machine/content/foreach_test.exs`,
`test/statifier/machine_state_acceptance_test.exs`,
`test/statifier/replay_round_trip_test.exs` - all five already exist.

Every one of these asserts `lib/` behavior and is therefore **sabotage-verified
per `.claude/wurk/implement.md`'s protocol**: break the `lib/` code it covers
with one plausible mutation, confirm it reddens for the right reason, revert,
confirm green, and write the `# sabotage: ... -> red` line directly above the
test. Budget for this inside the phase.

- `timer_counter` starts at `0` on a fresh `%MachineState{}` and on `new/2`.
- One `<send delay="1000">` yields `ordinal: 1`; a second yields `2`.
  Sabotage: start the counter at 1 / read before increment -> red.
- **The foreach test** - `<foreach>` over a three-element array whose body is
  `<send id="x" event="e" delay="1000"/>` yields three `%SendDelayed{}` sharing
  `send_id`, `c_index`, `owner`, `macrostep`, `microstep`, and `round`, with
  ordinals `1`, `2`, `3`. Assert the sharing *and* the distinctness in one
  pattern match; the sharing half is what proves the ordinal is doing work no
  other component does. Sabotage: stamp a constant `1` -> red.
- A `<foreach>` body of `<send id="x" delay="1000"/>` then `<cancel
  sendid="x"/>` over two iterations yields ordinals `1, 2, 3, 4` across the
  interleaved sends and cancels - one shared sequence, decision 2.
  Sabotage: give `cancel.ex` its own counter -> red.
- An immediate `<send>` (no `delay`) leaves `timer_counter` untouched -
  decision 5. Sabotage: drop the `delay_ms` guard on
  `advance_timer_counter/2` -> red.
- A rejected `<send delay="1000">` (unreachable route / unsupported type)
  leaves `timer_counter` untouched, and a `<cancel>` whose `sendidexpr` fails
  to evaluate leaves it untouched - the judgment call recorded above.
- Re-driving the same recorded inputs mints byte-identical ordinals, in
  `replay_round_trip_test.exs` beside the existing round-trip coverage. This is
  the replay-determinism property the whole key depends on.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (`mix quality --profile loop` between edits; a
      loop-profile green never satisfies this phase).
- [x] `mix gate.verify` exits zero, proving the run was a bare full gate and not
      profiled, scoped, `--quick`-ed, or `--skip`-ed.
- [x] `grep -c 'ordinal' lib/statifier/effect/send_delayed.ex
      lib/statifier/effect/cancel.ex` is non-zero for both, and `@enforce_keys`
      in each contains `:ordinal`.
- [x] The gate's sabotage scan reports no missing `# sabotage:` note.
- [x] `mix test.regression` (a full-gate stage) stays green with
      `test/passing_tests.json` unmodified - no conformance movement is possible
      from this change, and movement means something else broke.

#### Manual Verification:
- [ ] **Spec-conformance judgment**: no Appendix D procedure is touched, and
      spec 6.2/6.3 observable semantics are unchanged - a chart's event
      sequence, timer set, and cancellation behavior are identical before and
      after. Confirm by reading the diff of `send.ex` and `cancel.ex`: the only
      new writes are to `timer_counter` and `ordinal`.
- [ ] Each new test was genuinely sabotaged - the mutation was run, it reddened
      for the reason the note claims, and the note was not written from
      imagination.
- [ ] The `timer_counter` moduledoc section reads as a sibling of
      `send_counter`'s, not as a paraphrase of it, and correctly says *two* call
      sites.
- [ ] Every updated test literal got a meaningful ordinal, not a blanket `1`.

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving on. In looped (`--loop`)
execution, this phase's Automated Verification gates advancement automatically
via `/wurk:commit --auto`, and Manual Verification items are deferred and
surfaced once at the end. Do not open a pull request after this phase alone -
see the intermediate-state note in Implementation Approach.

---

## Phase 2: `timer_counter` serializes, and `Position` bumps to format 2

### Overview

**This is the phase with persistence-compatibility risk.** `timer_counter` joins
both of `Position`'s serialization paths, `@format_version` goes `1 -> 2`, and
`from_binary/2` learns to read a version-1 blob by defaulting `timer_counter:
0`. Without it a process-less host that resumes a persisted position with a
reset counter would mint already-used ordinals and its store would dedup live
timers against dead rows (ADR-0059 decision 4).

### Changes Required:

#### 1. Bump the format version and teach the version-1 read path
**File**: `lib/statifier/position.ex`
**Changes**: `@format_version 2` (`:66`). `check_version/1` (`:150-152`) accepts
both `1` and `2`. `from_binary/2` (`:137-148`) upgrades a version-1 payload
before `struct!/2`.

```elixir
@format_version 2

# ADR-0059: a version-1 blob predates timer_counter, so no ordinal was ever
# minted from it and 0 is the only correct value. The record blesses this
# default rather than leaving it to taste.
defp upgrade_payload(1, payload), do: Map.put_new(payload, :timer_counter, 0)
defp upgrade_payload(@format_version, payload), do: payload

defp check_version(@format_version), do: :ok
defp check_version(1), do: :ok
defp check_version(version), do: {:error, {:unsupported_format_version, version}}
```

The upgrade is deliberately explicit. `struct!/2` would fill the defstruct
default anyway, but only the explicit clause is a behavior a test can name and
a sabotage mutation can break. Keep `from_binary/2`'s documented check order -
tag, version, identity - and update its `@doc` to state that version 1 is read
with `timer_counter: 0`.

#### 2. `timer_counter` joins the export vocabulary
**File**: `lib/statifier/position.ex`
**Changes**: add `timer_counter` to `@required_export_keys` (`:186-190`), to
`build_exported/2` beside `send_counter` (`:297`), to `check_shapes/1`'s list as
`{:timer_counter, &is_integer/1}` (beside `:405`), and to
`build_machine_state/2` (beside `:484`). Carried verbatim, exactly as
`send_counter` is.

The `export/1`/`import/2` vocabulary is unversioned by design - it never calls
`check_version/1` - so there is deliberately **no** version-1 read rule here. An
exported map produced by an older build and missing the key correctly fails as
`{:malformed_export, {:missing_keys, [:timer_counter]}}`; ADR-0052 decision 6
makes migrating that host-held vocabulary the host's job, and ADR-0059 decision
4 puts the key in the allowlist without qualification.

#### 3. `docs/persistence.md`'s two-line claim about the version axis
**File**: `docs/persistence.md:43-53`
**Changes**: that passage says the format version "detects a library upgrade
that changed the blob's own shape" and that "a mismatch on either axis is a
returned error tuple." After this phase, version `1` is not a mismatch - it is
read, with `timer_counter` defaulted to `0`. Add one sentence recording that
`from_binary/2` reads version 1 as well as the current version, and why (a
version-1 blob predates the field, so `0` is the only correct value), citing
ADR-0059. This is the smallest edit that keeps the guide true; do not restructure
the section. Match the file's existing typography rather than converting it.

#### 4. Fix the version-bump test that now asserts a falsehood
**File**: `test/statifier/position_test.exs:318-331`
**Changes**: that test asserts a tampered version yields
`{:error, {:unsupported_format_version, 2}}`. `2` is now valid. Move the
tampered integer and the expectation to `3`, and update the sabotage note above
it to match the mutation actually re-run. Also update `describe
"format_version/0"` (`:360-371`) if it names the integer literally.

#### 5. New tests
**File**: `test/statifier/position_test.exs`

Sabotage-verified, same protocol as Phase 1.

- `to_binary/1` -> `from_binary/2` round trip preserves a **non-zero**
  `timer_counter`, asserted alongside the existing `invoke_counter`/
  `send_counter` assertions (`:124-125`, `:150-151`, `:188-189`, `:214-215`).
  A zero would pass under a build that dropped the field entirely.
- `export/1` -> `import/2` round trip preserves a non-zero `timer_counter`,
  beside `:420-421` and `:439-440`.
- An exported map with `timer_counter` removed fails
  `{:error, {:malformed_export, {:missing_keys, [:timer_counter]}}}`.
- An exported map with a non-integer `timer_counter` fails `check_shapes/1`.
- **The version-1 read-path proof**: hand-build a version-1 envelope -
  `:erlang.term_to_binary({:statifier_position, 1, identity, payload})` where
  `payload` is a real position's `Map.from_struct/1` with `:machine` and
  `:timer_counter` both deleted - and assert `from_binary/2` returns
  `{:ok, machine_state}` with `timer_counter: 0` and every other field intact.
  **Sabotage: delete the `check_version(1)` clause** -> red with
  `{:error, {:unsupported_format_version, 1}}`. That is the mutation to run and
  the one the note records.

  Do **not** try to sabotage this test by deleting `upgrade_payload/2`'s
  version-1 clause: `timer_counter` is not in `%MachineState{}`'s
  `@enforce_keys` and carries a defstruct default of `0`, so
  `struct!(MachineState, payload)` fills it either way and the test stays green.
  That is not a broken test - it is the honest fact that `check_version/1` is
  the load-bearing half of the version-1 path and `upgrade_payload/2` is a
  readability belt-and-braces over `struct!/2`'s existing behavior. Keeping the
  explicit clause is still right (a reader should not have to know `struct!/2`'s
  defaulting rule to see what a version-1 blob does), but the plan does not
  pretend a test can pin it.
- `Position.format_version() == 2`.
- A version-`3` and a version-`0` blob still return
  `{:error, {:unsupported_format_version, v}}`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes; `mix gate.verify` exits zero.
- [x] `mix test test/statifier/position_test.exs` is green, including the
      corrected `:318-331` test.
- [x] The version-1 read-path test exists and passes - this is what proves
      persistence compatibility, and it is the phase's single most important
      automated criterion.
- [x] `mix test.regression` green with `test/passing_tests.json` unmodified.
- [x] The gate's sabotage scan reports no missing `# sabotage:` note.

#### Manual Verification:
- [ ] **Spec-conformance judgment**: `lib/statifier/position.ex` holds no
      Appendix D procedure and this phase changes no interpreter behavior; the
      diff touches only serialization.
- [ ] Read the version-1 test's fixture by hand and confirm it is a genuine
      version-1 shape - `:timer_counter` actually absent from the payload map,
      not merely set to `0`. A fixture that sets it to `0` proves nothing.
- [ ] Confirm the `check_version(1)` sabotage was really run and reddened with
      `{:unsupported_format_version, 1}` - and that nobody "fixed" the test by
      inventing a mutation against `upgrade_payload/2`, which cannot redden.
- [ ] `docs/persistence.md:43-53` now reads correctly against a two-version
      `Position` - the added sentence says version 1 is read rather than
      refused, and the surrounding claim about identity mismatches is
      undisturbed.
- [ ] No regression for a host that never persisted anything - a session that
      never calls `to_binary/1` behaves identically.

**Implementation Note**: Same loop/full gate discipline as Phase 1. This phase
is the merge blocker referenced in Implementation Approach; the branch is not
publishable until it lands.

---

## Phase 3: `ordinal` in telemetry measurements, and the changelog fragment

### Overview

ADR-0059 decision 6 reopens ADR-0040 additively: `ordinal` is a counter, and
ADR-0040's rule puts counters in measurements. The struct already reaches
`metadata.effect` verbatim; this phase adds the measurement key and updates the
published contract table. It also carries the changelog fragment for the whole
change.

### Changes Required:

#### 1. Measurements on the two events
**File**: `lib/statifier/session/telemetry.ex`
**Changes**: `core_shape/2`'s `%SendDelayed{}` clause (`:488-502`) and
`%Cancel{}` clause (`:504-512`) each add `ordinal: <effect>.ordinal` to the
measurements map, beside the existing `macrostep`/`microstep`/`round` triple.
No metadata change is needed - `base_metadata/3` (`:471-474`) already carries
the whole struct.

#### 2. The published contract table
**File**: `lib/statifier/session/telemetry.ex` moduledoc, rows `:142` and `:143`
**Changes**: add `ordinal` to the measurements column of both rows.

```
| `[:statifier, :session, :effect, :send_delayed]` | `macrostep`, `microstep`, `round`, `delay_ms`, `ordinal` | ... |
| `[:statifier, :session, :effect, :cancel]` | `macrostep`, `microstep`, `round`, `ordinal` | ... |
```

#### 3. Changelog fragment
**File**: `changelog.d/st-q6b6.md` (new)
**Changes**: `.claude/wurk/commit.md` narrows the fragment test while v2 is
unreleased to "write one when v2 differs from v1", and this clears it: the
public effect vocabulary gains a field, a published telemetry event's
measurements gain a key, and `Position`'s format version moves - all things a
caller of the public API can observe, and none of them re-implementations of
something v1 did. `changelog.d/st-1xwh.md` and `changelog.d/st-oef3.md` are the
precedent for an effect-vocabulary addition earning a fragment. One `### Added`
section covering the field, the counter, the eight-component key, and the
format bump.

#### 4. New tests
**File**: `test/statifier/session/telemetry_test.exs`

Sabotage-verified, same protocol.

**Not in the `@core_fixtures` loop.** That table's loop (`:432-441`) asserts a
*uniform* `(macrostep, microstep, round, session_id)` shape across every core
effect, and `ordinal` exists on only two of them - the same reason the
`:datamodel_change`/`:datamodel_init` tags are held out of that table, stated in
the comment at `:700-703`. Add the assertions to per-effect tests instead:

- Extend the existing `test "puts delay_ms in measurements and
  send_id/target in metadata for :send_delayed"` (`:447-471`) with
  `assert measurements.ordinal == <fixture value>`, and update its `# sabotage:`
  note to name a mutation covering the new assertion. Sabotage: drop `ordinal`
  from `core_shape/2`'s `SendDelayed` clause -> red.
- Add a **new** dedicated `:cancel` test - `%Cancel{}` appears in this file only
  inside `@core_fixtures` (`:159`) today, so there is no per-effect cancel test
  to extend. Sabotage: drop `ordinal` from the `Cancel` clause -> red.
- Both fixtures use an `ordinal` that is not `1` and not equal to any other
  measurement in the map, so a stamp accidentally reading `round` reddens.

#### 5. Documentation reference spot-check
**Files**: `docs/durable-timers.md`
**Changes**: only where a `file:line` citation this branch's own edits made
wrong. Specifically the citations naming `lib/statifier/effect/cancel.ex:20-30`
(`:67`), `lib/statifier/effect/send_delayed.ex:33-34` and `:11-13`, and
`lib/statifier/machine_state.ex:349`. Correct the numbers; change no prose. If a
citation is still accurate, leave it - a needless renumbering is review noise.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes; `mix gate.verify` exits zero.
- [x] `mix test test/statifier/session/telemetry_test.exs` green.
- [x] `changelog.d/st-q6b6.md` exists and is a valid Keep a Changelog section.
- [x] `grep -n 'ordinal' lib/statifier/session/telemetry.ex` shows both
      `core_shape/2` clauses and both moduledoc table rows.
- [x] `mix quality --profile merge` is green before any push - it re-enables the
      ADR judge stage that the bare gate disables in `.quality.exs:23`, and this
      branch carries an ADR the judge should see.
- [x] The gate's sabotage scan reports no missing `# sabotage:` note.

#### Manual Verification:
- [ ] **Spec-conformance judgment**: `telemetry.ex` sits on the session side of
      ADR-0003's effect boundary and holds no Appendix D procedure; this phase
      changes no interpreter behavior.
- [ ] The moduledoc contract table matches what `core_shape/2` actually emits,
      key for key, for both rows - the table is the published contract and a
      drift between it and the code is the defect ADR-0040 exists to prevent.
- [ ] Read `docs/durable-timers.md` end to end against the finished `lib/` and
      confirm it describes nothing the code lacks. ADR-0059's Consequences make
      this the condition for merging the branch.
- [ ] Confirm the changelog fragment reads as a migration note for a 1.x user,
      not a transcript of the rewrite (`changelog.d/README.md`).

**Implementation Note**: Same loop/full gate discipline. This is the last phase;
after it, the branch satisfies ADR-0059's Consequences and is publishable.

---

## Testing Strategy

### Unit Tests:

- **Counter mechanics** (`test/statifier/machine_state_acceptance_test.exs`):
  `timer_counter` starts at `0`, is never reset, and is monotone across a drive.
- **The stamp** (`test/statifier/machine/content/send_test.exs` and the cancel
  content test): first ordinal is `1`; an immediate send does not advance; a
  rejected delayed send does not advance; a failed `sendidexpr` does not
  advance; sends and cancels share one sequence.
- **The reason the record exists** (foreach): three iterations of one
  `<send id="x" delay>` share every other key component and differ only in
  `ordinal`. Interleaved send/cancel iterations produce `1, 2, 3, 4`.
- **Replay determinism** (`test/statifier/replay_round_trip_test.exs`):
  re-driving the same recorded inputs mints byte-identical ordinals. This is the
  property that makes the dedup key sound; without it the field is worse than
  useless.
- **Serialization** (`test/statifier/position_test.exs`): non-zero
  `timer_counter` survives both round trips; a version-1 blob reads as
  `timer_counter: 0`; the allowlist and shape checks reject a malformed export;
  `format_version/0` is `2`; versions `0` and `3` are refused.
- **Telemetry** (`test/statifier/session/telemetry_test.exs`): `ordinal` in the
  measurements of both events, with a fixture value distinct from every other
  measurement.

Key edge cases: a `<foreach>` over an empty array (no effects, no advance); a
`<cancel>` for a `send_id` that was never scheduled (still constructs an effect,
so it still advances - the no-match is the *host's* no-op, not the core's); a
delayed send inside a nested `<foreach>`; a chart that mixes author-written and
generated ids in one microstep (the ordinal sequence is unaffected by which,
which is the point of not reusing `send_counter`).

Every test above asserts `lib/` behavior and carries a `# sabotage:` note
recording a mutation that was actually run. The only exemptions in this plan
would be a pure fixture-loading helper, and it would state
`# sabotage: n/a - ...` explicitly rather than omit the line.

### Manual Testing Steps:

1. Compile a chart with a `<foreach>` over `[1, 2, 3]` whose body is
   `<send id="x" event="tick" delay="5s"/>`, drive it, and inspect the three
   `%SendDelayed{}` effects by eye: identical `send_id`, `c_index`, `owner`,
   `macrostep`, `microstep`, `round`; ordinals `1`, `2`, `3`. Build the eight
   component key from each by hand and confirm the three are distinct - this is
   the exact failure ADR-0059 exists to fix, checked the way a host would.
2. Add `<cancel sendid="x"/>` after the send inside the same body and confirm
   the four effects carry `1, 2, 3, 4` across both kinds.
3. Attach a `:telemetry` handler to `[:statifier, :session, :effect,
   :send_delayed]` and `[..., :cancel]`, run the same chart, and confirm
   `ordinal` arrives in measurements *and* on `metadata.effect`.
4. `Position.to_binary/1` a position with a non-zero `timer_counter`, restart
   the VM, `from_binary/2` it back, and confirm the counter resumed - then
   schedule one more delayed send and confirm its ordinal continues the sequence
   rather than restarting at `1`.
5. Against a checkout of the pre-branch build, write a position blob; against
   this branch, read it, and confirm it decodes with `timer_counter: 0` rather
   than erroring. This is the version-1 compatibility check done by hand rather
   than by fixture.

## References

- Bead: `st-q6b6` (mirrors `sob-7yx`)
- Binding decision: `docs/adr/0059-per-execution-ordinal-on-durable-timer-effects.md`
  (committed on this branch as `90f0930`)
- Amended by 0059: `docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md`
  (decision 3's dedup key), `docs/adr/0040-session-telemetry-event-contract.md`
  (the two events' measurements)
- Format-version mechanism: `docs/adr/0052-chart-identity-and-position-serialization.md`
  decisions 2, 6, 7
- Recording scope: `docs/adr/0057-recording-identity-and-serialization.md`,
  `docs/adr/0034-*` (replay inputs)
- Counter precedent: `docs/adr/0035-*` (`send_counter` as pure fold state),
  `docs/adr/0046-*` (`round` on every core effect; the reopening precedent)
- Host-facing guide: `docs/durable-timers.md` (the eight-component key table at
  `:243`, the `ordinal` explanation at `:263-283`)
- Construction sites: `lib/statifier/machine/content/send.ex:159-207` and
  `:453-500`; `lib/statifier/machine/content/cancel.ex:56-72`
- Counter precedent in code: `lib/statifier/machine_state.ex:169-202` and
  `:337-360`; `lib/statifier/machine/content/send.ex:386-389`
- Serialization: `lib/statifier/position.ex:66`, `:101-104`, `:137-152`,
  `:186-190`, `:287-307`, `:396-419`, `:474-498`
- Telemetry: `lib/statifier/session/telemetry.ex:142-143`, `:471-474`,
  `:488-512`
- Cross-repo rules: `docs/adr/0025-cross-repo-tracker-authority-and-mirrors.md`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] **Spec-conformance judgment**: no Appendix D procedure is touched, and
      spec 6.2/6.3 observable semantics are unchanged - a chart's event
      sequence, timer set, and cancellation behavior are identical before and
      after. Confirm by reading the diff of `send.ex` and `cancel.ex`: the only
      new writes are to `timer_counter` and `ordinal`.
- [ ] Each new test was genuinely sabotaged - the mutation was run, it reddened
      for the reason the note claims, and the note was not written from
      imagination.
- [ ] The `timer_counter` moduledoc section reads as a sibling of
      `send_counter`'s, not as a paraphrase of it, and correctly says *two* call
      sites.
- [ ] Every updated test literal got a meaningful ordinal, not a blanket `1`.

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving on. In looped (`--loop`)
execution, this phase's Automated Verification gates advancement automatically
via `/wurk:commit --auto`, and Manual Verification items are deferred and
surfaced once at the end. Do not open a pull request after this phase alone -
see the intermediate-state note in Implementation Approach.

---

### Phase 2

- [ ] **Spec-conformance judgment**: `lib/statifier/position.ex` holds no
      Appendix D procedure and this phase changes no interpreter behavior; the
      diff touches only serialization.
- [ ] Read the version-1 test's fixture by hand and confirm it is a genuine
      version-1 shape - `:timer_counter` actually absent from the payload map,
      not merely set to `0`. A fixture that sets it to `0` proves nothing.
- [ ] Confirm the `check_version(1)` sabotage was really run and reddened with
      `{:unsupported_format_version, 1}` - and that nobody "fixed" the test by
      inventing a mutation against `upgrade_payload/2`, which cannot redden.
- [ ] `docs/persistence.md:43-53` now reads correctly against a two-version
      `Position` - the added sentence says version 1 is read rather than
      refused, and the surrounding claim about identity mismatches is
      undisturbed.
- [ ] No regression for a host that never persisted anything - a session that
      never calls `to_binary/1` behaves identically.

**Implementation Note**: Same loop/full gate discipline as Phase 1. This phase
is the merge blocker referenced in Implementation Approach; the branch is not
publishable until it lands.

---

### Phase 3

- [ ] **Spec-conformance judgment**: `telemetry.ex` sits on the session side of
      ADR-0003's effect boundary and holds no Appendix D procedure; this phase
      changes no interpreter behavior.
- [ ] The moduledoc contract table matches what `core_shape/2` actually emits,
      key for key, for both rows - the table is the published contract and a
      drift between it and the code is the defect ADR-0040 exists to prevent.
- [ ] Read `docs/durable-timers.md` end to end against the finished `lib/` and
      confirm it describes nothing the code lacks. ADR-0059's Consequences make
      this the condition for merging the branch.
- [ ] Confirm the changelog fragment reads as a migration note for a 1.x user,
      not a transcript of the rewrite (`changelog.d/README.md`).

**Implementation Note**: Same loop/full gate discipline. This is the last phase;
after it, the branch satisfies ADR-0059's Consequences and is publishable.

---
