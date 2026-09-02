# ADR-0056: After a renumbering, pointer citations move and history stands

Status: accepted (2026-08-19) - the standing rule for citations left
behind by an ADR renumbering, and the qualification rule for citing
another repository's ADRs; refines the st-0y0 ledger convention
(dated prose is correct as written) rather than amending any record
; amended 2026-09-02 (st-xj7o: decision 5 gains a canonical
compact form, `<prefix>-ADR-NNNN`, and its no-sweep rule)

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

One of the two pointer sites carries evidence about why it survived,
and it is not what it looks like. The 0043 -> 0044 renumber was done by
`2c26fe0` ("Renumbers this branch's ADR to 0044", `Refs: st-r6l9`),
whose message states that it "rewrites every ADR-0043 citation on this
branch" and which changed 82 lines of that same plan document. It even
handled the hard case deliberately, noting that "the parser's own
ADR-0043 references are left alone; they cite the
attribute-normalization record, not this one." A careful sweep, on the
renumbering branch, in the same commit, still left line 955 behind.
What failed there was not a missing obligation to sweep; it was an
unaided hand sweep across a dozen files.

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

   Name the bead that performed the renumber only when it is not the
   citing document's own bead. The st-cmq.7 plan gains "renumbered
   under st-7wql" because st-7wql is a different bead and routes the
   reader somewhere new; the st-r6l9 plan keeps the unattributed
   "renumbered after a number collision" even though its resolver is
   known to be st-r6l9, because that renumber was st-r6l9's own work
   and naming it there would cite the document to itself. The
   unattributed form is correct in that case rather than second-best.
   The renumbering commit is not cited by sha: worktrees here rebase
   onto `origin/main` routinely, so a sha written on a branch can move
   before it merges, while bead ids are stable.

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

   Preventing collisions never retires this obligation. Every mechanism
   st-9vco weighs still ends in a renumber: a pre-merge check detects
   the collision and hands off to one, reserving the number at plan
   time "moves the collision earlier but does not eliminate it" in that
   bead's own words, and the third option accepts collisions outright
   and makes the renumber cheap. The rule is written for any
   renumbering rather than only a collision's resolution, so it outlives
   collisions entirely. What it does need is a mechanical verifier
   behind it, on the evidence of the 0043 -> 0044 sweep above: the
   obligation was met there and a pointer leaked anyway. That verifier
   is st-9vco's other half, and it complements this rule instead of
   replacing it.

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
- Future renumberings carry their own pointer sweep on the renumbering
  branch, so this cleanup shape does not recur as a separate bead.
  st-9vco's prevention work does not lift that obligation - it is the
  mechanical check a hand sweep needs behind it.
- Any future mechanical link check over `docs/adr/` citations must
  either distinguish pointer from historical-statement sites or accept a
  suppression mechanism for the latter; a checker that demands every
  `docs/adr/` string resolve would force falsifying history. It must
  also treat repo-qualified citations (decision 5's forms) as out of
  scope.
- The same constraint binds harder on a *rewriter* than on a checker.
  st-9vco weighs "a script that renames a record and repoints every
  citation" as the cheap option; applied naively that script would
  rewrite the decision-3 historical statements and falsify them, and
  `2c26fe0` shows it would also have to decide which record a reused
  number means, since the parser's ADR-0043 citations pointed at a
  different record than the one being renumbered. A repointer that
  cannot make both judgments must leave what it cannot classify to a
  human rather than guess.
- New cross-repo citations that omit the repo are defects from this
  record forward, even when the number happens not to collide with a
  local record.

### Amendment 2026-09-02: the canonical compact cross-repo citation form (st-xj7o)

Status: accepted (2026-09-02) - extends decision 5 with a canonical
compact form and a no-sweep rule. Decisions 1 through 4 are unchanged,
and every form decision 5 already accepts stays acceptable; nothing in
this record is withdrawn.

Decision 5 fixed the *obligation* - a cross-repo ADR citation must carry
the repository's identity in the citation itself - and listed three
shapes that discharge it: a full URL, a path that names the repo, and
prose qualification. What it deliberately did not do is pick one, so
every citing site picks for itself and the family's prose now carries
all three shapes for the same kind of reference. That is fine for
resolvability, which is what decision 5 was about, and poor for
scanning: a reader cannot tell at a glance whether "ADR-0002" in a
paragraph is this repo's Appendix-D port or another repo's record,
because the qualifying words may be a sentence away.

A cross-repo convention adopted 2026-08-20 across the sibling
repositories settles the choice. This amendment records it here because
decision 5 is where this repository's citation rule lives, and a
convention nobody can find in the record it refines is not a rule.

**1. `<prefix>-ADR-NNNN` is the canonical compact form.** `st-ADR-0061`,
`ots-ADR-0002`, `px-ADR-0014`. It is the form to reach for when a
citation appears inline in prose, where a URL or a full path would break
the sentence. It is not a replacement for decision 5's other forms: a
References list still wants the full URL or path, because a reader
following a link there needs the link.

**2. The prefix is the repository's beads prefix**, not an abbreviation
invented per sentence. The prefixes, one per repository, are fixed:

| Prefix | Repository |
|---|---|
| `st` | statifier (this repository) |
| `sui` | statifier-ui |
| `sp` | statifier_persistence |
| `sob` | statifier_oban |
| `sb` | statifier_blocks |
| `ots` | opentelemetry_statifier |
| `px` | predicator-ex |
| `se` | statifier_examples |

Using the beads prefix rather than a package name is what makes the form
mechanical: the same token already identifies the repository in every
bead id a citation sits beside, so there is one table to know rather
than two, and a citation and the bead that produced it read alike.

**3. A bare `ADR-NNNN` remains local-only.** This is decision 5's last
sentence carried onto the number form: a bare `docs/adr/NNNN-...md`
always means this repository's record, and so does a bare `ADR-NNNN`. A
cross-repo citation written bare is the defect this record's final
consequence already names, and the compact form is now the cheapest way
to not commit it - which is the point of adding it, since decision 5's
three existing forms all cost more keystrokes than the bare one they
were competing with.

**4. No sweep.** Existing prose in any of decision 5's forms stays valid
and is not rewritten; the compact form is adopted in new text and in
text being edited for other reasons. This is the same st-0y0 rule
decision 3 applies to historical statements and decision 5 applies to
the four cross-repo names the link check flags, and it applies here for
the same reason: those citations resolve, a reader following them
arrives at the right record, and a sweep would churn dated documents to
no reader's benefit. A file already carrying a decision-5 form does not
become editable *because* of this amendment.

### Amendment 2026-09-02's own consequences

- The pointer sweep decision 4 obliges a renumbering branch to perform
  is unchanged in scope. It is bounded to this repository's tree, so it
  never touches a `<prefix>-ADR-NNNN` citation in a sibling repository,
  and the compact form does not extend the obligation across repos.
- A mechanical link check gains a form it can recognize rather than one
  it must parse prose around. The third consequence above requires such
  a check to treat repo-qualified citations as out of scope; the compact
  form makes that classification a regex over a fixed prefix list rather
  than a judgment about surrounding words. Nothing here schedules that
  check - it is still st-9vco's other half.
- The prefix table is the amendment's only maintenance burden: a new
  family repository owes a row here when it gains a beads prefix. A
  citation using an unlisted prefix is not a new form, it is an
  unresolvable one, and the fix is the row rather than the citation.
- What would reopen this amendment: two family repositories ever needing
  to share a beads prefix (point 2's mechanical property fails), or a
  consumer wanting the compact form to resolve automatically to a URL,
  which would need a prefix-to-URL mapping this record deliberately does
  not define.
