# ADR-0022: A parallel is never the LCCA; SCION's contrary tests leave the corpus

Status: accepted (2026-08-14)

## Context

Appendix D's `findLCCA` filters ancestor candidates through
`isCompoundStateOrScxmlElement`, and `Statifier.Machine.lcca/2` ports that
filter literally (`compound?/2`: `kind in [:state, :scxml] and children != []`).
A `<parallel>` therefore never wins the LCCA search: a transition whose source
and target both sit inside a `<parallel>` gets some compound ancestor *above*
the parallel as its domain, and taking it exits and re-enters the whole
parallel, running its `<onexit>`/`<onentry>` once more than a reading that
admits the parallel would.

Two SCION corpus files assume the other reading.
`test/scion_tests/more_parallel/test10_test.exs` and `test10b_test.exs` put
`<transition target="a" event="t1" cond="..."/>` on state `a`, a region of
`<parallel id="p">`, and count `<assign>` side effects across the re-entry;
test10b's inline comment says outright "we've exited and re-entered a, without
exiting and re-entering p". Under the literal port `x` reaches 6 where SCION
expects 4, so test10 takes a guard it should not and test10b misses one it
should take (st-cw3;
`docs/research/260814-st-cw3-scion-cond-assign-mismatch.md`). v1 passed test10
because its LCCA was an unfiltered deepest-common-ancestor
(`../statifier/lib/statifier/state_hierarchy.ex:91-103`) - the heuristic style
ADR-0002 exists to retire; v1 never passed test10b or claimed spec fidelity
here.

The spec is not ambiguous about this. It answers three separate times, all
normative (quoted from the local cache, `scxml-rec.html` / `appendix-d.txt`):

The definition of a compound state:

> [Definition: A compound state is a `<state>` that has `<state>`,
> `<parallel>`, or `<final>` children (or a combination of these).]

Section 3.1.5 ('Type' and Transitions), defining the LCCA and the exit set:

> the Least Common Compound Ancestor (LCCA) of the source and target states
> (which is the closest compound state that is an ancestor of all the source
> and target states).

> When a transition is taken, the state machine will exit all active states
> that are proper descendants of the LCCA, starting with the innermost one(s)
> and working up to the immediate descendant(s) of the LCCA.

And Appendix D's own prose for `findLCCA`:

> The Least Common Compound Ancestor is the `<state>` or `<scxml>` element s
> such that s is a proper ancestor of all states on stateList and no
> descendant of s has this property.

"`<state>` or `<scxml>`" excludes `<parallel>` by enumeration, not by
omission. The mandatory W3C test for the exit-set clause,
`test/scxml_tests/mandatory/selecting_transitions/test504_test.exs`, counts a
parallel's `<onexit>` firing under exactly this rule (its sources are the
parallel itself, so it does not discriminate the candidate-set question
directly, but it is the clause's enforcement test). No W3C mandatory test in
the corpus was found that *requires* the SCION reading.

ADR-0002 makes any divergence from the pseudocode a semantic bug unless a
comment cites a mechanical reason. Admitting `<parallel>` as an LCCA candidate
would be a semantic deviation - from three normative clauses at once - whose
only justification is agreement with one third-party implementation's two
tests. ADR-0006 adopted SCION's corpus as reusable infrastructure, not as an
authority over the REC.

## Decision

**`findLCCA` stays spec-literal: a `<parallel>` is never an LCCA candidate,
and a transition between (or within) regions of a parallel exits and
re-enters the whole parallel.** `Machine.compound?/2` and `Machine.lcca/2`
are correct as written and do not change.

**SCION's `more_parallel/test10` and `test10b` are recorded as corpus
deviations and leave the emitted corpus** via
`tools/corpus/scion/exclusions.exs`, under a new reason atom
(`:contradicts_w3c_semantics` or similar) whose comment cites this record.
That file already records the other class of never-passable SCION cases
(ADR-0004's `:needs_script`); "asserts behavior the REC normatively forbids"
is a second class of the same kind. Leaving the two files in the tree as
permanent failures was rejected: the corpus exists to measure the engine
against expectations the project accepts, and a file the engine must never
satisfy is noise in every full conformance run, forever unratchetable.

The rejected alternative - admit the parallel and match SCION - was rejected
because it trades three normative MUST-adjacent clauses and the literal-port
property for two tests, and its blast radius is every external transition
whose LCCA search passes through a parallel, a surface the W3C mandatory
suite (test504 among others) actively measures.

**One tension is flagged rather than resolved here.** The st-cw3 bead says
these five files are "Not to be excluded or skip-tagged (ADR-0011)". That
instruction was written at triage time, before root cause was known, to stop
an agent from papering over engine bugs; this record concludes the two
`more_parallel` files are not engine bugs. Executing the exclusion still
contradicts the bead's letter, so it waits for a human (or the orchestrator
updating the bead) to lift that constraint - the entry in `exclusions.exs` is
itself corpus-generator input reviewed on its own diff, and no
`test/passing_tests.json` shrink is involved (neither file was ever
ratcheted), so ADR-0011's guarded surfaces are untouched.

## Consequences

- The engine's LCCA remains diffable against the pseudocode (ADR-0002), and
  W3C mandatory conformance is preserved.
- `more_parallel/test10` and `test10b` are acknowledged as unwinnable rather
  than pending: once excluded, full conformance runs stop reporting them, and
  the SCION emitted-test count in `docs/testing.md` drops by two.
- Follow-up (not this record): add the two `exclusions.exs` entries with the
  new reason atom and its header prose, regenerate the corpus, and update the
  counts in `docs/testing.md` - after the bead's no-exclusion constraint is
  lifted on the record by a human.
- A future SCION case that fails the same way has a citable answer: check the
  LCCA reading first, and if it is this divergence, it joins the exclusion
  class instead of prompting a re-argument.
- If the W3C errata or a successor spec ever redefines LCCA candidacy, that
  is a new ADR superseding this one, not an edit here.
