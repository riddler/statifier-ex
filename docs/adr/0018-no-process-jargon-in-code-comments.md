# ADR-0018: Process artifacts are not code comments

Status: accepted (2026-08-10)

## Context

This project runs its work through beads (ADR-0007), one worktree and one
branch per issue (ADR-0010), and the `wurk:*` skills that drive plan and
implement cycles (ADR-0016). Every unit of work therefore arrives with a
vocabulary attached: a bead ID, a phase number from the plan that produced it,
a numbered decision in a dated plan document, a skill name. That vocabulary is
in the author's head at the moment the code is written, and it is the cheapest
thing to reach for when a comment needs to explain why a field exists or why a
function is a stub.

It has been reached for constantly. Measured against the current tree:

- 59 files under `lib/` and `test/` name a bead ID in a comment or a doc
  string, 181 mentions in total.
- 31 files name a plan phase or step by number ("Phase 4 populates
  `transitions`", "landing the Phase 1/2 engine API").
- 61 files cite a plan document's internal numbering ("plan Decision 10",
  "Decision 12"), 148 mentions, and 15 lines name a `docs/plans/` file by its
  dated filename.

Read at the moment of writing, each of those is informative. Read six months
later, each has a different problem:

- **Bead IDs rot on close.** `st-af3` in a moduledoc is a promise that
  something will change here. Once the bead is closed and merged, the sentence
  is stale but still reads as forward-looking, and the reader has no way to
  tell which without leaving the code to query the tracker. `st-wju.4` and
  `st-l5k.5` name work that no longer exists as a unit of anything.
- **Phase numbers are local to one plan.** "Phase 4" means nothing outside
  the dated plan that numbered it, and plans are re-planned. `Statifier.Machine`'s
  moduledoc says "Phase 4 populates `transitions`" - the useful fact is that
  the compiler's transition pass populates it, which is true forever and
  legible to someone who has never read a plan.
- **Plan documents are snapshots, and code is not.** A plan is a record of
  what was intended on one date. `docs/plans/260807-st-l5k.3-sax-dom-source-locations.md`
  is a stable file, but citing "Decision 1" of it makes the code's reasoning
  depend on a document nobody updates when the code changes.
- **Skill jargon dates fastest of all.** The workflow tooling has already
  moved repositories once (ADR-0016) and its constraints have been restated
  twice (ADR-0015, ADR-0017). Comments naming that machinery inherit every
  such move.

The failure these share is not that the information is wrong. It is that the
comment is explaining the *process artifact that produced the code* rather
than the code, and the process artifact has a different lifetime than the file
it is written into. Beads close. Plans are superseded. Skills move repos. The
`lib/statifier/` module stays.

Meanwhile the context is not lost by leaving it out. The commit message carries
it - `wurk:commit` writes the bead into every commit, so `git log -S` or
`git blame` finds the bead, the plan, and the phase from any line of code. Bead
notes carry the working record. The plan and research documents under `docs/`
carry the shape of the work. Three durable homes already hold this material,
and none of them is the source file.

## Decision

**Comments, moduledocs, and doc strings explain the code. Process artifacts -
bead IDs, phase and step numbers, plan-document decision numbers, plan filenames,
and `wurk`/beads tooling jargon - do not appear in `lib/` or `test/` source.
That context belongs in the commit message, the bead's notes, and the plan or
research document, all of which already carry it and none of which rots into
the code.**

1. **What is banned.** In any comment, `@moduledoc`, `@doc`, `@typedoc` or
   test description under `lib/` or `test/`:

   | Banned | Example of the shape |
   |---|---|
   | Bead IDs | `st-af3 replaces this function's body`, `(st-l5k.5)` |
   | Plan phase or step numbers | `Phase 4 populates transitions`, `Nothing before Phase 3` |
   | Plan-document decision numbers | `plan Decision 10`, `Decision 12` |
   | Plan or research filenames | `see docs/plans/260807-st-laz-....md` |
   | Workflow tooling jargon | `wurk:implement`, `the loop mode`, `this epic`, `this bead` |

2. **What is explicitly allowed, and why the distinction is not arbitrary.**
   The line is lifetime, not formality. A reference is fine when the thing it
   names is as durable as the code and is normative for it:

   - **ADR numbers.** `CLAUDE.md` says in as many words to cite ADR numbers
     instead of re-arguing settled questions, and ADR-0001 chose amendment-by-new-record
     precisely so a citation stays resolvable. An ADR is never deleted, never
     renumbered, and a superseded one still says what it said. `(ADR-0012 item 3)`
     is a citation of standing policy.
   - **W3C SCXML spec sections and Appendix D names.** ADR-0002 makes the spec
     normative for this codebase; a deviation from the pseudocode is a bug
     unless a comment cites the mechanical reason. Spec citations are the
     highest-value comments in the interpreter and this record does not touch
     them.
   - **The `# sabotage:` convention.** `CLAUDE.md` and `docs/testing.md`
     require a one-line mutation note above every test that asserts `lib/`
     behavior, including the `# sabotage: n/a - ...` form for exempt harness
     plumbing. That note describes an experiment run against *this test's own
     subject*; it is a property of the test, not a trace of the ticket that
     produced it. It stays required, unchanged.
   - **Long-lived project documents cited by stable path.** `docs/architecture.md`,
     `docs/datamodel.md`, `docs/testing.md`, `docs/observability.md`. These are
     maintained alongside the code, unlike a dated plan snapshot.
   - **The word "phase" as an ordinary description of a pipeline.** `Statifier.Compiler`'s
     "This phase interns every state to a flat tuple" is describing a compiler
     pass. What is banned is the *numbered* reference back to a plan's phases,
     not the English word.

3. **Modules whose subject matter is the tooling are not an exception, but
   they are not violations either.** `Mix.Statifier.AdrGuard`, `Mix.Statifier.AdrJudge`
   and `Mix.Statifier.GateGuard` exist to operate on `.claude/wurk/**`,
   `docs/adr/`, and the gate ledger. Naming those paths, and naming the ADRs
   they enforce, is describing the code's own inputs - that is what a moduledoc
   is for. The rule still binds their narrative asides: `st-6f7 Phase 4 ran the
   fixture corpus` is describing how the module was developed and has to go
   the way any other bead reference does. The test is whether removing the
   reference removes information about *what the code does*.

4. **How to rewrite instead of delete.** A comment carrying a process reference
   almost always carries a real fact wearing the wrong clothes. Restate the
   fact:

   - `Phase 4 populates transitions` becomes `the compiler's transition pass
     populates this`.
   - `st-af3 replaces condition_match/2's stub with a real evaluation` becomes
     `condition_match/2 is a stub returning true; the datamodel evaluation
     that replaces it is not yet implemented`. The bead is discoverable from
     the commit; the reader needs to know it is a stub.
   - `plan Decision 10: ids are unique and non-empty` becomes the invariant
     stated on its own, since the code depends on the invariant and not on the
     document that chose it.

   If restating the fact leaves nothing, the comment was about the process and
   deleting it is correct.

5. **Where the context goes instead.** Nothing here asks anyone to write less
   down; it routes it. The commit message names the bead and describes the
   functional change (`CLAUDE.md`'s commit conventions). The bead's notes carry
   the working record and survive the close. The plan or research document
   carries the numbered decisions and the phase breakdown, and stays the place
   those numbers mean something. `git blame` on any line reaches all three in
   one hop.

## Consequences

- The existing tree does not comply, and this record is a change of practice
  rather than a codification of one. That is stated plainly so no reader
  mistakes the current comments for the standard. st-a89 tracks the cleanup
  sweep and is blocked on this record; it inherits point 4 as its rewrite
  protocol, and the counts in the Context as its starting scope. Nothing in
  this ADR's own branch touches `lib/` or `test/`.
- New code is held to this immediately, cleanup or no cleanup. A reviewer can
  cite ADR-0018 on a diff rather than arguing taste, which is the point of
  having the record land before the sweep.
- Some information genuinely disappears from the source files, and that is the
  trade being made. A reader who wants to know which bead introduced a field
  runs `git blame`; a reader who wants to know why the field exists reads the
  comment. Optimizing for the second reader at the first's expense is
  deliberate, because the second reader is far more common and has no other
  recourse.
- Comments get slightly longer in the rewrite, because "Phase 4" is three
  characters shorter than the fact it was standing in for. The exchange is a
  few words for a sentence that stays true.
- This is a candidate for a mechanical check but does not get one here.
  `Mix.Statifier.AdrGuard` already flags likely violations of the ADRs whose
  shape is a line pattern over added diff lines, and a bead-ID regex over
  comment lines is exactly that shape. It is deliberately not added in this
  record: the tree is 59 files away from clean, so a guard added today would
  fire on nearly every branch that touches an existing moduledoc and be
  disabled within a week. The honest order is the sweep first, the guard after
  - and adding a guard is a gate-relevant change, so it is a human's call on
  the record (ADR-0011) rather than a follow-on an agent takes.

## Open questions

Recorded rather than guessed at; no maintainer was available when this record
was written.

- **Does this bind `docs/` and `CHANGELOG.md`?** As written it binds `lib/`
  and `test/` only. Project documents that discuss the workflow have to name
  the workflow, and ADRs like this one cite bead IDs freely because a decision
  record *is* a dated artifact. Changelog fragments are named `changelog.d/<issue-id>.md`
  by convention, so the ID is structural there. The unclear case is a
  long-lived guide such as `docs/architecture.md` picking up a phase number
  from the plan that revised it; the same rot applies, but nobody has been
  bitten by it yet and a rule with no observed failure is worth less than the
  words spent on it.
- **Should `AdrGuard` eventually cover this, and with what escape hatch?** The
  guard's existing convention clears a false positive with an inline comment
  naming an ADR or the word "deviation". That convention interacts oddly with
  a rule about comment content, since the escape hatch is itself a comment. If
  the check is ever built, it needs a deliberate answer for the legitimate
  ADR-and-spec citations in point 2, which share a line shape with nothing
  else in the codebase and should be cheap to distinguish.
