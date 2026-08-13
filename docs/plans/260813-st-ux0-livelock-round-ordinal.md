# Livelock round ordinal implementation plan

## Overview

Give `%Statifier.MachineState{}` a third counter, `round`, written once per
`Statifier.Interpreter.microstep/1` call and reset by `begin_macrostep/1`, and
stamp it onto the seven `Statifier.Effect.Trace.*` payloads,
`%Statifier.Event.Cause{}`, and `%Statifier.Effect.BudgetExhausted{}` - so a
trace of a livelocked macrostep can be ordered, counted, and diffed round by
round. Bead: st-ux0. Mechanism settled by ADR-0020 (accepted, amends ADR-0019
in part); this plan decides only what ADR-0020 explicitly delegates and how the
change is phased.

## Current State Analysis

During a livelock neither existing counter advances - `begin_macrostep/1` is
never reached (no external event arrives) and `begin_microstep/1` is never
reached (every selection is empty) - so every effect a round emits is
byte-identical to the same effect in every other round. Verified on the st-sd1
fixture at `max_macrostep_rounds: 20`: twenty rounds of three effects each, all
stamped `macrostep: 1, microstep: 1`, and all twenty dequeued `error.execution`
events carrying the same `%Event.Cause{origin: {:transition, 0}, macrostep: 1,
microstep: 1}`.

What exists today, from
`docs/research/260813-st-ux0-livelock-round-trace-identity.md`:

- Round count exists only as `rounds_left`, an argument to the private
  `macrostep/3` fold (`lib/statifier/interpreter.ex:438-455`). It never leaves
  the fold, and under `max_macrostep_rounds: :infinity` it is not even
  derivable.
- The two counters live on `%MachineState{}`
  (`lib/statifier/machine_state.ex:185-186`, `:218-231`), with the counter
  contract stated at `:92-122` and exactly two writers, `begin_macrostep/1`
  (`:399-401`) and `begin_microstep/1` (`:410-412`).
- Everything that stamps reads `%MachineState{}` and nothing else. Two paths:
  `Effect.trace/3`'s expansion to `payload_module.new(machine_state, fields)`
  (`lib/statifier/effect.ex:150-160`), and `Cause.new/3`
  (`lib/statifier/event/cause.ex:84-88`) called from `raise_internal/4`
  (`lib/statifier/machine_state.ex:349-358`) and `raise_platform/4` (`:382-391`).
- The seven trace payload `new/2` bodies are byte-identical apart from the
  module name (`lib/statifier/effect/trace/transitions_selected.ex:33-35` and
  the six siblings). There is no shared stamping helper; the convention is
  documented at `lib/statifier/effect.ex:89-92` and implemented seven times.
- `%Effect.BudgetExhausted{}` is built as a struct literal at exactly one site,
  `terminal_effects/2`'s `:exhausted` clause
  (`lib/statifier/interpreter.ex:404-415`).
- `microstep/1` has two clauses (`lib/statifier/interpreter.ex:322-332`): a
  `running: false` clause returning `{:quiescent, machine_state, []}`, and the
  ordinary body.
- The livelock fixture is inline at
  `test/statifier/interpreter/interpreter_acceptance_test.exs:463-587`
  (`@livelock_document`, `livelock_machine/0`, `budget_exhausted/1`,
  `internal_dequeue_count/1`), driven through
  `Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)`. Its
  existing test already pins twenty internal dequeues per call.

## Desired End State

`%MachineState{}` carries `round`; `MachineState.begin_round/1` is its only
incrementing writer and is called at the head of both `microstep/1` clauses;
`begin_macrostep/1` resets it to `0`. The seven trace payloads,
`%Event.Cause{}`, and `%Effect.BudgetExhausted{}` each carry a `round` field,
enforced like the two counters beside it. The other six core effects are
unchanged, so `test/support/context_recorder.ex` and
`test/support/test_content.ex`'s `%Effect.Log{macrostep: 0, microstep: 0}`
literals still compile untouched.

Verified by: on the st-sd1 livelock fixture at `max_macrostep_rounds: 20` with
`trace: true`, the twenty `Trace.EventDequeued(from: :internal)` effects carry
`round: 1..20` in order, the `%Event.Cause{}` on each dequeued event carries a
distinct, ascending round, and `%Effect.BudgetExhausted{round: 20, budget: 20}`
reports the depth. On a terminating chart, `Trace.MacrostepStable`'s `round`
reports how many rounds the stable fold took.

### Key Discoveries:

- The whole mechanism is one write: `begin_round/1` in `microstep/1` reaches
  every stamp, because both stamping paths read only `%MachineState{}`
  (`lib/statifier/effect.ex:150-160`, `lib/statifier/machine_state.ex:355`,
  `:388`).
- `begin_round/1` belongs at the head of `microstep/1`, not in the fold, so a
  human hand-stepping in iex advances it identically to the fold (ADR-0020;
  `lib/statifier/interpreter.ex:23-41` is the moduledoc that teaches that
  stepping recipe).
- `handle_event/2`'s own `Trace.EventDequeued` and `Trace.TransitionsSelected`
  are emitted before the fold begins (`lib/statifier/interpreter.ex:236-247`),
  so they are stamped `round: 0` exactly as they are already stamped
  `microstep: 0` - the round has not begun. Same for everything
  `initialize/2` emits before `main_event_loop/1`
  (`lib/statifier/interpreter.ex:157-196`).
- At exhaustion `round` equals the spent budget: the fold seeds `rounds_left`
  with the budget and only reaches its `0` clause after that many completed
  rounds (`lib/statifier/interpreter.ex:438-450`), which the existing
  `internal_dequeue_count(init_effects) == 20` assertion already pins.
- Adding `round` to `@enforce_keys` breaks *construction* literals only. In
  `test/` those are the vocabulary lists in `test/statifier/effect_test.exs`
  and `test/statifier/machine_state_acceptance_test.exs`, plus
  `test/statifier/effect/trace_test.exs`'s helpers and
  `test/statifier/event/cause_test.exs`. The dozen other test modules that
  mention these structs match on them rather than build them and need no edit.
- `test/passing_tests.json` has no coupling to struct shapes (research
  section 6), so the regression ratchet is untouched by every phase here.
- ADR-0002: the ordinal has no Appendix D counterpart (the inner loop carries
  `macrostepDone` and no round variable), so `begin_round/1`'s call site needs
  a mechanical-reason comment citing ADR-0020, the way the budget guard's
  comment cites ADR-0019 (`lib/statifier/interpreter.ex:422-437`).

## What We're NOT Doing

- **Not extracting a shared stamping helper for the seven trace `new/2`
  bodies** (ADR-0020 delegates this choice; decided here as "third merged key
  in place"). A plain-function helper would not reduce this change's edit
  count: each of the seven modules also gains a `defstruct` entry, an
  `@enforce_keys` entry, a `@type t` entry, and a `new/2` doc line, and the
  body is the smallest part of that edit. The variant that *would* reduce it -
  a `use`-style macro generating the struct, the type, and `new/2` - trades
  seven explicit structs and specs, which dialyzer and Doctor both read, for
  indirection in the one module family whose whole job is to be a readable
  data shape. If a fourth stamped field ever arrives, that is the moment to
  reconsider, with two precedents instead of one.
- **No `rounds_spent` field on `%Effect.BudgetExhausted{}`** (ADR-0020): at
  exhaustion it would always equal the existing `budget` field, and the `round`
  stamp already carries the number.
- **The other six core effects do not gain `round`** (ADR-0020). They are
  emitted only inside a microstep, so `(macrostep, microstep)` already
  distinguishes their rounds, and widening their `@enforce_keys` would break
  the two `test/support/` `%Effect.Log{}` literals for no ordering power.
- **No session-monotonic round number.** The ordinal is per-macrostep;
  `(macrostep, round)` is the lexicographic ordering key (ADR-0020).
- **No change to the fold, `spend/1`, the private `macrostep/3` tuple, or
  `macrostep/1`'s public contract.** `rounds_left` stays a fold-local
  accumulator; ADR-0019's budget decision is untouched.
- **`microstep` is not advanced per round** - that would break the counter
  contract and the spec's meaning of a microstep (ADR-0020's rejected list).
- **No trace formatter, timeline renderer, or effect-list pretty printer.**
  Reading the ordinal out of the effect list is the reader's job, as today.

## Implementation Approach

Four phases, ordered so each one leaves the tree green and says something true
on its own: the counter first (struct + writer + contract), then the wiring
(the writer's single call site, which makes `machine_state.round` real for a
hand-stepper), then the trace surface (which is where the bead's acceptance
criterion is met), then the cause and budget surfaces (which finish ADR-0020's
stamp list). Documentation moves with the phase that makes each sentence true:
`MachineState`'s counter contract in Phase 1, `Interpreter`'s counters section
and `docs/observability.md` constraint 4's first bullet in Phase 2, constraint
4's trace bullet and `Effect`'s moduledoc in Phase 3, constraint 4's cause
bullet and the changelog fragment in Phase 4.

**Appendix D rule (ADR-0002).** One deviation, already argued by ADR-0020: the
round ordinal has no pseudocode counterpart, because Appendix D's inner loop
carries only `macrostepDone` and the REC's Termination note describes a
non-terminating macrostep as "an infinitely long sequence of microsteps" with
no round variable. It is a hoisting artifact of this port's `microstep/1`, like
the two counters before it, and it changes no loop condition and no loop body.
The comment recording that goes at `begin_round/1`'s call site in Phase 2. No
other deviation is introduced by any phase here.

**A round is one `microstep/1` invocation, both clauses included.** The
`running: false` clause is a real call that makes a real round of the fold, and
counting it keeps `round` meaning exactly what `max_macrostep_rounds` means, so
`round` at exhaustion equals the spent budget with no off-by-one. It also keeps
the terminal probes symmetric: the quiescent probe (a real but empty selection
round) and the terminated probe are both counted, so `Trace.MacrostepStable`
and `Trace.Done` both report "how many `microstep/1` calls this macrostep's
fold made, terminal probe included".

---

## Phase 1: The `round` counter on `%MachineState{}`

### Overview

The struct field, its `new/2` default, its reset in `begin_macrostep/1`, its
sole incrementing writer `begin_round/1`, and the counter contract prose that
governs all three. Nothing calls `begin_round/1` yet; the phase is verified by
the contract's own unit tests.

### Changes Required:

#### 1. The struct, the type, and the constructor
**File**: `lib/statifier/machine_state.ex`
**Changes**: add `round: 0` to `defstruct` (after `microstep:`), `round:
non_neg_integer()` to `@type t`, and `round: 0` to `new/2`'s literal.

#### 2. The writers
**File**: `lib/statifier/machine_state.ex`
**Changes**: `begin_macrostep/1` also resets `round`; a new `begin_round/1`
beside `begin_microstep/1`, with `@doc` and `@spec` (Doctor's thresholds are
100%, so both are required, not optional).

```elixir
def begin_macrostep(%__MODULE__{macrostep: macrostep} = machine_state) do
  %{machine_state | macrostep: macrostep + 1, microstep: 0, round: 0}
end

@doc """
Begins a new round of this macrostep's fold: increments `round` by one,
leaving `macrostep` and `microstep` unchanged. The only writer of `round`
(the counter contract above) - called once per
`Statifier.Interpreter.microstep/1` invocation, empty rounds and the
terminal probe included, which is the same definition of a round that
`max_macrostep_rounds` uses (ADR-0020).
"""
@spec begin_round(machine_state :: t()) :: t()
def begin_round(%__MODULE__{round: round} = machine_state) do
  %{machine_state | round: round + 1}
end
```

#### 3. The counter contract
**File**: `lib/statifier/machine_state.ex` (moduledoc, `:92-122`)
**Changes**: `new/2` sets three counters to zero; `begin_macrostep/1` resets
both child counters; a new bullet for `begin_round/1` stating that it is the
only writer of `round`, that its single call site is
`Statifier.Interpreter.microstep/1`'s head, that the first round of a macrostep
is round 1, that `round: 0` means "no round of this macrostep's fold has begun"
(which is what an external event's own `EventDequeued` and the initialization
entry are stamped with), and that a round is defined under
`max_macrostep_rounds: :infinity` because it counts up rather than deriving
from the budget. Extend the closing prohibition to name all three counters and
three writer functions. Cite ADR-0020.

#### 4. The `max_macrostep_rounds` typedoc
**File**: `lib/statifier/machine_state.ex:208-216`
**Changes**: one sentence noting that the `round` counter counts the same
rounds this budget bounds, so at exhaustion `round` equals the spent budget.

#### 5. Contract tests
**File**: `test/statifier/machine_state_test.exs` (beside the existing counter
tests around `:375-420`)
**Changes**: `new/2` starts at `round: 0`; `begin_round/1` increments by one
and leaves `macrostep`/`microstep` alone; `begin_microstep/1` does not touch
`round`; `begin_macrostep/1` resets a non-zero `round` to `0`.

**File**: `test/statifier/machine_state_acceptance_test.exs:75-85`
**Changes**: add `:round` to the expected field list.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (use `mix quality --profile loop` between
      edits; a loop run alone does not satisfy this phase).
- [x] `mix test test/statifier/machine_state_test.exs
      test/statifier/machine_state_acceptance_test.exs` passes.
- [x] Every new test in this phase carries a `# sabotage: ... -> red` line;
      suggested mutations: `begin_round/1` returns `machine_state` unchanged;
      `begin_macrostep/1` drops its `round: 0` reset; `begin_microstep/1` also
      increments `round`.

#### Manual Verification:
- [ ] Spec conformance: the touched functions still match the W3C Appendix D
      pseudocode line for line - `begin_round/1` is a new hoisting artifact
      with no pseudocode counterpart (ADR-0002, comment owed in Phase 2), and
      no ported procedure changed.
- [ ] The counter contract prose reads as one contract over three counters, not
      two plus an appendix.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: `begin_round/1` at the head of `microstep/1`

### Overview

The single call site, its ADR-0002 comment, and the documentation that names
three counters. After this phase `machine_state.round` is real and observable
on any returned position - including the exhausted one - even though nothing is
stamped with it yet.

### Changes Required:

#### 1. The call site
**File**: `lib/statifier/interpreter.ex:320-332`
**Changes**: both clauses of `microstep/1` begin the round, with the
mechanical-reason comment above them.

```elixir
# ADR-0002 mechanical deviation (ADR-0020). Appendix D's inner loop carries
# `macrostepDone` and no round variable of any kind - the REC's Termination
# note describes a non-terminating macrostep as "an infinitely long sequence
# of microsteps", which is this port's rounds, not its microsteps. The
# ordinal is therefore a hoisting artifact of `microstep/1` itself, like the
# two counters before it: it labels the position a stepper resumes from
# (constraint 1) so that a fold whose rounds advance neither counter is still
# ordered and countable (ADR-0012 item 4). It decides nothing - the budget,
# not the ordinal, ends the fold - and the loop's condition and body are
# unchanged. It lives here rather than in the fold so a human hand-stepping
# in iex advances it identically to `macrostep/1`; both clauses count,
# because both are a round the fold spends.
def microstep(%MachineState{running: false} = machine_state),
  do: {:quiescent, MachineState.begin_round(machine_state), []}

def microstep(%MachineState{} = machine_state) do
  machine_state = MachineState.begin_round(machine_state)
  {machine_state, eventless_transitions} = Selection.select_eventless_transitions(machine_state)
  ...
```

#### 2. Interpreter documentation
**File**: `lib/statifier/interpreter.ex` (moduledoc "Counters", `:43-81`; the
"Deviations" list, `:82-125`; `microstep/1`'s own `@doc`, `:274-332`)
**Changes**: name `round`'s writer and its one call site alongside the other
two; state that `handle_event/2`'s pre-fold effects are stamped `round: 0` for
the same reason they are stamped `microstep: 0`; add the round ordinal to the
deviations list pointing at the comment above; note in `microstep/1`'s `@doc`
that one call is one round and the returned position carries its number.

#### 3. Observability constraint 4, first bullet
**File**: `docs/observability.md` (constraint 4, the "two counters" bullet)
**Changes**: name three counters - macrostep, microstep within the macrostep,
and round within the macrostep - each advancing in exactly one place, with
`begin_macrostep/1` resetting both child counters. Cite ADR-0020. Leave the
trace and cause bullets for Phases 3 and 4.

#### 4. Wiring tests
**File**: `test/statifier/interpreter/microstep_test.exs`
**Changes**: one `microstep/1` call advances `round` by exactly one; a
non-running machine_state's `:quiescent` return also advances it.

**File**: `test/statifier/interpreter/macrostep_test.exs` (the round-budget
describe, `:271-387`)
**Changes**: after `Interpreter.macrostep/1` on the terminating `@document`
chain the returned `round` equals the number of rounds the fold made (three
rounds to quiescence plus the terminal probe - probe the running code for the
exact number rather than assuming it, as the existing exact-budget test did);
under `max_macrostep_rounds: :infinity` the ordinal still counts up; hand
-stepping `microstep/1` the same number of times from the same start position
yields the same `round` as the fold.

**File**: `test/statifier/interpreter/interpreter_acceptance_test.exs` (the
livelock describe, `:467-587`)
**Changes**: the exhausted position carries `round == 20` at
`max_macrostep_rounds: 20`, and after `handle_event/2` on that same exhausted
position the round restarts and reaches `20` again (the reset half of the
contract, on the one fixture where it is visible).

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (loop gate between edits only).
- [x] `mix test test/statifier/interpreter/` passes, including the existing
      budget and livelock tests unchanged in their existing assertions.
- [x] Every new test carries a `# sabotage: ... -> red` line; suggested
      mutations: `begin_round/1`'s call moved from `microstep/1`'s head into
      the private `macrostep/3` fold (the hand-step equivalence test reddens,
      the fold tests do not); the `running: false` clause drops its
      `begin_round/1` call (the terminal-probe count reddens).

#### Manual Verification:
- [ ] Spec conformance: `microstep/1`'s two clauses still match the pseudocode
      inner-loop body line for line; the only addition is the counter write,
      and its mechanical reason is stated inline per ADR-0002.
- [ ] In iex on the livelock document, `Interpreter.microstep/1` stepped by
      hand from a fresh position reports `round: 1, 2, 3, ...` and matches what
      the fold reports at the same depth (ADR-0019's resumable-position
      payoff).
- [ ] `docs/observability.md` constraint 4 reads correctly for the code as it
      stands after this phase - three counters, one writer each - with the
      trace and cause bullets still describing the pre-stamp reality.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 3: The seven trace payloads carry `round`

### Overview

Each `Effect.Trace.*` payload gains a third stamped key, in place. This is the
phase that meets the bead's acceptance criterion: a livelocked trace becomes
ordered and countable.

### Changes Required:

#### 1. The seven payload modules
**Files**: `lib/statifier/effect/trace/content_executed.ex`, `done.ex`,
`entry_set.ex`, `event_dequeued.ex`, `exit_set.ex`, `macrostep_stable.ex`,
`transitions_selected.ex`
**Changes**: identical edit in each - `:round` joins `@enforce_keys` and
`defstruct`, `round: non_neg_integer()` joins `@type t`, `new/2`'s head and
merge gain it, and the `new/2` doc line and the moduledoc's "Built with `new/2`
... stamped from the `MachineState` at hand" sentence name the three counters.

```elixir
@enforce_keys [:t_indexes, :macrostep, :microstep, :round]
defstruct [:t_indexes, :event, :macrostep, :microstep, :round]

def new(%MachineState{macrostep: macrostep, microstep: microstep, round: round}, fields) do
  struct!(
    __MODULE__,
    Keyword.merge(fields, macrostep: macrostep, microstep: microstep, round: round)
  )
end
```

#### 2. Effect vocabulary documentation
**File**: `lib/statifier/effect.ex` (moduledoc `:46-54` and `:89-92`)
**Changes**: "Every trace payload carries `macrostep`/`microstep`/`round`
(constraint 4)"; the `new/2` convention sentence names the third counter, and
one sentence records that the ordinal is the only counter that advances in a
round which runs no microstep - which is what makes a livelocked trace ordered
(ADR-0020).

#### 3. Observability constraint 4, trace bullet
**File**: `docs/observability.md`
**Changes**: the stamp is the `(macrostep, round)` ordering key, which advances
on every round including those that run no microstep, so a fold that never
reaches quiescence is still ordered and countable.

#### 4. Test ripples for construction literals
**File**: `test/statifier/effect/trace_test.exs`
**Changes**: the `ms/2` helper becomes `ms/3` (or gains a round argument) and
each of the seven `new/2` describes asserts the round stamp with a value
distinct from its `macrostep`/`microstep` so a mis-wired merge cannot pass by
coincidence.

**File**: `test/statifier/effect_test.exs` (`@trace_effects`, `:40-`)
**File**: `test/statifier/machine_state_acceptance_test.exs` (`@trace_effects`,
`:160-180`)
**Changes**: add `round: 0` to the seven trace literals in each list. The
`@core_effects` lists in both files are untouched - verify that by running the
suite, since untouched core literals are precisely what ADR-0020's
"other six core effects do not gain the field" is protecting.

#### 5. The acceptance test
**File**: `test/statifier/interpreter/interpreter_acceptance_test.exs` (the
livelock describe)
**Changes**: the bead's criterion, stated directly on the fixture.

```elixir
# sabotage: `MachineState.begin_round/1` returns `machine_state` unchanged
# (the pre-st-ux0 behavior) -> every round stamps `round: 0`, so the list
# below is twenty zeros instead of 1..20 and both assertions redden.
test "a livelocked trace orders its rounds and reports how many ran" do
  m = livelock_machine()

  {_result, effects} = Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)

  dequeued_rounds =
    for {:trace, %Effect.Trace.EventDequeued{from: :internal, round: round}} <- effects,
        do: round

  assert dequeued_rounds == Enum.to_list(1..20)
end
```

Plus, in the same describe, a test that the three effects of one round share
one ordinal and differ from the next round's (group the effect list by `round`
and assert the first two groups are equal in shape and distinct in ordinal -
this is the "diff one round against another" half), and in
`macrostep_test.exs`, a test that `Trace.MacrostepStable`'s `round` reports the
depth of a *stable* fold on the terminating `@document` chain, which is the
"engine-level, not livelock-specific" half of the bead's second criterion.

#### 6. The terminated fold's depth
**File**: `test/statifier/interpreter/termination_test.exs` (a new test beside
the existing `exit_interpreter/1 - Trace.Done` describe, `:217-`)
**Changes**: the existing describes call `Interpreter.exit_interpreter/1`
directly on a hand-built machine_state, so they never run a fold and would
report `round: 0` - which asserts nothing about depth. Add one test that drives
a chart all the way to a top-level `<final>` through the fold
(`Interpreter.initialize/2`, or `handle_event/2` on `macrostep_test.exs`'s
`@document` chain, which reaches `final1` on the `term` event) with
`trace: true`, and assert `Trace.Done`'s `round`. This is the one path where
the "both `microstep/1` clauses count" decision in Implementation Approach is
observable: the microstep that enters the `<final>` returns a plain tuple, so
the fold calls `microstep/1` once more and that `running: false` probe is the
last counted round. Probe the running code for the exact number rather than
deriving it - the same instruction the existing exact-budget test in
`macrostep_test.exs` followed - and record the observed value in the test's
comment.

```elixir
# sabotage: `microstep/1`'s `running: false` clause drops its
# `begin_round/1` call -> the terminated fold reports one round fewer than
# the number of `microstep/1` calls it made, reddening this assertion (and
# nothing else in the suite, since that clause is the only place a round
# runs no selection at all).
```

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (loop gate between edits only).
- [x] `mix test` passes, with `test/support/context_recorder.ex` and
      `test/support/test_content.ex` unmodified - their
      `%Effect.Log{macrostep: 0, microstep: 0}` literals must still compile.
- [x] `git diff --stat test/support/` is empty for this phase.
- [x] Every new or changed test carries a `# sabotage: ... -> red` line;
      suggested mutations beyond the one inlined above: one payload module's
      `new/2` hardcodes `round: 0` (its own `trace_test.exs` describe reddens
      and no other does).

#### Manual Verification:
- [ ] Spec conformance: no ported procedure changed in this phase; the trace
      payloads are ADR-0003 effect data, outside the Appendix D pseudocode.
- [ ] Read a `trace: true` livelock dump by hand at
      `max_macrostep_rounds: 20`: the rounds are visibly numbered, countable
      without counting lines, and round *n* diffs against round *n*+1 in
      exactly one field. This is the bead's acceptance criterion, judged by a
      reader rather than by an assertion.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 4: `%Event.Cause{}` and `%Effect.BudgetExhausted{}` carry `round`

### Overview

The two remaining stamp sites from ADR-0020's list, plus the changelog
fragment. After this phase every diagnostics surface the counters reach carries
the ordinal.

### Changes Required:

#### 1. `Cause`
**File**: `lib/statifier/event/cause.ex`
**Changes**: `:round` joins `@enforce_keys`, `defstruct`, and `@type t`;
`new/3` becomes `new/4` taking `round` last, with its `@doc`/`@spec` updated.
It stays a positional constructor taking plain values rather than a
machine_state: `MachineState` already calls `Cause.new/3` and pattern-matches
the counters out of its own struct head, and making `Cause` match
`%MachineState{}` would add a compile-time struct dependency back the other way
across a module pair that is currently one-directional.

#### 2. The two callers
**File**: `lib/statifier/machine_state.ex:349-358`, `:382-391`
**Changes**: `raise_internal/4` and `raise_platform/4` pattern-match `round:
round` out of the struct head alongside the two counters and pass it to
`Cause.new/4`. Their `@doc`s note the round is stamped as it stood at the raise
- same rule as the counters.

#### 3. `BudgetExhausted`
**File**: `lib/statifier/effect/budget_exhausted.ex`
**Changes**: `:round` joins `@enforce_keys`, `defstruct`, and `@type t`; the
moduledoc records that `round` is the rounds-spent count, always equal to
`budget` on this path, and that it is carried by the stamp rather than by a
separate `rounds_spent` field (ADR-0020).

**File**: `lib/statifier/interpreter.ex:404-415`
**Changes**: `terminal_effects/2`'s `:exhausted` clause adds `round:
machine_state.round`.

#### 4. Observability constraint 4, cause bullet
**File**: `docs/observability.md`
**Changes**: internally raised events carry cause metadata naming which node
raised them, at which step *and round*.

#### 5. Tests
**File**: `test/statifier/event/cause_test.exs`
**Changes**: the four `new/3` tests become `new/4`, each with a round value
distinct from its two counters (so an argument-order slip cannot pass), and the
sabotage lines become the corresponding three-way swap.

**Files**: `test/statifier/event_test.exs:7`,
`test/statifier/evaluator/system_variables_test.exs:91`,
`test/statifier/machine_state_acceptance_test.exs:127`,
`test/statifier/machine_state_test.exs:273`, `:391`
**Changes**: five further `Cause.new/3` call sites that the research document's
test-surface section did not name (it listed `cause_test.exs` only). `Cause` is
built through a function rather than a struct literal, so an arity change
breaks all of them at compile time, not just the four assertion sites. Four
pass a fixture cause and only need the fourth argument added;
`machine_state_test.exs:391` asserts `cause == Cause.new(origin, ms.macrostep,
ms.microstep)` against a machine_state-derived cause and must gain
`ms.round` in the same position, or the assertion becomes a tautology-free but
wrong comparison. The `grep -rn "Cause.new(" lib/ test/` criterion below is the
backstop, not the discovery mechanism.

**File**: `test/statifier/effect_test.exs`,
`test/statifier/machine_state_acceptance_test.exs`
**Changes**: add `round: 0` to the `%BudgetExhausted{}` literal in each
`@core_effects` list. These are the only two core-effect literals that change
in this plan; the other six core payloads stay untouched.

**File**: `test/statifier/interpreter/interpreter_acceptance_test.exs` (the
livelock describe)
**Changes**: two tests.

```elixir
# sabotage: `terminal_effects/2`'s `:exhausted` clause stamps
# `round: machine_state.microstep` instead of `machine_state.round` -> the
# depth assertion reddens (microstep is 1 here, the depth is 20).
test "the exhausted effect reports how deep the fold got" do
  m = livelock_machine()

  {_result, effects} = Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)

  assert %Effect.BudgetExhausted{round: 20, budget: 20} = budget_exhausted(effects)
end
```

and one that the causes are no longer identical: collect
`%Event.Cause{round: r}` from each dequeued `error.execution` in the trace,
assert the collected rounds are strictly ascending, twenty distinct values, and
start at `1`. Assert those three properties rather than a fixed
cause-round-to-dequeue-round offset: on this fixture the raise and the dequeue
fall in the same round (the probe raises and `internal_round/1` drains it
before the round ends), while ADR-0020's worked example of a raise in round *k*
dequeued in round *k*+1 describes a shape where the queue does not drain in
one round. The three properties are what the bead asks for and hold under both.
Confirm the actual relation against the running interpreter while implementing
and record it in the test's comment, the way the existing
`pending_internal_events` test in this describe records its own verified
observation.

#### 6. Changelog fragment
**File**: `changelog.d/st-ux0.md`
**Changes**: this qualifies under `changelog.d/README.md` - it is a public API
addition and a change in observable behavior, on the same footing as
`changelog.d/st-sd1.md`, which took a fragment for `:max_macrostep_rounds` and
the `BudgetExhausted` effect.

```markdown
### Added

- `%Statifier.MachineState{}` carries a `round` counter, and the seven
  `Statifier.Effect.Trace.*` payloads, `%Statifier.Event.Cause{}`, and
  `%Statifier.Effect.BudgetExhausted{}` are stamped with it, so the rounds of
  a macrostep that never reaches quiescence can be ordered and counted in a
  trace.
```

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (loop gate between edits only).
- [x] `mix test` passes; `changelog.d/st-ux0.md` exists.
- [x] `grep -rn "Cause.new(" lib/ test/` shows no remaining `new/3` call.
- [x] Every new or changed test carries a `# sabotage: ... -> red` line.

#### Manual Verification:
- [ ] Spec conformance: `terminal_effects/2` and the two raise functions still
      match their pseudocode counterparts - the raise sites are ADR-0002
      hoists that already existed, and only the stamped field set changed.
- [ ] An `error.execution` message built from a cause reads correctly with the
      round included, and constraint 4's exemplar ("raised by the `<assign>` at
      line 42, transition 7, microstep 3") still parses as a sentence with the
      round added.
- [ ] The changelog fragment reads as one line a library user would care about,
      per `changelog.d/README.md`'s "too much" example.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/machine_state_test.exs` - the counter contract for `round`:
  `new/2` default, `begin_round/1` increments only `round`, `begin_microstep/1`
  leaves it alone, `begin_macrostep/1` resets it (Phase 1).
- `test/statifier/machine_state_acceptance_test.exs` - `:round` in the field
  list (Phase 1) and `round: 0` in the vocabulary literals (Phases 3, 4).
- `test/statifier/effect/trace_test.exs` - the round stamp in all seven `new/2`
  describes, with a value distinct from the two counters (Phase 3).
- `test/statifier/event/cause_test.exs` - `new/4` with three distinct values
  (Phase 4), plus the five other `Cause.new/3` call sites listed in Phase 4,
  which are compile-time breakage rather than new coverage.
- `test/statifier/interpreter/termination_test.exs` - `Trace.Done`'s round on a
  fold that terminates, driven through the fold rather than by calling
  `exit_interpreter/1` directly (Phase 3).
- `test/statifier/interpreter/microstep_test.exs` - one call, one round, on
  both clauses (Phase 2).
- `test/statifier/interpreter/macrostep_test.exs` - the fold's depth on a
  terminating chart, under a finite budget and under `:infinity`;
  `MacrostepStable`'s round (Phases 2, 3).
- `test/statifier/interpreter/interpreter_acceptance_test.exs` - the livelock
  fixture: the exhausted position's round and its reset on the next macrostep
  (Phase 2), the ordered-and-countable trace (Phase 3), the exhausted effect's
  depth and the distinct cause rounds (Phase 4).

Edge cases the tests must cover: `round: 0` on everything emitted before the
fold begins (`handle_event/2`'s `EventDequeued`, `initialize/2`'s entry
effects); the terminal probe counting as a round on both the quiescent path
(`Trace.MacrostepStable`) and the terminated path (`Trace.Done`, where the
extra `running: false` probe round is the only place that clause's own
increment is observable); `:infinity`, where no
`budget - rounds_left` derivation exists; and the second macrostep on an
already-exhausted position, which is the only place the reset is observable.

Every new test asserting `lib/` behavior carries its `# sabotage: <mutation>
-> red` line per `docs/testing.md`, verified by actually running the mutation.
No test in this plan is harness plumbing, so no exemption line applies.

**Ratchet**: no conformance impact. `test/passing_tests.json` is a registry of
test identifiers with no coupling to struct shapes (research section 6), and no
phase here changes which SCXML documents interpret correctly, so
`mix test.regression` should be unchanged throughout and no
`mix test.baseline add` is expected. If a conformance test does move, that is a
signal something semantic changed and the phase is wrong.

### Manual Testing Steps:

1. Compile the livelock document from
   `test/statifier/interpreter/interpreter_acceptance_test.exs` in iex and run
   `Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)`; read the
   effect list and confirm the rounds are numbered 1..20 and that any two
   adjacent rounds differ only in the ordinal.
2. From the exhausted position, hand-step `Interpreter.microstep/1` three times
   and confirm `round` continues 21, 22, 23 - the resumed position keeps
   counting, which is ADR-0020's argument for putting the ordinal on the
   struct.
3. Send an external event to the exhausted position with
   `Interpreter.handle_event/2` and confirm the `EventDequeued` it emits is
   stamped `round: 0`, then the fold's first round is 1.
4. Run a terminating chart to quiescence with `trace: true` and read
   `Trace.MacrostepStable`'s round as the fold's depth.
5. Run the same terminating chart with `max_macrostep_rounds: :infinity` and
   confirm the ordinal still counts.

## Performance Considerations

One integer increment per round on top of ADR-0019's decrement, and one small
integer on each trace payload, `%Event.Cause{}`, and
`%Effect.BudgetExhausted{}`. Nothing changes when `trace: false` beyond the
increment itself: `Effect.trace/3`'s gate still builds no payload, and the
other six core effects are untouched.

## References

- Bead: `st-ux0`
- Source document: `docs/research/260813-st-ux0-livelock-round-trace-identity.md`
- Decision: `docs/adr/0020-round-ordinal-joins-the-step-counters.md` (accepted;
  amends ADR-0019 in part)
- Related ADRs: `docs/adr/0019-macrostep-round-budget.md` (the budget and the
  fold-local accumulator), `docs/adr/0012-debuggability-designed-into-the-core.md`
  (item 4, the promise this restores), `docs/adr/0002-*` (mechanical deviations
  need an inline reason), `docs/adr/0003-*` (effects out, never side effects)
- Binding detail: `docs/observability.md` constraints 1 and 4
- Prior plan for the budget: `docs/plans/260812-st-sd1-macrostep-round-budget.md`
  (its Deferred Manual Verification section is where this bead was filed)
- The counter contract: `lib/statifier/machine_state.ex:92-122`
- The stamping paths: `lib/statifier/effect.ex:150-160`,
  `lib/statifier/machine_state.ex:349-358`, `:382-391`
- The livelock fixture:
  `test/statifier/interpreter/interpreter_acceptance_test.exs:463-587`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Spec conformance: the touched functions still match the W3C Appendix D
      pseudocode line for line - `begin_round/1` is a new hoisting artifact
      with no pseudocode counterpart (ADR-0002, comment owed in Phase 2), and
      no ported procedure changed.
- [ ] The counter contract prose reads as one contract over three counters, not
      two plus an appendix.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 2

- [ ] Spec conformance: `microstep/1`'s two clauses still match the pseudocode
      inner-loop body line for line; the only addition is the counter write,
      and its mechanical reason is stated inline per ADR-0002.
- [ ] In iex on the livelock document, `Interpreter.microstep/1` stepped by
      hand from a fresh position reports `round: 1, 2, 3, ...` and matches what
      the fold reports at the same depth (ADR-0019's resumable-position
      payoff).
- [ ] `docs/observability.md` constraint 4 reads correctly for the code as it
      stands after this phase - three counters, one writer each - with the
      trace and cause bullets still describing the pre-stamp reality.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 3

- [ ] Spec conformance: no ported procedure changed in this phase; the trace
      payloads are ADR-0003 effect data, outside the Appendix D pseudocode.
- [ ] Read a `trace: true` livelock dump by hand at
      `max_macrostep_rounds: 20`: the rounds are visibly numbered, countable
      without counting lines, and round *n* diffs against round *n*+1 in
      exactly one field. This is the bead's acceptance criterion, judged by a
      reader rather than by an assertion.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 4

- [ ] Spec conformance: `terminal_effects/2` and the two raise functions still
      match their pseudocode counterparts - the raise sites are ADR-0002
      hoists that already existed, and only the stamped field set changed.
- [ ] An `error.execution` message built from a cause reads correctly with the
      round included, and constraint 4's exemplar ("raised by the `<assign>` at
      line 42, transition 7, microstep 3") still parses as a sentence with the
      round added.
- [ ] The changelog fragment reads as one line a library user would care about,
      per `changelog.d/README.md`'s "too much" example.
- [ ] No regressions in related features.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---
