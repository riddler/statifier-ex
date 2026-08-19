---
date: 2026-08-19T10:33:08-0600
researcher: Claude
git_commit: 8ea9ca20e5a5f72b1c24ad3b6745b440aa8195d3
branch: st-6f7h-exitset-trace-coverage
repository: statifier-ex
beads_issue: st-6f7h
topic: "Decision 3 review: no site-C fixture for enter_states/2"
tags: [research, decision, adr-judge-corpus, observability]
status: complete
last_updated: 2026-08-19
last_updated_by: Claude
---

# Decision 3 review: site C (`enter_states/2`) stays unfixtured

**Decision: st-6f7h Decision 3 stands, amended - site C gets no ADR-judge
fixture and no follow-up bead; the conclusion is upheld, but the premise "a
transplant could only buy path-string sensitivity" is retired as falsified,
and the decision now rests on the grounds below.**

This review was escalated from the st-6f7h `/wurk:verify` pass, which flagged
Decision 3 of
`docs/plans/260819-st-6f7h-interpreter-exitset-trace-coverage.md` as the
decision most likely to be overturned. No human was available; this is a
Direction-stage agent decision, recorded durably and - like every provisional
decision in that plan - a maintainer's to overturn. What makes it decidable
without one is that both outcomes were weighed against evidence already on the
record, and the trigger that would flip it is named below with its cost.

## Why the original grounds no longer carry the decision

Decision 3's grounds said a site-C row "could only ever be the transplant
Decision 1 rejects, at a third of a CE for a path string" - resting on the
premise that transplanting a measured-caught edit to a new site buys only the
judge's sensitivity to a file path, which no ADR clause makes relevant.

The verify pass falsified that premise at least once. The site-B violation
fixture's changed lines are byte-identical to
`0012_trace_stamp_swapped_comment_kept.diff` - the same four lines, re-cut at
`--unified=14` against `exit_interpreter/1`. Site A's row is caught 3/3;
site B's was missed 3/3 (st-6f7h Phase 2, `claude-sonnet-5`, seeds
101/202/303, a failure to propose). A "mere transplant" re-situated in new
surrounding context did surface a real judge blind spot that per-rule coverage
had missed. A decision resting on "transplants are uninformative" cannot stand
on that ground any more, and this record retires it rather than quietly
keeping it.

## The argument for overturning, at full strength, and why it is rejected

The strongest form: per-site coverage found something per-rule coverage
missed, therefore each governed site deserves its own row, therefore site C -
governed by the same amendment, carrying an identically worded comment,
exercised by nothing - should be fixtured, or at least held open by a bead.

Rejected, for three reasons that survive the falsification:

1. **The divergence is not attributable to the site.** The site-B miss has
   three live, unseparated explanations: hunk width (60 lines vs 22 - no
   prior fixture used more than `--unified=3`), the presence of a second
   trace call in the hunk, and the production site itself. Of the three, the
   site is the hypothesis with the least mechanical support: the judge sees
   only the ADR text and the hunk bytes ("they are everything you get" -
   `lib/mix/statifier/adr_judge.ex`), so the site enters only through context
   lines and a path string, and no ADR clause makes either relevant. What
   demonstrably changed between caught and missed is the hunk's composition,
   and "per-site coverage found this" misattributes the finding - the *pair
   design* found it, and the site came along for the ride.

2. **Site C cannot reproduce the composition that did the finding.**
   `enter_states/2` (`lib/statifier/interpreter/exit_entry.ex:706-733`) emits
   exactly one trace call, `Trace.EntrySet`. It has no adversarial partner in
   its function, so a site-C pair cannot pose the two-trace discrimination
   that made the site-B pair informative. A site-C fixture would be a plainer
   transplant than site B's was - and if width is the true cause of the
   site-B miss, a site-C transplant cut at the ordinary width would simply be
   caught, buying nothing at 0.33 CE plus authoring. It tests only the
   least-supported hypothesis, confounded with the `EntrySet`/`ExitSet`
   wording difference, at double the cost of the sharp experiment below.

3. **A per-site coverage standard does not terminate, and the corpus does not
   hold it.** The corpus's mechanical coverage unit is `{registry key, tier}`
   (`test/mix/statifier/adr_judge_corpus_shape_test.exs:39-49`); ADR-0012's
   amendment is written generally, with `exit_states/2` named only as a
   worked example; and ADR-0012 alone has three governed sites today, with no
   principle that stops a per-site standard at three or confines it to
   ADR-0012. Adopting that standard is a corpus-sizing decision a maintainer
   would have to take deliberately - it is not implied by one blind-spot
   finding whose cause is unattributed. A follow-up bead would encode the
   standard this decision declines, and would stand permanently open arguing
   for work nobody intends.

## What would change the answer

The disambiguating measurement is **not a site-C fixture**. It is a re-cut of
the site-B violation edit itself at `--unified=3` - the width every prior
ADR-0012 fixture uses, producing the narrow transplant the plan originally
rejected - measured at three seeds on `claude-sonnet-5`: 3 fixture-runs =
**0.17 CE** (cumulative 5.70 of 8 if bought; 2.47 CE remain under st-2ts
Decision 3's ceiling).

- **Caught**: the site is exonerated - site B behaves like site A at the
  ordinary width, the cause is the hunk's composition (width or the second
  trace call, still confounded with each other but with no per-site
  implication), and this decision is confirmed.
- **Missed**: the site (or path) does influence the judge, the per-site
  hypothesis is confirmed, and this decision is **overturned**: a site-C pair
  (0.33 CE plus authoring) becomes warranted and a bead should be filed then,
  citing this record and the measurement.

Buying that measurement is a human's call. A maintainer chose on 2026-08-19
to record the three-hypothesis narrowing and spend nothing further, and this
review does not override that choice - it names the trigger so the choice can
be revisited with its price attached. Until the measurement is bought and
misses, no site-C fixture and no follow-up bead.

## Why this is a research-level record, not an ADR

The decision changes no rule and mints no standard: it confirms the coverage
unit the shape test already enforces and ADR-0012's already-general wording,
and it declines to adopt a new per-site standard. That is a call about one
bead's scope, recorded where the bead's research lives. (Verified while
deciding: were an ADR warranted, the next free number is 0060 - 0059 is
already claimed by `docs/adr/0059-per-execution-ordinal-on-durable-timer-effects.md`
on `origin/st-q6b6-senddelayed-ordinal`, invisible to a local listing of this
worktree's `docs/adr/` - the exact collision ADR-0058's gate guard exists to
catch.)

## Residual uncertainty

- The three hypotheses for the site-B miss remain unseparated **by choice,
  not by budget** (2.47 CE remain). If the 0.17 CE re-cut is never bought,
  the site hypothesis stays formally alive, and this decision stays what it
  is: the best call available on unattributed evidence, weighted by which
  hypothesis has mechanical support in what the judge is shown.
- Site C remains governed, identically commented, and exercised by nothing -
  a stamp swap there is value-inert today and no `test/` assertion can catch
  it. That standing fact is recorded in the violation row's manifest note and
  does not decay; what this review adds is that leaving it unfixtured is a
  reviewed decision with a named reopening trigger, not an unexamined gap.

## Record consistency

Updated alongside this document, so no artifact still asserts the retired
premise as the decision's ground:

- `docs/plans/260819-st-6f7h-interpreter-exitset-trace-coverage.md` -
  Decision 3 carries a dated review note; the deferred item "Whether
  Decision 3 (no site-C fixture) survives maintainer review" is ticked with
  this outcome.
- `docs/research/260819-st-6f7h-interpreter-exitset-trace-coverage.md` -
  open questions 1 and 3 carry the review outcome.
- `test/fixtures/adr_judge/manifest.exs` - the site-B violation row's note
  points here for the reviewed decision.
