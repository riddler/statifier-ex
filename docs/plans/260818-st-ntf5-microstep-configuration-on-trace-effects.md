# Microstep Configuration on the Trace Effects Implementation Plan

## Overview

`Statifier.Effect.Trace.EntrySet` and `Statifier.Effect.Trace.ExitSet` gain a
`configuration` field carrying the full configuration (ADR-0005, interned
indexes, ancestors included) *as it stands after* the mutation each trace
names - post-entry for `EntrySet`, post-exit for `ExitSet`, at all three
emission sites including `exit_interpreter/1`'s whole-configuration sweep.
That makes every microstep self-contained on the trace stream, so a consumer
redrawing the diagram per microstep no longer has to reimplement the fold.
Bead: st-ntf5 (mirrors statifier-ui `sui-t36.1`, GAP 7).

## Current State Analysis

**What carries a configuration today.** Three payloads:
`Statifier.Effect.Trace.MacrostepStable` (`lib/statifier/effect/trace/macrostep_stable.ex:24`),
`Statifier.Effect.Trace.Done`, and `Statifier.Effect.BudgetExhausted`. All
three are macrostep- or run-granular. Nothing on the stream is
microstep-granular.

**The two payloads to change.**
`lib/statifier/effect/trace/entry_set.ex` and
`lib/statifier/effect/trace/exit_set.ex` are structurally identical: fields
`indexes`/`macrostep`/`microstep`/`round`, all four in `@enforce_keys`, built
only through `new/2`, which stamps the three counters from the
`%Statifier.MachineState{}` handed to it. `MacrostepStable` is the precedent
for the field: `configuration: MapSet.t(non_neg_integer())`, also enforced.

**The three emission sites** (grep for `Effect.Trace.ExitSet` /
`Effect.Trace.EntrySet` over `lib/` returns exactly these, and no others):

1. `Statifier.Interpreter.ExitEntry.exit_states/2`,
   `lib/statifier/interpreter/exit_entry.ex:138` - the trace is built from
   `machine_state` *before* `record_history_values/2` and before the
   `depart/2` reduce that removes each exiting state from the configuration
   (`exit_entry.ex:221-224`).
2. `Statifier.Interpreter.ExitEntry.enter_states/2`,
   `lib/statifier/interpreter/exit_entry.ex:679` - built from `machine_state`
   before the `arrive/3` reduce that adds each entering state
   (`exit_entry.ex:707-710`).
3. `Statifier.Interpreter.exit_interpreter/1`,
   `lib/statifier/interpreter.ex:1643` - built before the termination sweep
   that empties the configuration state by state
   (`lib/statifier/interpreter.ex:1665`).

At all three sites the returned effect list is assembled at the end
(`trace_effects ++ depart_effects`, `trace_effects ++ arrive_effects`,
`exit_set_trace ++ exit_effects ++ done_trace ++ [done_effect]`), so **moving
the `Effect.trace/3` call below the reduce does not move the effect in the
list.**

**The crux, and the ADR-0012 constraint on it.** The bead wants the
*resulting* configuration, which only exists after the mutation; the counters
must keep coming from the pre-mutation state. The repo has already judged
exactly this shape, twice, as ADR-judge fixtures over this very function:

- `test/fixtures/adr_judge/0012_trace_after_departure.diff`, `expect:
  :violation` - the trace call moves below the departure reduce and is
  stamped against the post-reduce `machine_state`. Manifest note
  (`test/fixtures/adr_judge/manifest.exs:46-53`): "it no longer records the
  exit-set phase boundary it names and any state-derived field it stamps
  would take post-departure values".
- `test/fixtures/adr_judge/0012_trace_prestate_captured.diff`, `expect:
  :clean` - the same move, but stamped against `pre_exit_state`, a binding
  captured before the reduce. Manifest note (`manifest.exs:54-61`): "the
  state it is stamped against is the same one the unmoved call read".

So the sanctioned pattern is fixed and this plan does not get to invent one:
capture the pre-mutation binding, move the call below the mutation, stamp
from the captured binding, and take *only* the new `configuration` field from
the post-mutation state.

**Test-side blast radius of a new enforced key.** No test asserting on these
payloads matches all fields at once, so assertions are safe; but a number of
tests build `%Trace.ExitSet{}` / `%Trace.EntrySet{}` struct literals by hand
and would fail to construct. Every such site:
`test/statifier/machine_state_acceptance_test.exs:208,217`,
`test/statifier/session/effects_test.exs:325-326,346-347`,
`test/statifier/session/telemetry_test.exs:206,216,729,818,827,838,860,869,880`,
`test/statifier/effect_test.exs:96,105`, and the full-field *match* patterns
in `test/statifier/effect/trace_test.exs:66,90`.

**Telemetry.** `Statifier.Session.Telemetry.trace_shape/2` gives
`Trace.ExitSet` and `Trace.EntrySet` `{counters + size, %{}}`
(`lib/statifier/session/telemetry.ex:608-620`), and the whole payload struct
already rides in `metadata.effect`, so the new field reaches a telemetry
consumer with no code change. `Trace.MacrostepStable`'s clause
(`telemetry.ex:621-623`) carries a `configuration` on its payload and
deliberately does *not* resolve it into metadata; only `:done` does
(`telemetry.ex:625`), and ADR-0040 explains why - `MachineState.configuration`
is already empty when `:done` is emitted, so it is otherwise unobtainable.

## Desired End State

`Trace.EntrySet` and `Trace.ExitSet` each carry `configuration`, a
`MapSet.t(non_neg_integer())` holding the full configuration after the entry
or exit the payload describes, at all three emission sites. A consumer holding
only the trace stream can render the active configuration after every
microstep without folding deltas and without reimplementing
`exit_interpreter/1`'s sweep or the parallel entry ordering.

Verified by: a new acceptance test that drives a parallel-region chart from
`initialize/2` through to `exit_interpreter/1` and asserts, for the whole run,
that each `EntrySet`/`ExitSet` `configuration` equals the configuration folded
from that payload's own `indexes` onto the previous payload's `configuration`
- i.e. the fold a consumer would have written, now redundant - and that the
last `ExitSet` (from `exit_interpreter/1`) carries the empty set.

### Key Discoveries:

- The three emission sites are exactly
  `lib/statifier/interpreter/exit_entry.ex:138`,
  `lib/statifier/interpreter/exit_entry.ex:679`, and
  `lib/statifier/interpreter.ex:1643`. Nothing else in `lib/` emits either
  payload.
- Effect list position is unaffected by moving the `Effect.trace/3` call,
  because all three sites concatenate at the end of the function.
- The clean/violation pattern for "trace below the mutation" is already
  settled by `test/fixtures/adr_judge/0012_trace_prestate_captured.diff`
  (clean) and `0012_trace_after_departure.diff` (violation). ADR-0012's own
  fixtures quote `exit_states/2` and will need re-anchoring, exactly as
  commit `b3fa844` re-anchored them after a rebase moved the same lines.
- `Effect.trace/3` (`lib/statifier/effect.ex`) binds its machine_state
  argument once and splices `fields` lazily inside the `if`, so
  `configuration: machine_state.configuration` is not evaluated at all under
  `trace: false`. The untraced hot path stays free.
- The field name is `configuration`, not `resulting_configuration`: it matches
  `MacrostepStable`/`Done`/`Effect.Done`, and it is the name the originating
  research asks for (statifier-ui
  `docs/research/260816-sui-t36.1-trace-coverage-spike.md`, GAP 7: "A
  `configuration` field on `EntrySet` (post-entry) and `ExitSet`
  (post-exit)"). The post-mutation semantics are carried by the moduledoc,
  not by the field name.
- Wire format is interned indexes, not ids: statifier-ui ADR-0005 commits to
  indexes plus a definition message, so no id resolution is owed to the UI
  consumer (confirmed by re-reading `sui-t36.1`, closed 2026-08-17).
- ADR-0005 (full configuration, ancestors included) fixes what "the
  configuration" means here: `machine_state.configuration` verbatim, not a
  leaf-state view.
- `docs/observability.md`'s constraint 2 says the trace *set* is the
  commitment and the *shapes* are "settled at implementation", so widening a
  payload is not an ADR amendment.

## What We're NOT Doing

- **Not deriving the resulting configuration by set algebra.** The obvious
  alternative - keep the trace call where it is and compute
  `MapSet.difference(configuration, MapSet.new(states_to_exit))` /
  `MapSet.union(configuration, MapSet.new(entry_order))` - would need no code
  movement and no fixture re-anchoring. It is rejected because it
  reimplements `depart/2`/`arrive/3`'s configuration bookkeeping a second
  time, inside the engine, which is a smaller version of the very duplication
  the bead exists to remove: the day either reduce touches the configuration
  differently, the trace silently lies. Reading the post-mutation
  `machine_state.configuration` cannot drift.
- **Not changing `Statifier.Session.Telemetry`.** No new `trace_shape/2`
  metadata key for `:entry_set`/`:exit_set`. Three reasons: `MacrostepStable`
  is the standing precedent for a configuration-bearing payload whose
  telemetry clause resolves nothing; ADR-0040's original list-carrying rule
  names an "O(configuration) `Machine` walk on every microstep" as the cost
  it declines to pay, and resolving a whole configuration per microstep is
  literally that walk (unlike the singleton case its later amendments
  argued over); and under the st-cmq.2 shape freeze, adding a metadata key
  later is additive while removing one is breaking, so the reversible
  direction wins. The raw payload still reaches telemetry consumers under
  `metadata.effect`.
- **Not adding a new ADR-judge fixture pair.** The new failure mode this
  change makes possible ("`configuration` read from the pre-mutation binding,
  so the field lies about being the *resulting* one") would make a defensible
  subtle pair, but a new pair obliges a real-`claude` measurement pass against
  the corpus scorecard that st-2ts owns, and this branch is not the place to
  spend that. Phase 3 re-anchors the two existing fixtures without moving
  either one's meaning, which is what keeps st-2ts's recorded measurement
  standing. Filing the new pair is recorded under Open Questions as follow-up
  work for st-2ts's corpus.
- **Not amending ADR-0012 or ADR-0005.** Neither decision changes; both are
  cited.
- **Not amending ADR-0040 either, but only after checking its own trigger.**
  ADR-0040's Consequences section
  (`docs/adr/0040-session-telemetry-event-contract.md:449-456`) names "a field
  being added to, removed from, or renamed on any
  `Statifier.Effect.*`/`Statifier.Effect.Trace.*` struct" as one of the three
  things that would reopen that record, because the raw struct rides verbatim
  in every event's `effect` metadata key. This change is exactly that trigger,
  so it is checked rather than passed over. It does not reopen the record, for
  the reason the clause itself supplies: the concern is the st-cmq.2
  breaking-change argument, and *adding* a field is additive - no `trace_shape/2`
  clause changes, no event name or measurement changes, no metadata key is
  removed or renamed, and no subscriber reading a field off `effect` today
  reads a different value tomorrow. A removal or a rename would reopen it; an
  addition is the same non-breaking direction the record's own reversibility
  argument favours. A reviewer who disagrees should say so on the bead before
  Phase 1 lands, since the amendment would be a direction-level call rather
  than a plan edit.
- **Not touching the conformance corpus or the regression ratchet.** No
  SCXML semantics change - the payloads are observation only - so
  `test/passing_tests.json` cannot move.
- **Not adding a configuration to any other trace payload.**
  `TransitionsSelected`, `ContentExecuted`, `InvokePass`,
  `FinalizeAutoforward`, and `EventDequeued` are out of scope; the bead names
  the two set payloads that bracket a microstep, and those two are sufficient
  to make each microstep self-contained.

## Implementation Approach

Three phases, in dependency order, each independently committable and each
green on a bare `mix quality` on its own.

Phase 1 is necessarily atomic: adding an `@enforce_keys` field breaks every
struct-literal construction site at once, so the struct change, the three
emission sites, their moduledocs, the per-site unit assertions, the literal
fix-ups, and the user-facing docs land together. Phase 2 adds the bead's
acceptance test, which needs a chart fixture no existing test file has (a
parallel region driven all the way through `exit_interpreter/1`). Phase 3
re-anchors the ADR-0012 judge fixtures against the moved source, which is
only meaningful once the source has moved.

Per `.claude/wurk/plan.md`'s Appendix D rule: **this change introduces no new
deviation from the Appendix D pseudocode.** Appendix D's `exitStates`,
`enterStates`, and `exitInterpreter` contain no trace emission at all -
tracing is this port's ADR-0012 addition, already a documented mechanical
extension - so moving the emission point of a non-pseudocode statement is not
a reordering of any pseudocode statement. The pseudocode-ordered numbered
lists in the three moduledocs are the record of that, and Phase 1 updates
them so the record stays true.

---

## Phase 1: Carry the resulting configuration on both payloads

### Overview

Add the enforced `configuration` field to both payload structs, populate it
at all three emission sites using the ADR-0012-sanctioned pre-state capture,
update every moduledoc that describes the emission ordering, repair the
struct-literal construction sites in the test suite, and add one unit
assertion per emission site.

### Changes Required:

#### 1. The two payload structs

**File**: `lib/statifier/effect/trace/exit_set.ex`
**Changes**: add `:configuration` to `@enforce_keys`, `defstruct`, and
`@type t()` as `MapSet.t(non_neg_integer())`; extend `new/2`'s `@doc` to name
the field. Extend the moduledoc to say what the field means and, crucially,
that it is the one field read *after* the exit while the counters are stamped
before it, and that at `exit_interpreter/1` it is the empty set.

```elixir
  @enforce_keys [:indexes, :configuration, :macrostep, :microstep, :round]
  defstruct [:indexes, :configuration, :macrostep, :microstep, :round]

  @type t :: %__MODULE__{
          indexes: [non_neg_integer()],
          configuration: MapSet.t(non_neg_integer()),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }
```

Moduledoc addition, in substance: `configuration` is the full configuration
(ADR-0005, ancestors included) as it stands *after* every state in `indexes`
has left it, so a consumer can render the configuration per microstep without
folding deltas (st-ntf5). It is deliberately the only field taken from the
post-exit state; `macrostep`/`microstep`/`round` are stamped from the state as
it stood at the phase boundary the payload names, which is what keeps this
payload an "exit set" marker rather than an after-the-fact report
(`test/fixtures/adr_judge/0012_trace_prestate_captured.diff` is the sanctioned
shape). At `Statifier.Interpreter.exit_interpreter/1` the sweep empties the
configuration, so `configuration` is `MapSet.new()` there - which is the true
resulting configuration and not a missing value; `Trace.Done.configuration`,
which carries the configuration as it stood *at* exit, is the payload that
answers "what was active when the run ended".

**File**: `lib/statifier/effect/trace/entry_set.ex`
**Changes**: the same three-line struct change, and the mirror moduledoc:
`configuration` is the full configuration after every state in `indexes` has
been added, including the parallel entry ordering `enter_states/2` performs.

#### 2. `exit_states/2`

**File**: `lib/statifier/interpreter/exit_entry.ex` (around `:138`)
**Changes**: capture the pre-exit binding, move the `Effect.trace/3` call
below the `depart/2` reduce, stamp from the captured binding, and read
`configuration` from the post-reduce state. The returned list is unchanged.

```elixir
    states_to_exit = Machine.exit_order(machine, exit_set)

    # ADR-0012: the counters this payload stamps must be the ones that stood
    # at the exit-set phase boundary, so the trace is stamped against
    # `pre_exit_state`; only `configuration` is read from the post-departure
    # state, because "the configuration after this exit set was applied" does
    # not exist until the reduce below has run (st-ntf5). Effect-list
    # position is unchanged: the list is concatenated at the end either way.
    pre_exit_state = machine_state

    machine_state = record_history_values(machine_state, states_to_exit)

    {machine_state, depart_effects} =
      Enum.reduce(states_to_exit, {machine_state, []}, fn state_index, {ms, effects} ->
        {ms, new_effects} = depart(ms, state_index)
        {ms, effects ++ new_effects}
      end)

    trace_effects =
      Effect.trace(pre_exit_state, Effect.Trace.ExitSet,
        indexes: states_to_exit,
        configuration: machine_state.configuration
      )

    {machine_state, trace_effects ++ depart_effects}
```

Also rewrite the numbered moduledoc body: today's items 4-6 describe the
trace as emitted between the `states_to_invoke` update and
`record_history_values/2`. They become: history recording, then the departure
reduce, then the trace built from the captured pre-exit binding with the
post-departure configuration - stating explicitly that the payload's position
in the returned list is unchanged.

#### 3. `enter_states/2`

**File**: `lib/statifier/interpreter/exit_entry.ex` (around `:679`)
**Changes**: the mirror change - `pre_entry_state = machine_state` before the
`arrive/3` reduce, the `Effect.trace/3` call moved below it with
`configuration: machine_state.configuration`, and moduledoc item 3 rewritten
(it currently reads "before any mutation, over the *original*
`machine_state`", which stops being true).

#### 4. `exit_interpreter/1`

**File**: `lib/statifier/interpreter.ex` (around `:1643`)
**Changes**: `configuration_at_exit` already exists as the pre-sweep capture
for `Trace.Done`/`Effect.Done`, but the *counters* still need a pre-sweep
`%MachineState{}` binding, so capture one (`pre_exit_state = machine_state`)
and move the `exit_set_trace` assignment below the reduce with `configuration:
machine_state.configuration`. Do not hardcode `MapSet.new()` even though the
sweep provably empties the configuration - read it from the post-sweep state
so the field cannot drift from the walk. Effect-list position is unchanged
(`exit_set_trace ++ exit_effects ++ done_trace ++ [done_effect]`). Update
numbered item 2 of the moduledoc, which describes the emission as happening
"before any state leaves", and add a sentence distinguishing the new empty
`ExitSet.configuration` from `Trace.Done.configuration`.

#### 5. Struct-literal construction sites in the suite

**Files**: `test/statifier/machine_state_acceptance_test.exs:208,217`;
`test/statifier/session/effects_test.exs:325-326,346-347`;
`test/statifier/session/telemetry_test.exs:206,216,729,818,827,838,860,869,880`;
`test/statifier/effect_test.exs:96,105`;
`test/statifier/effect/trace_test.exs:66,90`
**Changes**: add `configuration: MapSet.new([...])` to each literal. These are
fixtures for unrelated behavior (telemetry shaping, effect classification,
session effect handling), so the value only has to be a plausible index set;
do not turn them into assertions about configuration. The full-field *match*
patterns in `trace_test.exs` should gain the field so the match stays a
complete description of the payload.

#### 6. Per-site unit assertions

**Files**: `test/statifier/interpreter/exit_entry_exit_test.exs`,
`test/statifier/interpreter/exit_entry_enter_test.exs`,
`test/statifier/interpreter/termination_test.exs`
**Changes**: one test each, modelled on
`test/statifier/interpreter/macrostep_test.exs:173-185` (the
`MacrostepStable.configuration` assertion), extracting the payload with the
`for {:trace, %Mod{} = payload} <- effects, do: payload` comprehension these
files already use:

- `exit_entry_exit_test.exs`: `ExitSet.configuration` equals the starting
  configuration minus `indexes`, and its counters equal the *pre-call*
  machine_state's counters (the second assertion is what catches a regression
  to the `0012_trace_after_departure.diff` shape).
- `exit_entry_enter_test.exs`: `EntrySet.configuration` equals the returned
  `machine_state.configuration`, over a chart where `arrive/3` enters more
  than one state.
- `termination_test.exs`: the `ExitSet` from `exit_interpreter/1` carries
  `configuration == MapSet.new()` while the `Trace.Done` in the same effect
  list carries the non-empty configuration as it stood at exit - one test
  asserting both, since the pair is the distinction the moduledoc makes.

Each new test carries a `# sabotage:` line in the style these files already
use (a named mutation, an `->`, and the assertion it reddens), e.g.
`# sabotage: exit_states/2 stamps configuration from pre_exit_state instead of
the post-departure machine_state -> the exited states are still present and
the assertion reddens.` Break the code, confirm red, revert, and keep the
line.

#### 7. Documentation and changelog

**File**: `docs/observability.md`
**Changes**: under constraint 2's Rules list, add a rule stating that the
"exit set" and "entry set" rows carry the resulting configuration (post-exit
and post-entry respectively, ADR-0005 full configuration), so a consumer
rendering per microstep does not fold deltas and does not re-derive
`exit_interpreter`'s whole-configuration sweep. Keep the table's "before
exiting"/"before entering" wording, which still describes the boundary; say
in the new rule that the boundary is where the payload is stamped and the
configuration is what the boundary produced.

**File**: `lib/statifier/effect.ex`
**Changes**: no vocabulary-table change (the set of effects is unchanged). If
the "Trace effects carry indexes and counters, never structs" section reads as
an exhaustive field list on inspection, add `configuration` to it as another
constraint-3 identity set; otherwise leave it.

**File**: `changelog.d/st-ntf5.md` (new)
**Changes**: warranted - a public payload gains a field and the observable
trace stream changes, and v1 had no trace stream at all
(`changelog.d/README.md`'s "write a fragment when v2 differs from v1"). One
`### Added` entry naming both payloads, the field, its post-mutation
semantics, and the `exit_interpreter/1` empty-set case.

No `docs/quality-gate-changes.md` entry is needed: this branch touches none of
the guarded paths (`.quality.exs`, `.credo.exs`, `coveralls.json`,
`.sobelow-conf`, `.doctor.exs`, gate-relevant `mix.exs` lines), adds no
`@tag :skip`, and does not shrink `test/passing_tests.json`.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` green between edits (iteration command, not
      the phase gate).
- [x] Full `mix quality` green, and `mix gate.verify` exits zero proving the
      run was unprofiled, unscoped, and unskipped.
- [x] `grep -rn "Effect.Trace.EntrySet\|Effect.Trace.ExitSet" lib/` shows the
      new `configuration:` field at all three emission sites and nowhere else
      emitting these payloads.
- [x] Doctor stage green (100% thresholds) - the two payload moduledocs and
      `new/2` docs still document every public surface.
- [x] `mix test test/statifier/interpreter/exit_entry_exit_test.exs
      test/statifier/interpreter/exit_entry_enter_test.exs
      test/statifier/interpreter/termination_test.exs` green, with the three
      new tests present.
- [x] `mix test.regression` green - the ratchet is unchanged, and this proves
      no conformance test moved.

#### Manual Verification:
- [ ] Spec-conformance judgment: `exit_states/2`, `enter_states/2` and
      `exit_interpreter/1` still match the W3C Appendix D pseudocode line for
      line. Only the ADR-0012 trace statement moved, and Appendix D contains
      no trace statement, so no pseudocode statement was reordered - confirm
      by reading the three moduledoc numbered lists against
      `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/appendix-d.txt`.
- [ ] Each of the three new tests was actually sabotaged: the named mutation
      was applied, the test went red, and the change was reverted.
- [ ] Read the diff against
      `test/fixtures/adr_judge/0012_trace_prestate_captured.diff`: every moved
      call is stamped from a binding captured before the mutation, and only
      `configuration` reads the post-mutation state.
- [ ] No regressions in related features: trace effect ordering within a
      microstep is unchanged (the payload is still first in each function's
      returned list).

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: The parallel-region acceptance test

### Overview

The bead's acceptance criterion asks for one test specifically: that the
carried configuration matches the configuration folded from the deltas, across
a parallel-region chart, including `exit_interpreter`. No existing test file
drives a parallel chart through `exit_interpreter/1` - `termination_test.exs`'s
document has no `<parallel>`, and the two files that do have one
(`exit_entry_enter_test.exs:85-182`,
`exit_entry_acceptance_test.exs:42-93`) only call `ExitEntry` functions
directly on hand-built states. This phase adds that test.

### Changes Required:

#### 1. The acceptance test

**File**: `test/statifier/interpreter/exit_entry_acceptance_test.exs`
(this file already owns the cross-function acceptance assertions for this
area and already has a `<parallel>` document with a sibling top-level
`<final>`; extend it rather than creating a new file)
**Changes**: one test that

1. compiles a chart with a `<parallel>` of two regions, each with at least two
   states so entry ordering is observable, plus a sibling top-level `<final>`
   reachable by an event, written as a triple-quoted heredoc at 4-space base
   indentation per the project convention;
2. drives it with `Statifier.Interpreter.initialize/2` and then
   `handle_event/2` calls to completion, collecting the effect list from every
   drive in order (including the `exit_interpreter/1` effects the terminal
   drive produces);
3. filters the stream to the `EntrySet`/`ExitSet` payloads in arrival order;
4. folds independently: starting from `MapSet.new()`, for each payload in
   order apply `MapSet.union` for an `EntrySet`'s `indexes` and
   `MapSet.difference` for an `ExitSet`'s, and assert after each step that the
   fold equals that payload's own `configuration`;
5. asserts the terminal `ExitSet` (the `exit_interpreter/1` one) carries
   `MapSet.new()` and that the fold agrees;
6. asserts the last `EntrySet` before termination carries every state of both
   parallel regions plus their ancestors, which is the ADR-0005 full-
   configuration property and the part a delta-folding consumer gets wrong.

The fold in step 4 is deliberately the naive one a consumer would write -
the test's value is that the naive fold and the engine's answer agree at every
step, which is exactly what makes the consumer's fold unnecessary.

Sabotage line, in this file's style, e.g.
`# sabotage: enter_states/2 takes configuration from pre_entry_state -> the
fold diverges at the first EntrySet and the assertion reddens.`

#### 2. Nothing else

No `lib/` change in this phase. If the test cannot be made green without one,
that is a Phase 1 defect and belongs in a fix to Phase 1's code, not a
widening here.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` green between edits.
- [x] Full `mix quality` green, `mix gate.verify` exits zero.
- [x] `mix test test/statifier/interpreter/exit_entry_acceptance_test.exs`
      green with the new test present.
- [x] `git diff --name-only` for this phase's commit shows no file under
      `lib/`.
- [x] `mix test.regression` green.

#### Manual Verification:
- [ ] Spec-conformance judgment: the chart exercises real Appendix D parallel
      entry ordering (`addDescendantStatesToEnter` over a `<parallel>`), not a
      compound chart in disguise - read the entry order the test observes
      against the pseudocode.
- [ ] The sabotage named above was applied, went red, and was reverted.
- [ ] The test covers `exit_interpreter/1`'s whole-configuration sweep, not
      only the ordinary exit path - confirm the terminal `ExitSet` in the
      captured stream came from `exit_interpreter/1` (it is the one whose
      `indexes` is the whole configuration and whose `configuration` is
      empty).
- [ ] No regressions: the rest of the acceptance file's assertions still
      describe the same behavior.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically, and Manual Verification items are deferred.

---

## Phase 3: Re-anchor the ADR-0012 judge fixtures

### Overview

`test/fixtures/adr_judge/0012_trace_after_departure.diff` and
`0012_trace_prestate_captured.diff` both quote `exit_states/2` at the exact
lines Phase 1 rewrites. Both are stale after Phase 1 in two ways: their hunk
headers point at moved lines, and - more seriously - the clean fixture's
"before" side is now the production code itself, so the diff it holds is close
to a no-op and no longer demonstrates the judgment it was authored to
demonstrate. Commit `b3fa844` ("Re-anchors the subtle fixtures after the
rebase") is the precedent and the method: apply a real edit to the current
source, capture with `git diff`, revert.

Note that the automated gate cannot catch this staleness - the fixtures are
read as text and fed to the judge, never applied
(`test/support/adr_judge_corpus.ex:46-62`), and the shape test only checks
existence, key, tier, scope, and verdict coverage
(`test/mix/statifier/adr_judge_corpus_shape_test.exs`). This phase is
therefore mostly manual verification over a mechanical change.

### Changes Required:

#### 1. Regenerate the violation fixture

**File**: `test/fixtures/adr_judge/0012_trace_after_departure.diff`
**Changes**: regenerate against Phase 1's `exit_states/2`. The edit to capture
is: delete the `pre_exit_state` binding and stamp the trace from the
post-departure `machine_state` instead - i.e. change
`Effect.trace(pre_exit_state, ...)` to `Effect.trace(machine_state, ...)`,
leaving `indexes` and `configuration` untouched.

This preserves the fixture's meaning exactly: the counters take
post-departure values while the payload still claims the exit-set phase
boundary, which is what the existing manifest note describes. In the new code
it is a *sharper* instance of the same thing, because the correct
pre-state binding is right there in the function being removed.

**File**: `test/fixtures/adr_judge/manifest.exs`
**Changes**: the note (`manifest.exs:46-53`) stays accurate as written, but should gain a
clause naming what is now removed, e.g. "...post-departure values - the
`pre_exit_state` capture that existed for exactly this reason is deleted;
payload and list position unchanged". Keep `expect: :violation`, `tier:
:subtle`.

#### 2. Regenerate the clean fixture

**File**: `test/fixtures/adr_judge/0012_trace_prestate_captured.diff`
**Changes**: the old edit (move the call below the reduce, keep a pre-state
binding) *is* the new production code, so it must be replaced by a different
meaning-preserving edit over the same code. Capture: rename `pre_exit_state`
to `exit_set_state` and hoist the configuration read into a local
(`resulting_configuration = machine_state.configuration`) placed immediately
before the trace call, with the trace call reading both locals.

That keeps the fixture's judged property identical - the state the payload is
stamped against is the same one the unmoved call read, and the configuration
is still the post-departure one - while giving the judge a real diff to
evaluate rather than an empty one.

**File**: `test/fixtures/adr_judge/manifest.exs`
**Changes**: rewrite the note (`manifest.exs:54-61`) to describe the new edit: the
captured pre-exit binding is renamed and the post-departure configuration read
is hoisted into a local; neither the stamping state nor the carried
configuration changes. Keep `expect: :clean`, `tier: :subtle`.

#### 3. Verify nothing else quotes the moved lines

**Files**: all of `test/fixtures/adr_judge/*.diff`
**Changes**: none expected. `0012_dropped_trace.diff` (blatant) and the
`0012_location_*` / `0014_*` / `0015_*` fixtures quote other files or other
functions; confirm with a grep for `exit_entry.ex` and for
`interpreter.ex` across the fixture directory and re-anchor anything else that
turns up.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` green between edits.
- [x] Full `mix quality` green, `mix gate.verify` exits zero. This includes
      `Mix.Statifier.AdrJudgeCorpusShapeTest`, which enforces that every
      manifest row's file exists, its key is registered, its tier is known,
      each `{key, tier}` still has both a `:violation` and a `:clean` fixture,
      and each fixture's diff lands in its own registry scope and no other.
- [x] `grep -rln "exit_entry.ex\|interpreter.ex" test/fixtures/adr_judge/ |
      grep -v 0012_dropped_trace.diff` returns exactly
      `0012_trace_after_departure.diff` and
      `0012_trace_prestate_captured.diff`. `0012_dropped_trace.diff` always
      matches this grep - its header quotes `lib/statifier/interpreter.ex` -
      and is deliberately excluded: it is a blatant-tier fixture over
      synthetic content, out of this phase's scope, and
      `git diff --stat` must show it unchanged.
- [x] Each regenerated diff applies cleanly to the Phase 1 source:
      `git apply --check test/fixtures/adr_judge/<file>` exits zero from a
      clean tree.
- [x] `mix quality --profile merge` (which enables the ADR judge stage) is
      green on the branch, confirming the judge does not read this branch's
      own `lib/` diff as an ADR-0012 violation. Note this makes real `claude`
      CLI calls; it is the same run `/wurk:mr` performs before pushing.

#### Manual Verification:
- [ ] Read both regenerated diffs and confirm each one's meaning is the one
      its manifest note claims - the violation stamps counters from the
      post-departure state, the clean one does not.
- [ ] Confirm the two fixtures' *judged properties* are unchanged from before
      this branch, so st-2ts's recorded Phase 5 scorecard measurement still
      stands (this is the same claim `b3fa844`'s commit body makes, and it is
      a human's call on the record, not an automated one).
- [ ] Optionally hand-run the real-CLI corpus suite for the two rows only -
      `mix test --only fixture:0012_trace_after_departure.diff` and
      `mix test --only fixture:0012_trace_prestate_captured.diff`, the
      per-fixture spend control `test/mix/statifier/adr_judge_corpus_test.exs`
      documents at its own call site (ExUnit's include beats the module's
      `:adr_judge_corpus` exclusion, so `--only fixture:...` reaches one row
      without running the whole paid corpus; do **not** use `--include
      adr_judge_corpus`, which runs every row) - and confirm the judge returns
      the expected verdicts. This costs real spend, so treat a green
      `--profile merge` plus the reading above as sufficient if spend is a
      concern; record which was done.
- [ ] No regressions: the other fifteen fixtures are byte-identical to their
      pre-branch state.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate, and `mix quality --profile merge` is the
one this phase additionally needs. In interactive execution, pause here for
the human to confirm the manual testing. In looped (`--loop`) execution, this
phase's Automated Verification gates advancement automatically, and Manual
Verification items are deferred.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/interpreter/exit_entry_exit_test.exs` - `ExitSet.configuration`
  is the post-departure configuration, and the counters are the pre-call ones.
  Edge case: an exit set that empties a compound state's whole subtree, so the
  ancestors leave too.
- `test/statifier/interpreter/exit_entry_enter_test.exs` -
  `EntrySet.configuration` equals the returned `machine_state.configuration`
  over a multi-state entry. Edge case: entering a `<parallel>`, where the
  entry set is larger than the transition target set.
- `test/statifier/interpreter/termination_test.exs` - `exit_interpreter/1`'s
  `ExitSet` carries the empty set while the sibling `Trace.Done` in the same
  list carries the configuration as it stood at exit.
- `test/statifier/interpreter/exit_entry_acceptance_test.exs` (Phase 2) - the
  whole-run fold agreement over a parallel chart including termination.
- Existing fixture repairs in `machine_state_acceptance_test.exs`,
  `session/effects_test.exs`, `session/telemetry_test.exs`, `effect_test.exs`,
  and `effect/trace_test.exs` are construction fix-ups, not new coverage; they
  need no sabotage line of their own beyond what they already carry.
- Untraced path: no new test. `Effect.trace/3`'s laziness is already covered
  in `test/statifier/effect_test.exs`, and the new field is a `fields` entry,
  so it is inside the existing guarantee rather than a new one.

### Manual Testing Steps:

1. In `iex -S mix`, compile a two-region parallel chart, start a session with
   `Statifier.Session.start_link(machine, trace: true, subscribers: [self()])`,
   drive it to a top-level final, and flush the mailbox. Confirm every
   `{:trace, %Trace.EntrySet{}}` and `{:trace, %Trace.ExitSet{}}` message
   carries a `configuration`, and that reading them in arrival order gives a
   sensible per-microstep animation with no gaps.
2. Confirm the terminal `ExitSet` carries `MapSet.new()` and arrives before
   `Trace.Done`, whose `configuration` is the non-empty exit-time set.
3. Start the same session with `trace: false` and confirm no trace messages
   arrive at all - the new field must not have introduced eager evaluation.
4. Attach `:telemetry` per `Statifier.Session.Telemetry` and confirm
   `[:statifier, :session, :trace, :entry_set]` metadata's `:effect` payload
   carries the new field, and that no new top-level metadata key appeared
   (this plan deliberately adds none).

## Open Questions

Recorded here rather than left in the body, per this run's unattended
constraint. Each has a decision made and implemented; the entry records what a
human might want to revisit.

1. **Should telemetry resolve `configuration` into metadata for
   `:entry_set`/`:exit_set`, the way it does for `:done`?** Decided: no, for
   the three reasons under "What We're NOT Doing". The reversible direction
   was chosen deliberately - if a non-Elixir consumer turns out to need
   resolved state ids per microstep, adding the key later is additive and
   non-breaking under the st-cmq.2 freeze. Worth revisiting once
   `docs/wire-format.md` on the statifier-ui side is written against real
   consumers.
2. **Should a new ADR-judge fixture pair cover "`configuration` read from the
   pre-mutation binding"?** Decided: not on this branch, because a new pair
   obliges a real-CLI measurement pass against st-2ts's scorecard. This should
   be filed as a follow-up bead in the st- tracker against the judge corpus,
   citing this plan; opening it is a tracker action a human or the
   orchestrating session takes, not something this plan does.
3. **Field name `configuration` versus `resulting_configuration`.** Decided:
   `configuration`, matching `MacrostepStable`/`Done`/`Effect.Done` and the
   name statifier-ui's GAP 7 asks for. The risk is a consumer reading it as
   "as it stood" (the sibling payloads' meaning) rather than "as it resulted";
   the mitigation is the moduledoc and the changelog fragment, both of which
   state the post-mutation semantics explicitly. If review prefers the
   unambiguous name, it is a one-line change in Phase 1 plus the fixture
   fix-ups, and it should be made before the payload ships.
4. **Whether Phase 3's real-CLI corpus run is required before merge.** Decided:
   a green `mix quality --profile merge` plus a human read of the two
   regenerated diffs is the bar; the `:adr_judge_corpus` suite hand-run is
   offered as an option because it costs real spend. A reviewer who wants the
   measurement re-taken should say so on the bead.

## Corpus/Ratchet Notes

No corpus regeneration and no ratchet movement. The change is observation-only:
it adds a field to two trace payloads and moves no SCXML semantics, so no
SCION or W3C test can change verdict. `mix test.regression` is listed as an
automated criterion in every phase precisely to prove that, and
`test/passing_tests.json` must be byte-identical at the end of the branch.
`mise run corpus` is not run.

## Performance Considerations

The new field is one `MapSet` reference copied into a struct per emission, and
only when `trace: true`. `Effect.trace/3` splices `fields` inside the gate's
`if`, so under `trace: false` the `machine_state.configuration` read never
happens and nothing is allocated - the untraced hot path is unchanged, which
is `docs/observability.md` constraint 2's standing requirement. Under
`trace: true` the cost is a pointer copy, not a copy of the set, and no
`Machine` walk is introduced anywhere: the deliberate absence of a telemetry
resolution step (see "What We're NOT Doing") is what keeps the
O(configuration) `Machine.id/2` walk ADR-0040 warned about off the
per-microstep path.

## References

- Bead: `st-ntf5` (mirrors `sui-t36.1`, closed 2026-08-17)
- Source document: `../statifier-ui/docs/research/260816-sui-t36.1-trace-coverage-spike.md`, GAP 7
- Related ADRs: `docs/adr/0012-debuggability-designed-into-the-core.md`
  (item 2, trace at Appendix D phase boundaries),
  `docs/adr/0005-full-configuration-and-interned-state-indexes.md`,
  `docs/adr/0040-session-telemetry-event-contract.md` (metadata rules for the
  trace family), `docs/adr/0002-literal-w3c-appendix-d-port.md`,
  `docs/adr/0003-pure-core-with-effects.md`
- Constraints doc: `docs/observability.md`, constraints 2, 3 and 4
- Precedent payload: `lib/statifier/effect/trace/macrostep_stable.ex:24`
- Sanctioned pattern: `test/fixtures/adr_judge/0012_trace_prestate_captured.diff`
  and `test/fixtures/adr_judge/manifest.exs:54-61`
- Counter-pattern: `test/fixtures/adr_judge/0012_trace_after_departure.diff`
  and `test/fixtures/adr_judge/manifest.exs:46-53`
- Re-anchoring precedent: commit `b3fa844`
- Emission sites: `lib/statifier/interpreter/exit_entry.ex:138`,
  `lib/statifier/interpreter/exit_entry.ex:679`,
  `lib/statifier/interpreter.ex:1643`
- Test model: `test/statifier/interpreter/macrostep_test.exs:173-185`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Spec-conformance judgment: `exit_states/2`, `enter_states/2` and
      `exit_interpreter/1` still match the W3C Appendix D pseudocode line for
      line. Only the ADR-0012 trace statement moved, and Appendix D contains
      no trace statement, so no pseudocode statement was reordered - confirm
      by reading the three moduledoc numbered lists against
      `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/appendix-d.txt`.
- [ ] Each of the three new tests was actually sabotaged: the named mutation
      was applied, the test went red, and the change was reverted.
- [ ] Read the diff against
      `test/fixtures/adr_judge/0012_trace_prestate_captured.diff`: every moved
      call is stamped from a binding captured before the mutation, and only
      `configuration` reads the post-mutation state.
- [ ] No regressions in related features: trace effect ordering within a
      microstep is unchanged (the payload is still first in each function's
      returned list).

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

### Phase 2

- [ ] Spec-conformance judgment: the chart exercises real Appendix D parallel
      entry ordering (`addDescendantStatesToEnter` over a `<parallel>`), not a
      compound chart in disguise - read the entry order the test observes
      against the pseudocode.
- [ ] The sabotage named above was applied, went red, and was reverted.
- [ ] The test covers `exit_interpreter/1`'s whole-configuration sweep, not
      only the ordinary exit path - confirm the terminal `ExitSet` in the
      captured stream came from `exit_interpreter/1` (it is the one whose
      `indexes` is the whole configuration and whose `configuration` is
      empty).
- [ ] No regressions: the rest of the acceptance file's assertions still
      describe the same behavior.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically, and Manual Verification items are deferred.

---

### Phase 3

- [ ] Read both regenerated diffs and confirm each one's meaning is the one
      its manifest note claims - the violation stamps counters from the
      post-departure state, the clean one does not.
- [ ] Confirm the two fixtures' *judged properties* are unchanged from before
      this branch, so st-2ts's recorded Phase 5 scorecard measurement still
      stands (this is the same claim `b3fa844`'s commit body makes, and it is
      a human's call on the record, not an automated one).
- [ ] Optionally hand-run the real-CLI corpus suite for the two rows only -
      `mix test --only fixture:0012_trace_after_departure.diff` and
      `mix test --only fixture:0012_trace_prestate_captured.diff`, the
      per-fixture spend control `test/mix/statifier/adr_judge_corpus_test.exs`
      documents at its own call site (ExUnit's include beats the module's
      `:adr_judge_corpus` exclusion, so `--only fixture:...` reaches one row
      without running the whole paid corpus; do **not** use `--include
      adr_judge_corpus`, which runs every row) - and confirm the judge returns
      the expected verdicts. This costs real spend, so treat a green
      `--profile merge` plus the reading above as sufficient if spend is a
      concern; record which was done.
- [ ] No regressions: the other fifteen fixtures are byte-identical to their
      pre-branch state.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate, and `mix quality --profile merge` is the
one this phase additionally needs. In interactive execution, pause here for
the human to confirm the manual testing. In looped (`--loop`) execution, this
phase's Automated Verification gates advancement automatically, and Manual
Verification items are deferred.

---
