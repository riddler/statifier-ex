# Testing strategy

The conformance corpus is the contract for this rewrite. v1's most valuable asset is
its test infrastructure, and it ports almost for free: the 281 SCION/W3C test files
touch no library internals - everything goes through one `Statifier.Case` module
([ADR-0006](adr/0006-reuse-conformance-corpus-and-regression-ratchet.md)).

## The three suites

1. **Internal tests** (`test/statifier/...`) - unit tests for parser, machine
   compiler, interpreter functions, datamodel. Written fresh for v2, pattern-matching
   style. Run by default with `mix test`.
2. **SCION suite** (`test/scion_tests/`, tag `:scion`) - 119 emitted tests out of
   127 native upstream SCION cases; the rest are excluded at generation time,
   with the count and the reason per case in `tools/corpus/scion/exclusions.exs`
   (see `tools/corpus/README.md`). Excluded by default.
3. **W3C suite** (`test/scxml_tests/`, tag `:scxml_w3`) - 162 emitted tests (159
   mandatory + 3 optional) out of 193 upstream W3C cases. Excluded by default.
   Dependency documents an `<invoke>` loads at runtime (manifest `<dep>`
   entries) are not emitted as standalone tests - see `tools/corpus/README.md`.

`Statifier.Case.test_scxml/4` needs exactly four things from the library: parse,
build/initialize, synchronous send-event, and the active leaf-state set. That is the
whole coupling surface; keep it that way.

### A fourth, hand-run suite: the ADR judge corpus

`Mix.Statifier.AdrJudge` (`lib/mix/statifier/adr_judge.ex`) judges a branch's diff
against a registry of ADRs using two real `claude` CLI calls per candidate
(propose, then an adversarial refute). Nothing in the ordinary suite can tell
whether a prompt change to that module helped or hurt, so
`test/mix/statifier/adr_judge_corpus_test.exs` exists as a fourth suite, separate
from the three above in kind, not just in tag:

- **What it is.** A manifest (`test/fixtures/adr_judge/manifest.exs`) binds each
  hand-written unified-diff fixture (`test/fixtures/adr_judge/*.diff`) to the
  judged-ADR key it targets and the verdict it should produce - `:violation` or
  `:clean` - with at least one of each per registry entry. One generated ExUnit
  test per manifest row calls `AdrJudge.analyze/2` with
  `caller: &AdrJudge.call_claude_cli/1` passed explicitly, so it is the one place
  in the suite that deliberately reaches the real CLI.
- **Why it is excluded.** Real CLI calls, real spend, and ~15-20 minutes for the
  full corpus (roughly two model round trips per fixture). Tagged
  `:adr_judge_corpus` and excluded in `test/test_helper.exs` the same way `:scion`
  and `:scxml_w3` are. There is a further reason on top: `:test`'s
  `@default_caller` still raises on a forgotten `opts[:caller]` everywhere else,
  and this module's own tests keep injecting stubs - only the corpus test module
  opts into the real caller, visibly, at its own call site.
- **How to run it.** `mix test --only adr_judge_corpus`. A cheap, caller-free
  companion, `test/mix/statifier/adr_judge_corpus_shape_test.exs`, runs in the
  ordinary suite and keeps the corpus from rotting between hand-runs: every
  manifest file exists, every key is real, every registry entry has both a
  violating and a clean fixture, every fixture's diff lands in its own scope and
  not a differing one, and no fixture contains the literal `@tag :skip` (which
  would trip `Mix.Statifier.GateGuard`'s skip-tag scan, since fixtures live under
  `test/`).
- **How to read a failure.** Each corpus test's failure message names which of
  three things went wrong: a **false negative** (a known-violating fixture
  produced no surviving finding), a **false positive** (a known-clean fixture
  produced one anyway), or a **wrong-ADR attribution** (a violation survived
  under the wrong registry key).
- **Recorded scores**, `claude-haiku-4-5-20251001` unless noted, 8 fixtures
  (4 violating, 4 clean) each run:

  | Run | False negatives | False positives | Wall time |
  |---|---|---|---|
  | Baseline (2026-08-08, unmodified `refute_prompt/1`) | 4/4 | 0/4 | 357.9s |
  | Phase 2 (grounded `refute_prompt/1`, hunks shown) | 0/4 | 0/4 | 272.4s |
  | Phase 4, `claude-sonnet-5` (same grounded prompt) | 0/4 | 0/4 | 91.4s |

  The prompt rework (st-6f7 Phase 2) closed every false negative; Phase 4
  measured `claude-sonnet-5` against the same corpus and found it equally
  accurate. With no accuracy difference to decide it, `@default_model` is
  `claude-sonnet-5` on wall time - 91.4s against haiku's 272.4s here, and 19.6s
  against 54.4s on a real three-entry `mix adr.judge`. That trades token cost
  for gate time on a `:merge`-profile-only, opt-in stage. See
  `Mix.Statifier.AdrJudge`'s moduledoc and
  `docs/plans/260808-st-6f7-adr-judge-refute-grounding.md`'s Phase 4
  measurement section for the full per-fixture numbers and the decision.

## Sabotage testing

A test that passes on its first run has proven nothing yet. It might be asserting
real behavior, or it might be asserting a tautology, exercising a branch its setup
never reaches, or checking a variable the code never touches. The only way to tell
the two apart is to break the code and watch what happens.

So every new or changed test that asserts `lib/` behavior gets sabotaged before it
is considered done:

1. Get the test green.
2. Break the implementation it covers - one edit, in `lib/`, in the code path the
   test claims to cover.
3. Run the test. It must fail, and the failure must be about the thing the test is
   for.
4. Revert the sabotage; confirm green again.
5. Record the mutation in a one-line comment directly above the test.

The comment is the artifact. Without it, the next reader cannot tell a test that was
verified from one that merely passed:

```elixir
# sabotage: enter_states/2 skips the initial child -> red
test "compound state enters its initial descendant" do
  ...
end
```

Format: `# sabotage: <what was broken> -> red`. One line, present tense, naming the
function and the mutation. It sits above the `test` line, above any `@tag`.

**What counts as a valid mutation.** It has to be a change a reasonable person could
make by mistake: invert a condition, drop a clause, skip a recursive call, return the
input unchanged, use the wrong set operation, off-by-one a boundary. Deleting the
function body or raising is not sabotage - everything fails, so nothing is learned.
A mutation also has to actually fire: the note must name a change that demonstrably
alters behavior for the case under test, not one that type-checks against the code
but leaves every value it touches unchanged.

**The truthy-sentinel trap.** `||` is the most common way to write a mutation that
never fires. Elixir's `||` falls back to its right side only when the left side is
`nil` or `false` - every other value, including `:undefined`, `:none`, `0`, and `""`,
is truthy and short-circuits the fallback. A note that proposes `x || fallback`
against a value that is one of these sentinels is a no-op: the mutated line runs,
produces the exact same value as before, and the suite stays green - not because the
test verified anything, but because nothing changed. That result is indistinguishable
after the fact from a note whose mutation genuinely ran and was reverted, which is
exactly the failure this section exists to prevent, and `mix quality`'s sabotage scan
cannot catch it: the scan only checks that a `# sabotage:` note exists above the test,
never that the mutation it names would actually change the value under test.

A real case: a note claimed to break `resolve_params/2` by defaulting its params with
`params || %{}`, where the incoming `params` was `:undefined`.

```elixir
# does NOT fire - :undefined is truthy, `||` never reaches the fallback
params || %{}

# fires - :undefined is mapped to a real default
if params == :undefined, do: %{}, else: params
```

Before writing a `||`-shaped mutation, check what the left side actually is for the
case under test. If it can be a truthy sentinel, use an explicit `if` or pattern match
that maps the sentinel to the fallback instead.

**Two failures worth catching.** If the test stays green, it is not testing what its
name says; fix the test, do not weaken the sabotage. If a single mutation reddens
twenty tests, they are all asserting one thing through twenty doors - note it and
consider whether the coverage is as broad as it looks.

**Exempt.** Generated corpus files (`test/scion_tests/`, `test/scxml_tests/`) are
machine-emitted and carry no notes; the corpus is sabotage-proof by construction,
since a broken interpreter shows up as a failing conformance test immediately.
Harness plumbing that asserts no `lib/` behavior - helper round-trips, the tag table
in `feature_detector_test.exs`, fixture loaders - is exempt too, but the exemption is
stated, not silent:

```elixir
# sabotage: n/a - asserts the sample table matches the registry, no lib/ behavior
```

**Stale beam after revert.** If step 4's "confirm green again" comes back red on a
tree with correct source and a clean `git status`, do not read it as a failed
revert. `mix`'s staleness check is mtime-based, so a mutate -> compile -> revert
cycle that finishes inside one second can leave the *mutated* beam loaded instead
of recompiling. Left uninvestigated, every later mutation in the session gets
judged against that stale module, and its reds prove nothing. Run
`MIX_ENV=test mix compile --force` after the mutation and again after the
revert; treat a red that survives a forced recompile on clean source as the real
signal.

**Cost.** This makes writing a test meaningfully slower, and that is the trade being
made deliberately: the conformance corpus tells us whether the engine is right, and
the internal suite only earns its keep if each test can fail. Spending a minute per
test to know which ones can is cheaper than discovering a vacuous suite after it has
been trusted for a year.

## The regression ratchet

- `test/passing_tests.json` - the registry of tests that must always pass. Three
  lists (`internal_tests`, `scion_tests`, `w3c_tests`), whose entries are literal
  paths or globs. The internal list is globbed, so unit tests are covered the moment
  they are written; the conformance lists start empty and are grown one verified test
  at a time.
- `mix test.regression` - runs exactly what the registry expands to, including the
  tags the excluded-by-default suites need. Any failure is a blocking regression, and
  an entry that matches no file on disk fails the run too: silently dropping a deleted
  entry would shrink the ratchet, which is the one thing it exists to prevent. Wired
  into `mix quality` as the `Regression ratchet` custom stage (`.quality.exs`), absent
  from the `:loop` profile so a regression is a named failure on a bare `mix quality`
  rather than a buried test count.
- `mix test.baseline` - runs every conformance test the registry does not track yet,
  one file at a time, and reports which now pass. `--add` ratchets those in;
  `mix test.baseline add <files>` verifies specific files and is all-or-nothing.
  Nothing enters the registry without passing first.

### Per-corpus coverage figures

Both tasks report per-corpus coverage - SCION and W3C separately, passing/total
and a percentage - but each uses a different numerator. `mix test.baseline`'s
figure is the measured one: ratcheted tests plus every newly-passing candidate
found in that scan. `mix test.regression`'s figure is the floor: ratcheted
tests only, since that task never runs a file outside the registry. Both are
computed by `Mix.Statifier.RegressionRegistry.corpus_stats/3`.

These figures print when the tasks are run directly - `mix test.baseline` or
`mix test.regression` from the shell - not in `mix quality`'s stage summary.
The `Regression ratchet` stage shells out to `mix test.regression` and reports
only pass/fail for the stage as a whole; a passing command stage renders as
one line in the gate's output regardless of what the underlying command
printed. Surfacing the figures there would need a JSON summary mode for the
task plus a guarded `.quality.exs` edit with its own ledger entry (see the
"Which skipped stages" discipline in `CLAUDE.md`) - both out of scope here.

The denominator behind both figures is the emitted corpus: 119 SCION and 162
W3C files on disk today (`test/scion_tests/`, `test/scxml_tests/` - the W3C
figure is 159 `mandatory/` plus 3 `optional/`), not the upstream suites (127
native SCION cases, 193 W3C cases). The emitted count is
the only one 100% is reachable against - some upstream cases have no
predicator equivalent and are excluded at generation time (script tags, list
concatenation, the BasicHTTP Event I/O Processor tree, and more), so no build
of this engine could ever pass every upstream case under the predicator
datamodel commitment (docs/datamodel.md). `tools/corpus/README.md` documents
the exclusion counts and reasons; a future edit to those exclusions changes
what these tasks read as the denominator.

Both tasks are thin wrappers over `Mix.Statifier.RegressionRegistry`, which holds the
load/expand/categorize/add logic and writes the JSON back with sorted keys and one
entry per line, so ratcheting a test in is a one-line diff.

The ratchet only moves forward. A feature PR that makes tests pass adds them in the
same PR; a test that used to pass and now does not is a regression to fix, never a
line to delete.

v2 starts from zero because it has no engine yet. v1's final baseline - **90/127
SCION, 27/59 W3C** - is the reference target to beat, not a seed to copy in. Both
denominators there are v1's own *emitted* corpus (`../statifier/test/scion_tests`
holds 127 `_test.exs` files, `../statifier/test/scxml_tests` holds 59), the same
kind of figure this section describes above, not the upstream suite sizes - so
the comparison to v2's figures is like-for-like, emitted corpus against emitted
corpus.

### Scratch directories in tests

`mix quality` runs the `Regression ratchet` (`mix test.regression`) and the
built-in `Tests` stage concurrently, in the same working directory, and
`test/passing_tests.json`'s globs mean both stages execute largely the same
modules. ExUnit's `@tag :tmp_dir` hardcodes its scratch root to `tmp/`
relative to the process's cwd with no way to configure it, so two concurrent
runs of the same test compute byte-identical paths and race on
`rm_rf!`/`mkdir_p!`.

Use `@tag :isolated_tmp_dir` (`Statifier.TmpDir`) instead - same `tmp_dir`
context key, same directory shape, but `root/0` always ends in a
`System.pid()` segment, so two concurrent OS processes cannot resolve to the
same scratch path even if they somehow agree on everything else
(`test/statifier/tmp_dir_test.exs` itself used to do exactly that, mutating
`STATIFIER_TMP_ROOT` process-globally mid-run). `STATIFIER_TMP_ROOT` (default
`"tmp"`) still exists, but only to choose where a run's pid-scoped tree lives
for readability - `mix test.regression` sets it to `tmp/regression` so the
ratchet's directories are easy to pick out by eye, not because isolation
depends on it. ExUnit's own `@tag :tmp_dir` / `@describetag :tmp_dir` is
banned repo-wide; `test/statifier/tmp_dir_test.exs` enforces it by scanning
`test/**/*.exs` and failing with the offending file names.

Directories accumulate: each OS process leaves its own `tmp/<root>/<pid>/`
subtree behind rather than being swept, so a failure stays inspectable and no
`setup` callback risks deleting a tree a concurrent run is still using. Clear
`tmp/` by hand between sessions if that bothers you.

## Corpus generation

v1's corpus was a frozen artifact - machine-converted test files with no committed
generator. v2 keeps the generator in-repo under `tools/corpus/`, seeded from
ex_statechart's Makefile + `cases.exs` scripts (which already do the bulk of the
work: cloning the SCION scxml-test-framework, fetching W3C TXML and transforming via
saxon, and emitting test files from the JSON case descriptions).

`mise run corpus` is the single entrypoint for regeneration; the stages behind it
and the scratch layout are documented in `tools/corpus/README.md`. Upstream
downloads land in the gitignored `tools/corpus/scratch/`, so nothing fetched is
committed.

Target pipeline:

    upstream corpora (SCION json/scxml, W3C txml)
      -> tools/corpus (fetch, transform, filter)
      -> generated .exs test files with @tag required_features
      -> checked in (generated output is committed; regeneration is a diffable PR)

Unsupported-feature tests **fail, not skip** (v1's FeatureDetector rule, kept): a
test that depends on an unsupported feature flunks with the feature named, so it can
never masquerade as passing. Feature detection lives in `test/support`, not `lib/` -
it is harness code, not library surface.

The W3C corpus also has a recorded exclusion set: tests whose `.txml` templates
have no predicator equivalent (ADR-0004), listed with a reason atom in
`tools/corpus/scxml_w3/exclusions.exs`. That file is the source of truth; this
paragraph does not duplicate its entries.

The SCION corpus has its own recorded exclusion set for the same reason
(ADR-0004), plus SCION's own untransformed duplicate of the W3C IRP suite,
listed with a reason atom in `tools/corpus/scion/exclusions.exs`. That file
is the source of truth; this paragraph does not duplicate its entries.

## Quality gate

- `mix quality --profile loop` - inner loop: format, compile, credo, changed-scope
  tests. Use between edits.
- `mix quality` - full gate: adds dialyzer, deps audit, full suite with coverage,
  regression stage. Required green before commit; enforced in CI.
- Coverage: the gate fails below **90%** (`coveralls.json`); 95%+ is the target to
  aim at. Raising the floor as the suite grows is a decision for a human, and
  lowering it is not a way to go green.
- Coverage measures `lib/` only: `coveralls.json` skips `test/support/`, which is
  harness code rather than library surface. The harness is still tested directly
  (`feature_detector_test.exs`, `case_test.exs`) - it is just not what the floor
  is set for, and counting it would let the harness's own line count move a
  number that exists to describe the engine.
