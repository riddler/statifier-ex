# `round` on Every Core Effect Implementation Plan

## Overview

ADR-0045 withdraws ADR-0020's core-effect exemption: every effect in the
vocabulary, core and trace, carries `macrostep`/`microstep`/`round`. This plan
implements it - the ten core payloads that lack `round` gain an enforced field
stamped from `%Statifier.MachineState{}` at their existing construction sites,
`Statifier.Session.Telemetry` carries `round` in every core-effect event's
measurements, the exemption prose disappears from three moduledocs and
`docs/observability.md`, and the ADR-0044 delivery-order harness stops
splitting its stream into "carries `round`" and "does not". Bead: st-xb2b.

## Current State Analysis

`%Statifier.MachineState{}` has carried three counters since ADR-0020
(`lib/statifier/machine_state.ex:352`, `:451`, `begin_macrostep/1` at `:679`).
Only eleven of the twenty vocabulary members stamp all three: the nine
`Statifier.Effect.Trace.*` payloads (through each module's `new/2`, driven by
`Effect.trace/3` at `lib/statifier/effect.ex:170-180`) and
`%Statifier.Effect.BudgetExhausted{}`
(`lib/statifier/effect/budget_exhausted.ex:30-38`). `%Statifier.Event.Cause{}`
carries it too (`lib/statifier/event/cause.ex:162`).

The other ten core payloads carry only `macrostep`/`microstep`:

| Payload | Module | `@enforce_keys` today |
|---|---|---|
| `Send` | `lib/statifier/effect/send.ex:48` | `[:event, :macrostep, :microstep]` |
| `SendDelayed` | `lib/statifier/effect/send_delayed.ex:25` | `[:event, :delay_ms, :macrostep, :microstep]` |
| `Cancel` | `lib/statifier/effect/cancel.ex:20` | `[:send_id, :macrostep, :microstep]` |
| `Invoke` | `lib/statifier/effect/invoke.ex:46` | `[:invoke_id, :state_index, :invoke_index, :macrostep, :microstep]` |
| `CancelInvoke` | `lib/statifier/effect/cancel_invoke.ex:36` | `[:invoke_id, :state_index, :macrostep, :microstep]` |
| `Autoforward` | `lib/statifier/effect/autoforward.ex:41` | `[:invoke_id, :state_index, :event, :macrostep, :microstep]` |
| `Done` | `lib/statifier/effect/done.ex:21` | `[:configuration, :macrostep, :microstep]` |
| `Log` | `lib/statifier/effect/log.ex:23` | `[:macrostep, :microstep]` |
| `DatamodelChange` | `lib/statifier/effect/datamodel_change.ex:44` | `[:location_path, :location_source, :new_value, :prior_value, :macrostep, :microstep]` |
| `DatamodelInit` | `lib/statifier/effect/datamodel_init.ex:37` | `[:datamodel, :macrostep, :microstep]` |

The construction sites, re-derived from the codebase rather than taken from
ADR-0045's itemization (the record said "~13"; the verified count is **13**,
in eight files):

| # | Site | Payload | Counter source in scope |
|---|---|---|---|
| 1 | `lib/statifier/interpreter.ex:672-678` (`autoforward_effect/5`) | `Autoforward` | `machine_state` |
| 2 | `lib/statifier/interpreter.ex:798-807` (`write_finalize_target/6`) | `DatamodelChange` | `machine_state` |
| 3 | `lib/statifier/interpreter.ex:1362-1373` (`invoke_one/6`) | `Invoke` | `machine_state` |
| 4 | `lib/statifier/interpreter.ex:1532-1541` (`datamodel_change_effects/5`) | `DatamodelChange` | `machine_state` |
| 5 | `lib/statifier/interpreter.ex:1676-1681` (`exit_interpreter/1`) | `Done` | `machine_state` (the fold's rebound accumulator) |
| 6 | `lib/statifier/interpreter/datamodel.ex:293-297` (`initialize/1`) | `DatamodelInit` | `machine_state` |
| 7 | `lib/statifier/interpreter/datamodel.ex:402-412` (`bind_value/4`) | `DatamodelChange` | `machine_state` |
| 8 | `lib/statifier/interpreter/exit_entry.ex:307-312` (`cancel_one_invocation/4`) | `CancelInvoke` | `machine_state` |
| 9 | `lib/statifier/machine/content/log.ex:54-61` (`Log.execute/2`) | `Log` | `context.machine_state` (ADR-0028 threaded context) |
| 10 | `lib/statifier/machine/content/send.ex:304-313` (`datamodel_change_effects/4`) | `DatamodelChange` | `ms` |
| 11 | `lib/statifier/machine/content/send.ex:339-350` (`build_effect/6`, no delay) | `Send` | `ms` |
| 12 | `lib/statifier/machine/content/send.ex:356-368` (`build_effect/6`, delayed) | `SendDelayed` | `ms` |
| 13 | `lib/statifier/machine/content/assign.ex:97-105` (`Assign.execute/2`) | `DatamodelChange` | `machine_state` |
| 14 | `lib/statifier/machine/content/cancel.ex:64-69` (`Cancel.execute/2`) | `Cancel` | `machine_state` |

That is fourteen rows, not thirteen: ADR-0045's estimate undercounted by one
(`machine/content/send.ex` has three sites, not two - a `DatamodelChange` for
`<send idlocation>` plus the two `build_effect/6` clauses). **Every one has a
`%MachineState{}` in scope already**, so all fourteen edits are the single
line `round: <ms>.round` appended to the existing counter pair. There is no
site where the stamp is non-mechanical.

Two seams that could have been non-mechanical, checked and found not to be:

- **`Statifier.Replay`** (`lib/statifier/replay.ex`) constructs no effect
  payload at all - it drives the pure core and re-derives effects through the
  interpreter, so the stamp arrives for free and the ADR-0034 round-trip
  stream equality is preserved by construction. This is exactly why ADR-0045
  rejected the session-side-wrapper alternative.
- **`Statifier.Session`** constructs no core effect either. Its only counter
  read is `build_status/1` (`lib/statifier/session.ex:1501-1510`), which
  already reports all three from `machine_state` and needs no change.

The one genuinely caller-supplied case is `Statifier.Session.interpret/2`:
effects handed in from outside have no `%MachineState{}` behind them, so the
caller stamps `round` itself. `@enforce_keys` makes that a compile error for
callers rather than a silent `nil` - which is the desired API-change signal,
and is the reason this needs a changelog fragment.

`Statifier.Session.Telemetry` reads the counters off the payload, not off a
machine state: eleven `core_shape/2` clauses at
`lib/statifier/session/telemetry.ex:476-583`, of which ten build
`%{macrostep: _, microstep: _}` and only the `BudgetExhausted` clause
(`:536-543`) carries `round`. The `@moduledoc` contract table at `:139-151` is
the authoritative published copy of those measurements. `counters/1`
(`:623-625`) already destructures all three and serves the trace family; the
core family cannot simply reuse it, because six of the eleven core clauses add
a payload-specific measurement (`delay_ms`, `budget`) or none at all.

The prose that has to change:

- `lib/statifier/effect/autoforward.ex:32-36` and
  `lib/statifier/effect/cancel_invoke.ex:28-33` - two `## No round field`
  sections asserting "No core effect carries `round` - only the seven trace
  payloads do" (already wrong on the count: there are nine trace payloads).
- `lib/statifier/effect.ex:53-64` - the `## Trace effects carry indexes and
  counters` section, whose framing is what those two sections cite.
- `lib/statifier/effect/budget_exhausted.ex:19-23` - `round`'s
  "carried by the stamp" framing, written when this payload was the
  single exception.
- `docs/observability.md:96-99` - constraint 2's "`round` is carried by the
  `Trace.*` payloads and by `BudgetExhausted` today and by no other effect, so
  a mixed stream cannot be sorted back into this order once its arrival order
  is lost".
- `test/support/stream_order.ex:6-15` - the same claim, load-bearing on the
  harness's behavior rather than just its prose: `counters/1` (`:99-101`) has
  a two-clause fallback and `assert_monotone/1` (`:56-74`) runs two separate
  monotonicity checks because part of the stream had no `round`.

## Desired End State

Every `Statifier.Effect.*` payload struct has `round` in its `defstruct`,
`@enforce_keys`, and `@type t`. Every one of the fourteen construction sites
stamps it from the machine state in scope. Every
`[:statifier, :session, :effect, kind]` telemetry event carries `round` in its
measurements, and `Statifier.Session.Telemetry`'s contract table says so. No
file in `lib/`, `docs/`, or `test/support/` claims an effect exists that does
not carry `round`. `Statifier.StreamOrder.assert_monotone/1` checks
`(macrostep, round)` over the whole counter-bearing stream with no second-tier
`macrostep`-only pass.

Verified by: a full `mix quality` green; a grep for the withdrawn claim
(`No core effect carries`, `by no other effect`) returning nothing outside
`docs/adr/` and `docs/research/`; and the strengthened `StreamOrder` assertion
passing across the existing ADR-0044 delivery-order suite.

### Key Discoveries:

- ADR-0045 (`docs/adr/0045-round-on-every-core-effect.md`) is the
  specification; its Decision section fixes the stamp semantics
  (`round: 0` for anything emitted before the fold begins, per ADR-0020's
  counter contract) and its Consequences section itemizes the work.
- ADR-0020's and ADR-0040's status lines **already** carry the partial-amendment
  notes - they landed with the record in `9ab61fb`
  (`docs/adr/0020-round-ordinal-joins-the-step-counters.md:3-5`,
  `docs/adr/0040-session-telemetry-event-contract.md`). Nothing in `docs/adr/`
  needs editing in this plan.
- `@enforce_keys` turns the change inventory into a compile-error list: once
  `:round` joins a payload's enforce list, `mix compile` names every
  construction site in `lib/` and every literal build in `test/` that has not
  been updated. The implementer does not have to find them by grep; the tables
  above are the expected answer to check the compiler's list against.
- All fourteen `lib/` sites already have a `%MachineState{}` bound. The content
  executors get theirs off ADR-0028's threaded `Predicator.Context`
  (`context.machine_state`), which is why `<log>`, `<send>`, `<assign>`, and
  `<cancel>` are no harder than the interpreter sites.
- `Statifier.Replay` re-derives effects from the core (ADR-0034), so replayed
  streams get the stamp identically to live ones and the round-trip stream
  equality holds without any replay-side change. The round-trip test's own
  `interpret/2`-injected literals are the exception, and they are test data the
  test author stamps.
- The trace family stamps through `Trace.*.new/2` so no call site repeats the
  counters (`lib/statifier/effect.ex:99-102`). The core family has no such
  constructor, and this plan does not introduce one - see What We're NOT Doing.
- `docs/observability.md` constraint 4 already calls `(macrostep, round)` "the
  ordering key for any timeline UI or log merge" (`:143-146`); constraint 2 is
  the only place that still says the key is unavailable on part of the stream.

## What We're NOT Doing

- **Not introducing a `new/2` constructor for the core payloads.** The trace
  family has one because `Effect.trace/3` needs a uniform entry point behind
  the emission gate; the core family is built inline at fourteen sites with
  payload-specific field sets and no gate. Adding constructors would be a
  refactor of ADR-0003's vocabulary shape, not this bead, and ADR-0045 asks for
  the field "stamped from `%MachineState{}` at their existing construction
  sites exactly as `macrostep`/`microstep` are stamped today".
- **Not adding `round` to `[:statifier, :session, :unroutable]`.** ADR-0045
  amends ADR-0040's *core-effect* measurements line and names
  `[:statifier, :session, :effect, kind]` specifically; `:unroutable` is a
  routing failure the session detected, with its own contract row
  (`lib/statifier/session/telemetry.ex:122-127`). Widening a second event's
  measurements is a contract change ADR-0045 did not decide. Recorded as open
  question 1 below.
- **Not touching `docs/adr/`.** The amendment notes on ADR-0020 and ADR-0040
  landed with ADR-0045 itself, and ADR-0045 is explicit that the amended
  records' body text stands as written.
- **Not changing `%Statifier.Event.Cause{}`, the counter definitions, the
  reset points, or `begin_round/1`.** ADR-0045 leaves all of ADR-0020's
  mechanism untouched.
- **Not attempting within-round interleave across separately recorded logs.**
  ADR-0045's "What this record does not promise" section: `(macrostep, round)`
  places an effect between rounds, and finer ordering across two channels is
  out of scope by decision, not by omission.
- **Not correcting `lib/statifier/effect.ex:47-51`'s "`:send`, `:send_delayed`,
  and `:cancel` remain unproduced" sentence**, which is stale (they are
  produced by `Statifier.Machine.Content.{Send,Cancel}` today). It is a
  pre-existing inaccuracy unrelated to `round`; fixing it here would put an
  unrelated change in the tree, which this repo's commit trigger forbids. File
  it separately.

## Implementation Approach

Split by payload family along the pipeline's module boundaries, so each phase
compiles, gates, and commits on its own. `@enforce_keys` is what forces a
payload's struct change, its `lib/` construction sites, and its `test/` literal
builds into the same commit - splitting those apart would leave an
intermediate red gate, which is exactly the case the phase-sizing rule says to
combine. Splitting *between* payload families is free, because the ten payloads
are independent structs.

Phases 1-3 each take one family end to end: struct fields, construction sites,
that family's `core_shape/2` telemetry clauses, that family's rows in the
telemetry contract table, and the test literals that build those payloads.
Phase 4 retires the exemption prose once all ten payloads actually carry the
field, so no phase ever commits a doc claim that is false at that commit.
Phase 5 collects the payoff: the ADR-0044 harness stops needing its two-tier
split.

This is not interpreter-algorithm work: no Appendix D procedure changes
behavior, no selection or entry/exit set is computed differently, and no
pseudocode line is deviated from. The `.claude/wurk/plan.md` Appendix D rule is
therefore satisfied vacuously - **there is no deviation to declare** - and the
per-phase spec-conformance manual criterion below is a check that the touched
functions still match their pseudocode after the edit, not a claim that any of
them moved.

---

## Phase 1: The interpreter-emitted family

### Overview

`Invoke`, `CancelInvoke`, `Autoforward`, and `Done` - the four payloads
`Statifier.Interpreter` and `Statifier.Interpreter.ExitEntry` build directly.
Includes deleting the two `## No round field` moduledoc sections, since they
sit on two of these four payloads and would be self-contradictory the moment
the field lands.

### Changes Required:

#### 1. Payload modules

**Files**: `lib/statifier/effect/invoke.ex`, `cancel_invoke.ex`,
`autoforward.ex`, `done.ex`
**Changes**: add `:round` to `@enforce_keys` and `defstruct`, add
`round: non_neg_integer()` to `@type t`, and update the moduledoc's counter
sentence from "`macrostep`/`microstep` are the counters ..." to name all
three. Delete `autoforward.ex:32-36` and `cancel_invoke.ex:28-33` (the
`## No round field` sections) outright.

```elixir
@enforce_keys [:invoke_id, :state_index, :macrostep, :microstep, :round]
defstruct [:invoke_id, :state_index, :macrostep, :microstep, :round]

@type t :: %__MODULE__{
        invoke_id: String.t(),
        state_index: non_neg_integer(),
        macrostep: non_neg_integer(),
        microstep: non_neg_integer(),
        round: non_neg_integer()
      }
```

#### 2. Construction sites

**Files**: `lib/statifier/interpreter.ex` (sites 1, 3, 5 of the table above),
`lib/statifier/interpreter/exit_entry.ex` (site 8)
**Changes**: one line each, directly under `microstep:`.

```elixir
macrostep: machine_state.macrostep,
microstep: machine_state.microstep,
round: machine_state.round
```

At `exit_interpreter/1` (`interpreter.ex:1676`), `machine_state` is the
accumulator the exit fold rebound at `:1646`, which is the state as it stands
at termination - the same binding `macrostep`/`microstep` already read from,
so `round` is consistent with them by construction and no re-binding is needed.

#### 3. Telemetry

**File**: `lib/statifier/session/telemetry.ex`
**Changes**: add `round: <payload>.round` to the measurements map in the
`Invoke` (`:508`), `CancelInvoke` (`:518`), `Autoforward` (`:527`), and `Done`
(`:545`) clauses of `core_shape/2`; update those four rows of the
`## Core effect events` contract table - `:144`, `:145`, `:146`, and `:148`
individually - to read `macrostep`, `microstep`, `round`. **Leave `:147`
(`:budget_exhausted`) alone**: it sits inside that span and already reads
`macrostep`, `microstep`, `round`, `budget`.

#### 4. Tests

**Files**: `test/statifier/effect_test.exs` (the `@core_effects` table),
`test/statifier/machine_state_acceptance_test.exs` (its `@core_effects`
table), `test/statifier/replay_test.exs`,
`test/statifier/replay_round_trip_test.exs`,
`test/statifier/session_test.exs`, plus any further literal build the compiler
names.
**Changes**: add `round: <n>` to every literal build of these four payloads.
Then add one new behavior assertion per payload family member group - the
cheapest honest shape is a single test per emitting function asserting the
emitted payload's `round` equals the machine state's, e.g. in
`test/statifier/interpreter/cancel_invoke_test.exs` and
`test/statifier/interpreter/termination_test.exs`.

Every new or changed `lib/`-asserting test carries a verified `# sabotage:`
line per `docs/testing.md` and `.claude/wurk/implement.md` - for these,
"`cancel_one_invocation/4` stamps `round: 0` instead of
`machine_state.round` -> red". Purely mechanical additions of `round: 0` to an
existing fixture table do not change what the test asserts and need no new
sabotage line.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` green between edits (not a phase gate on its own)
- [x] Full `mix quality` passes, verified with `mix gate.verify`
- [x] `grep -rn "No core effect carries" lib/` returns nothing
- [x] `mix test test/statifier/replay_round_trip_test.exs` passes - the
      ADR-0034 stream-equality obligation still holds with the new field

#### Manual Verification:
- [ ] The touched interpreter functions (`autoforward_effect/5`,
      `invoke_one/6`, `exit_interpreter/1`,
      `ExitEntry.cancel_one_invocation/4`) still match their W3C Appendix D
      pseudocode line for line - read against
      `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/appendix-d.txt`,
      not from memory
- [ ] Each new test's sabotage mutation was actually run and confirmed red,
      then reverted
- [ ] No regressions in related features

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: The content-emitted family

### Overview

`Send`, `SendDelayed`, `Cancel`, and `Log` - the four payloads
`Statifier.Machine.Content.*` executors build from ADR-0028's threaded context.

### Changes Required:

#### 1. Payload modules

**Files**: `lib/statifier/effect/send.ex`, `send_delayed.ex`, `cancel.ex`,
`log.ex`
**Changes**: `:round` into `@enforce_keys`, `defstruct`, and `@type t`;
moduledoc counter sentence names all three. Note `Send`/`SendDelayed` keep
`id_from_author?: false` as the last, defaulted `defstruct` entry - `:round`
goes before it, with the other required keys.

#### 2. Construction sites

**Files**: `lib/statifier/machine/content/log.ex:54-61`,
`send.ex:339-350` and `:356-368`, `cancel.ex:64-69`
**Changes**: `round: machine_state.round` (or `round: ms.round` in `send.ex`,
matching that file's local binding name).

#### 3. Telemetry

**File**: `lib/statifier/session/telemetry.ex`
**Changes**: `round` into the measurements of the `Send` (`:476`),
`SendDelayed` (`:487`), `Cancel` (`:498`), and `Log` (`:553`) clauses;
corresponding contract-table rows (`:141`, `:142`, `:143`, `:149`) updated.
`SendDelayed` keeps `delay_ms` as its own extra measurement.

#### 4. Tests

**Files**: `test/support/test_content.ex:70`,
`test/support/context_recorder.ex:65` and `:87`,
`test/statifier/session_test.exs` (several `%Effect.SendDelayed{}` /
`%Effect.Cancel{}` / `%Effect.CancelInvoke{}` literals),
`test/statifier/replay_test.exs`, `test/statifier/replay_round_trip_test.exs`,
`test/statifier/effect_test.exs`,
`test/statifier/machine_state_acceptance_test.exs`, plus whatever else the
compiler names.
**Changes**: `round:` on every literal build. The two `test/support/` files are
harness and carry `# sabotage: n/a - ...` exemptions already; keep them.
Add a behavior assertion that `<log>`, `<send>`, and `<cancel>` stamp the
machine state's `round` - `test/statifier/machine/content/send_test.exs` and
`cancel_test.exs` are the natural homes, each with its verified sabotage line.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality --profile loop` green between edits (not a phase gate on its own)
- [ ] Full `mix quality` passes, verified with `mix gate.verify`
- [ ] `mix test test/statifier/session_test.exs test/statifier/replay_round_trip_test.exs`
      passes - the session's timer/cancel paths and the recorded round trip
      both still round-trip with the wider structs

#### Manual Verification:
- [ ] `<send>`, `<cancel>`, and `<log>` behavior against spec 6.2/6.3/4.7 is
      unchanged - the stamp is additive and nothing reads it in the executors
- [ ] Each new test's sabotage mutation was run, confirmed red, and reverted
- [ ] No regressions in related features

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 3: The datamodel family

### Overview

`DatamodelChange` and `DatamodelInit` - two payloads with five construction
sites between them, spread across the interpreter, the datamodel module, and
two content executors. This is the family where ADR-0045's "`round: 0` before
the fold begins" clause actually bites: `Datamodel.initialize/1` runs inside
`Statifier.Interpreter.initialize/2`, before any macrostep, so its
`machine_state.round` is `0` by `MachineState.new/2`
(`lib/statifier/machine_state.ex:352`) and no special-casing is needed - the
counter contract already produces the value the ADR specifies.

### Changes Required:

#### 1. Payload modules

**Files**: `lib/statifier/effect/datamodel_change.ex`, `datamodel_init.ex`
**Changes**: `:round` into `@enforce_keys`, `defstruct`, and `@type t`;
moduledoc counter sentences updated. `DatamodelChange`'s `defstruct` order
keeps `d_index`/`c_index`/`owner` where they are and appends `:round` after
`:microstep`.

#### 2. Construction sites

**Files**: `lib/statifier/interpreter.ex:798-807` and `:1532-1541`,
`lib/statifier/interpreter/datamodel.ex:293-297` and `:402-412`,
`lib/statifier/machine/content/send.ex:304-313`,
`lib/statifier/machine/content/assign.ex:97-105`
**Changes**: `round: <ms>.round` on each.

#### 3. Telemetry

**File**: `lib/statifier/session/telemetry.ex`
**Changes**: `round` into the `DatamodelChange` (`:563`) and `DatamodelInit`
(`:580`) measurements; contract-table rows `:150` and `:151` updated. With
this phase, every row of the `## Core effect events` table reads
`macrostep`, `microstep`, `round` plus its own extras, and the
`:budget_exhausted` row is no longer distinguished by carrying `round`.

#### 4. Tests

**Files**: `test/statifier/interpreter/datamodel_test.exs`,
`test/statifier/session/datamodel_reconstruction_test.exs`,
`test/statifier/effect_test.exs`,
`test/statifier/machine_state_acceptance_test.exs`, plus compiler-named sites.
**Changes**: literal builds gain `round:`. Add one behavior test asserting
`DatamodelInit` carries `round: 0` (the pre-fold case ADR-0045 names
explicitly) and one asserting a `<data>` binding performed on state entry
carries the entering round, each with a verified sabotage line.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality --profile loop` green between edits (not a phase gate on its own)
- [ ] Full `mix quality` passes, verified with `mix gate.verify`
- [ ] `mix test test/statifier/interpreter/datamodel_test.exs test/statifier/session/datamodel_reconstruction_test.exs`
      passes - datamodel reconstruction from the effect stream alone still works
- [ ] After this phase: `grep -rn "microstep: non_neg_integer()" lib/statifier/effect/`
      shows a `round: non_neg_integer()` line following it in all eleven core
      payload modules

#### Manual Verification:
- [ ] `Datamodel.initialize/1`'s emitted `DatamodelInit` carries `round: 0`,
      confirmed by reading the value rather than assuming the default
- [ ] The spec 5.3.3 / B.2.2 binding order the datamodel module implements is
      unchanged
- [ ] Each new test's sabotage mutation was run, confirmed red, and reverted
- [ ] No regressions in related features

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 4: Retire the exemption prose

### Overview

With all ten payloads stamped, the documents that describe the exemption are
now false. This phase makes them true. It lands after phases 1-3 precisely so
that no commit in this branch ever carries a doc claim contradicted by the code
in the same tree.

### Changes Required:

#### 1. The vocabulary moduledoc

**File**: `lib/statifier/effect.ex`
**Changes**: the `## Trace effects carry indexes and counters, never structs`
section (`:53-64`) currently reads as though the counter triple is a trace-only
property, and two payload moduledocs cited it as the source of the exemption.
Rewrite its first sentence to state the vocabulary-wide rule - every effect,
core and trace, carries `macrostep`/`microstep`/`round` - while keeping the
section's actual subject (trace payloads carry constraint-3 identities, never
compiled structs) and its `round`-advances-in-anonymous-rounds paragraph, which
is still exactly right and now applies to the whole vocabulary.

#### 2. `BudgetExhausted`'s framing

**File**: `lib/statifier/effect/budget_exhausted.ex:19-23`
**Changes**: drop the "the one core effect ADR-0020 stamps with a round"
framing. Keep the substantive fact, which is unaffected: on this path `round`
always equals `budget`, which is why there is no separate `rounds_spent` field.

#### 3. `docs/observability.md` constraint 2

**File**: `docs/observability.md:96-99`
**Changes**: replace "this is a guarantee about delivery order rather than one
a consumer can re-derive: `round` is carried by the `Trace.*` payloads and by
`BudgetExhausted` today and by no other effect, so a mixed stream cannot be
sorted back into this order once its arrival order is lost (ADR-0044 decision
4)" with the new fact: every effect carries the counter triple (ADR-0045), so a
consumer holding a mixed stream whose arrival order was lost **can** sort it
back into `(macrostep, round)` order offline, including under `trace: false`.
Keep ADR-0044 decision 1's live-arrival guarantee as stated - it is a stronger
promise than re-derivability, not a substitute for it - and keep constraint 4's
existing "ordering key for any timeline UI or log merge" sentence, which this
change finally makes true across the whole stream.

#### 4. The `internal_event/1` placeholder

**File**: `lib/statifier/session/effects.ex:282`
**Changes**: `Cause.new({:content, send.c_index, send.owner}, send.macrostep,
send.microstep, 0)` becomes `..., send.round)`. The surrounding comment
(`:276-279`) already explains that this cause is a placeholder never read, so
this is consistency rather than behavior - but a hardcoded `0` sitting beside
two real counter reads now reads as an oversight, and the payload carries the
real value. Update the comment to say the placeholder is now the send's own
provenance rather than a zero. **No new test**: the comment states the field is
never read, so there is nothing observable to assert, and inventing an
assertion for it would test the test.

#### 5. Changelog fragment

**File**: `changelog.d/st-xb2b.md` (new)
**Changes**: this change *is* user-facing by `changelog.d/README.md`'s bar - a
caller of the public API can tell. Two ways: reading `round` off any effect off
the subscriber stream or out of a telemetry event's `effect` metadata, and,
more sharply, **building** a core effect to hand to
`Statifier.Session.interpret/2`, which now fails to compile without `round`.
Write the fragment naming both directions.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality --profile loop` green between edits (not a phase gate on its own)
- [ ] Full `mix quality` passes, verified with `mix gate.verify`
- [ ] `grep -rn "by no other effect\|No core effect carries\|only the seven trace payloads" lib/ docs/ test/`
      returns hits only under `docs/adr/` and `docs/research/` (historical
      records, which are never edited to match later decisions)
- [ ] `changelog.d/st-xb2b.md` exists

#### Manual Verification:
- [ ] The rewritten constraint 2 paragraph does not weaken ADR-0044 decision
      1's live-arrival guarantee while adding the offline one
- [ ] `lib/statifier/effect.ex`'s rewritten section still says what it was
      there to say about identities-not-structs
- [ ] The changelog fragment's wording matches `changelog.d/README.md`'s bar
- [ ] No regressions in related features

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 5: One-tier delivery-order assertion

### Overview

The payoff. `Statifier.StreamOrder` (`test/support/stream_order.ex`) splits the
subscriber stream in two because part of it carried no `round`; after phases
1-3 no such part exists. Collapsing the split makes the ADR-0044 delivery-order
suite strictly stronger: effects that were previously checked only for
non-decreasing `macrostep` are now checked for non-decreasing
`(macrostep, round)`.

### Changes Required:

#### 1. The harness

**File**: `test/support/stream_order.ex`
**Changes**: `counters/1` (`:98-101`) loses its `%{macrostep: macrostep}`
fallback clause and its `nil`-round return, so its spec narrows to
`{non_neg_integer(), non_neg_integer()} | nil` - `nil` now meaning only
"envelope, no counters" (`{:halted, _}` / `{:unroutable, _}`), which was
always the third clause's job. `assert_monotone/1` (`:56-74`) drops the
`rounded` filter and the second `check_non_decreasing/3` call, running one
check over `{macrostep, round}` for the whole counter-bearing stream. The
moduledoc's `:6-15` paragraph is rewritten: the two-tier split existed because
ADR-0044 decision 4 left the stamp as follow-on work, and ADR-0045 did it.

```elixir
@spec counters(message :: term()) :: {non_neg_integer(), non_neg_integer()} | nil
defp counters({:effect, {_tag, %{macrostep: macrostep, round: round}}}), do: {macrostep, round}
defp counters(_message), do: nil
```

#### 2. Confirming the assertion actually got stronger

**Changes**: this file carries `# sabotage: n/a - test plumbing` and asserts no
`lib/` behavior of its own, so it needs no sabotage line - but the *claim* that
the check is stronger does need evidence. Confirm it by mutating a core
construction site to stamp a stale round (for instance,
`machine/content/log.ex` stamping `round: 0`) and watching an existing
`StreamOrder.assert_monotone/1` caller go red where it previously passed, then
reverting. Record that one-line finding as a comment above `assert_monotone/1`.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality --profile loop` green between edits (not a phase gate on its own)
- [ ] Full `mix quality` passes, verified with `mix gate.verify`
- [ ] Every existing `StreamOrder.assert_monotone/1` caller still passes with
      the one-tier check - `grep -rln "StreamOrder" test/` names them, and the
      full suite covers them
- [ ] `grep -n "is_nil(round)\|rounded =" test/support/stream_order.ex`
      returns nothing - those are the two constructs the one-tier check
      removes, and a bare `nil` grep would not decide this, since the file
      legitimately keeps `| nil` in `counters/1`'s spec and a `nil ->` branch
      in `assert_halted_last/1`

#### Manual Verification:
- [ ] The stale-round mutation described above was run and confirmed to redden
      a test that previously passed, then reverted - this is the evidence the
      assertion strengthened rather than merely simplified
- [ ] The rewritten moduledoc states the current contract without implying the
      old two-tier behavior was wrong for its time
- [ ] No regressions in related features

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Testing Strategy

### Unit Tests:

- **Field presence, per payload.** `test/statifier/effect_test.exs`'s
  `@core_effects` and `test/statifier/machine_state_acceptance_test.exs`'s
  parallel table are the vocabulary fixtures; every entry gains `round:`. These
  are fixture-completeness tables, not behavior assertions, so they carry no
  new sabotage lines.
- **Stamp correctness, per emitting function.** The assertions worth adding are
  the ones that would catch a hardcoded `0` or a stale machine state: drive a
  chart far enough that `round` is non-zero, then assert the emitted payload's
  `round` equals the interpreter's. One per family is enough - a
  `<log>`/`<send>` case (Phase 2), a `cancel_invoke`/`done` case (Phase 1), a
  `<data>`-binding case (Phase 3). Each of these asserts `lib/` behavior and
  therefore needs a verified sabotage line naming the mutation that reddens it.
- **The `round: 0` pre-fold case.** `DatamodelInit` and the effects
  `initialize/2` performs directly are ADR-0045's named boundary; assert the
  value rather than trusting the default (Phase 3).
- **Telemetry measurements.** `test/statifier/session/telemetry_test.exs`
  already has the pattern at `:440-460` (the `BudgetExhausted` `round`
  assertion, with its sabotage line). Extend the existing per-kind measurement
  assertions rather than adding an eleventh near-duplicate test.
- **Edge cases worth naming:** an effect emitted during `exit_interpreter/1`,
  which runs after the event loop has stopped, and effects emitted from an
  ADR-0039 re-entry, where `round` advanced but `macrostep` did not - the
  second is the case the whole field exists for and is already covered by the
  delivery-order suite once Phase 5 lands.

### Manual Testing Steps:

1. Start a session with `trace: false` on a chart that logs and assigns, drain
   the subscriber stream, and confirm every delivered effect carries a
   `round` - this is the `trace: false` configuration ADR-0045's Context names
   as the one the trace-join recipe could not serve.
2. Record a run (`record: true`), replay it with `Statifier.Replay`, and
   compare the two effect streams field for field, including `round`. Equality
   here is ADR-0034's obligation and the reason ADR-0045 put the stamp in the
   core rather than in the session.
3. On a chart with an ADR-0039 mid-macrostep re-entry, confirm the re-entered
   effects carry a higher `round` than the outer batch's tail at the same
   `macrostep` - the ordering the field was added to express.
4. Attach a `:telemetry` handler to `[:statifier, :session, :effect, :log]` and
   confirm `measurements.round` is present and matches the payload.

## Corpus/Ratchet Notes

No conformance results move. This change adds a field to effect payloads and
changes no transition selection, no entry/exit set, no datamodel semantics, and
no error behavior - nothing a SCION or W3C corpus test can observe. `mix
test.regression` is expected to be green unchanged at every phase, and no
`mix test.baseline add` call is warranted. If a corpus test does move, that is
a defect in the change, not a ratchet update to record.

## Performance Considerations

ADR-0045 accepted the bill explicitly: one extra map read per core-effect
emission and one small integer per payload. Core effects are emitted far less
often than trace effects, which already pay it. The untraced hot path is
unaffected in shape - `Effect.trace/3`'s gate is untouched, and the core
payloads were already being constructed on every emission; they are one field
wider, not newly allocated. No benchmark is warranted.

## Open Questions

Recorded rather than resolved, because each is a contract call above this
plan's authority. Neither blocks implementation; both have a stated default the
plan follows.

1. **Should `[:statifier, :session, :unroutable]` gain `round` in its
   measurements?** Its emitter (`lib/statifier/session/telemetry.ex:454-466`)
   reads `payload.macrostep`/`payload.microstep` off whatever core payload
   failed to route, and after this change every such payload carries `round`
   too. ADR-0040's "counters are numbers, so they are measurements" rule would
   put it there; ADR-0045 amends only the *core-effect* measurements line and
   names `[:statifier, :session, :effect, kind]` specifically. **Default taken:
   leave `:unroutable` unchanged**, on the reading that ADR-0045 decided the
   scope of its own amendment and widening a second event's contract is a
   separate decision. If the answer is "add it", it is a one-line change plus
   one contract-table row and can land as a follow-on without disturbing
   anything here.
2. **Does `round` belong on the `{:halted, _}` and `{:unroutable, _}` stream
   envelopes?** `Statifier.StreamOrder`'s moduledoc notes they "carry no
   counters at all" and excludes them from every check. After this change they
   are the only members of the subscriber stream with no ordering key, which is
   defensible (an envelope is not an effect) but is now the sole remaining
   asymmetry. **Default taken: leave them alone** - ADR-0044 decision 2 already
   gives `{:halted, _}` a positional guarantee (it is last), which is stronger
   than a sort key, and ADR-0045 says nothing about envelopes.

## References

- Source document: `docs/adr/0045-round-on-every-core-effect.md` (the
  specification for this plan; commit `9ab61fb`)
- Related ADRs: `docs/adr/0020-round-ordinal-joins-the-step-counters.md`
  (amended in part), `docs/adr/0040-session-telemetry-event-contract.md`
  (amended in part),
  `docs/adr/0044-re-entry-effects-defer-to-the-outer-batch.md`
  (decision 4 deferred this bead),
  `docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md`,
  `docs/adr/0003-pure-core-with-effects.md`,
  `docs/adr/0019-macrostep-round-budget.md`
- Constraints: `docs/observability.md` constraints 2, 3, and 4
- Similar implementation: `lib/statifier/effect/budget_exhausted.ex:30-46`
  (the one core payload already carrying the field) and
  `lib/statifier/session/telemetry.ex:536-543` (its measurements clause)
- Bead: `st-xb2b`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The touched interpreter functions (`autoforward_effect/5`,
      `invoke_one/6`, `exit_interpreter/1`,
      `ExitEntry.cancel_one_invocation/4`) still match their W3C Appendix D
      pseudocode line for line - read against
      `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/appendix-d.txt`,
      not from memory
- [ ] Each new test's sabotage mutation was actually run and confirmed red,
      then reverted
- [ ] No regressions in related features

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
