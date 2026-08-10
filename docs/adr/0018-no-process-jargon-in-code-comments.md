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
- The habit has reached the prose documents too. `docs/observability.md` tags
  each entry of its seam list with the bead that owns the seam, and
  `docs/testing.md` carries both a plan-phase-keyed results table and two
  incident IDs. Those are maintained guides rather than dated records, which is
  what makes them a case this record has to answer rather than a separate
  question.

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
and `wurk`/beads tooling jargon - do not appear in `lib/` or `test/` source, nor
in the maintained guides under `docs/`. That context belongs in the commit
message, the bead's notes, and the plan or research document, all of which
already carry it and none of which rots into the code.**

1. **What is banned.** In any comment, `@moduledoc`, `@doc`, `@typedoc` or
   test description under `lib/` or `test/`, and in the maintained guides that
   point 4 names:

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
     maintained alongside the code, unlike a dated plan snapshot, so pointing at
     one from a comment stays resolvable. Being citable is not being exempt:
     point 4 binds these same four files, for the same reason they are safe to
     cite.
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

4. **Which documents this binds, and why the split is by genre.** The rule is
   about lifetime, so it reaches any file maintained alongside the code and
   stops at files that are dated records by construction:

   - **Bound: the maintained guides.** `docs/architecture.md`,
     `docs/datamodel.md`, `docs/testing.md`, `docs/observability.md`. These are
     revised as the code is revised and read by the same reader, so a phase
     number rots there exactly as it rots in a moduledoc. `docs/observability.md`
     currently tags its seam list with the bead that owns each seam; once those
     beads close the tags read as pending work and are not.
   - **Exempt: dated records.** Records under `docs/adr/`, `docs/plans/`,
     `docs/research/`, the gate ledger `docs/quality-gate-changes.md`, and
     changelog fragments named `changelog.d/<issue-id>.md`. In all of these the
     bead ID *is* the entry rather than a trace left on something else. This
     record cites bead IDs freely for that reason.
   - **Exempt: documents whose subject is the process.** `docs/workflow.md`
     describes the bead, worktree and plan machinery, so naming that machinery
     is describing its own subject - the same reasoning point 3 applies to
     `AdrGuard` and `GateGuard`.

   Inside the bound set, one distinction decides the borderline cases: **a
   citation is allowed when the cited document is the evidence for a claim
   being made, and banned when it is the origin story of the code.**
   `docs/testing.md`'s table of ADR-judge false-negative rates is keyed to the
   plan phases that produced each prompt revision; those numbers are
   uninterpretable without knowing which prompt produced them, so the citation
   is the measurement's provenance and it stays. The same file's `(st-0vz)` and
   `(st-iao)` asides are origin stories - the durable fact is the failure mode
   those incidents exposed, and it survives the ID being removed.

5. **How to rewrite instead of delete.** A comment carrying a process reference
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

6. **Where the context goes instead.** Nothing here asks anyone to write less
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
  sweep and is blocked on this record; it inherits point 5 as its rewrite
  protocol, and the counts in the Context as its starting scope, plus the four
  maintained guides point 4 brings in. Nothing in this ADR's own branch touches
  `lib/`, `test/`, or those guides.
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
- **`Mix.Statifier.AdrGuard` gains a bead-ID check, narrowed, and it does not
  wait for the sweep.** The guard analyzes *added diff lines only*, so a check
  added now does not fire on the 59 files already in the tree: it fires when a
  branch adds a line carrying a bead ID, and code written under this record is
  compliant by construction. Two constraints on how it is built, both load
  bearing:

  - **Bead IDs only** (`st-` plus the id, including dotted children). That
    third of the rule is a precise pattern with essentially no false positives.
    "Phase N" and "Decision N" are ordinary English before they are process
    references, and point 2 deliberately keeps the unnumbered word "phase" - a
    regex cannot draw that line, so those stay a review matter.
  - **Its own escape marker, not the shared one.** Every other check in the
    guard has the violation in *code* and the escape in a *comment*, so the two
    sit on different axes. Here they sit on the same axis, and the existing
    `ADR-0\d{3}|deviation` pattern would clear a violation *by accident*. That
    is not hypothetical - three lines in the tree at the time of writing would
    exempt themselves:

    - `Mix.Statifier.AdrJudge`: "`.claude/scripts/` under st-6yb) and must not
      be re-judged here: ADR-0015" - one line, both tokens.
    - `machine_state_acceptance_test.exs`: "call (ADR-0003); the session
      (st-cmq) owns queueing" - the same shape, in a test.
    - `Statifier.MachineState`: `(st-cmq)` sits on the line *below* an
      ADR-citing line, which `cited?/1` clears through its `previous` field.

    In all three the author cited an ADR for an unrelated and entirely correct
    reason. The hatch would stop meaning "someone asserted this is fine" and
    start meaning "this line happens to mention an ADR", which is worse than
    having no hatch at all. The check therefore needs a dedicated marker, so
    that clearing it is a deliberate act rather than a side effect of a
    citation point 2 explicitly encourages.

  st-wjg tracks the check. Adding a gate check is gate-relevant, so it lands
  with a ledger entry per ADR-0011. It is filed separately from the sweep
  because it constrains new code while the sweep is still running, which is the
  order that keeps the tree from getting worse in the meantime.
