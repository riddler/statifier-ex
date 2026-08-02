# ADR-0006: Reuse the v1 conformance corpus and regression ratchet; commit a generator

Status: accepted (2026-08-02)

## Context

v1's most valuable asset is its test infrastructure: 127+ SCION and 59+ W3C test
files whose only coupling to the library is a single `Statifier.Case` module
needing four functions (parse, initialize, send-event, active leaf states), plus a
regression registry (`passing_tests.json`) with `mix test.regression` /
`mix test.baseline` tasks that have zero library coupling. But the corpus was a
frozen artifact - no committed generator from the upstream corpora - while
ex_statechart (the older sibling project) has a Makefile + scripts that already do
the fetch/transform/generate work.

## Decision

The SCION and W3C suites, `Statifier.Case`'s public shape (`test_scxml/4`), the
regression registry, and the ratchet tasks carry over. The unsupported-feature rule
is kept: such tests fail with the feature named, never skip. New in v2: the
generator lives in `tools/corpus/`, seeded from ex_statechart's Makefile and
`cases.exs` scripts; generated test files are committed so regeneration is a
reviewable diff. Feature detection moves to `test/support` (it is harness code,
not library surface).

## Consequences

- The rewrite has its safety net before it has an engine; progress is measured in
  ratchet entries from day one.
- The corpus can grow (upstream additions, ECMAScript-to-predicator rewrites)
  without archaeology.
- `Statifier.Case`'s four-function contract is a hard API constraint on the v2
  surface - deliberately so.
