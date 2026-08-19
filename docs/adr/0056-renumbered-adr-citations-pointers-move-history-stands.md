# ADR-0056: After a renumbering, pointer citations move and history stands

Status: accepted (2026-08-19) - the standing rule for citations left
behind by an ADR renumbering, and the qualification rule for citing
another repository's ADRs; refines the st-0y0 ledger convention
(dated prose is correct as written) rather than amending any record

## Context

ADR number collisions have happened at least three times: two branches
each picked 0037 concurrently (resolved under st-7wql, the send-failure
record becoming 0039), the same shape produced 0043/0044, and st-hbdr's
record was renumbered to 0053 when ADR-0052 landed on main mid-flight.
Prevention is st-9vco's problem. This record decides what happens to the
citations a renumbering strands, because each occurrence leaves some
behind and the answer must not be re-litigated per occurrence.

Today five citations in dated plan documents name the pre-renumbering
filenames `0037-session-detected-send-failures-re-enter-the-core.md`
(now 0039) and `0043-re-entry-effects-defer-to-the-outer-batch.md` (now
0044). Two rules collide over them:

- `docs/quality-gate-changes.md`'s st-0y0 entry states this repo's
  convention for dated prose: plan and research documents "are correct
  as written because they record what was true when they were written,"
  and declines to sweep such references.
- A citation to a path that no longer resolves is not merely dated - it
  is unfollowable. Worse than unfollowable, here it is misdirecting:
  0037 and 0043 are both live filenames today, held by unrelated records
  (`0037-unbound-spelled-undefined-at-the-writer.md`,
  `0043-attribute-values-normalize-per-xml-3-3-3.md`), so a bare number
  reference silently points a reader at a different decision instead of
  failing loudly.

Reading the five sites shows they are not one kind of thing:

- **The old name as subject.** In three sites the old filename is the
  thing the sentence is about - a historical fact being reported.
  `docs/plans/260815-st-1bjz-undefined-at-the-writers.md:247` narrates
  the 0037/0037 collision and its resolution (and already states, in the
  same sentence, that the record became ADR-0039); line 857 of the same
  plan instructs filing a bead "recording that these two files share the
  number 0037"; `docs/plans/260815-st-cmq.7-invoke-scxml-child-sessions.md:131`
  reports "`docs/adr/` contains two files numbered 0037". Rewriting any
  of these to 0039 would make the text assert something false - that
  0039 collided with 0037.
- **The citation as pointer.** In two sites the citation exists to be
  followed. `docs/plans/260815-st-cmq.7-invoke-scxml-child-sessions.md:1155`
  lists `0037-session-detected-send-failures-re-enter-the-core.md` under
  "Related ADRs"; `docs/plans/260817-st-r6l9-reentry-effects-defer-to-outer-batch.md:955`
  names `docs/adr/0043-re-entry-effects-defer-to-the-outer-batch.md` as
  "Decision this plan implements" - and the very next line of that file
  already cites 0039 by its current name, so the document is internally
  inconsistent besides.

A naive link check also flags four names that are not this repo's
records at all: `0010-bounded-rebase-conflict-auto-resolution.md` and
`0011-codebase-orientation-extension-file.md` are wurk's ADRs, cited by
absolute path in `docs/plans/260812-st-rtm-wurk-config-catchup.md`;
`0010-tracker-authority-and-the-mirror-obligation.md` is predicator-ex's,
cited by full GitHub URL in ADR-0025; and
`0014-functions-are-provided-by-modules.md` is predicator-ex's, cited in
the st-p3t research and plan and the st-sdh research sometimes with the
repo named and sometimes as a bare `docs/adr/0014-...md`. The bare form
is genuinely ambiguous, not merely unqualified: this repo holds its own
unrelated 0010, 0011, and 0014
(`0014-expression-spans-in-cond-diagnostics.md`), so the bare path reads
as a broken link to the wrong record.

## Decision

1. **The rule turns on the citation's role, not on whether the path
   resolves.** A citation is either a *pointer* - it exists so a reader
   can follow it to the decision (References lists, "Decision this plan
   implements", "see ADR-NNNN" used as authority) - or a *historical
   statement* - the old name is the subject of the sentence, reporting
   what was true at the time. Resolvability is the symptom that surfaces
   the problem; role is what decides the fix.

2. **Pointers are corrected, with the original number preserved in
   place.** A stranded pointer is updated to the record's current
   filename, plus a brief parenthetical preserving what it said at the
   time, in the shape
   `(cited as 0037-... when this plan was written; renumbered under
   st-7wql)`. Not a silent path fix: these are dated documents, and a
   silent edit makes the document claim it always said what it now says.
   The note keeps the dated record honest while making the pointer
   followable again. Of the five sites, this covers
   `260815-st-cmq.7-invoke-scxml-child-sessions.md:1155` (0037 -> 0039)
   and `260817-st-r6l9-reentry-effects-defer-to-outer-batch.md:955`
   (0043 -> 0044).

3. **Historical statements stand as written, exactly per st-0y0.** The
   old name named as a fact of the past is correct prose, and correcting
   it would falsify the record. This covers the remaining three sites:
   `260815-st-1bjz-undefined-at-the-writers.md:247` and `:857`, and
   `260815-st-cmq.7-invoke-scxml-child-sessions.md:131`. No edit, no
   annotation - the st-1bjz narrative already states the new number
   itself, and the others describe a past state of the tree that no
   current filename can restate.

4. **This is the standing rule for every future renumbering.** The
   branch that renumbers a record owes a sweep of *pointer* citations in
   the same change, applying decision 2's form, and leaves historical
   statements alone. Citations inside other accepted ADRs are pointers
   by nature (they cite authority) and get the same treatment. The sweep
   is bounded to this repo's tree; nothing is owed to prose in other
   repositories.

5. **A cross-repo ADR citation must carry the repository's identity in
   the citation itself.** Acceptable forms: a full URL (as ADR-0025
   cites predicator-ex's 0010), a path that names the repo
   (`~/repos/github/wurk/docs/adr/0011-...md`, as the st-rtm plan does),
   or prose qualification ("predicator-ex's ADR-0014",
   "`docs/adr/0014-...md` in that repo", as the st-sdh research does). A
   bare `docs/adr/NNNN-...md` always means this repository's record. The
   rule is forward-looking: the existing bare-path citations of
   predicator-ex's 0014 in the dated st-p3t documents stay as written
   per st-0y0 - their surrounding prose supplies the repo, they resolve
   to nothing here rather than to a wrong record, and they are exactly
   the dated prose the convention protects. The four cross-repo names
   the link check flags are not defects and are not edited.

## Consequences

- The next stage of st-8d5e edits exactly two lines
  (`260815-st-cmq.7-invoke-scxml-child-sessions.md:1155`,
  `260817-st-r6l9-reentry-effects-defer-to-outer-batch.md:955`) in the
  decision-2 form, and touches nothing else the link check flagged.
- Future renumberings (until st-9vco prevents them) carry their own
  pointer sweep on the renumbering branch, so this cleanup shape does
  not recur as a separate bead.
- Any future mechanical link check over `docs/adr/` citations must
  either distinguish pointer from historical-statement sites or accept a
  suppression mechanism for the latter; a checker that demands every
  `docs/adr/` string resolve would force falsifying history. It must
  also treat repo-qualified citations (decision 5's forms) as out of
  scope.
- New cross-repo citations that omit the repo are defects from this
  record forward, even when the number happens not to collide with a
  local record.

Open questions, recorded rather than resolved here:

1. Whether st-9vco's prevention mechanism (reserving the number at plan
   time, or a pre-merge collision check) makes decision 4's sweep
   obligation moot. Until it lands, the sweep stands.
2. Whether the decision-2 parenthetical should also name the collision's
   resolving bead when it is known. The form shown includes it
   (st-7wql); when the resolver is unknown, "renumbered after a number
   collision" suffices.
