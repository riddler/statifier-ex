# Per-corpus pass percentage implementation plan

## Overview

Make a single job run answer "what percentage of SCION and of W3C do we pass".
Add one pure statistics function to `Mix.Statifier.RegressionRegistry` and print
its result from both conformance tasks: `mix test.baseline` reports the measured
figure after its scan, and `mix test.regression` reports the ratcheted figure at
the end of a green ratchet run - the cheap number, available in seconds without
running the corpus. Beads issue: `st-up2`.

## Current State Analysis

Nothing in the repo computes a completion percentage today. The three pieces
that hold the raw numbers are:

- `Mix.Statifier.RegressionRegistry.corpus_files/2`
  (`lib/mix/statifier/regression_registry.ex:286-298`) globs
  `test/scion_tests/**/*_test.exs` and `test/scxml_tests/**/*_test.exs`. This is
  the denominator, already written, already parameterized by a `root` so tests
  can point it at a fixture tree. On disk today: **118 SCION, 159 W3C**.
- `RegressionRegistry.expand/2` (`:149-154`) expands the registry's per-suite
  lists to files on disk. `test/passing_tests.json` currently holds **107**
  `scion_tests` entries and **58** `w3c_tests` entries.
- `Mix.Tasks.Test.Baseline.scan/4` (`lib/mix/tasks/test.baseline.ex:94-106`)
  already computes `corpus_files -- tracked` as its candidate list and then
  partitions it into `{passing, failing}` by running each file on its own
  (`:115-117`). `report/2` (`:119-125`) prints only the two candidate counts;
  it never relates them to the corpus size.

So the numerator and denominator both exist inside a `mix test.baseline` scan
and are simply not multiplied together.

`Mix.Tasks.Test.Regression.run_tests/2`
(`lib/mix/tasks/test.regression.ex:77-91`) knows the full set of registry files
and whether they all passed, and prints only `"All N regression test files
passed."`. It has no `root` seam - `execute/2` takes `opts[:runner]` only
(`:50-60`) - so one has to be added for a fixture-tree test of the new output.

The `Regression ratchet` stage in `.quality.exs:82-88` shells out to
`mix test.regression` on every non-loop gate run. It does **not** follow that
whatever the task prints lands in the gate's console: `ExQuality.Stages.Command`
gives a passing command stage whose output is not a JSON document the summary
`"Passed"` (`deps/ex_quality/lib/ex_quality/stages/command.ex:206-221, :284`),
and `deps/ex_quality/lib/mix/tasks/quality.ex:542` writes a stage's captured
output only for *failures*. `--verbose` does not change this - only the Sobelow
stage consults it (`deps/ex_quality/lib/ex_quality/stages/sobelow.ex:280`). So
the gate's own console line stays one line no matter what this plan does; the
figures are seen by running the tasks.

`docs/testing.md:165-166` records the target to beat as v1's final baseline,
"**90/127 SCION, 27/59 W3C**". Those denominators are v1's *emitted* corpus:
`../statifier/test/scion_tests` holds 127 `_test.exs` files and
`../statifier/test/scxml_tests` holds 59. v1 emitted every native SCION case and
a much smaller W3C selection; v2 excludes some of each at generation time.

## Desired End State

Two commands print per-corpus figures, and no other behavior changes:

```
$ mix test.baseline --only scion
Checking 11 untracked conformance test files...
2 newly passing, 9 still failing (not a regression - these were never tracked).
  + test/scion_tests/...
Corpus coverage (ratcheted + newly passing / emitted corpus files):
  SCION: 109/118 (92.4%)
Emitted files only; cases excluded at generation time are not counted (tools/corpus/README.md).

$ mix test.regression
Running 167 regression test files...
All 167 regression test files passed.
Corpus coverage (ratcheted / emitted corpus files):
  SCION: 107/118 (90.7%)
  W3C:    58/159 (36.5%)
Emitted files only; cases excluded at generation time are not counted (tools/corpus/README.md).
```

Verified by: the two tasks' unit tests asserting the lines against fixture
trees, and by eye on a real `mix quality` run, where the `Regression ratchet`
stage's output now carries the figures.

### Key Discoveries

- The denominator function already exists and is already fixture-parameterized:
  `RegressionRegistry.corpus_files/2`
  (`lib/mix/statifier/regression_registry.ex:286-298`).
- The baseline scan's numerator is `tracked ++ passing`, both already in hand at
  `lib/mix/tasks/test.baseline.ex:102`; only `tracked` is currently discarded
  inside `candidates/3` (`:108-113`).
- A registry entry may be a glob and may point anywhere, so the numerator must
  be a set intersection with the corpus glob, not a length. `expand_patterns/1`
  (`:167-178`) already returns only files that exist.
- Doctor runs at 100% on every axis (`.doctor.exs`), so every new public
  function needs a `@doc` and a `@spec`; the module already carries doctests and
  new ones are the cheapest way to cover the formatter.
- `mix test.regression` has no `root` seam today
  (`lib/mix/tasks/test.regression.ex:50-60`); Phase 2 adds one, matching
  `Baseline.execute/2`'s existing `opts[:root]`
  (`lib/mix/tasks/test.baseline.ex:57-65`).
- Changelog: `changelog.d/README.md` explicitly excludes "test harness, corpus
  tooling, or conformance fixtures" from fragments. This work is entirely that,
  so **no `changelog.d/st-up2.md` fragment is written**.
- **The gate's console will not show the figures, and this plan does not try to
  make it.** A passing custom command stage renders as one summary line
  (`command.ex:284`, `quality.ex:542`). Surfacing the numbers there would mean
  teaching `mix test.regression` a JSON document mode and editing the stage's
  `args` in `.quality.exs` - a path ADR-0011 guards, needing a
  `docs/quality-gate-changes.md` entry that CLAUDE.md says is a human's call, not
  an agent's. Out of scope; see "What We're NOT Doing".
- Because no guarded file is touched, this branch needs no ledger entry and the
  `Gate guard` stage has nothing to flag.

## Decisions this plan makes

The bead left two calls open. Both are decided here.

### Decision 1: extend the existing tasks, no new mix task

`mix test.baseline` is the home for the *measured* figure, and
`mix test.regression` gains the *ratcheted* figure. No `mix corpus.stats` is
added.

Rationale:

- The baseline scan already runs every untracked corpus file individually and
  already globs the corpus. The percentage is a two-line addition to output it
  has already paid for; a new task would either duplicate that scan (minutes of
  nested `mix test` runs) or report a strictly weaker number.
- The bead's real ask is "a single job run tells you", and the cheapest such run
  is `mix test.regression`: it already resolves the registry and already knows
  its run was green, so the ratcheted figure costs nothing and arrives in
  seconds, without the baseline scan's nested `mix test` per untracked file.
  That is the run-free figure a `mix corpus.stats` task would have provided, on
  a command that already exists.
- A new task would have to re-derive both halves and would still be a command
  someone has to remember to type, so it buys nothing over putting the same two
  lines on the two commands people already run when they care about conformance.
- Both tasks are already thin wrappers over one pure module
  (`docs/testing.md:157-159`); keeping the arithmetic in
  `RegressionRegistry` preserves that and keeps the two outputs from drifting.

The two figures differ, deliberately, and each is labeled for what it is:

| Command | Numerator | Meaning |
| --- | --- | --- |
| `mix test.regression` | registry files in the suite dir, all just run green | the floor: what is guaranteed to pass |
| `mix test.baseline` | that same set plus the files that passed in this scan | the true current figure, including work not yet ratcheted |

The baseline numerator counts tracked files that this invocation did not itself
re-run - the scan skips them by construction (`:108-113`). That is sound because
`mix test.regression` is what guarantees them, and it is why the baseline line is
worded "ratcheted + newly passing" rather than plain "passing".

### Decision 2: the total is emitted corpus files on disk

`total` is `length(RegressionRegistry.corpus_files(category, root))` - 118 SCION
and 159 W3C today - not the 127/193 upstream suite sizes.

Rationale:

- It is the only denominator 100% is reachable against. The excluded cases are
  excluded because they have no predicator equivalent (ADR-0004,
  `tools/corpus/*/exclusions.exs`) or are not standalone tests at all
  (`sub_documents.exs`). A percentage that can never reach 100 measures the
  datamodel commitment, not progress.
- It cannot drift. Regenerating the corpus moves the denominator in the same
  commit that moves the files; an upstream count would be a constant in
  `lib/` that rots the first time `mise run corpus` changes an exclusion.
- It keeps the number comparable to the recorded target. `docs/testing.md:165`
  quotes v1 as 90/127 SCION and 27/59 W3C, and those denominators are v1's
  *emitted* corpus (127 and 59 files on disk in `../statifier`), not upstream
  suite sizes. Emitted-over-emitted is the like-for-like comparison.
- Reading the upstream size at runtime would mean a task under `lib/mix/`
  evaluating `tools/corpus/scxml_w3/manifest.exs` and two `exclusions.exs`
  files - a hard coupling from the test harness to the generator, for a second
  denominator nobody acts on.

The cost is that the figure overstates conformance against the published suites,
so the output carries a standing one-line caveat naming
`tools/corpus/README.md`, and Phase 3 states the same thing in
`docs/testing.md`. The upstream counts stay documented there, in prose, where
they are already maintained by hand.

## What We're NOT Doing

- **No new mix task**, and no `--stats` no-run flag on `mix test.baseline`.
  Decision 1 already delivers a run-free figure through
  `mix test.regression`, which is faster to reach than a flag on the slow task.
- **No second, upstream-sized denominator** in task output (Decision 2). The
  emitted/upstream gap is documented, not computed.
- **No machine-readable output** (JSON, a written stats file, a gate threshold),
  and **no attempt to put the figures on the gate's own console line.** The
  mechanism that would work is known and deliberately deferred: teach
  `mix test.regression` a `--format json` document whose `"summary"` field
  carries the two figures, then change the `Regression ratchet` stage's `args`
  in `.quality.exs` to pass it, at which point `ExQuality.Stages.Command` prints
  that summary instead of `"Passed"`
  (`deps/ex_quality/lib/ex_quality/stages/command.ex:275`). That edits a path
  ADR-0011 guards, so it needs a `docs/quality-gate-changes.md` entry, which
  CLAUDE.md reserves for a human. If the figure on every gate run is wanted, it
  is a follow-up bead with a human on the ledger, not a quiet addition here.
  A percentage threshold that fails the gate is likewise out of scope: that is a
  ratchet redesign.
- **No per-section or per-spec breakdown** (`test/scxml_tests/<conformance>/...`).
  Two lines is the ask.
- **No change to what the ratchet tracks or how it grows.**
  `test/passing_tests.json` is read, never written differently.
- **No changelog fragment**, per `changelog.d/README.md`'s exclusion of test
  harness and corpus tooling.

## Implementation Approach

Three phases along the module boundary the project already has: the pure
registry module, then each task that consumes it, then the docs. Phase 1 is
self-contained and ships a visible improvement on its own; Phase 2 depends on
Phase 1's function existing but nothing else; Phase 3 touches no Elixir.

---

## Phase 1: Corpus statistics in the registry, reported by `mix test.baseline`

### Overview

Add the pure arithmetic and formatting to `Mix.Statifier.RegressionRegistry`,
and print it at the end of a `mix test.baseline` scan.

### Changes Required

#### 1. Pure statistics and formatting

**File**: `lib/mix/statifier/regression_registry.ex`
**Changes**: add a suite-label table and three public functions, each with
`@doc`, `@spec`, and doctests where the inputs are cheap.

```elixir
@suite_labels %{scion: "SCION", w3c: "W3C"}

@type stats :: %{passing: non_neg_integer(), total: non_neg_integer(), percent: float() | nil}

@doc "Human-readable name of a conformance suite."
@spec suite_label(category :: category()) :: String.t() | nil
def suite_label(category), do: Map.get(@suite_labels, category)

@doc """
How much of `category`'s emitted corpus `passing` covers.

`total` counts the test files on disk under the suite directory, which is the
only denominator the ratchet can reach 100% of - cases excluded at generation
time (`tools/corpus/*/exclusions.exs`) never emit a file. `percent` is `nil`
when the corpus is empty, so callers report "no files" rather than dividing by
zero.
"""
@spec corpus_stats(passing :: [String.t()], category :: category(), root :: String.t()) :: stats()
def corpus_stats(passing, category, root \\ ".") do
  total = corpus_files(category, root)
  hit = passing |> MapSet.new() |> MapSet.intersection(MapSet.new(total)) |> MapSet.size()
  %{passing: hit, total: length(total), percent: percent(hit, length(total))}
end

defp percent(_hit, 0), do: nil
defp percent(hit, total), do: Float.round(hit * 100 / total, 1)

@doc """
One report line per conformance category, plus the denominator caveat.

Returns `[]` when no category has any emitted files, so a fixture tree with no
corpus prints nothing at all.
"""
@spec stats_lines(passing :: [String.t()], categories :: [category()], root :: String.t()) :: [String.t()]
def stats_lines(passing, categories, root \\ ".")
```

The intersection matters: registry entries may be globs and may name files
outside the suite directories, so the numerator must be "tracked files that are
also emitted corpus files", never a list length.

`stats_lines/3` pads the labels so the counts line up, and emits nothing for a
category whose `total` is `0`.

#### 2. Baseline reporting

**File**: `lib/mix/tasks/test.baseline.ex`
**Changes**: keep the tracked set that `candidates/3` currently throws away, and
print the block after `report/2`.

- Change `candidates/3` to return `{candidates, tracked}` (or add a sibling that
  returns the tracked set), so `scan/4` has both halves of the numerator.
- After `report(passing, failing)`, print:

  ```
  Corpus coverage (ratcheted + newly passing / emitted corpus files):
    SCION: 109/118 (92.4%)
  Emitted files only; cases excluded at generation time are not counted (tools/corpus/README.md).
  ```

  built from `RegressionRegistry.stats_lines(tracked ++ passing, categories, context.root)`.
- The `--only` filter already narrows `categories`, so the block narrows with it
  for free.
- The `"No untracked conformance tests found"` early return
  (`lib/mix/tasks/test.baseline.ex:96-98`) prints the block too - a fully
  ratcheted corpus is exactly when the figure is most worth seeing.
- The `add` subcommand prints nothing new: it verifies named files and never
  scans, so it has no denominator in hand.
- Extend the `@moduledoc` to describe the new output and what its numerator
  includes.

#### 3. Tests

**File**: `test/mix/statifier/regression_registry_test.exs`
**Changes**: cover `corpus_stats/3` and `stats_lines/3` against a fixture tree -
the intersection dropping a tracked path outside the corpus, an empty corpus
yielding `percent: nil` and no lines, and rounding to one decimal.

**File**: `test/mix/tasks/test_baseline_test.exs`
**Changes**: assert the coverage block in the existing scan tests' captured
output, including that `--only scion` prints only the SCION line and that the
"nothing untracked" path still prints the block.

Every new test carries its sabotage line per `docs/testing.md`, e.g.
`# sabotage: have corpus_stats/3 use length(passing) instead of the intersection -> red`.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes (use `mix quality --profile loop` while
      iterating; a loop run alone does not satisfy this phase).
- [x] `mix gate.verify` confirms the green run was a full, unscoped gate.
- [x] Doctor stays at 100% - every new public function has `@doc` and `@spec`.
- [x] `mix test.regression` still passes; the registry file is unchanged by this
      branch (`git diff --stat test/passing_tests.json` is empty).
- [x] `mix test test/mix/statifier/regression_registry_test.exs test/mix/tasks/test_baseline_test.exs`
      passes.

#### Manual Verification:

- [ ] `mix test.baseline --only scion` prints a SCION line whose numbers match
      `find test/scion_tests -name '*_test.exs' | wc -l` and the registry's
      `scion_tests` length, and prints no W3C line.
- [ ] Each new test was sabotaged red and reverted, with the mutation noted in
      one line above it.
- [ ] The wording distinguishes "ratcheted + newly passing" from a claim that
      every counted file ran in this invocation.
- [ ] No regressions in `mix test.baseline add <file>` behavior.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: `mix test.regression` reports the ratcheted figure

### Overview

Print the same block from `mix test.regression` after a green run, so the
ratcheted figure is available in seconds from a command that resolves the
registry anyway.

Note for the implementer: the gate runs this task
(`.quality.exs:82-88`) but renders a passing command stage as the single line
`Passed` and writes stage output only on failure
(`deps/ex_quality/lib/ex_quality/stages/command.ex:284`,
`deps/ex_quality/lib/mix/tasks/quality.ex:542`). Do not chase the figures into
`mix quality`'s console - that is deliberately out of scope, for the ADR-0011
reason recorded in "What We're NOT Doing".

### Changes Required

#### 1. A root seam and the report

**File**: `lib/mix/tasks/test.regression.ex`
**Changes**:

- Add `opts[:root]`, defaulting to `"."`, alongside the existing
  `opts[:runner]` (`:50-60`), matching `Baseline.execute/2`'s seam. Document it
  in the `@doc` the same way baseline's is documented
  (`lib/mix/tasks/test.baseline.ex:47-55`).
- In `run_tests/2`, after `"All #{count} regression test files passed."`, print:

  ```
  Corpus coverage (ratcheted / emitted corpus files):
    SCION: 107/118 (90.7%)
    W3C:    58/159 (36.5%)
  Emitted files only; cases excluded at generation time are not counted (tools/corpus/README.md).
  ```

  from `RegressionRegistry.stats_lines(files, RegressionRegistry.conformance_categories(), root)`.
  `files` is the resolved registry set that just passed, and `stats_lines/3`'s
  intersection discards the internal-test entries.
- Print only on success. A failing run's output belongs to ExUnit, and a
  percentage under a red ratchet would be a lie about which files pass.
- Extend the `@moduledoc` with the new output line.

#### 2. Tests

**File**: `test/mix/tasks/test_regression_test.exs`
**Changes**: with a fixture corpus tree and a stub runner returning `0`, assert
both suite lines and their arithmetic; with a runner returning non-zero, assert
the block is absent and the error is unchanged. Sabotage line on each.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes (loop gate while iterating only).
- [x] `mix gate.verify` confirms a full, unscoped green run.
- [x] `mix test test/mix/tasks/test_regression_test.exs` passes.
- [x] Doctor stays at 100%.
- [x] `test/passing_tests.json` is unchanged by this branch.

#### Manual Verification:

- [ ] A direct `mix test.regression` run shows both suite lines with correct
      numbers, after the "All N regression test files passed." line.
- [ ] A bare `mix quality` still renders the `Regression ratchet` stage as its
      usual one-line pass summary, and its total runtime is unchanged. This
      confirms the plan added no output the gate has to swallow, and is the
      expected result, not a shortfall.
- [ ] A deliberately failing ratchet (temporarily point `--registry` at a
      registry naming a failing file) prints no coverage block and the same
      error text as before; revert afterwards.
- [ ] Each new test was sabotaged red and reverted, with the mutation noted.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 3: Document the two figures and the denominator

### Overview

Record in `docs/testing.md` what each figure means and why the denominator is
the emitted corpus, so the number is not misread as conformance against the
published suites.

### Changes Required

#### 1. The regression ratchet section

**File**: `docs/testing.md`
**Changes**: in the ratchet section (`:138-166`), after the two task bullets,
add a short subsection stating:

- both tasks report per-corpus coverage, and which numerator each uses;
- that the figures appear when the tasks are run directly, not in `mix quality`'s
  stage summary, and why (a passing command stage renders as one line;
  changing that means a JSON summary mode plus a guarded `.quality.exs` edit
  with a ledger entry);
- the denominator is emitted corpus files (118 SCION, 159 W3C today), not the
  upstream suites (127 SCION, 193 W3C), with the reason from Decision 2 and a
  pointer to `tools/corpus/README.md`;
- that the v1 target at `:165-166` (90/127 SCION, 27/59 W3C) is stated over v1's
  own *emitted* corpus, so the comparison is like-for-like. Amend that sentence
  to say so explicitly rather than leaving the denominators ambiguous.

House style: this file is ASCII, hyphens only - match it.

#### 2. Corpus README cross-reference

**File**: `tools/corpus/README.md`
**Changes**: one sentence in the Status section noting that
`mix test.regression` and `mix test.baseline` report coverage against the
emitted counts documented there, so a future edit to the exclusion counts knows
what reads them.

### Success Criteria:

#### Automated Verification:

- [x] Full `mix quality` passes (this phase touches no Elixir, so the gate is a
      no-change confirmation, but it still runs).
- [x] `mix gate.verify` confirms a full, unscoped green run.

#### Manual Verification:

- [ ] The counts written into the docs match what the corpus actually holds,
      checked by running `find test/scion_tests -name '*_test.exs' | wc -l` and
      the same for `test/scxml_tests` and reading the prose against them. This
      is a manual item on purpose: nothing compares a number in prose to a shell
      count, and labeling it automated would let a green gate stand in for a
      check no command performed.
- [ ] A reader of `docs/testing.md` alone can tell why the SCION figure is over
      118 and not 127.
- [ ] The docs say the figures come from running `mix test.regression` or
      `mix test.baseline` directly, and do not promise them in `mix quality`'s
      stage summary.
- [ ] The v1-target sentence no longer invites an apples-to-oranges reading.
- [ ] No stray typographic characters introduced into an ASCII file.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Corpus/Ratchet Notes

This plan reads `test/passing_tests.json` and never writes it. No corpus
regeneration happens, no test file is emitted or removed, and no entry is
ratcheted in - so the `Gate guard` stage has nothing to flag and
`docs/quality-gate-changes.md` needs no entry.

Both figures are derived, so they follow the ratchet automatically: a later
branch that ratchets tests in moves the reported percentage with no code change
here. Conversely, a corpus regeneration that emits more files lowers the
percentage in the same commit that adds them, which is the honest behavior.

The one standing caveat worth naming for a future reader: the baseline figure
counts ratcheted files it did not re-run in that invocation. If someone ever
runs `mix test.baseline` on a branch with a red ratchet, its number will be
optimistic. `mix test.regression` is the check that keeps that from being
misleading, and the gate runs it on every non-loop profile.

## Performance Considerations

`stats_lines/3` adds two `Path.wildcard/1` calls and two MapSet intersections
over a few hundred paths - microseconds against a task that already spawns
`mix test`. `mix test.regression` gains no test runs at all, so the gate's
runtime is unchanged. `mix test.baseline`'s cost is unchanged: it already ran
every untracked file.

## Testing Strategy

### Unit Tests

- `test/mix/statifier/regression_registry_test.exs` - `corpus_stats/3` against a
  fixture tree: exact counts, one-decimal rounding, `percent: nil` on an empty
  corpus, and a tracked path outside the corpus directory excluded from the
  numerator by the intersection. `stats_lines/3`: label alignment, category
  filtering, `[]` when nothing is emitted. Doctests for `suite_label/1`.
- `test/mix/tasks/test_baseline_test.exs` - the coverage block appears in scan
  output with the right numbers, narrows under `--only`, appears on the
  "nothing untracked" path, and does not appear for `add`.
- `test/mix/tasks/test_regression_test.exs` - the block appears after a green
  run and is absent after a failing one.

All new tests use `@tag :isolated_tmp_dir` with `Statifier.TmpDir`, never
ExUnit's `@tag :tmp_dir`, and each carries its sabotage line.

### Manual Testing Steps

1. `mix test.baseline --only scion` and check the SCION line against
   `find test/scion_tests -name '*_test.exs' | wc -l` (118) and the registry's
   `scion_tests` length (107 today).
2. `mix test.baseline --only w3c` and check the W3C line the same way against
   159 and 58.
3. `mix test.regression` and confirm both lines appear only after the "All N ...
   passed." line.
4. `mix quality` and confirm the `Regression ratchet` stage is unchanged - still
   one pass line, no new noise, no added runtime. The figures are not expected
   here.
5. Confirm `mix test.baseline add <a passing file>` prints no coverage block and
   behaves exactly as before.

## References

- Bead: `st-up2`
- Registry module: `lib/mix/statifier/regression_registry.ex:286-298`
  (`corpus_files/2`), `:149-154` (`expand/2`)
- Baseline task: `lib/mix/tasks/test.baseline.ex:94-125`
- Regression task: `lib/mix/tasks/test.regression.ex:50-91`
- Gate wiring: `.quality.exs:82-88` (`Regression ratchet` stage)
- Why the gate console shows only a summary:
  `deps/ex_quality/lib/ex_quality/stages/command.ex:206-221, :275, :284` and
  `deps/ex_quality/lib/mix/tasks/quality.ex:542`
- Ratchet docs: `docs/testing.md:138-166`
- Corpus counts and exclusion rationale: `tools/corpus/README.md:80-142`
- ADR-0004 (excluded cases carry a recorded reason), ADR-0006 (reuse the
  conformance corpus and the regression ratchet), ADR-0011 (gate-config edits
  need a ledger entry - none needed here)
- Changelog policy: `changelog.d/README.md` (no fragment for test-harness work)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

All items below were walked through and confirmed on 2026-08-14, against the
branch at `1b4da9b`. One item did not hold on the first pass; it is annotated
in place and fixed by `d32fd54`.

### Phase 1

- [x] `mix test.baseline --only scion` prints a SCION line whose numbers match
      `find test/scion_tests -name '*_test.exs' | wc -l` and the registry's
      `scion_tests` length, and prints no W3C line.
      Confirmed: `SCION: 107/118 (90.7%)`, no W3C line; 118 from `find`, 107
      from the registry's `scion_tests` length.
- [x] Each new test was sabotaged red and reverted, with the mutation noted in
      one line above it.
      Confirmed: the gate's sabotage scan reports no `missing` and no
      `unverifiable` entries. Two mutations were re-run by hand during this
      walkthrough - see the Phase 2 annotation.
- [x] The wording distinguishes "ratcheted + newly passing" from a claim that
      every counted file ran in this invocation.
      Confirmed: the header reads `Corpus coverage (ratcheted + newly passing
      / emitted corpus files):`, and the task's moduledoc states that tracked
      files the invocation skipped re-running are still counted.
- [x] No regressions in `mix test.baseline add <file>` behavior.
      Confirmed: the diff leaves `add_named/3` untouched, changing only
      `scan/4` and `candidates/3`; all 20 tests in the file pass.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

### Phase 2

- [x] A direct `mix test.regression` run shows both suite lines with correct
      numbers, after the "All N regression test files passed." line.
      Confirmed: `SCION: 107/118 (90.7%)` and `W3C: 58/159 (36.5%)`.
- [x] A bare `mix quality` still renders the `Regression ratchet` stage as its
      usual one-line pass summary, and its total runtime is unchanged. This
      confirms the plan added no output the gate has to swallow, and is the
      expected result, not a shortfall.
      Confirmed across two runs: `Regression ratchet: Passed (6.1s)` and
      `(6.7s)`, one line, no coverage output. Runtime was not benchmarked
      against `main`; the work added to the stage is one `Path.wildcard` per
      suite, which is below the run-to-run spread those two numbers show.
- [x] A deliberately failing ratchet (temporarily point `--registry` at a
      registry naming a failing file) prints no coverage block and the same
      error text as before; revert afterwards.
      Confirmed against a scratch registry naming an untracked, failing SCION
      file: no coverage block, and the unchanged "regression failure (mix test
      exited 2)" text.
- [x] Each new test was sabotaged red and reverted, with the mutation noted.
      **Did not hold on the first pass.** Both new tests here carried a
      `sabotage: n/a` note claiming no `lib/` code path could print a coverage
      block on the branch they assert about. Both claims were wrong - the
      mutation is to call `print_coverage` from that branch - and running it
      split them:

      - `add prints no coverage block` (baseline) went red. Sound test, wrong
        note; the note now names the mutation that was run.
      - `a failing run prints no coverage block` (regression) stayed green.
        It was vacuous: it built its corpus file as `scion_tests/...`, but
        `corpus_files/2` globs `<root>/test/scion_tests/**`, so the corpus was
        empty, `stats_lines/3` returned `[]`, and the `refute` held whatever
        the failing branch printed. The trap is that the two files' tmp-tree
        helpers differ - the baseline file's `corpus/2` joins `[tmp_dir,
        "test", relative]` while the regression file's `test_file/2` does not
        add `test/`.

      Fixed in `d32fd54`: the path gains its `test/` prefix, the mutation now
      goes red, and both notes name a mutation that was actually run.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

### Phase 3

- [x] The counts written into the docs match what the corpus actually holds,
      checked by running `find test/scion_tests -name '*_test.exs' | wc -l` and
      the same for `test/scxml_tests` and reading the prose against them. This
      is a manual item on purpose: nothing compares a number in prose to a shell
      count, and labeling it automated would let a green gate stand in for a
      check no command performed.
      Confirmed: 118 and 159, matching the prose in both files.
- [x] A reader of `docs/testing.md` alone can tell why the SCION figure is over
      118 and not 127.
      Confirmed: the section names the upstream 127, says the excluded cases
      have no predicator equivalent, and points at `tools/corpus/README.md`
      for the per-exclusion detail.
- [x] The docs say the figures come from running `mix test.regression` or
      `mix test.baseline` directly, and do not promise them in `mix quality`'s
      stage summary.
      Confirmed, and it matches the gate runs observed above.
- [x] The v1-target sentence no longer invites an apples-to-oranges reading.
      Confirmed, and the claim it now makes was checked against the v1 tree:
      `../statifier/test/scion_tests` holds 127 `_test.exs` files and
      `../statifier/test/scxml_tests` holds 59, so 90/127 and 27/59 are indeed
      emitted-corpus figures.
- [x] No stray typographic characters introduced into an ASCII file.
      Confirmed: no added line anywhere on the branch contains a non-ASCII
      character.

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution, pause
here for the human to confirm the manual testing before moving to the next
phase. In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
