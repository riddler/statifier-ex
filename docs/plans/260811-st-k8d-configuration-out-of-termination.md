# Carries the configuration out of termination Implementation Plan

## Overview

A terminated state chart has an empty configuration, so every W3C corpus file -
all of which assert a top-level `<final id="pass">` - fails with `Expected
active states ["pass"], but got []`. This plan carries the configuration as it
stood at exit out of `exit_interpreter/1` on the core `{:done, _}` effect,
teaches `Statifier.Case` to assert against it when the chart terminated, adds
the nameless-leaf cardinality assertion deferred from st-wju.7, and
re-baselines the W3C mark. Bead: st-k8d.

## Current State Analysis

**The interpreter is correct and stays correct.**
`Statifier.Interpreter.exit_interpreter/1` (`lib/statifier/interpreter.ex:539`)
binds `configuration_at_exit = machine_state.configuration` before the exit
fold, then deletes each state from `configuration` as it exits it. That is
Appendix D's `exitInterpreter` verbatim. When the walk finishes,
`machine_state.configuration` is `MapSet.new()` and `status` is `:done`.

**The configuration at exit already exists, on the wrong effect.**
`configuration_at_exit` is handed to `Effect.Trace.Done`
(`lib/statifier/interpreter.ex:566-570`), which is gated behind
`Effect.trace/3` and therefore only exists when `machine_state.trace` is true.
`Statifier.Effect.Done` (`lib/statifier/effect/done.ex:17`) is
`[:donedata, :macrostep, :microstep]` - no configuration. st-wju.6's plan
(`docs/plans/260810-st-wju.6-microstep-macrostep-and-interpreter-entry.md:615-619`)
recorded that as a deliberate non-decision at the time ("`Effect.Done` carries
no configuration, so there is nothing to keep consistent with"); this bead
revisits it, and the consistency obligation it names is discharged below by
populating both fields from the same binding.

**The harness cannot see effects at all.** `test/support/case.ex` drops them on
both driving paths: `initialize/1` is `machine |> Statifier.initialize() |>
elem(0)` (`test/support/case.ex:119`), and `send_event/2` matches `{:ok, next,
_effects}` and returns only `next` (`test/support/case.ex:124-132`).
`assert_configuration/2` (`test/support/case.ex:102-108`) therefore sees only a
`%MachineState{}` and compares `Statifier.active_leaf_states/1` against the
expected id set. Threading the terminal configuration into the assertion means
threading effects out of both adapters first - that is the bulk of the harness
change, not the assertion itself.

**The done effect is produced on both paths.** `Statifier.initialize/2` runs
`Interpreter.initialize/2`, which runs `main_event_loop/1`, which calls
`exit_interpreter/1` when `enter_states/2` set `running: false`; `send_event/2`
reaches the same call through `handle_event/2`. So a chart that terminates
during initialization and one that terminates on an event both hand back a
`{:done, %Effect.Done{}}` in the effect list of that call, as the last member
(pinned by `test/statifier/interpreter/termination_test.exs:114-123`).

**Indexes, not ids.** `Effect.Done.configuration` will be a
`MapSet.t(non_neg_integer())`, the same interned indexes `Trace.Done` carries -
ADR-0005 keeps string ids at the `Statifier` boundary and nowhere deeper. The
expectation strings the corpus writes are leaf ids, so the harness needs a
leaf-only translation with exactly `Statifier.active_leaf_states/1`'s semantics:
filter by `Machine.atomic?/2`, map through `Machine.id/2`, drop `nil`.

**The nameless-leaf hole.** `Statifier.active_leaf_states/1`
(`lib/statifier.ex`, final function) rejects `nil` ids, which is right - an
unnamed state cannot be named by any expectation - but it means an anonymous
active leaf is invisible while the named leaves match, so a false pass is
possible. With the ratchet live (`test/passing_tests.json`, `mix
test.regression`) such a false pass would be written into the registry and
defended forever. The corpus has exactly one nameless state today (a bare
`<final />` in `test/scxml_tests/mandatory/invoke/test530_test.exs`, gated
behind `:invoke_elements`), so the assertion cannot fire until invoke lands.

**Measured baseline.** 8 of 164 W3C files clear the feature gate and all 8 fail
identically on the empty configuration; 87 SCION tests pass and are unaffected
(no SCION test asserts a top-level final). `test/passing_tests.json` currently
records `scion_tests: 87`, `w3c_tests: 0`.

### Key Discoveries:

- `lib/statifier/interpreter.ex:539-541` - `configuration_at_exit` is already
  bound before the fold; nothing new needs computing.
- `lib/statifier/interpreter.ex:566-580` - `Trace.Done` and `Effect.Done` are
  built from the same locals, six lines apart.
- `lib/statifier/effect/trace/done.ex:8-10` - the moduledoc asserts the core
  `:done` effect "does not carry" the configuration; that sentence becomes
  false in Phase 1 and must be rewritten, not left.
- `test/support/case.ex:119` and `:124-132` - both adapters discard effects.
- `test/statifier/effect_test.exs:27` and
  `test/statifier/machine_state_acceptance_test.exs:141` - two vocabulary
  fixture tables build `%Effect.Done{macrostep: _, microstep: _}` literals;
  adding `:configuration` to `@enforce_keys` breaks both at compile time, which
  is the point.
- ADR-0002 - `exit_interpreter/1`'s state mutation stays verbatim. ADR-0005 -
  indexes below the facade, string ids at it. ADR-0006 - `Statifier.Case`'s
  four-function *driving* contract. ADR-0012 / `docs/observability.md:68` - the
  "done" row belongs to the trace vocabulary; the core effect gaining a field
  does not change that row.

## Desired End State

- `Statifier.Effect.Done` has a `configuration` field, enforced, populated by
  `exit_interpreter/1` from the same `configuration_at_exit` binding
  `Trace.Done` gets, so the two can never disagree.
- `Statifier.active_leaf_states/1` is unchanged: a terminated chart still
  reports no active states, because it genuinely has none.
- `Statifier.Case.assert_configuration/3` asserts against the done effect's
  configuration when the call that produced the chart terminated it, and
  against `Statifier.active_leaf_states/1` otherwise, with tracing off.
- `assert_configuration/3` also fails loudly when the observed leaf set
  contains a nameless state, rather than silently passing on the named subset.
- `test/passing_tests.json` records a nonzero `w3c_tests` count; `mix
  test.regression` is green on it.

Verify: `mix quality` green; `mix test --include scion --include scxml_w3`
shows the W3C failures replaced by passes; `mix test.regression` green;
`grep w3c_tests test/passing_tests.json` shows a nonzero count.

## What We're NOT Doing

- **Not keeping states in the configuration after exit.** v1 has no
  `exitInterpreter` at all, which is why its W3C mark came cheaply; copying
  that is an ADR-0002 semantic bug. The exit walk is untouched.
- **Not making the conformance assertion depend on `:trace`.** The harness
  never sets `trace: true`, and `Trace.Done` is never read by it.
- **Not adding a fifth public function to `Statifier`.** ADR-0006's
  four-function surface holds; the harness rebuilds a `%MachineState{}` view
  and calls the existing `active_leaf_states/1` on it (see Phase 2).
- **Not changing `Statifier.active_leaf_states/1`,
  `MachineState.active_leaf_states/1`, or `Machine.id/2`.** `lib/` stays as it
  is on the nameless-state question; the assertion is a harness-side
  cardinality check.
- **Not touching the SCION suite or the corpus generator.** No corpus
  regeneration, no `tools/corpus/` change.
- **Not editing `docs/quality-gate-changes.md`.** `test/passing_tests.json`
  only grows, so `mix gate.check` has nothing to guard (ADR-0011); the PR body
  says so.
- **Not implementing `<invoke>` or the datamodel.** The nameless-leaf assertion
  is dormant until `:invoke_elements` is supported; that is expected, not a
  gap.

## Implementation Approach

Three phases along this project's module-boundary convention
(`.claude/wurk/plan.md` names parser vs interpreter vs corpus tooling; this
bead touches no parser, so the split lands as interpreter / test harness /
ratchet), each independently green.

Phase 1 is a `lib/` change with its own unit coverage: one field, one
population site, the two doc sentences it falsifies, and the fixture tables the
enforced key breaks. Phase 2 is a `test/support/` change: thread effects out of
the two adapters, branch the assertion on the presence of a `{:done, _}`
effect, add the cardinality check. Phase 3 runs the conformance suites and
moves the ratchet.

Phase 2 is where the W3C tests start passing, but they are excluded from `mix
test` by default, so Phase 2 commits green with the registry untouched; Phase 3
is the only phase that writes `test/passing_tests.json`. That split is what
keeps each phase's gate meaningful on its own.

**Appendix D note (project extension's rule).** Phase 1 introduces no deviation
from the pseudocode. `exitInterpreter`'s statements - the exit walk, the
per-state `onexit`, the configuration deletions, `returnDoneEvent(donedata)` -
are unchanged in content and order. Appendix D's `returnDoneEvent` is an I/O
call whose reification as a returned effect is the already-recorded mechanical
deviation (ADR-0003, `lib/statifier/interpreter.ex:113-114`); widening that
effect's payload with a value the function already computed adds information to
a returned struct and changes no interpreter state, no event, and no order.

**How the terminal translation works, exactly.** The harness builds
`%{state_chart | configuration: done.configuration}` - a `%MachineState{}` at
the position the chart held at exit - and passes it to
`Statifier.active_leaf_states/1`. The translation therefore lives where ADR-0005
puts it, inside the facade, and matches `active_leaf_states/1`'s semantics by
being that function rather than by reimplementing it. The harness never maps an
index to an id itself.

## Phase 1: Effect.Done carries the configuration at exit

### Overview

The core `:done` effect gains a `configuration` field, populated from the same
binding `Trace.Done` already receives. No interpreter behavior changes.

### Changes Required:

#### 1. The effect payload
**File**: `lib/statifier/effect/done.ex`
**Changes**: add `:configuration` to the struct, to `@enforce_keys`, and to
`@type t()`; rewrite the moduledoc's closing sentence, which currently says
`Trace.Done` "additionally carries the configuration as it stood at exit".

```elixir
@enforce_keys [:configuration, :macrostep, :microstep]
defstruct [:donedata, :configuration, :macrostep, :microstep]

@type t :: %__MODULE__{
        donedata: term() | nil,
        configuration: MapSet.t(non_neg_integer()),
        macrostep: non_neg_integer(),
        microstep: non_neg_integer()
      }
```

The moduledoc states what the field is and why it exists: the full
configuration (ADR-0005, ancestors included) as it stood at exit, carried on
the core effect so a consumer can observe the terminal position without
switching tracing on; `MachineState.configuration` is empty by then, and
`Statifier.active_leaf_states/1` correctly reports nothing active.

Enforcing the key is deliberate: `Trace.Done` enforces its `configuration`, a
done effect always has one, and the compile error is what routes the two
fixture tables below to the update they need.

#### 2. The population site
**File**: `lib/statifier/interpreter.ex` (`exit_interpreter/1`, ~line 572)
**Changes**: add one field to the struct literal.

```elixir
done_effect =
  {:done,
   %Effect.Done{
     donedata: donedata,
     configuration: configuration_at_exit,
     macrostep: machine_state.macrostep,
     microstep: machine_state.microstep
   }}
```

Extend the moduledoc's numbered walk-through: item 1's "configuration captured
before the walk" note (`lib/statifier/interpreter.ex:500`) and item 6's terminal
effects paragraph (~`:528-532`) should read for both effects and say they are
populated from one binding.

#### 2b. The trace counterpart's moduledoc
**File**: `lib/statifier/effect/trace/done.ex` (moduledoc, ~lines 7-8)
**Changes**: the sentence "`configuration` is the full configuration (ADR-0005,
ancestors included) as it stood at exit, which the core `:done` effect does not
carry" is false after this phase. Rewrite it: both effects carry the same set
from the same binding, and `Trace.Done` exists for the observability row
(ADR-0012, `docs/observability.md:68`), not because it is the only carrier.

#### 3. Vocabulary fixtures broken by the enforced key
**Files**: `test/statifier/effect_test.exs:27`,
`test/statifier/machine_state_acceptance_test.exs:141`
**Changes**: add `configuration: MapSet.new()` to each `%Effect.Done{}`
literal. These tables assert the shape of the effect vocabulary
(`trace?/1` classification, the thirteen-effect count); the value is irrelevant
to what they check.

#### 4. Unit coverage
**File**: `test/statifier/interpreter/termination_test.exs`
**Changes**: extend the existing `exit_interpreter/1 - Trace.Done` describe
block (or add a sibling `- configuration` block) with a test asserting the core
done effect carries the configuration as it stood at exit, that it equals
`Trace.Done`'s, and - the property that matters for the harness - that it is
non-empty while the returned `machine_state.configuration` is empty. Run it
with tracing both on and off; with tracing off there is no `Trace.Done` and the
core effect must still carry the set.

```elixir
# sabotage: exit_interpreter/1 populates Effect.Done's configuration from
# machine_state.configuration (post-fold) instead of configuration_at_exit
# -> the effect comes back with an empty set -> red
```

#### 5. Changelog fragment
**File**: `changelog.d/st-k8d.md`
**Changes**: one line - the `:done` effect now carries the configuration as it
stood at exit. This is a public API addition (effects are returned data), so it
clears `changelog.d/README.md`'s bar.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (use `mix quality --profile loop` between
      edits; a loop run does not satisfy this phase).
- [x] `mix test test/statifier/interpreter/termination_test.exs` passes,
      including the new configuration test in both trace-on and trace-off form.
- [x] `mix test.regression` still green (no conformance movement expected in
      this phase; this proves it).
- [x] `grep -n "configuration" lib/statifier/effect/done.ex` shows the field in
      the struct, `@enforce_keys`, and `@type t()`.
- [x] `grep -rn "does not carry" lib/statifier/effect/` returns nothing - the
      stale `Trace.Done` sentence is gone.
- [x] `changelog.d/st-k8d.md` exists.

#### Manual Verification:
- [ ] `exit_interpreter/1` matches the W3C Appendix D `exitInterpreter`
      pseudocode line for line; the only deviations are the two already
      documented (effects returned rather than performed, `cancelInvoke`
      skipped), and this phase adds none.
- [ ] `Effect.Done`'s and `Trace.Done`'s moduledocs no longer contradict each
      other about which effect carries the configuration.
- [ ] The sabotage note on the new test names a mutation a reasonable person
      could make (per `docs/testing.md`), and the test was seen red under it.

**Implementation Note**: Use `mix quality --profile loop` between edits and the
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual items before Phase 2. In `--loop` execution the
automated list gates advancement via `/wurk:commit --auto` and the manual items
are surfaced at the end.

---

## Phase 2: The harness asserts the terminal configuration

### Overview

Thread effects out of `Statifier.Case`'s two driving adapters, assert against
the done effect's configuration when the chart terminated, and add the
nameless-leaf cardinality assertion. This is the phase that turns the 8
gate-clearing W3C tests green; it does not ratchet them.

### Changes Required:

#### 1. Thread effects through the drivers
**File**: `test/support/case.ex`
**Changes**: `initialize/1` and `send_event/2` return `{state_chart, effects}`;
`test_scxml/4` threads the pair.

```elixir
def test_scxml(xml, description, expected_initial_config, events) do
  validate_features!(xml, description)

  {state_chart, effects} = xml |> parse_document() |> initialize()
  assert_configuration(state_chart, effects, expected_initial_config)

  Enum.reduce(events, state_chart, fn {event_map, expected_states}, current ->
    {next, next_effects} = send_event(current, event_map)
    assert_configuration(next, next_effects, expected_states)
    next
  end)

  :ok
end

defp initialize(machine), do: Statifier.initialize(machine)

defp send_event(state_chart, %{"name" => name}) do
  case Statifier.send_event(state_chart, name) do
    {:ok, next, effects} -> {next, effects}
    {:error, :not_running} -> flunk("Sent #{inspect(name)} to a state chart that has terminated")
  end
end
```

The reduce still threads only the state chart; each iteration's effects belong
to that iteration's assertion and nothing later reads them.

#### 2. Branch the assertion on termination
**File**: `test/support/case.ex`
**Changes**: `assert_configuration/3` picks its observation source from the
effects, then asserts.

```elixir
defp assert_configuration(state_chart, effects, expected_state_ids) do
  expected = MapSet.new(expected_state_ids)
  observed = observed_state_chart(state_chart, effects)
  actual = Statifier.active_leaf_states(observed)

  assert_every_leaf_named(observed, actual)

  assert expected == actual,
         "Expected active states #{inspect(Enum.sort(expected))}, but got #{inspect(Enum.sort(actual))}"
end

# A terminated chart has an empty configuration by construction
# (exit_interpreter/1, Appendix D) - the position it held at exit rides the
# core :done effect instead. Restoring it onto the MachineState keeps the
# index-to-id translation inside Statifier.active_leaf_states/1, where
# ADR-0005 puts it, rather than reimplementing that translation here.
defp observed_state_chart(state_chart, effects) do
  case Enum.find(effects, &match?({:done, _payload}, &1)) do
    {:done, done} -> %{state_chart | configuration: done.configuration}
    nil -> state_chart
  end
end
```

Keying on the `{:done, _}` effect rather than on `status == :done` keeps the
branch tied to the call that terminated the chart: the effect appears exactly
once, in the effect list of that one call, and a later `send_event/2` on a
terminated chart flunks instead of returning effects.

#### 3. The nameless-leaf cardinality assertion
**File**: `test/support/case.ex`
**Changes**: compare the raw leaf count against the translated one.

```elixir
alias Statifier.MachineState

# Statifier.active_leaf_states/1 drops nil ids - correct, since no expectation
# can name an unnamed state - but that would let an anonymous active leaf pass
# unobserved while the named ones match, and the ratchet would then defend the
# false pass forever. Cardinality is the one thing the harness can check
# without naming what it cannot name.
defp assert_every_leaf_named(observed, translated) do
  raw = MachineState.active_leaf_states(observed)

  assert MapSet.size(raw) == MapSet.size(translated),
         "#{MapSet.size(raw) - MapSet.size(translated)} active leaf state(s) have no id; " <>
           "the expectation #{inspect(Enum.sort(translated))} cannot name them"
end
```

`MachineState` is the one library module the harness names beyond `Statifier`
itself. ADR-0006's four-function contract constrains what it takes to *drive* a
chart - parse, initialize, send an event, read the leaf set - and all four
still do that job. This is an assertion-side inspection of a value the harness
already holds, and it is the only way to see the leaves the id translation
dropped. The `%{state_chart | configuration: _}` update in `observed_state_chart/2`
touches the same struct for the same reason.

#### 4. Moduledoc
**File**: `test/support/case.ex`
**Changes**: the moduledoc's "It needs exactly four things from `Statifier`"
paragraph is now incomplete. Rewrite it to keep the four-function driving
contract as the headline and add, honestly, that the assertion path additionally
reads the terminal configuration off the `:done` effect and the untranslated
leaf set off `Statifier.MachineState`, with the reason for each.

#### 5. Harness tests
**File**: `test/statifier/case_test.exs`
**Changes**: add a describe block for terminal assertions.

- A document whose initial configuration terminates immediately
  (`<scxml initial="pass"><final id="pass"/></scxml>`): `test_scxml(xml, _,
  ["pass"], [])` returns `:ok`. This is the W3C corpus shape in miniature and
  the test that would have caught the bug.
  `# sabotage: exit_interpreter/1 populates Effect.Done's configuration from the
  post-fold configuration -> red`
- A document that terminates on an event: `test_scxml(xml, _, ["s1"],
  [{%{"name" => "go"}, ["pass"]}])` returns `:ok`, covering the
  `send_event/2` path as well as the `initialize/1` one.
  `# sabotage: assert_configuration/3's observed_state_chart/2 always returns
  state_chart -> red`
- A non-terminating document still asserts against the live configuration (the
  existing end-to-end test covers this; assert it still passes unchanged).
- The nameless-leaf assertion fires: a document with an unnamed active leaf
  (`<scxml><state id="s1"/><state/></scxml>` shaped so an id-less state is
  active - a parallel with one nameless region is the direct way) makes
  `test_scxml/4` raise an `ExUnit.AssertionError` naming the missing ids.
  This is the assertion the corpus cannot exercise until invoke lands, so a
  hand-written document is the only coverage it can have.
  `# sabotage: Statifier.active_leaf_states/1 keeps nil ids instead of rejecting
  them -> the sizes match and the test goes green` - note this mutation reddens
  by *not* raising, so state it that way in the note.

Any harness test whose subject is `lib/` behavior gets a real sabotage note;
the ones that only exercise the harness's own flunk path carry
`# sabotage: n/a - ...` per `docs/testing.md`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (loop profile between edits only).
- [x] `mix test test/statifier/case_test.exs` passes, including the new
      terminal and nameless-leaf tests.
- [x] `mix test --include scxml_w3` shows no remaining `Expected active states
      ["pass"], but got []` failures.
- [x] `mix test --include scion` still shows the 87 known-passing SCION tests
      passing (no harness regression).
- [x] `mix test.regression` green with `test/passing_tests.json` unchanged in
      this phase.
- [x] `git diff --stat` for this phase touches `test/` only.

#### Manual Verification:
- [ ] Tracing is off in every corpus run - `grep -rn "trace" test/support/case.ex`
      finds nothing that enables it, and the terminal assertion works anyway.
- [ ] The rewritten moduledoc describes the coupling surface as it now is,
      including why `MachineState` appears on the assertion side.
- [ ] A spot-read of two newly passing W3C files confirms they pass for the
      right reason (the chart really reached `pass`), not because the assertion
      was weakened.

**Implementation Note**: Use `mix quality --profile loop` between edits and the
full `mix quality` as the phase gate. In interactive execution, pause for the
manual items before Phase 3; in `--loop` execution they are deferred to the end.

---

## Phase 3: Re-baseline the W3C mark

### Overview

Run both conformance suites, ratchet in everything newly passing, and record
the new W3C mark on the bead.

### Changes Required:

#### 1. Measure
**Command**: `mix test --include scion --include scxml_w3`
**Changes**: none - this is the measurement. Record the pass/fail counts per
suite before touching the registry. Expect the 8 gate-clearing W3C files to
pass; a file that clears the feature gate and still fails is a separate defect,
not something to ratchet or to work around here.

#### 2. Ratchet
**Command**: `mix test.baseline --only w3c` to report, then `mix test.baseline
--add --only w3c` (or `mix test.baseline add <file> ...` for a named set)
**File**: `test/passing_tests.json`
**Changes**: `w3c_tests` grows from 0 to the measured count; `last_updated`
moves. The task re-runs each candidate on its own before writing, so nothing
enters the registry without passing in isolation. Nothing is removed - the
ratchet only moves forward.

#### 3. Record the mark
**Changes**: `bd note st-k8d` with the new W3C count, the SCION count, and the
count of W3C files still stopped by the feature gate. The bead's acceptance
criteria ask for the mark in the notes.

### Success Criteria:

#### Automated Verification:
- [ ] `mix test --include scion --include scxml_w3` run in full and its counts
      recorded.
- [ ] `mix test.baseline --only w3c` reports nothing left to ratchet after the
      add.
- [ ] `mix test.regression` green against the grown registry.
- [ ] `grep w3c_tests test/passing_tests.json` shows a nonzero count.
- [ ] Full `mix quality` passes.
- [ ] `mix gate.check` passes with no entry in `docs/quality-gate-changes.md` -
      the registry only grew (ADR-0011).

#### Manual Verification:
- [ ] The ratcheted set is exactly the W3C files that passed; no file was added
      by hand.
- [ ] Every W3C file still failing fails on a named unsupported feature, not on
      a configuration mismatch.
- [ ] The bead note records the new mark and the residual gate-blocked count.

**Implementation Note**: The conformance run is minutes, not seconds; do not
substitute a scoped run for it. Full `mix quality` is still the phase gate.

---

## Corpus/Ratchet Notes

- No corpus regeneration. `tools/corpus/` and every generated file under
  `test/scion_tests/` and `test/scxml_tests/` are untouched; the emitted tests
  already assert the right thing and always did.
- `test/passing_tests.json` grows only, in Phase 3 alone. A shrinking registry
  is what `mix gate.check` guards, so no `docs/quality-gate-changes.md` entry is
  needed and none should be written. The PR body says this explicitly (bead
  acceptance criteria).
- SCION is unaffected in principle (no SCION test asserts a top-level final),
  but Phase 2 changes the shared harness, so the SCION run is part of Phase 2's
  automated criteria as a regression check rather than as a source of new
  entries.
- If the measured W3C count is below 8, the shortfall is a separate defect:
  ratchet what passes, file a bead for the rest, do not hold the phase.

## Open Questions

None outstanding. The three judgment calls this plan had to make were made
here rather than left for the implementer:

1. **Where the index-to-id translation lives** - in
   `Statifier.active_leaf_states/1`, reached by restoring the terminal
   configuration onto a `%MachineState{}` in the harness. The alternatives were
   a fifth public function (breaks ADR-0006's surface constraint) and a
   hand-rolled translation in the harness (duplicates ADR-0005's boundary and
   can drift from `active_leaf_states/1`'s atomic-filter semantics).
2. **`:configuration` is enforced on `Effect.Done`** - matching `Trace.Done`,
   at the cost of updating two vocabulary fixture tables. A done effect without
   a configuration is not a thing that should be constructible.
3. **The harness may name `Statifier.MachineState`** on the assertion side.
   ADR-0006's four-function contract is read as constraining what it takes to
   drive a chart, not as forbidding inspection of a value already in hand; the
   cardinality check is impossible otherwise, and the moduledoc records the
   widening rather than hiding it. If a reviewer disagrees, the fallback is to
   drop the cardinality assertion and re-file st-wju.7's open question 1 - it
   would not change Phases 1 or 3.

## Testing Strategy

### Unit Tests:

- `test/statifier/interpreter/termination_test.exs` - the core `:done` effect
  carries the configuration as it stood at exit; it equals `Trace.Done`'s when
  tracing is on; it is still populated when tracing is off; the returned
  `machine_state.configuration` is empty at the same time.
- `test/statifier/effect_test.exs`,
  `test/statifier/machine_state_acceptance_test.exs` - vocabulary fixtures
  updated for the enforced key; their assertions are unchanged.
- `test/statifier/case_test.exs` - terminal assertion on the initialize path,
  terminal assertion on the send-event path, live assertion unchanged for a
  non-terminating chart, nameless-leaf assertion raising with a message naming
  the count.
- Edge cases worth an explicit test or an explicit decision: a chart that
  terminates during initialization (the corpus shape), a chart that terminates
  on an event, a parallel region whose leaves include the top-level final's
  siblings (the exit-order set is the whole configuration, and only atomic
  members survive the leaf filter), and a nameless active leaf.
- Every new test asserting `lib/` behavior carries a sabotage note per
  `docs/testing.md`; harness-only assertions carry `# sabotage: n/a - ...`.

### Manual Testing Steps:

1. `mix quality` after each phase - full, unscoped, no `--skip`; confirm with
   `mix gate.verify` before reporting the work complete.
2. `mix test --include scion --include scxml_w3` before and after Phase 2;
   diff the failure summaries and confirm the W3C failures that disappeared are
   exactly the `Expected active states ["pass"], but got []` ones.
3. Open two newly passing W3C test files and read their XML: confirm the chart
   really is expected to terminate in `pass`.
4. Read `exit_interpreter/1` against the Appendix D `exitInterpreter`
   pseudocode and confirm the walk is unchanged.
5. `mix test.regression` after Phase 3 and confirm the registry counts match
   the suite run.

## References

- Bead: `st-k8d` (decided approach recorded on the bead, 2026-08-11)
- Prior plan: `docs/plans/260811-st-wju.7-four-function-api-and-corpus-on.md`
  (seeded the baseline; open question 1 is folded in here)
- Prior plan: `docs/plans/260810-st-wju.6-microstep-macrostep-and-interpreter-entry.md:615-619`
  (why `Effect.Done` carried no configuration until now)
- ADRs: `docs/adr/0002-literal-w3c-appendix-d-port.md`,
  `docs/adr/0003-pure-core-with-effects.md`,
  `docs/adr/0005-full-configuration-and-interned-state-indexes.md`,
  `docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md`,
  `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `docs/adr/0012-debuggability-designed-into-the-core.md`
- Docs: `docs/testing.md` (sabotage rule, suites),
  `docs/observability.md:68` (the "done" row)
- Implementation sites: `lib/statifier/interpreter.ex:539-582`,
  `lib/statifier/effect/done.ex`, `lib/statifier/effect/trace/done.ex`,
  `test/support/case.ex:102-134`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] `exit_interpreter/1` matches the W3C Appendix D `exitInterpreter`
      pseudocode line for line; the only deviations are the two already
      documented (effects returned rather than performed, `cancelInvoke`
      skipped), and this phase adds none.
- [ ] `Effect.Done`'s and `Trace.Done`'s moduledocs no longer contradict each
      other about which effect carries the configuration.
- [ ] The sabotage note on the new test names a mutation a reasonable person
      could make (per `docs/testing.md`), and the test was seen red under it.

**Implementation Note**: Use `mix quality --profile loop` between edits and the
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual items before Phase 2. In `--loop` execution the
automated list gates advancement via `/wurk:commit --auto` and the manual items
are surfaced at the end.

---

### Phase 2

- [ ] Tracing is off in every corpus run - `grep -rn "trace" test/support/case.ex`
      finds nothing that enables it, and the terminal assertion works anyway.
- [ ] The rewritten moduledoc describes the coupling surface as it now is,
      including why `MachineState` appears on the assertion side.
- [ ] A spot-read of two newly passing W3C files confirms they pass for the
      right reason (the chart really reached `pass`), not because the assertion
      was weakened.

**Implementation Note**: Use `mix quality --profile loop` between edits and the
full `mix quality` as the phase gate. In interactive execution, pause for the
manual items before Phase 3; in `--loop` execution they are deferred to the end.

---
