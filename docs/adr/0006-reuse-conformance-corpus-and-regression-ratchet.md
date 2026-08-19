# ADR-0006: Reuse the v1 conformance corpus and regression ratchet; commit a generator

Status: accepted (2026-08-02) - amended 2026-08-17 (st-hgyu: the four-function constraint binds the synchronous driving path; the session path's coupling is a closed nine-function set) - amended in part by 0052 (st-hbdr: the harness modules' home moves to `lib/`'s `Statifier.Testing` namespace; the coupling constraint stands)

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
  surface - deliberately so. *(Amended 2026-08-17, st-hgyu: this constraint now
  binds per driving path rather than corpus-wide, and each path's set is closed.
  st-cmq.9 gave `test_scxml/4` a second path: a document detecting any of the
  ten send/invoke feature atoms (106 of the 281 generated files at that commit)
  drives through a live `Statifier.Session`, because real delivery, wall-clock
  timers, and child sessions have no synchronous equivalent. The synchronous
  path - every other document, including every file ratcheted before st-cmq.9 -
  still couples to exactly the four. The sanctioned driving surface is these
  nine functions and no others: shared by both paths, `Statifier.compile/1` and
  `Statifier.active_leaf_states/1`; synchronous path only,
  `Statifier.initialize/2` and `Statifier.send_event/2`; session path only,
  `Statifier.start_session/2`, `Statifier.Session.send_event/2`,
  `Statifier.Session.snapshot/1`, `Statifier.Session.status/1` and
  `Statifier.Session.stop/2` (ADR-0027, ADR-0029). One assertion-side read sits
  outside that set by declaration rather than by exception:
  `Statifier.MachineState.active_leaf_states/1`, read to compare cardinality
  against the id-translated set, inspects a value the harness already holds and
  is not a way to drive the chart. Adding a function to any of these lists, or
  adding a third driving path, reopens this record - it is not a harness change
  to be made in passing. The constraint's purpose is unchanged: the corpus
  still cannot widen the library surface, because every function either path
  touches is public API carried by its own record.)*

*(Amended 2026-08-19, st-hbdr / ADR-0052: "feature detection moves to
`test/support`" stops being a placement rule. `Statifier.Case` and
`Statifier.FeatureDetector` are promoted into `lib/` as
`Statifier.Testing.Case` and `Statifier.Testing.FeatureDetector`, with thin
`test/support` shims keeping the generated corpus files' names working. The
load-bearing half of the rule is kept in namespace terms: no `lib/` module
outside `Statifier.Testing.*` may reference anything inside it, so the engine
still never consults feature detection, and unsupported-feature tests still
fail with the feature named rather than skip. The coupling constraint above
is untouched - promotion moves the module, not the driving surface.)*
