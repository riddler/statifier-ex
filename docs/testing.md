# Testing strategy

The conformance corpus is the contract for this rewrite. v1's most valuable asset is
its test infrastructure, and it ports almost for free: the 186 SCION/W3C test files
touch no library internals - everything goes through one `Statifier.Case` module
([ADR-0006](adr/0006-reuse-conformance-corpus-and-regression-ratchet.md)).

## The three suites

1. **Internal tests** (`test/statifier/...`) - unit tests for parser, machine
   compiler, interpreter functions, datamodel. Written fresh for v2, pattern-matching
   style. Run by default with `mix test`.
2. **SCION suite** (`test/scion_tests/`, tag `:scion`) - 127+ tests from the SCION
   project. Excluded by default.
3. **W3C suite** (`test/scxml_tests/`, tag `:scxml_w3`) - 59+ mandatory conformance
   tests. Excluded by default.

`Statifier.Case.test_scxml/4` needs exactly four things from the library: parse,
build/initialize, synchronous send-event, and the active leaf-state set. That is the
whole coupling surface; keep it that way.

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
  into `mix quality` as a custom stage once the corpus lands (st2-00p.10).
- `mix test.baseline` - runs every conformance test the registry does not track yet,
  one file at a time, and reports which now pass. `--add` ratchets those in;
  `mix test.baseline add <files>` verifies specific files and is all-or-nothing.
  Nothing enters the registry without passing first.

Both tasks are thin wrappers over `Mix.Statifier.RegressionRegistry`, which holds the
load/expand/categorize/add logic and writes the JSON back with sorted keys and one
entry per line, so ratcheting a test in is a one-line diff.

The ratchet only moves forward. A feature PR that makes tests pass adds them in the
same PR; a test that used to pass and now does not is a regression to fix, never a
line to delete.

v2 starts from zero because it has no engine yet. v1's final baseline - **90/127
SCION, 27/59 W3C** - is the reference target to beat, not a seed to copy in.

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

## Quality gate

- `mix quality --profile loop` - inner loop: format, compile, credo, changed-scope
  tests. Use between edits.
- `mix quality` - full gate: adds dialyzer, deps audit, full suite with coverage,
  regression stage. Required green before commit; enforced in CI.
- Coverage: the gate fails below **90%** (`coveralls.json`); 95%+ is the target to
  aim at. Raising the floor as the suite grows is a decision for a human, and
  lowering it is not a way to go green.
