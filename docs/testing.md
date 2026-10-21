# Testing strategy

**Read this to:** write, run, or gate tests in this repo.

**Short version:** the conformance corpus is the contract. Every new test of
`lib/` behavior needs a sabotage note. The regression ratchet only moves
forward. `mix quality` must be green before you commit.

The generated SCION/W3C test files use no library internals. They all go
through one `Statifier.Testing.Case` module. Generated files still say
`Statifier.Case`, a `test/support` shim over it.

Decision: [ADR-0006](adr/0006-reuse-conformance-corpus-and-regression-ratchet.md),
ADR-0053.

## The three suites

| Suite | Path | Tag | Size | Default run |
|---|---|---|---|---|
| Internal | `test/statifier/...` | none | unit tests for the parser, machine compiler, interpreter functions, and datamodel, in pattern-matching style | included |
| SCION | `test/scion_tests/` | `:scion` | 119 emitted tests out of 127 native upstream cases | excluded |
| W3C | `test/scxml_tests/` | `:scxml_w3` | 168 emitted tests (154 mandatory, 14 optional) out of 193 upstream cases | excluded |

- Generation excludes the rest of the SCION cases. The count and the reason for
  each case are in `tools/corpus/scion/exclusions.exs`.
- Generation does not emit a dependency document that an `<invoke>` loads at
  runtime (manifest `<dep>` entries) as a standalone W3C test.
- Details: `tools/corpus/README.md`.

`Statifier.Testing.Case.test_scxml/4` needs four things from the library:
parse, build/initialize, synchronous send-event, and the active leaf-state
set. These four things are the whole coupling surface. Keep it that way.

### A fourth, hand-run suite: the ADR judge corpus

`Mix.Statifier.AdrJudge` (`lib/mix/statifier/adr_judge.ex`) judges the diff of
a branch against a registry of ADRs. For each candidate it makes two real
`claude` CLI calls: a proposal, then an adversarial refutation. The ordinary
suite cannot show whether a prompt change to that module helped or hurt, so
`test/mix/statifier/adr_judge_corpus_test.exs` exists as a fourth suite. It
differs from the three above in kind, not only in tag.

**What it is.** A manifest (`test/fixtures/adr_judge/manifest.exs`) binds each
hand-written unified-diff fixture (`test/fixtures/adr_judge/*.diff`) to two
things: the judged-ADR key that it targets, and the verdict that it must
produce (`:violation` or `:clean`).

- Each registry entry has at least one fixture of each verdict.
- Each manifest row generates one ExUnit test.
- The test calls `AdrJudge.analyze/2` with `caller: &AdrJudge.call_claude_cli/1`
  passed explicitly. It is the one place in the suite that deliberately uses
  the real CLI.

**Why it is excluded.**

- It makes real CLI calls and costs real money.
- The full corpus takes about 15-20 minutes (about two model round trips per
  fixture).
- The tag is `:adr_judge_corpus`. `test/test_helper.exs` excludes it as it
  does `:scion` and `:scxml_w3`.
- The `@default_caller` of `:test` still raises on a missing `opts[:caller]`
  everywhere else. The tests of this module keep injecting stubs. Only the
  corpus test module uses the real caller, at its own call site.

**How to run it.**

- `mix test --only adr_judge_corpus` runs the paid corpus.
- `mix test --only tier:subtle` runs one tier.
- `mix test --only fixture:<name>` runs one fixture. Use it while you word a
  new fixture. It costs one model round trip, not the whole corpus.
- `test/mix/statifier/adr_judge_corpus_shape_test.exs` needs no caller. It runs
  in the ordinary suite and keeps the corpus from decaying between hand-runs.
  It checks these conditions:
  - Every manifest file exists.
  - Every key is real.
  - Every registry entry has a violating fixture and a clean fixture in every
    tier where it has a row.
  - Every tier is `:blatant` or `:subtle`.
  - The diff of every fixture lands in its own scope and not in another one.
  - No fixture contains the literal `@tag :skip`. That text would trigger the
    skip-tag scan of `Mix.Statifier.GateGuard`, because fixtures live under
    `test/`.

**Tiers.** Every manifest row has a `:tier`.

- `:blatant`: a deletion or omission that the deterministic guards (`AdrGuard`,
  `GateGuard`) would also catch, or that a reviewer would see at once.
- `:subtle`: a violation that keeps the shape of the change it fakes and
  breaks only its meaning.

**How to read a failure.** The failure message names one of three problems:

- A false negative: a known-violating fixture produced no surviving finding.
- A false positive: a known-clean fixture produced a finding.
- A wrong-ADR attribution: a violation survived under the wrong registry key.

**Recorded scores.** All scores in the first table are on the `:blatant` tier
(the original eight fixtures: 4 violating, 4 clean). Model:
`claude-haiku-4-5-20251001` unless noted.

| Run | False negatives | False positives | Wall time |
|---|---|---|---|
| Baseline (2026-08-08, unmodified `refute_prompt/1`) | 4/4 | 0/4 | 357.9s |
| Phase 2 (grounded `refute_prompt/1`, hunks shown) | 0/4 | 0/4 | 272.4s |
| Phase 4, `claude-sonnet-5` (same grounded prompt) | 0/4 | 0/4 | 91.4s |

The prompt rework (st-6f7 Phase 2) closed every false negative. Accuracy is
equal on both models. `@default_model` is `claude-sonnet-5` because of wall
time: 91.4s against 272.4s here, and 19.6s against 54.4s on a real
three-entry `mix adr.judge`. This trades token cost for gate time on a stage
that is opt-in and runs only in the `:merge` profile.
`STATIFIER_ADR_JUDGE_MODEL` overrides the default.

Sources: `Mix.Statifier.AdrJudge` moduledoc and the Phase 4 measurement
section of `docs/plans/260808-st-6f7-adr-judge-refute-grounding.md`.

The `:subtle` tier joined the corpus alongside the original eight `:blatant`
fixtures (st-2ts, `docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md`). It
has fourteen fixtures (seven per-registry-entry pairs). It was measured on
2026-08-18 under Decision 2 of that plan: three runs per model at seeds
101/202/303. The verdict of a fixture is the majority of its three runs.

Two ADR-0012 pairs came later:

- A sixth pair (st-xsb1) separates a payload field that is stamped from the
  wrong state from one that is deliberately read after the mutation. It came
  with an amendment to the text of ADR-0012. The amendment required a partial
  re-measurement, which is row 3 below.
- A seventh pair (st-6f7h) separates a `Trace.ExitSet` stamp that is wrongly
  taken after the mutation from a `Trace.Done` stamp that is rightly taken after
  it. Both trace calls are visible in the same hunk. It was measured on
  2026-08-19, which is row 4 below.

| Tier | Model | False negatives | False positives | Flaps | Wall (mean) |
|---|---|---|---|---|---|
| subtle | `claude-sonnet-5` | 3/5 | 0/5 | 3/10 | 145.7s |
| subtle | `claude-haiku-4-5-20251001` | 1/5 | 0/5 | 3/10 | 890.6s |
| ADR-0012 subtle only, 6 rows (partial, st-xsb1) | `claude-sonnet-5` | 1/3 | 0/3 | 0/6 | 21.5s |
| ADR-0012 subtle, 2 new rows, first measurement (st-6f7h) | `claude-sonnet-5` | 1/2 | 0/2 | 0/2 | 17.9s |

How to read rows three and four. Neither replaces a row above it.

- **Row 3 (st-xsb1).** A partial re-measurement of the six ADR-0012 rows on one
  model. The two rows above it cover the whole ten-fixture tier on two models
  and still stand. This row exists because the amendment to the text of
  ADR-0012 invalidated the earlier ADR-0012 numbers without saying in which
  direction. The amendment moved two violation rows from false negative to
  caught. One of them is the row that st-ntf5 measured by hand as a false
  negative against the unamended rubric. The amendment caused no false positive
  on either clean row.
  `0012_location_precision_one_caller.diff` is still missed. Phase 5 of
  `docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md` has the per-fixture
  matrix. It also shows that this row points to the wording of the ADR, not to
  the judge.
- **Row 4 (st-6f7h).** A first measurement of the site-B `exit_interpreter/1`
  pair that st-6f7h Phase 1 added, on `claude-sonnet-5` only. It covers a
  two-fixture slice. The rows above it cover wider slices (ten and six
  fixtures), so this row re-measures nothing above it.
  - The judge missed the violation row
    (`0012_exit_sweep_stamp_swapped_beside_done.diff`) in all runs across seeds
    101/202/303. The propose step returned no candidate, so the miss is a
    failure to propose, not an over-rejection by the refute pass. One cell was
    not captured. It was a real miss whose assertion text was not recorded.
  - The judge acquitted the clean row (`0012_done_trace_stamped_post_sweep.diff`)
    in all runs.
  - The plan predicted the inverse: it expected the clean row, not the
    violation row, to be the likely miss.
  - Open question: does content, hunk width, or production site explain the
    miss?
  - Matrix and provenance: Phase 5 of the st-2ts plan above and
    `docs/plans/260819-st-6f7h-interpreter-exitset-trace-coverage.md`.

**What the scores mean.**

- The subtle tier separates the two models where the blatant tier does not.
  This is the reason the tier exists.
- It separates them against the current `@default_model`. Haiku is the more
  accurate model here, at about six times the wall time. The accuracy tie that
  justified the `claude-sonnet-5` default no longer holds. The attribute stays
  unchanged on purpose. The findings of the st-2ts plan recommend that you
  reconsider it.
- Read the blatant-tier rows as single-run observations, not as a reproducible
  floor. In the control runs of 2026-08-18 (one per model, seed 101), each
  model produced one false positive on a known-clean fixture: sonnet on
  `0015_mechanics_only.diff`, haiku on `0014_span_preserving_refactor.diff`.
  The recorded baseline is 0/4. Neither run used the majority-of-three policy.
  To re-record that table, re-measure under that policy.

## Sabotage testing

A test that passes on its first run proves nothing yet. It can assert real
behavior. It can also assert a tautology, run a branch that its setup never
reaches, or check a variable that the code never touches. To tell these apart,
break the code and watch what happens.

Every new or changed test that asserts `lib/` behavior must pass a sabotage
check before you consider it done:

1. Get the test green.
2. Break the implementation that the test covers. Make one edit, in `lib/`, in
   the code path that the test claims to cover.
3. Run the test. It must fail, and the failure must be about the thing that the
   test is for.
4. Revert the sabotage. Confirm that the test is green again.
5. Record the mutation in a one-line comment directly above the test.

The comment is the record. Without it, the next reader cannot tell a verified
test from a test that only passed:

```elixir
# sabotage: enter_states/2 skips the initial child -> red
test "compound state enters its initial descendant" do
  ...
end
```

Format: `# sabotage: <what was broken> -> red`. Use one line in the present
tense. Name the function and the mutation. Put the line above the `test` line
and above any `@tag`.

**A valid mutation.** It must be a change that a reasonable person could make
by mistake.

- Good examples: invert a condition, drop a clause, skip a recursive call,
  return the input unchanged, use the wrong set operation, change a boundary
  by one.
- Not sabotage: deleting the function body, or raising. Everything fails, so
  you learn nothing.
- The mutation must also fire. The note must name a change that alters
  behavior for the case under test. A change that type-checks but leaves every
  value it touches unchanged does not fire.

**The truthy-sentinel trap.** The `||` operator is the most common cause of a
mutation that never fires. In Elixir, `||` uses its right side only when the
left side is `nil` or `false`. Every other value is truthy and skips the
fallback. This includes `:undefined`, `:none`, `0`, and `""`.

Assume a note that proposes `x || fallback` against one of these sentinel
values. The mutated line runs and produces the same value as before, and the
suite stays green. This green result does not mean that the test verified
anything. You cannot tell it from a note whose mutation ran and was reverted.
That is the failure this section exists to prevent.

The sabotage scan of `mix quality` cannot catch this. It checks only that a
`# sabotage:` note exists above the test. It does not check that the mutation
would change the value under test.

A real case: a note claimed to break `resolve_params/2` by defaulting its
params with `params || %{}`, where the incoming `params` was `:undefined`.

```elixir
# does NOT fire - :undefined is truthy, `||` never reaches the fallback
params || %{}

# fires - :undefined is mapped to a real default
if params == :undefined, do: %{}, else: params
```

Before you write a mutation with `||`, check what the left side is for the
case under test. If it can be a truthy sentinel, use an explicit `if` or a
pattern match that maps the sentinel to the fallback.

**Two failures to catch.**

- If the test stays green, it does not test what its name says. Fix the test.
  Do not weaken the sabotage.
- If one mutation turns twenty tests red, they all assert one thing through
  twenty doors. Note this, and check whether the coverage is as broad as it
  looks.

**Exempt.** Generated corpus files (`test/scion_tests/`, `test/scxml_tests/`)
are machine-emitted and carry no notes. The corpus is sabotage-proof by
construction: a broken interpreter shows up at once as a failing conformance
test. Harness plumbing that asserts no `lib/`
behavior is also exempt. Examples are helper round-trips, the tag table in
`feature_detector_test.exs`, and fixture loaders. State the exemption in the
file:

```elixir
# sabotage: n/a - asserts the sample table matches the registry, no lib/ behavior
```

A test that covers `Statifier.Testing.*` asserts `lib/` behavior and is not
exempt, even if it looks like harness plumbing.

**Stale beam after revert.** In step 4, "confirm green again" can come back red
on a tree with correct source and a clean `git status`. This is not a failed
revert. The staleness check of `mix` uses file modification times. If a
mutate, compile, revert cycle finishes within one second, `mix` can keep the
*mutated* beam loaded and not recompile. Every later mutation in the session
is then judged against that stale module, and its red results prove nothing.

Run `MIX_ENV=test mix compile --force` after the mutation and again after the
revert. A red result that survives a forced recompile on clean source is the
real signal.

**Cost.** Sabotage makes writing a test much slower, on purpose. The conformance
corpus tells you whether the engine is right. The internal suite is worth its
cost only if each test can fail. One minute per test to
learn which tests can fail is cheaper than finding a vacuous suite after a
year of trust.

## The regression ratchet

- `test/passing_tests.json` - the registry of tests that must always pass.
  - It has four lists: `internal_tests`, `scion_tests`, `w3c_tests`,
    `statifier_tests`. Entries are literal paths or globs.
  - The internal list uses globs, so unit tests are covered when you write
    them. The conformance lists start empty, and you add one verified test at
    a time.
  - A `statifier_tests` entry is the JSON file of an authored conformance case
    under `conformance/cases/`. The case has no test module. Both tasks below
    run it through `Mix.Statifier.Corpus.Runner`, as `mix statifier.corpus`
    does, not through `mix test`.
- `mix test.regression` - runs exactly what the registry expands to, including
  the tags that the excluded-by-default suites need.
  - Any failure is a blocking regression.
  - An entry that matches no file on disk also fails the run. A silent drop
    would shrink the ratchet, and the ratchet exists to prevent that.
  - It is part of `mix quality` as the `Regression ratchet` custom stage
    (`.quality.exs`). The `:loop` profile does not include it. A regression is
    therefore a named failure on a bare `mix quality`, not a buried test count.
- `mix test.baseline` - runs every conformance test that the registry does not
  track yet, one file at a time, and reports which tests now pass.
  - `--add` adds those tests to the ratchet.
  - `mix test.baseline add <files>` verifies specific files and is
    all-or-nothing. No test enters the registry before it passes.

The ratchet only moves forward. A feature PR that makes tests pass adds them in
the same PR. A test that passed before and fails now is a regression. Fix it.
Never delete its line.

Both tasks are thin wrappers over `Mix.Statifier.RegressionRegistry`. That
module holds the load, expand, categorize, and add logic. It writes the JSON
back with sorted keys and one entry per line, so adding a test to the ratchet
is a one-line diff.

### Per-corpus coverage figures

Both tasks report coverage per corpus (SCION, W3C, and the authored
`statifier` cases) as passing/total and a percentage. Each task uses a
different numerator:

- `mix test.baseline` reports the measured figure: the ratcheted tests plus
  every newly passing candidate found in that scan.
- `mix test.regression` reports the floor: the ratcheted tests only, because
  it never runs a file outside the registry.

`Mix.Statifier.RegressionRegistry.corpus_stats/3` computes both.

**Where the figures print.** They print when you run the tasks directly from
the shell. They do not print in the stage summary of `mix quality`. The
`Regression ratchet` stage reports only pass or fail, and a passing command
stage renders as one line whatever the command printed. To show the figures
there, the project would need a JSON summary mode for the task and a guarded
`.quality.exs` edit with its own ledger entry (see the "Which skipped stages"
discipline in `CLAUDE.md`). Both are out of scope.

**The denominator.** It is the emitted corpus: 119 SCION files and 168 W3C
files on disk today. The W3C figure is 154 `mandatory/` files plus 14
`optional/` files. It is not the upstream suites (127 native SCION cases, 193
W3C cases). Only the emitted count can reach 100%.

- Some upstream cases have no predicator equivalent, and generation excludes
  them. Examples are script tags, list concatenation, and an `<invoke src>`
  that the library never dereferences.
- No build of this engine can pass every upstream case under the predicator
  datamodel commitment ([datamodel.md](datamodel.md)).
- `tools/corpus/README.md` documents the exclusion counts and reasons. A future
  edit to those exclusions changes the denominator.

### Scratch directories in tests

`mix quality` runs the `Regression ratchet` (`mix test.regression`) and the
built-in `Tests` stage concurrently, in the same working directory. The globs
in `test/passing_tests.json` make both stages run mostly the same modules. The
`@tag :tmp_dir` of ExUnit fixes its scratch root to `tmp/` relative to the cwd
of the process, and you cannot configure it. Two concurrent runs of the same
test compute identical paths and race on `rm_rf!`/`mkdir_p!`.

**Use `@tag :isolated_tmp_dir` (`Statifier.TmpDir`) instead.** It has the same
`tmp_dir` context key and the same directory shape. `root/0` always ends in a
`System.pid()` segment, so two concurrent OS processes cannot resolve to the
same scratch path, even if they agree on everything else. The old
`test/statifier/tmp_dir_test.exs` did exactly that: it changed
`STATIFIER_TMP_ROOT` for the whole process in the middle of a run.

- `STATIFIER_TMP_ROOT` (default `"tmp"`) only chooses where the pid-scoped tree
  of a run lives, for readability. `mix test.regression` sets it to
  `tmp/regression`. Isolation does not depend on it.
- The repo bans the `@tag :tmp_dir` and `@describetag :tmp_dir` of ExUnit.
  `test/statifier/tmp_dir_test.exs` enforces the ban. It scans
  `test/**/*.exs` and fails with the names of the offending files.

Directories accumulate. Each OS process leaves its own `tmp/<root>/<pid>/`
subtree and nothing sweeps it. A failure stays inspectable, and no `setup`
callback can delete a tree that a concurrent run still uses. Clear `tmp/` by
hand between sessions if the accumulation is a problem.

## Corpus generation

The generator lives in the repo under `tools/corpus/`. It starts from the
Makefile and `cases.exs` scripts of ex_statechart. These scripts clone the
SCION scxml-test-framework, fetch W3C TXML and transform it with saxon, and
emit test files from the JSON case descriptions.

`mise run corpus` is the single entrypoint for regeneration. The stages behind
it and the scratch layout are in `tools/corpus/README.md`. Upstream downloads
go to the gitignored `tools/corpus/scratch/`. The repo commits what the
pipeline derives from them:

- The language-neutral corpus under `conformance/`. It holds the upstream
  documents under the licences in `conformance/LICENSES/`.
  Decision: ADR-0070.
- The generated test modules.

The generators read the corpus as their source:

    upstream corpora (SCION json/scxml, W3C txml)
      -> tools/corpus fetch + transform (gitignored scratch/)
      -> mix statifier.corpus (filter, run every case, write conformance/)
      -> mise run corpus:emit (generated .exs test modules with @tag
         required_features, read from conformance/corpus/)
      -> checked in (conformance/ and the generated modules are committed;
         regeneration is a diffable PR)

The full gate keeps the committed pieces consistent without the upstream tree.
Its `Conformance corpus` stage runs `mix statifier.corpus --check`. This
command fails in two cases:

- A committed corpus file, the manifest, the exclusions, or the registry
  differs from what `mix statifier.corpus` writes from the committed inputs.
- `conformance/corpus/` is absent or empty.

`test/corpus/corpus_files_test.exs` fails when a committed generated module
differs from what its generator writes from the corpus. A hand edit of either
makes the gate red.

**Unsupported features fail, not skip.** A test that depends on an unsupported
feature calls `flunk` and names the feature, so it can never look like a pass.

- Feature detection lives in `lib/` under `Statifier.Testing`. It is test-side
  surface for chart authors, not engine.
- No module in `lib/` outside `Statifier.Testing.*` may reference anything
  inside it.
- Engine semantics come from the Appendix D port. An unsupported feature
  appears as a real error or a real conformance failure. It never appears as a
  branch that detection gates.

Decision: ADR-0053 (amends ADR-0006), ADR-0002.

**Exclusion sets.** Each set is the source of truth. Do not copy its entries
into prose.

- W3C: the tests whose `.txml` templates have no predicator equivalent, each
  with a reason atom, in `tools/corpus/scxml_w3/exclusions.exs`.
- SCION: tests excluded for the same reason, plus the untransformed duplicate
  of the W3C IRP suite in SCION, each with a reason atom, in
  `tools/corpus/scion/exclusions.exs`.

Decision: ADR-0004.

## Quality gate

- `mix quality --profile loop` - inner loop: format, compile, credo, and
  changed-scope tests. Use it between edits.
- `mix quality` - full gate. It adds dialyzer, deps audit, the full suite with
  coverage, the regression stage, and the conformance corpus stage. It must be
  green before commit. CI enforces it.
- Coverage: the gate fails below **90%** (`coveralls.json`). The target is 95%
  or more. Raising the floor as the suite grows is a decision for a human.
  Lowering it is not a way to get a green gate.
- Coverage measures `lib/` only. This includes `Statifier.Testing`:
  `Statifier.Testing.Case` and `Statifier.Testing.FeatureDetector` count toward
  the floor like any other library module.
- `coveralls.json` skips `test/support/`. That directory holds two
  compatibility shims (`Statifier.Case`, `Statifier.FeatureDetector`) and five
  private harness modules (`ContextRecorder`, `TestContent`, `StreamOrder`,
  `TmpDir`, `Mix.Statifier.AdrJudgeCorpus`). They stay out of `lib/` for their
  own reasons. Tests still cover the harness directly
  (`feature_detector_test.exs`, `case_test.exs`). If `test/support/` counted,
  its own line count could move a number that exists to describe the engine.

Decision: ADR-0053 decision 4.

Next: run `mix quality --profile loop` between edits.
