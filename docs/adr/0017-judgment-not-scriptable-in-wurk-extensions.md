# ADR-0017: Judgment is not scriptable, scoped to the wurk extension surface

Status: accepted (2026-08-09) - supersedes ADR-0015; amends ADR-0016 in part

## Context

ADR-0015 recorded five constraints over a `.claude/scripts/` tree and thirteen
`.claude/skills/**/SKILL.md` files. ADR-0016 recorded that both moved to the
`wurk` repo, amended ADR-0015's location clause and its constraint 5, and
declined to supersede it on the ground that "three of whose five constraints
are still live policy" here.

That ground does not hold, and the disagreement is not academic. Two claims
made on the record are false against this repo as it stands today:

- ADR-0015's amendment note says constraints 1-4 "are still what
  `Mix.Statifier.AdrGuard` and `Mix.Statifier.AdrJudge` enforce, now scoped to
  `.claude/wurk/`". `AdrGuard` covers ADR-0002, 0003, 0004 and 0008 and its
  moduledoc says in as many words that ADR-0015's banned-operation list is
  *deliberately not covered*. `AdrJudge`'s registry comment says its
  `adr-0015-swallowed-judgment` entry "judges ADR-0015's constraint 4 only"
  and that re-judging the others would be a regression. No enforcement site in
  this repo has ever read constraints 1, 2 or 3.
- ADR-0016's own point 4 says of constraint 1 that "nothing in this repo
  enforces the ban, and nothing in this repo should try to" - which
  contradicts its point 2's implication that constraints 1-4 survive here.

Checked against what the extension surface actually contains, the same answer
falls out. `.claude/wurk/` holds six markdown files (`commit.md`,
`implement.md`, `iterate.md`, `mr.md`, `plan.md`, `research.md`, ~354 lines
total). There is no executable code in the directory at all. Constraint 1 bans
operations in scripts; there are no scripts. Constraint 2 names `lib/refs.rb`
and `rebase_onto.rb` as single definition sites; neither file is in this
repository. Constraint 3 requires a JSON envelope from every script; nothing
here emits one. Constraint 5 was removed by st-6yb with the ADR-0011 ledger
entry. Only constraint 4 - judgment is not scriptable - describes anything a
reviewer or a judge can find in `.claude/wurk/`, and it describes it densely:
`commit.md`'s sabotage refusal, `implement.md`'s mutation protocol, `mr.md`'s
hard-refuse on an ADR judge finding.

The operational fact that decides the shape of this record: `AdrJudge` ships
the file named by a registry entry's `adr_path` to a model verbatim as the
propose/refute input. That entry still names
`docs/adr/0015-skill-mechanics-in-scripts.md`, whose Decision section opens
"Deterministic skill mechanics belong in scripts under `.claude/scripts/`".
A model asked to judge a diff to `.claude/wurk/mr.md` against that text has to
first work out which four fifths of it no longer apply, from an amendment note
that is itself wrong about the enforcement sites. Retargeting the entry at
ADR-0016 does not help: ADR-0016 is a location-and-gating decision that states
constraint 4 only by reference, so read cold it never says what the constraint
*is*. Neither existing record, read alone, describes the surface being judged.

## Decision

**ADR-0015's constraint 4 is restated here, scoped to `.claude/wurk/**` and
`.claude/wurk.json` (point 6, added by st-8nj), and this record supersedes
ADR-0015 as this repository's live policy. ADR-0015's constraints 1, 2, 3 and 5
moved to the `wurk` repo with the code they govern and are not enforced here,
by anything, on purpose.**

1. **The constraint, stated for this surface.** A `.claude/wurk/*.md`
   extension may name a script, a `mix` task, or a generic skill step for
   mechanics, and must state the policy itself wherever a step is a policy
   call, a human gate, or a verification discipline. Handing such a step to a
   script - or deleting it rather than restating it - is the violation. The
   failure mode is a step that used to state a decision now delegating it, and
   the tell is prose that turns a discipline into a check on its own artifact:
   a script can confirm a `# sabotage:` note exists, which converts "break the
   code and watch it go red" into a comment-formatting rule. When a step needs
   judgment, the mechanics report the inputs and the model decides. ADR-0015's
   original text for this constraint and its two worked examples remain the
   long-form reasoning; this paragraph is what must be readable standing alone.

2. **`adr_path` for the `adr-0015-swallowed-judgment` entry is this file.**
   `docs/adr/0017-judgment-not-scriptable-in-wurk-extensions.md`. The entry's
   key and label may keep their ADR-0015 wording for continuity with the
   fixtures and plans that name them, but the text shipped to the model is this
   record. That is the whole reason this is a separate record rather than a
   third round of inline corrections to ADR-0015: the judge's input has to be a
   document that describes the surface being judged without a reader having to
   reconstruct which parts were overtaken.

3. **Moved to `wurk`, not dropped.** Each of the other four constraints has a
   live home, and the point of naming them is that none of them lapsed:

   | ADR-0015 constraint | Where it lives now |
   |---|---|
   | 1. absolute banned-operation list for kit scripts | `wurk` repo, wurk ADR-0006, enforced by the ported contract test that re-reads the ADR prose on every run |
   | 2. shared mechanics have one definition site (`lib/refs.rb`, `rebase_onto.rb`) | `wurk` repo, wurk ADR-0002 and ADR-0006 - the cross-repo drift this constraint had no answer for is what the standalone repo solves |
   | 3. one JSON envelope with `ok`/`data`/`warnings`/`blocked`/`commands` | `wurk` repo, wurk ADR-0006 |
   | 5. anything the scripts do is measured by the gate | `wurk` repo's own gate, per ADR-0016 point 2; removed from `.quality.exs` by st-6yb with the ADR-0011 ledger entry dated 2026-08-09 |

   This repo does not re-enforce any of them, and should not. ADR-0015's
   argument against re-enforcing an absolute ban through a second, weaker
   mechanism (ADR-0016 point 4) generalizes: a local echo of a rule whose
   authoritative check lives elsewhere drifts, and drifting silently is worse
   than not checking.

4. **This amends ADR-0016 in two places.** Its point 2's claim that ADR-0015's
   constraints survive here beyond the location clause and constraint 5 is
   corrected to constraint 4 alone. Its point 5's decision not to supersede is
   reversed, on its own stated criterion: it declined supersession because
   three of five constraints were still live policy here, and that count is
   one. ADR-0016's own subject matter - where the skills and kit live, what
   this gate still measures, the two resolved open questions - is untouched and
   remains the record for all of it.

5. **ADR-0015 becomes history.** Its status changes to superseded. It stays the
   record of why the split exists, what the audit found, and why constraint 1's
   enforcement site was a whole-tree test rather than the ADR guard. Nothing in
   it governs this repository any longer, and no tool should read it as
   current.

6. **The scope covers `.claude/wurk.json` as well as `.claude/wurk/**`.**
   Added 2026-08-09 by st-8nj, settling this record's first open question.

   Most of the manifest is exactly what wurk ADR-0004 says it is - machine-
   consumed constants, loaded by the kit's `lib/manifest.rb`. Argv arrays, path
   prefixes, a bead prefix, a tmux session name: those are facts, judging them
   is noise, and the constraint does not reach them. What it does reach is the
   subset of keys that encode a policy call rather than a fact.
   `gate.project_level_skips` decides which skipped gate stages stop blocking.
   `gate.sabotage.exempt_prefixes` decides which tests are exempt from the
   sabotage discipline. `beads.areas.lands_alone` and `always_batchable` decide
   how work batches. Each of those is a list of strings, and each is a decision
   somebody made. The constants-versus-prose line ADR-0004 draws is about which
   seam a value enters through and which consumer reads it - scripts or skills
   - not about whether the value carries judgment, and it was never a claim
   that a manifest key cannot.

   Stated for this half of the surface, in the same shape as point 1: **a
   manifest key that encodes a policy call, a human gate, or a verification
   discipline must have the policy stated in prose it points back to - the
   matching `.claude/wurk/<skill>.md` extension, an ADR, or `CLAUDE.md`. The
   key is the mechanism; the prose is the record.** The violation is the
   decision arriving as a key with nothing prose-side that states it: prose
   deleted in the same move and replaced by the key, or a policy born as a key
   that was never written down at all. Adding or changing a genuine constant -
   a command, a path, a name, a threshold that is a project fact rather than a
   choice about what blocks - is not a violation and must not be reported as
   one.

   **Why this is decided rather than watched.** ADR-0016's second open question
   was correctly left to evidence, because the judge reads the surface in
   question there and a run of findings-free extension branches is itself the
   evidence. That reasoning does not transfer. A scope that excludes a file
   produces the same silence whether the file is clean or not, so "revisit when
   a concrete diff moves judgment into the manifest" names a trigger nobody is
   positioned to observe - the check that would notice it is the one being
   deferred. Waiting for evidence only works where absence of a finding is
   informative.

   The demonstration is already on the record, and it is not the shape the open
   question predicted. st-5y5 added `gate.project_level_skips`, converting three
   previously blocking skipped stages into non-blocking reports. No prose moved,
   so nothing under `.claude/wurk/` appeared in the diff; the gate's own
   carve-out predicate does not name the manifest either, so `gate.rb` reported
   `applicable: false` and no gate ran (st-29g, which settles that second
   mechanism separately). A change to what counts as a blocking failure landed
   in the one file neither supervision reaches. That is the hole, whether or not
   the specific move that opened it was a re-expression.

   The cost is bounded and is not a per-run cost. The stage is opt-in at merge
   time and the judge slices the diff per scope, so this buys one propose call
   on a branch that touches the manifest and nothing at all on a branch that
   does not. That is a smaller bill than the one-character widening was being
   held against.

## Consequences

- The judge's input is now a document a model can act on cold. The shape of
  `AdrJudge` is otherwise unchanged: one entry, constraint 4 only, opt-in at
  merge time via `mix quality --profile merge`. Only the entry's scope widens,
  per point 6. ADR-0016's resolved second open question stands as written -
  keep the scope, watch rather than decide, revisit on evidence rather than on
  file count - and point 6 is not an exception to it but a statement of where
  that posture does not apply.
- Mechanical follow-ups this record makes unambiguous, for the stage that does
  the code change: `adr_path` in
  `lib/mix/statifier/adr_judge.ex`'s `adr-0015-swallowed-judgment` entry points
  at this file; the entry's `scope.prefix` becomes `.claude/wurk` (no trailing
  slash, so one prefix match covers the directory and the manifest beside it)
  and its `scope.describe` becomes `.claude/wurk/** and .claude/wurk.json`, so
  `mix adr.judge`'s skip reason reads "no changes under lib/statifier/,
  .claude/wurk/** and .claude/wurk.json"; the registry comment above `@judged`
  and the module's ADR-0015 references should cite ADR-0017 for what is judged
  and ADR-0015 for the history; `docs/skill-automation.md`'s "(ADR-0015,
  amended by ADR-0016)" citation gains ADR-0017.
- The widened prefix is a prefix, not a glob: it matches any path beginning
  `.claude/wurk`, which today is exactly the extension directory and the
  manifest. A future `.claude/wurk-something` would be in scope without anyone
  deciding it should be. That is the right default for this seam - a new file
  in the wurk consumer surface is judged unless someone argues it out - but it
  is a consequence of the mechanism rather than a decision this record made.
- `docs/skill-automation.md` was checked as part of this decision. The sentence
  ADR-0015's supersession was once "pending" - "ADR-0015 is itself pending its
  own supersession record now that the tree it describes has moved" - is
  already gone; st-gh9 trimmed that file to a pointer at `docs/workflow.md`'s
  Model roles section and a pointer at the dated st-hzf research snapshot.
  Nothing is re-added there. (st-ct0 later deleted the file outright, on the
  finding that a pointer document nothing links to and that says nothing
  beyond `docs/workflow.md`, the ADRs, and the dated research snapshot is a
  maintenance cost with no reader; the citation bullet above is moot as a
  result, and this bullet's history stands as written.)
- Three ADRs now have to be read in order for the full story of the move:
  0015 for why the split exists, 0016 for where the code went and what the
  gate measures, 0017 for what is judged here today. That is one more hop than
  a rewrite-in-place would have cost, and it is the cost ADR-0001 chose when it
  said an ADR is amended by a new ADR and not by rewriting history.
- A future consolidation is available and deliberately not taken now: if
  `.claude/wurk/` and `.claude/wurk.json` ever stop holding judgment-bearing
  policy, the honest move is to retire this record and its judge scope
  together, not to keep a scope that cannot fire.

## Open questions

Recorded rather than guessed at; no maintainer was available when this record
was written. The first is now answered, in point 6 of the Decision; the
question is kept because the reasoning against it is real and a reader deserves
to see what was weighed.

- **Should the constraint-4 scope cover `.claude/wurk.json` as well as
  `.claude/wurk/`?** The judge's scope prefix was `.claude/wurk/`, which
  excludes the manifest file beside it. Wurk ADR-0004 draws the line at
  machine-consumed constants versus prose, and a constant is not a judgment
  call, so the exclusion looked right. The hazard is the seam: a policy that
  today reads as a sentence in an extension could be re-expressed as a manifest
  key, and that move would be exactly the swallow constraint 4 exists to catch
  while landing entirely outside the scope.

  **Resolved: yes, it covers the manifest.** Decision point 6 above states the
  scope, what a manifest violation is, and what is explicitly not one. Two
  things decided it. First, the manifest already carries policy calls -
  `gate.project_level_skips`, `gate.sabotage.exempt_prefixes`,
  `beads.areas.lands_alone` - so the exclusion was not merely a seam to watch,
  it was already leaving live decisions unsupervised. Second, "leave it until
  such a change is actually proposed" is a trigger no one can observe, because
  the thing that would observe it is the scope being deferred; st-5y5 landed a
  change to what counts as a blocking gate failure with neither this judge nor
  the gate itself seeing it. The counter-argument the question rested on - that
  widening is a one-character change available the day it is needed - is sound
  about the cost and wrong about the day, which is not detectable from inside
  the current arrangement.
- **Should `wurk` carry a mirrored constraint-4 judge over its own generic
  SKILL.md prose?** ADR-0016 names the exposure - a policy call that migrates
  upward into a generic skill leaves this gate's reach - and correctly says
  that is no longer this project's call. Whether the `wurk` repo takes it up is
  an upstream question this record can only flag.
