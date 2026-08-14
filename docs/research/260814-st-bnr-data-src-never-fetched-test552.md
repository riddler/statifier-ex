---
date: 2026-08-14T04:19:57-0600
researcher: Claude
git_commit: 8df2c50dc40807e6070e82a4779d670e114427bd
branch: st-bnr-data-src-not-fetched
repository: statifier-ex
beads_issue: st-bnr
topic: "Why test552 fails: <data src> is deliberately never fetched, and what the corpus does about it"
tags: [research, codebase, datamodel, corpus, ratchet]
status: complete
last_updated: 2026-08-14
last_updated_by: Claude
---

# Research: `<data src>` is never fetched - test552's failure is a decision, not a bug

**Date**: 2026-08-14T04:19:57-0600
**Git Commit**: 8df2c50dc40807e6070e82a4779d670e114427bd
**Branch**: st-bnr-data-src-not-fetched
**Bead**: st-bnr

## Research Question

st-bnr observes that `test/scxml_tests/mandatory/data/test552_test.exs` fails
its own assertion (expected active state `["pass"]`, got `["fail"]`) on the
full conformance run, because `<data id="Var1" src="file:test552.txt"/>` is
never fetched. Is that a bug st-bnr should fix, or a decided behavior whose
design call belongs elsewhere? And regardless of which, what do the corpus and
the regression ratchet do with test552 in the meantime?

## Summary

The non-fetch is deliberate and already shipped as such; the failure is the
visible consequence of a design stance, not a defect in the code path. The
design question itself - whether `<data src>` is ever fetched, and at what
time, against ADR-0003's pure functional core - is exactly the deliverable of
**st-322** ("Decides `<data src>` fetch timing against a pure core"), a
`decision`-typed bead whose acceptance criteria call for an ADR or research
note deciding it and a rewrite of `docs/datamodel.md`'s open-contradiction
paragraph. st-bnr is subsumed by st-322 on that question and does not
pre-empt it here.

What st-bnr decides on its own, and this note records as decided:

1. **test552 stays failing and visible.** It is not `@tag :skip`-ed, not
   excluded, and gets no new `FeatureDetector` gate atom. `<data>` is gated
   only by `data_elements`, which is `:supported`; adding a `data_src` atom
   would convert a visible failure into a silent skip, the exact move
   ADR-0011 exists to prevent. st-af3.8's plan already declined the atom on
   purpose ("Not adding a detector atom for `<data src=...>`"), and this note
   ratifies that as st-bnr's answer, not just st-af3.8's.
2. **test552 stays out of `test/passing_tests.json`.** The ratchet registers
   only tests that pass (`docs/testing.md`, ADR-0006); a failing test cannot
   be ratcheted in, and nothing here shrinks or reshapes the registry. If
   st-322 lands on "fetch as an effect" and the fetch is later implemented,
   test552 passing is the signal, and ratcheting it in is that future
   branch's one-line diff - never this one's.
3. **One factual correction feeding st-322.** st-322's note says corpus
   impact is nil because test552 "is not in this repo's generated corpus".
   That is out of date: test552 *is* checked in at
   `test/scxml_tests/mandatory/data/test552_test.exs`, emitted by the v2 W3C
   emitter (commit 47f4a25) and since respelled by the boundness rework
   (commit 8cfc4c2). Corpus impact is exactly one file, and it is the one
   this bead observed failing. That does not change which way st-322 should
   lean - one file is still one file - but st-322 should decide from the
   corrected fact.

## The observed failure and its exact mechanism

test552's document declares a top-level
`<data id="Var1" src="file:test552.txt"/>` with no `expr` and no child
content, then branches on `cond="Var1 !== undefined"` from `s0` to `pass`,
with an unconditional fallthrough to `fail`. The test's embedded description
is the spec sentence itself: the Platform is expected to fetch the object
named by `src` at binding time and assign it as the data element's value.

What ships today, end to end:

- **Compile time**: `src` is lowered and validated like any other attribute,
  and `Statifier.Compiler` records it on the interned element as
  `{:src, uri}` - `Statifier.Machine.Data.value`'s type includes
  `{:src, uri :: String.t()}`, and the struct's moduledoc says plainly that
  "`src` never resolves in this pure core (ADR-0003) - it is carried as
  `{:src, uri}` and always fails at binding time"
  (`lib/statifier/machine/data.ex:18-20,39`).
- **Binding time**: `bind_value/4` in
  `lib/statifier/interpreter/datamodel.ex:195-197` has a dedicated clause
  that matches `%{value: {:src, uri}}` and calls
  `raise_binding_error(machine_state, d_index, {:src, uri})` - raising
  `error.execution` and leaving `Var1` seeded to `nil`, per the seeding
  contract in the comment at `datamodel.ex:163-166`.
- **Runtime consequence**: `Var1` is bound-but-nil rather than fetched, so
  `Var1 !== undefined` behaves as the sentinel semantics define for a
  declared-but-valueless id, the `pass` transition does not fire, and the
  machine lands in `fail`. The test asserts `["pass"]` and goes red.

So every stage behaves exactly as designed; the design is simply that no
fetch happens. The failing assertion is the corpus doing its job: keeping a
known deviation (or a not-yet-decided conformance gap) visible on every full
run instead of laundering it through a gate.

## What the spec requires, quoted from the local cache

From `scxml-rec.html` in the spec cache (clause 5.3.2, tags stripped,
whitespace collapsed):

> If the 'src' attribute is present, the Platform MUST fetch the specified
> object at the time specified by the 'binding' attribute of &lt;scxml&gt;
> and MUST assign it as the value of the data element.

and the failure clause the shipped behavior is shaped after:

> If the value specified for a &lt;data&gt; element (by 'src', children, or
> the environment) is not a legal data value, the SCXML Processor MUST raise
> place error.execution in the internal event queue and MUST create an empty
> data element in the data model with the specified id.

The shipped `{:src, uri}` -> `raise_binding_error` path matches the second
clause's shape (error.execution plus an empty data element under the id) but
is applied unconditionally, without attempting the fetch the first clause
mandates. Whether that unconditional application is a recorded deviation or
becomes a session-layer effect like `<send>` is precisely st-322's fork; see
its bead description for both options and their costs.

## Why the design call is st-322's, not st-bnr's

- st-322 predates this observation and was filed for this exact question,
  down to naming the same two options (deliberate deviation citing ADR-0003
  vs. fetch-as-effect touching st-cmq's session layer). Its acceptance
  criteria own the ADR-or-note deliverable *and* the `docs/datamodel.md`
  rewrite; a second record deciding the same question here would collide
  with it, and carrying the datamodel.md rewrite on this branch would be an
  unrelated change on st-bnr's commit.
- st-322 is ready: its only dependency (st-af3.3) is closed.
- st-bnr's own description anticipates this split - "see also st-322 ...,
  which may already cover the design question." It does.
- `docs/datamodel.md:22-27` still names the contradiction without resolving
  it ("The fetch's correct timing is unsettled between this paragraph and
  spec 5.3.2 - that contradiction is named here, not resolved"). This note
  leaves that paragraph untouched on purpose; rewriting it is st-322's
  acceptance criterion.

## What st-bnr decides regardless of how st-322 lands

Whichever branch st-322 takes, the corpus handling is the same until a fetch
actually exists and test552 actually passes:

- test552 remains in the corpus, remains red on full conformance runs
  (`mix test --include scion --include scxml_w3`), and remains absent from
  `test/passing_tests.json`.
- No `@tag :skip`, no exclusion, no `required_features` gate atom for
  `<data src>`. The feature gate answers "can the engine even parse and run
  this shape", and it can - the failure is semantic, and semantic failures
  stay visible (ADR-0011's principle applied to the corpus, as
  `docs/testing.md` requires).
- If st-322 decides "deliberate deviation, never fetched", test552 becomes
  this repo's one permanently-red `<data src>` conformance file - the same
  standing that ECMAScript-only tests have, accepted and documented rather
  than hidden. If st-322 decides "fetch as a session effect", test552 is the
  acceptance test for that future implementation bead.

## Code References

- `test/scxml_tests/mandatory/data/test552_test.exs` - the failing corpus
  file (generated; do not hand-edit)
- `lib/statifier/machine/data.ex:18-20,39` - `{:src, uri}` value type and
  the "never resolves in this pure core" contract
- `lib/statifier/interpreter/datamodel.ex:195-197` - the `bind_value/4`
  clause that raises at binding time
- `lib/statifier/compiler.ex` - `<data>` compilation deciding the value
  source once at Machine-build time
- `test/support/feature_detector.ex` - no atom gates on `<data src=...>`,
  by design
- `docs/datamodel.md:22-27` - the open-contradiction paragraph (st-322's to
  rewrite)

## Related Research

- `docs/research/260812-st-af3.3-datamodel-data-early-late-binding.md` -
  where the binding pipeline and the spec reading were established
- ADR-0003 (pure core with effects), ADR-0006 (corpus and ratchet),
  ADR-0011 (visible failure must not become a silent skip)
- Beads: st-322 (owns the design decision), st-af3.8 (the triage run that
  filed st-bnr)

## Open Questions

- None blocking st-bnr. One item is handed to st-322 rather than left open
  here: its "corpus impact: nil" note is factually out of date (test552 is
  in the generated corpus and is the file this bead observed); st-322 should
  decide with that corrected fact in hand.
