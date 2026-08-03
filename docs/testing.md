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

## The regression ratchet

- `test/passing_tests.json` - the registry of tests that must always pass.
- `mix test.regression` - runs exactly the registry; any failure is a blocking
  regression. Wired into `mix quality` as a custom stage once the corpus lands.
- `mix test.baseline` - reports newly passing tests; `mix test.baseline add` verifies
  then ratchets them into the registry.

The ratchet only moves forward. A feature PR that makes tests pass adds them in the
same PR. v1 final baseline for reference: 90/127 SCION, 27/59 W3C.

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

## Quality gate

- `mix quality --profile loop` - inner loop: format, compile, credo, changed-scope
  tests. Use between edits.
- `mix quality` - full gate: adds dialyzer, deps audit, full suite with coverage,
  regression stage. Required green before commit; enforced in CI.
- Coverage target: 95%+ on `lib/`.
