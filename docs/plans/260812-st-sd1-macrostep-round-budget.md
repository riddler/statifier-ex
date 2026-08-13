---
date: 2026-08-12
planner: Claude
git_commit: adeff58cdadd0f17f5714d82559d34ec2c8c6530
branch: st-sd1-macrostep-step-budget
repository: statifier-ex
beads_issue: st-sd1
topic: "A round budget bounds the macrostep fold, ending a livelock with an observable effect"
status: ready
last_updated: 2026-08-12
last_updated_by: Claude
---

# Macrostep Round Budget Implementation Plan

## Overview

`Statifier.Interpreter.macrostep/1`'s fold is unbounded, so a macrostep that
cannot reach quiescence never returns and the calling process hangs. ADR-0019
(accepted 2026-08-12) decides the fix: a round budget carried as configuration
on `%MachineState{}`, spent one round per `microstep/1` call, that stops the
fold and appends a new core effect `{:budget_exhausted,
%Statifier.Effect.BudgetExhausted{}}` on exhaustion. This plan implements that
decision. Bead: st-sd1.

## Current State Analysis

The fold is three lines with no guard (`lib/statifier/interpreter.ex:362-367`):

```elixir
defp macrostep(machine_state, effects) do
  case microstep(machine_state) do
    {:quiescent, machine_state, round_effects} -> {machine_state, effects ++ round_effects}
    {machine_state, round_effects} -> macrostep(machine_state, effects ++ round_effects)
  end
end
```

`macrostep/1` (`lib/statifier/interpreter.ex:341-354`) calls it with an empty
effects accumulator and then appends `Trace.MacrostepStable` when the returned
machine_state is still `running`. It has no way to distinguish "the fold
stopped because it reached quiescence" from any other stop, because there is
no other stop today.

The st-sd1 livelock, reproduced from the bead and ADR-0019's Context: an
eventless transition whose `cond` deterministically errors. Each round,
`Selection.select_eventless_transitions/1` evaluates the failing cond, enqueues
`error.execution`, and returns `[]`; `internal_round/1`
(`lib/statifier/interpreter.ex:386-410`) finds the queue non-empty, dequeues
the error, and selects on it, which never re-evaluates the eventless cond
because an event-matched round short-circuits `%Transition{events: []}` before
reaching it; nothing is enabled, the queue is empty, and the fold repeats.
**No microstep ever runs** on this cycle - `run_selected/3`'s non-empty branch
is never reached (`lib/statifier/interpreter.ex:437-441`), so
`MachineState.begin_microstep/1` is never called and the `microstep` counter
never advances. A bound expressed in microsteps would not catch it.

What exists to build on:

- `MachineState.new/2` (`lib/statifier/machine_state.ex:199-215`) reads its
  options with `Keyword.get/3` and stores them as read-only struct fields;
  `trace` is the model (`lib/statifier/machine_state.ex:152, 164-170, 213`).
  `Interpreter.initialize/2` passes `opts` through uninterpreted
  (`lib/statifier/interpreter.ex:141-142, 151-155`), so a new option needs no
  entry-point change.
- The effect vocabulary is one `@type t()` union in `lib/statifier/effect.ex`
  with a moduledoc table (`lib/statifier/effect.ex:24-38`), a `@type core`
  (`:102-110`) and a `@type trace` (`:111-119`). One payload struct per
  effect under `lib/statifier/effect/`; `Statifier.Effect.Done`
  (`lib/statifier/effect/done.ex`) is the closest model - a core effect built
  directly by the interpreter, carrying `configuration` and both counters.
- Two tests enumerate the whole vocabulary and would fail on an unlisted
  member: `test/statifier/effect_test.exs:23-65` (the `trace?/1` tables and
  the "thirteen effects" count) and
  `test/statifier/machine_state_acceptance_test.exs:162-176` ("the core six
  plus all seven trace points").
- `test/statifier/interpreter/macrostep_test.exs` already holds the fold's
  unit tests over a fixture document of eventless chains, and
  `test/statifier/interpreter/interpreter_acceptance_test.exs:327-445` holds
  the st-af3.2 cond-error acceptance block, whose comment at `:326`
  explicitly defers the eventless livelock to st-sd1.

## Desired End State

`Statifier.Interpreter.macrostep/1` never runs forever. Each `microstep/1`
call inside one fold spends one round of `machine_state.max_macrostep_rounds`
(default `10_000`, `:infinity` to opt out). When the budget is spent before
quiescence, the fold returns the position exactly as the last round left it -
`running: true`, `status: :running`, `exit_interpreter/1` not run - with
`{:budget_exhausted, %Statifier.Effect.BudgetExhausted{}}` appended to the
effect list and **no** `Trace.MacrostepStable`. No signature outside the
private fold changes.

Verified by: the st-sd1 reproduction (an erroring eventless `cond`) terminating
with that effect under a small explicit budget, an ordinary eventless self-loop
doing the same, the existing macrostep suite still green with the default
budget untouched, and a bare `mix quality` green.

### Key Discoveries:

- The livelock advances no microstep counter, so the bound must count fold
  rounds including empty ones (`lib/statifier/interpreter.ex:437-441`,
  ADR-0019 Context).
- `initialize/2` passes `opts` to `MachineState.new/2` uninterpreted
  (`lib/statifier/interpreter.ex:151-155`), so one option covers both folding
  seams (`initialize/2` and `handle_event/2`).
- `macrostep/1` currently infers "stable" from `machine_state.running`
  (`lib/statifier/interpreter.ex:344-351`). With a third outcome that also
  leaves `running: true`, that inference is no longer sufficient - the private
  fold must report its outcome. See Decision 1 below.
- `Statifier.initialize/2`'s `@doc` enumerates the MachineState option set
  (`lib/statifier.ex:83-85`) and must gain the new option.
- ADR-0002 binds this work: the deviation comment's exact text and its
  location (immediately above the private fold) are specified by ADR-0019
  lines 122-137 and must be reproduced verbatim.
- ADR-0003 rules out a tagged return and a platform error event; ADR-0019
  records both rejections (lines 96-115). Do not re-argue them.

## What We're NOT Doing

- **No cond-specific dedupe or memoization inside `Selection`.** ADR-0019 and
  the bead both reject it: Appendix D contains no such guard, and SCXML
  permits non-terminating macrosteps for ordinary eventless self-loops too, so
  a cond-shaped fix would be a semantic deviation with no mechanical reason
  (ADR-0002).
- **No tagged return, no platform error event, no `running: false`.** All
  three were considered and rejected in ADR-0019's Decision. `handle_event/2`
  still returns `{:ok, machine_state, effects}`.
- **No session-layer policy.** What to do about a livelocked chart - kill,
  alert, retry with a bigger budget - is st-cmq's, and this plan adds no
  handling of the new effect anywhere.
- **No conformance-harness budget.** ADR-0019's Consequences leave the
  per-test budget to st-af3.8; this plan changes nothing under
  `test/support/` or `test/passing_tests.json`.
- **No microstep-counted bound and no wall-clock timeout.** Rounds, per
  ADR-0019.
- **Not fixing `Statifier.initialize/2`'s omission of `:session_id`** from its
  option list (`lib/statifier.ex:83-85`). It is a pre-existing doc gap, out of
  scope here, and touching it would put an unrelated change in the diff. Only
  `:max_macrostep_rounds` is added to that enumeration.
- **Not editing `docs/observability.md`.** Its constraint-2 table lists trace
  effects only, and `:budget_exhausted` is a core effect, so no row is owed.
  Its line 42 ("The fold function started private (`macrostep/2`)") is a past-
  tense origin note that stays true after the arity change; leave it alone.
- **No `Trace.BudgetExhausted` companion.** ADR-0019 makes this a core effect
  precisely because it must be observable with `trace: false`; adding a trace
  twin would grow constraint 2's committed set without a decision.

## Implementation Approach

Three phases, split along the module boundaries the project's plan extension
names: the data (MachineState configuration plus the effect vocabulary), then
the interpreter fold, then the acceptance-level reproduction of the bug.

Phase 1 adds a struct field and a payload module with no runtime producer -
both are exercised in their own phase by the vocabulary and constructor tests
that already enumerate them, so the phase stands on its own gate. Phase 2 is
the only phase that changes behavior. Phase 3 proves the bead's acceptance
criterion against the real interpreter loop.

### Decisions this plan makes that ADR-0019 left to the implementer

1. **The private fold reports its outcome.** `defp macrostep/3` returns
   `{:quiescent | :exhausted, machine_state, effects}` rather than the bare
   pair it returns today, because `macrostep/1` can no longer infer stability
   from `running` alone (a budget-exhausted fold is still `running: true`).
   This is private, so no public contract moves. The alternative - having the
   fold append the `BudgetExhausted` effect itself and having `macrostep/1`
   scan the effect list for it - would make the stable/exhausted decision
   depend on list inspection, which is worse.
2. **`:infinity` is a separate decrement clause, not arithmetic.** A private
   `defp spend(:infinity), do: :infinity` / `defp spend(n), do: n - 1` keeps
   the hot path an integer decrement and makes `:infinity` unable to
   underflow.
3. **Phase 1 writes the vocabulary-table row as "not yet produced", and Phase
   2 flips it.** The table already carries four such rows
   (`lib/statifier/effect.ex:26-29`), so this is the file's own convention
   rather than a placeholder, and it keeps Phase 1's documentation true at the
   moment Phase 1 commits. The one-cell edit in Phase 2 is deliberate, not an
   oversight.

## Phase 1: The budget field and the `:budget_exhausted` vocabulary

### Overview

Adds `max_macrostep_rounds` to `%MachineState{}` and its `new/2` option, and
adds `Statifier.Effect.BudgetExhausted` to the effect vocabulary. Nothing
produces the effect yet and nothing reads the field yet.

### Changes Required:

#### 1. MachineState configuration field
**File**: `lib/statifier/machine_state.ex`
**Changes**: New field defaulting to `10_000`, a typedoc in the style of
`trace`'s (`:164-170`), a `@type t` entry, `new/2` reading the option, and
`new/2`'s `@doc` option list extended. The moduledoc's "set once in `new/2`,
read-only thereafter" discipline applies (ADR-0019 Consequences); no new
writer function is added.

```elixir
defstruct [
  # ...
  trace: false,
  max_macrostep_rounds: 10_000
]

@typedoc """
The round budget one macrostep's fold may spend - `pos_integer()`, or
`:infinity` for the spec's literal unbounded behavior (ADR-0019). Set once
in `new/2` and read-only thereafter, like `trace`. One round is one
`Statifier.Interpreter.microstep/1` call inside the fold, empty rounds
included; it is not a microstep count, because a livelocked fold can run
forever without advancing the microstep counter at all.
"""
@type max_macrostep_rounds :: pos_integer() | :infinity
```

and in `new/2`:

```elixir
max_macrostep_rounds: Keyword.get(opts, :max_macrostep_rounds, 10_000)
```

`new/2`'s `@doc` "Options:" sentence gains `:max_macrostep_rounds` (default
`10_000`).

#### 2. The payload module
**File**: `lib/statifier/effect/budget_exhausted.ex` (new)
**Changes**: One struct, modelled on `Statifier.Effect.Done`
(`lib/statifier/effect/done.ex`). Fields per ADR-0019: the configuration, both
counters, the budget that was spent, and the pending internal events.

```elixir
defmodule Statifier.Effect.BudgetExhausted do
  @moduledoc """
  Payload for `{:budget_exhausted, %__MODULE__{}}` - ADR-0019's outcome when
  `Statifier.Interpreter.macrostep/1`'s fold spends
  `Statifier.MachineState.max_macrostep_rounds` without reaching quiescence.

  A core effect, not a trace effect: it is the outcome of the call rather
  than diagnostics about it, so it must be observable with `trace: false`.
  `Statifier.Effect.Trace.MacrostepStable` is *not* emitted alongside it -
  the configuration did not stabilize - which keeps the three macrostep
  outcomes (stable, done, budget-exhausted) mutually exclusive.

  `configuration` is the full configuration (ADR-0005, ancestors included)
  as the last round left it; `budget` is the value that was spent, i.e.
  `max_macrostep_rounds` for that fold; `pending_internal_events` is
  `Statifier.MachineState.internal_events/1`'s ordered view of the queue,
  which is where a livelock's repeatedly-raised events pile up.
  `macrostep`/`microstep` are the counters as they stand at exhaustion - and
  `microstep` may well be `0`, because a fold can livelock without any
  microstep ever running.

  The machine_state returned alongside this effect is a complete, resumable
  position (ADR-0012): step it through
  `Statifier.Interpreter.microstep/1` to watch the cycle round by round.
  """

  @enforce_keys [:configuration, :budget, :pending_internal_events, :macrostep, :microstep]
  defstruct [:configuration, :budget, :pending_internal_events, :macrostep, :microstep]

  @type t :: %__MODULE__{
          configuration: MapSet.t(non_neg_integer()),
          budget: pos_integer() | :infinity,
          pending_internal_events: [Statifier.Event.t()],
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
end
```

Every key is enforced, including `pending_internal_events`. Unlike
`Effect.Done.donedata`, which is legitimately absent for a final carrying no
`<donedata>` and is therefore typed `term() | nil`, there is no position in
which the pending queue is unknown - an empty queue is `[]`, not `nil`. A
non-enforced key typed as a bare list would let any struct literal that omits
it produce a value contradicting the module's own `@type t()`. Every fixture
in the test tables below therefore supplies it too.

#### 3. The vocabulary union and table
**File**: `lib/statifier/effect.ex`
**Changes**:

- `alias Statifier.Effect.BudgetExhausted` added to the alias block.
- `@type core` gains `| {:budget_exhausted, BudgetExhausted.t()}`.
- The `@type core` typedoc becomes, per ADR-0019 line 89-92: `"The seven core
  effects - the ADR-0003 set plus ADR-0019's `:budget_exhausted`."`
- The moduledoc vocabulary table gains a row, written in this phase with the
  file's existing "not yet produced" wording (Decision 3):

  | `:budget_exhausted` | `Statifier.Effect.BudgetExhausted` | not yet produced (ADR-0019 round budget) |

#### 4. The enumerating tests
**File**: `test/statifier/effect_test.exs`
**Changes**: `@core_effects` gains
`{:budget_exhausted, %BudgetExhausted{configuration: MapSet.new(), budget: 1, pending_internal_events: [], macrostep: 1, microstep: 1}}`
(every enforced key supplied);
the count test becomes fourteen and its name updated. The existing sabotage
line above the core-effect loop still describes the mutation that reddens it;
add a sabotage line to the count test only if it stops being the "fixture
tables are complete" check it currently declares itself exempt as
(`test/statifier/effect_test.exs:57-62`) - it does not change character here,
so it keeps its `# sabotage: n/a` line with the count updated in the prose.

**File**: `test/statifier/machine_state_acceptance_test.exs`
**Changes**: the same tag, with the same fully-populated struct, added to its
`@core_effects` list; `assert
length(@core_effects) == 6` becomes `== 7`, the total becomes `14`, the test
name and the `# AC:` comment above it updated to say the core set is now seven
and cite ADR-0019 for the seventh.

**File**: `test/statifier/machine_state_test.exs`
**Changes**: a new test beside the `:trace` option test
(`test/statifier/machine_state_test.exs:142-147`):

```elixir
# sabotage: `MachineState.new/2` hardcodes `max_macrostep_rounds: 10_000`
# and ignores the option -> the `:infinity` and explicit-integer
# assertions redden.
test "max_macrostep_rounds defaults to 10_000, and the option is honored" do
  assert new_machine_state().max_macrostep_rounds == 10_000
  assert new_machine_state(max_macrostep_rounds: 25).max_macrostep_rounds == 25
  assert new_machine_state(max_macrostep_rounds: :infinity).max_macrostep_rounds == :infinity
end
```

#### 5. The facade's option enumeration
**File**: `lib/statifier.ex`
**Changes**: `initialize/2`'s `@doc` sentence "`opts` is
`Statifier.MachineState.new/2`'s own option set (`:trace`, `:datamodel`)"
gains `:max_macrostep_rounds`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (`mix quality --profile loop` between edits,
      never as the phase gate).
- [x] `test/statifier/effect_test.exs` and
      `test/statifier/machine_state_acceptance_test.exs` both count fourteen
      effects and classify `:budget_exhausted` as non-trace.
- [x] `test/statifier/machine_state_test.exs` proves the default and both
      option forms (integer and `:infinity`).
- [x] Doctor's 100% doc-coverage thresholds hold for the new module (the full
      gate decides this; the new module carries a `@moduledoc` and needs no
      function docs).
- [x] Dialyzer accepts `pos_integer() | :infinity` in both the `MachineState`
      and `BudgetExhausted` types (full gate).
- [x] Each new test that asserts `lib/` behavior carries a sabotage line, and
      each mutation was actually run red and reverted (CLAUDE.md,
      `docs/testing.md`).

#### Manual Verification:
- [ ] The touched functions still match the W3C Appendix D pseudocode line for
      line - this phase touches no ported function, so the check is that
      `MachineState.new/2` gained only a field read and `Effect` gained only a
      union member.
- [ ] The `@type core` typedoc wording matches ADR-0019 lines 89-92, and the
      table row uses the file's own "not yet produced" convention.
- [ ] `%Statifier.Effect.BudgetExhausted{}` field names read the way ADR-0019
      names them (configuration, counters, budget, pending internal events).
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: The bounded fold

### Overview

Threads the round accumulator through the private fold, stops on exhaustion
with the `BudgetExhausted` effect and no `MacrostepStable`, and carries
ADR-0019's port-site deviation comment. This is the phase that changes
behavior.

### Changes Required:

#### 1. The fold and its driver
**File**: `lib/statifier/interpreter.ex`
**Changes**: `macrostep/1` (`:341-354`) seeds the budget from the
machine_state and routes on the fold's outcome; the private `macrostep/2`
(`:356-367`) becomes `macrostep/3`.

```elixir
def macrostep(%MachineState{} = machine_state) do
  {outcome, machine_state, effects} =
    macrostep(machine_state, [], machine_state.max_macrostep_rounds)

  {machine_state, effects ++ terminal_effects(machine_state, outcome)}
end
```

`terminal_effects/2` is a new private helper holding the three mutually
exclusive outcomes in one place:

```elixir
# The three mutually exclusive ways one macrostep ends (ADR-0019).
# `:quiescent` while still `running` is the stable configuration and the one
# case `Trace.MacrostepStable` names; `:quiescent` with `running: false` is
# termination, whose vocabulary row is `Trace.Done` from
# `exit_interpreter/1`; `:exhausted` is the spent round budget, a core
# effect because it is the outcome of the call rather than diagnostics about
# it, so it is built directly and not through the `Effect.trace/3` gate.
defp terminal_effects(machine_state, :quiescent) do
  if machine_state.running do
    Effect.trace(machine_state, Effect.Trace.MacrostepStable,
      configuration: machine_state.configuration
    )
  else
    []
  end
end

defp terminal_effects(machine_state, :exhausted) do
  [
    {:budget_exhausted,
     %Effect.BudgetExhausted{
       configuration: machine_state.configuration,
       budget: machine_state.max_macrostep_rounds,
       pending_internal_events: MachineState.internal_events(machine_state),
       macrostep: machine_state.macrostep,
       microstep: machine_state.microstep
     }}
  ]
end
```

The private fold, with ADR-0019's comment reproduced **verbatim** (ADR-0019
lines 127-137) immediately above it, joining the existing hoisting comment:

```elixir
@spec macrostep(
        machine_state :: MachineState.t(),
        effects :: [Effect.t()],
        rounds_left :: MachineState.max_macrostep_rounds() | 0
      ) :: {:quiescent | :exhausted, MachineState.t(), [Effect.t()]}
# The private accumulator behind `macrostep/1` - repeatedly calls
# `microstep/1` until it returns `:quiescent`, threading the machine_state
# and appending each round's effects in order. Not an Appendix D function
# name; see `macrostep/1`'s own comment. ADR-0002.
#
# ADR-0002 mechanical deviation (ADR-0019). Appendix D's inner loop is
# unbounded, and the REC allows that ("A macrostep may not [terminate].
# ... This is currently allowed.") because it presumes an interpreter
# an "external entity" can cancel mid-macrostep. A pure core (ADR-0003)
# has no external entity inside a fold - a non-terminating macrostep
# would hang the calling process with no recourse - so the fold spends
# one round per `microstep/1` call and stops with a `:budget_exhausted`
# effect when `max_macrostep_rounds` runs out. The loop's condition and
# body are otherwise unchanged; `max_macrostep_rounds: :infinity`
# restores the literal spec behavior for a caller that owns its own
# interruption.
defp macrostep(machine_state, effects, 0), do: {:exhausted, machine_state, effects}

defp macrostep(machine_state, effects, rounds_left) do
  case microstep(machine_state) do
    {:quiescent, machine_state, round_effects} ->
      {:quiescent, machine_state, effects ++ round_effects}

    {machine_state, round_effects} ->
      macrostep(machine_state, effects ++ round_effects, spend(rounds_left))
  end
end

defp spend(:infinity), do: :infinity
defp spend(rounds_left), do: rounds_left - 1
```

The `0` head fires *before* the round runs, so a budget of `n` permits exactly
`n` `microstep/1` calls; `:infinity` never matches it.

#### 2. Documentation at the port site
**File**: `lib/statifier/interpreter.ex`
**Changes**:

- `macrostep/1`'s `@doc` (`:305-333`) - "The fold ends one of two ways"
  becomes three, with a new bullet for budget exhaustion: the position comes
  back as the last round left it, `running` stays `true` and `status` stays
  `:running` (no `exit_interpreter/1`, no `Effect.Done` - ADR-0019 rejects
  faking termination), `Trace.MacrostepStable` is not emitted, and the
  `{:budget_exhausted, _}` core effect is appended last. The closing sentence
  "The two trace effects are therefore mutually exclusive per macrostep"
  becomes the three outcomes being mutually exclusive. While rewriting that
  paragraph, **drop the stale "(not yet landed)" qualifier** on its
  `exit_interpreter/1` mention: that function is fully implemented
  (`lib/statifier/interpreter.ex:556-601`), so the phrase is already false
  today, and carrying it forward into the rewritten sentence would launder a
  known-wrong claim through this branch. Deleting three words inside a
  paragraph this phase rewrites anyway is not scope creep; leaving them is the
  churn.
- The moduledoc's "Deviations, with their reasons (ADR-0002)" list (`:82-119`)
  gains a bullet: **the macrostep fold is bounded** - one sentence pointing at
  the fold's own comment and ADR-0019, in the shape the other five bullets use
  ("See `macrostep/1`'s own `@doc`").
- The moduledoc's function-map table (`:14-22`) needs no change: `macrostep/1`
  is still that loop folded to quiescence.

#### 3. The vocabulary table's producer cell
**File**: `lib/statifier/effect.ex`
**Changes**: the row added in Phase 1 flips from "not yet produced (ADR-0019
round budget)" to `Statifier.Interpreter.macrostep/1`, and the prose sentence
at `:40-43` ("The interpreter now produces `:log`, `:done`, and all seven
trace effects") gains `:budget_exhausted`.

#### 4. Fold tests
**File**: `test/statifier/interpreter/macrostep_test.exs`
**Changes**: a new `describe "macrostep/1 round budget"` block. The fixture is
a second document with an ordinary eventless self-loop - deliberately not a
cond, so the budget is proven shape-agnostic (ADR-0019: "The bound must be
engine-level and shape-agnostic"):

```xml
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="spin">
    <state id="spin">
        <transition target="spin"/>
    </state>
</scxml>
```

Every test in the block passes an explicit small budget so a regression fails
in milliseconds rather than at ExUnit's 60-second timeout. Tests:

1. **Exhaustion returns the effect and no `MacrostepStable`.** `macrostep/1`
   on the self-loop with `max_macrostep_rounds: 5` returns; the effects hold
   exactly one `{:budget_exhausted, %Effect.BudgetExhausted{budget: 5}}`; no
   `Trace.MacrostepStable` is present.
   *sabotage: the `defp macrostep(machine_state, effects, 0)` head is removed
   so the fold is unbounded again -> the test hangs to ExUnit's timeout and
   reddens.*
2. **The position is intact and resumable.** The returned machine_state has
   `running: true`, `status: :running`, its configuration still holds `spin`,
   and `Interpreter.microstep/1` on it returns a further non-quiescent round
   (ADR-0012's payoff, ADR-0019's Consequences).
   *sabotage: `terminal_effects/2`'s `:exhausted` clause also sets
   `running: false` -> the `running` assertion reddens.*
3. **The budget bounds rounds exactly.** With the self-loop and
   `max_macrostep_rounds: 5`, the payload's counters show five rounds' worth
   of progress (each self-loop round is a real microstep, so
   `microstep == 5`), and no sixth round ran.
   *sabotage: `spend/1`'s integer clause becomes `rounds_left` (never
   decrementing) -> the fold no longer terminates and the test times out; a
   second mutation, `defp macrostep(ms, effects, 0)` changed to match `1`,
   reddens the counter equality by one.*
4. **A legitimate chart is untouched by the default budget.** The existing
   `@document` eventless chain folded with default options reaches
   quiescence, emits `MacrostepStable`, and emits no `:budget_exhausted`.
   *sabotage: `macrostep/1` seeds the fold with `0` instead of
   `machine_state.max_macrostep_rounds` -> the chain exhausts immediately and
   both assertions redden.*
5. **A budget exactly equal to the rounds needed still reaches quiescence.**
   The off-by-one boundary: run the `@document` chain from `p1` with the
   budget set to the exact round count it uses and assert quiescence plus
   `MacrostepStable`; with one fewer, assert `:budget_exhausted`. (The exact
   count is read off the existing test at
   `test/statifier/interpreter/macrostep_test.exs:114-135`, which pins three
   selection rounds for that chain; the implementer confirms it against the
   run rather than assuming.)
   *sabotage: the `0`-matching head becomes a `when rounds_left <= 1` guard ->
   the exact-budget case exhausts instead of reaching quiescence and reddens.*
6. **`:infinity` folds a terminating chart to quiescence.** The `@document`
   chain with `max_macrostep_rounds: :infinity` behaves identically to the
   default. Deliberately **not** run against the self-loop, which would hang
   by design.
   *sabotage: `spend(:infinity)` returns `0` -> the `:infinity` run exhausts
   after one round instead of reaching quiescence, reddening the
   configuration assertion.*
7. **`trace: false` still yields the effect.** The self-loop with
   `trace: false` and a small budget still produces `{:budget_exhausted, _}`
   and zero trace effects - the core-vs-trace distinction ADR-0019 turns on.
   *sabotage: `terminal_effects/2`'s `:exhausted` clause is routed through
   `Effect.trace/3` -> the untraced run emits nothing and the assertion
   reddens.*

#### 5. Changelog fragment
**File**: `changelog.d/st-sd1.md` (new)
**Changes**: this is a user-visible behavior change and a capability v1 never
had, which is the narrower bar `changelog.d/README.md` sets while v2 is
unreleased.

```markdown
### Added

- `Statifier.MachineState.new/2` accepts `:max_macrostep_rounds` (a positive
  integer, default `10_000`, or `:infinity`), bounding one macrostep's fold.

### Fixed

- A macrostep that cannot reach quiescence now returns a
  `{:budget_exhausted, %Statifier.Effect.BudgetExhausted{}}` effect with a
  resumable position instead of hanging the calling process.
```

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes.
- [x] The whole existing `test/statifier/interpreter/` suite is green with no
      edits to its assertions beyond the new block - the default budget must
      change nothing about any chart already under test.
- [x] The new budget block covers exhaustion, resumability, the exact-budget
      boundary, `:infinity`, and `trace: false`.
- [x] `mix test.regression` is green (the ratchet must not move; see
      Corpus/Ratchet Notes).
- [x] `mix test --include scion --include scxml_w3` completes without hanging
      - the run that would have hung is exactly the risk ADR-0019 names.
- [x] `changelog.d/st-sd1.md` exists and uses only Keep a Changelog headings.
- [x] Every new test asserting `lib/` behavior carries a sabotage line whose
      mutation was run red and reverted. **Two of this phase's mutations hang
      rather than fail** - test 1's (removing the `0`-matching head) and test
      3's first (`spend/1` never decrementing). Bound them with a short
      `@tag timeout:` on the test under mutation while confirming red, so each
      costs a second rather than ExUnit's 60, and say so in the sabotage line.
      The mutation is still genuinely run; only the wait is bounded.

#### Manual Verification:
- [ ] The touched functions still match the W3C Appendix D pseudocode line for
      line: `microstep/1`'s body, `internal_round/1`, and `run_selected/3` are
      untouched, and the fold's condition and body are unchanged apart from
      the guard - the deviation is the guard alone.
- [ ] The ADR-0002 deviation comment above `defp macrostep/3` is ADR-0019
      lines 127-137 **verbatim**, including the quoted REC Termination note.
- [ ] The three macrostep outcomes are mutually exclusive in practice: a
      terminating chart emits `Trace.Done` and no `MacrostepStable`; a stable
      one emits `MacrostepStable` and no `:budget_exhausted`; an exhausted one
      emits `:budget_exhausted` and neither.
- [ ] `Trace.MacrostepStable`'s absence on exhaustion is visible in a
      `trace: true` run in iex, and the repeating `TransitionsSelected` /
      `EventDequeued` rounds read as the cycle ADR-0019 describes.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 3: The st-sd1 reproduction at the acceptance level

### Overview

Pins the bead's own bug: an eventless transition whose `cond` deterministically
errors, driven through the real interpreter loop rather than the fold's unit
fixture. This is the phase that proves the acceptance criterion, and the one
that proves the bound counts *rounds* rather than microsteps - the property no
Phase 2 test can show, because every self-loop round is a real microstep.

### Changes Required:

#### 1. The livelock acceptance block
**File**: `test/statifier/interpreter/interpreter_acceptance_test.exs`
**Changes**: a new `describe "an erroring eventless cond terminates on the
round budget"` block after the existing st-af3.2 cond block. The fixture is
the bead's own reproduction - eventless, not event-matched, which is the one
difference from `@uncaught_document` at `:344-352`:

```xml
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a" datamodel="predicator">
    <state id="a">
        <transition cond="nope" target="b"/>
    </state>
    <state id="b"/>
</scxml>
```

The livelock strikes during the initialization macrostep, so the entry point
is `Interpreter.initialize(machine, max_macrostep_rounds: 20, trace: true)` -
a small explicit budget so a regression reddens in milliseconds instead of at
ExUnit's 60-second timeout. Tests:

1. **It terminates with the effect instead of hanging.** `initialize/2`
   returns; effects hold one `{:budget_exhausted, %Effect.BudgetExhausted{
   budget: 20}}`; no `Trace.MacrostepStable`; `machine_state.running` is
   `true` and `status` is `:running`; the configuration still holds `a` and
   never `b` (the failing cond genuinely gated the transition).
   *sabotage: the `defp macrostep(machine_state, effects, 0)` head is removed
   -> the test hangs to ExUnit's timeout and reddens. This is the whole bead
   in one mutation.*
2. **The bound counts rounds, not microsteps.** The payload's `microstep`
   counter is `1` - the initial entry `initialize/2` performs directly - and
   has not advanced past it, because no round of the livelock ever ran a
   microstep. This is ADR-0019's "a bound expressed in microsteps would not
   catch this loop at all" made executable.
   *sabotage: the fold's budget is decremented only on the branch that runs a
   microstep (moving `spend/1` inside `run_selected/3`'s non-empty path) ->
   the livelock consumes no budget, the fold never stops, and the test times
   out.*
3. **The pending internal events are carried out.** The payload's
   `pending_internal_events` is non-empty and every member is named
   `error.execution` - the queue state that makes the cycle diagnosable, and
   the reason ADR-0019 puts the field on the payload at all.
   *sabotage: `terminal_effects/2`'s `:exhausted` clause hardcodes
   `pending_internal_events: []` -> the non-empty assertion reddens.*
4. **A later call gets a fresh budget and exhausts again.**
   `Interpreter.handle_event/2` on the returned machine_state with any event
   returns `{:ok, _, effects}` whose effects again hold `:budget_exhausted` -
   ADR-0019's "defined and repeatable, never hanging".
   *sabotage: `macrostep/1` seeds the fold from a value carried on the struct
   across calls rather than from `machine_state.max_macrostep_rounds` -> the
   second call has no budget left and its counters differ from the first,
   reddening the equality.*

#### 2. The deferred-work comment
**File**: `test/statifier/interpreter/interpreter_acceptance_test.exs`
**Changes**: the comment at `:325-326` currently reads "Deliberately
event-matched (not eventless) so the macrostep terminates - see the plan's
'What We're NOT Doing' on the eventless-cond-error livelock (st-sd1), which
this test does not touch." Repoint it at the block that now does touch it and
at ADR-0019, so the two blocks read as the pair they are.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` passes.
- [ ] The whole default suite completes in its usual wall-clock time - no test
      sits at an ExUnit timeout.
- [ ] `mix test.regression` is green.
- [ ] Every new test carries a sabotage line whose mutation was run red and
      reverted. The two hang-shaped mutations are run with a short
      `@tag timeout:` or `mix test --max-cases 1` so confirming red does not
      cost a 60-second wait - the mutation is still genuinely run, only
      bounded.

#### Manual Verification:
- [ ] The touched functions still match the W3C Appendix D pseudocode line for
      line - this phase adds tests only, so the check is that no `lib/` change
      was needed to make them pass. If one was, the phase boundary was wrong
      and Phase 2 was incomplete.
- [ ] The reproduction matches the bead's description step for step: eventless
      probe raises, error is dequeued and selects nothing, queue empties, cycle
      repeats.
- [ ] Reading the `trace: true` effect list by hand shows the repeating
      round structure, confirming the returned machine_state is the debugging
      artifact ADR-0019's Consequences promise.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Corpus/Ratchet Notes

No ratchet movement is expected and none should be recorded. The default
budget is roughly three orders of magnitude above the largest legitimate
corpus macrostep (ADR-0019), and `conditional_transitions` is still off, so no
generated corpus document can reach the exhaustion branch today. `mix
test.regression` is therefore a *guard* in every phase's criteria rather than
a step: it must stay green, and `mix test.baseline add` must **not** be run as
part of this work. If a corpus test's status changes, that is a finding to
report, not a baseline to update.

`test/passing_tests.json` is a gate-guarded path (ADR-0011): shrinking it
would require a ledger entry in `docs/quality-gate-changes.md`, which is a
human's call. This plan expects no such entry.

The per-test conformance budget ADR-0019's Consequences mention belongs to
st-af3.8, not here; `test/support/case.ex` is untouched.

## Performance Considerations

Legitimate charts pay one pattern match against `0` and one integer decrement
per round. `:infinity` is a separate `spend/1` clause, so an opted-out caller
pays a match and no arithmetic and cannot underflow. `terminal_effects/2`
builds the `BudgetExhausted` struct only on the exhaustion branch, so the
stable path allocates exactly what it allocates today. Nothing is added to
`microstep/1`, `run_selected/3`, or any per-transition path.

## Testing Strategy

### Unit Tests:
- `test/statifier/machine_state_test.exs` - the field's default and both
  option forms.
- `test/statifier/effect_test.exs` and
  `test/statifier/machine_state_acceptance_test.exs` - the vocabulary now
  enumerates fourteen effects and classifies `:budget_exhausted` as core.
- `test/statifier/interpreter/macrostep_test.exs` - the fold's budget:
  exhaustion, resumable position, exact-budget boundary, default budget
  invisible to a legitimate chart, `:infinity`, and `trace: false`.
- `test/statifier/interpreter/interpreter_acceptance_test.exs` - the st-sd1
  reproduction end to end, including the round-not-microstep property and the
  fresh budget on a later call.

Key edge cases: budget exactly equal to rounds needed (must reach quiescence);
budget one below (must exhaust); a livelock that advances no microstep counter;
`trace: false` still producing the core effect; a second call after exhaustion.

Every test above asserts `lib/` behavior and therefore needs its sabotage line
per CLAUDE.md and `docs/testing.md`. **Four** of the mutations make the suite
hang rather than fail - two in Phase 2 (the budget block's tests 1 and 3) and
two in Phase 3 (the reproduction's tests 1 and 2) - which is unavoidable, since
the bug being fixed *is* a hang and the honest mutation is to reintroduce it.
Bound each with a short `@tag timeout:` on the test under mutation while
confirming red, and say so in that test's sabotage line.

### Manual Testing Steps:
1. In iex, compile the erroring-eventless-cond document and run
   `Statifier.initialize(machine, max_macrostep_rounds: 20, trace: true)`.
   Confirm it returns immediately with `{:budget_exhausted, _}` in the effect
   list and no `MacrostepStable`.
2. Take the returned machine_state and call `Interpreter.microstep/1` on it
   two or three times by hand. Confirm each call returns a non-quiescent round
   and that the configuration never moves - the livelock, watched directly.
3. Read the returned effect list: confirm the repeating
   `TransitionsSelected` (empty) / `EventDequeued` (`error.execution`) pairs.
4. Run a legitimate multi-round document with default options and confirm the
   effect list is byte-for-byte what it was before this branch.
5. Diff `lib/statifier/interpreter.ex`'s fold against Appendix D's
   `mainEventLoop` inner loop and confirm the guard is the only difference.

## References

- Decision record: `docs/adr/0019-macrostep-round-budget.md` (accepted,
  2026-08-12) - the settled design, including the verbatim deviation comment
  at lines 127-137 and the rejected alternatives at lines 96-115.
- Related ADRs: `docs/adr/0002-literal-w3c-appendix-d-port.md`,
  `docs/adr/0003-pure-core-with-effects.md`,
  `docs/adr/0005-full-configuration-and-interned-state-indexes.md`,
  `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `docs/adr/0012-debuggability-designed-into-the-core.md`
- Where the bug was found: `docs/plans/260812-st-af3.2-condition-match-cond-gates-selection.md`
  ("What We're NOT Doing")
- The fold as it stands: `lib/statifier/interpreter.ex:341-367`
- The livelock's mechanism: `lib/statifier/interpreter.ex:386-410`,
  `lib/statifier/interpreter.ex:426-442`
- Payload module to model: `lib/statifier/effect/done.ex`
- Vocabulary tests that enumerate every effect:
  `test/statifier/effect_test.exs:23-65`,
  `test/statifier/machine_state_acceptance_test.exs:162-176`
- The deferred test comment this plan repoints:
  `test/statifier/interpreter/interpreter_acceptance_test.exs:315-326`
- Spec: W3C SCXML REC, Appendix D `mainEventLoop`, and the Termination note
  quoted in ADR-0019 (local cache: `$(git rev-parse --path-format=absolute
  --git-common-dir)/spec-cache/`)
- Bead: st-sd1

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The touched functions still match the W3C Appendix D pseudocode line for
      line - this phase touches no ported function, so the check is that
      `MachineState.new/2` gained only a field read and `Effect` gained only a
      union member.
- [ ] The `@type core` typedoc wording matches ADR-0019 lines 89-92, and the
      table row uses the file's own "not yet produced" convention.
- [ ] `%Statifier.Effect.BudgetExhausted{}` field names read the way ADR-0019
      names them (configuration, counters, budget, pending internal events).
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 2

- [ ] The touched functions still match the W3C Appendix D pseudocode line for
      line: `microstep/1`'s body, `internal_round/1`, and `run_selected/3` are
      untouched, and the fold's condition and body are unchanged apart from
      the guard - the deviation is the guard alone.
- [ ] The ADR-0002 deviation comment above `defp macrostep/3` is ADR-0019
      lines 127-137 **verbatim**, including the quoted REC Termination note.
- [ ] The three macrostep outcomes are mutually exclusive in practice: a
      terminating chart emits `Trace.Done` and no `MacrostepStable`; a stable
      one emits `MacrostepStable` and no `:budget_exhausted`; an exhausted one
      emits `:budget_exhausted` and neither.
- [ ] `Trace.MacrostepStable`'s absence on exhaustion is visible in a
      `trace: true` run in iex, and the repeating `TransitionsSelected` /
      `EventDequeued` rounds read as the cycle ADR-0019 describes.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---
