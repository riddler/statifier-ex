# ADR-0058: ADR number collisions fail the gate via a tree-local numbering invariant

Status: accepted (2026-08-19) - amended 2026-08-19 (st-9vco verify walk:
decision 2's bite point corrected against a measured replay - the base-ref
half compares against the merge-base, so it fires after the rebase, not
merely after a fetch; what it adds over the tree-local checks is the
rename/renumber shape); renumbered from 0056 to 0058 before
merge, per ADR-0056 decision 4

## Context

Two branches picking the same next ADR number concurrently has happened at
least three times. st-7wql resolved a 0037/0037 collision where both records
were on `origin/main` with the same number and `docs/adr/README.md`'s table
listed only one of them (documented in
`docs/plans/260815-st-1bjz-undefined-at-the-writers.md:247-252`); the
0043/0044 pair shows the same shape; and st-hbdr hit it on 2026-08-19, when
ADR-0052 (chart identity) landed on main while a branch carrying its own 0052
was in flight, forcing a renumber to 0053 that moved 43 references across 12
files - including `lib/` moduledocs and an approved entry in
`docs/quality-gate-changes.md`. Each occurrence was caught by a human at
rebase time, cost a renumber sweep, and left stale citations behind (st-8d5e
is the cleanup half; st-9vco, which this record decides, is the prevention
half).

The seam for a mechanical check already exists.
`lib/mix/statifier/adr_guard.ex` reads the branch diff against a base ref
(`opts[:base]`, then `origin/main`, then `main`), exposes a pure `analyze/1`
over data that `collect/1` gathers, and is registered as the `ADR guard`
custom stage in `.quality.exs` (`mix adr.check`, `skip_exit_code: 2`). A
collision check is a sibling of that machinery, though different in kind: the
existing checks are patterns over added diff lines, and this is a filename
question.

The constraint that makes the design non-obvious: **a naive gate-time check
against the local `origin/main` would not have caught st-hbdr.** The colliding
record was authored on a branch whose `origin/main` predated main's 0052, so
at authoring time there was no collision to see, and `mix quality` does not
fetch. A check that passes against a stale base ref is worse than no check,
because the pass would be trusted. Whatever is adopted has to bite at a point
where the remote's state is actually visible.

The point where it becomes visible already exists in the workflow. The
`wurk:mr` skill's step 3 runs `git fetch origin` and rebases the branch onto
the fetched default branch before step 4's full gate, and
`.claude/wurk/mr.md` additionally runs `mix quality --profile merge`
unconditionally before every push. After that fetch-and-rebase, a collision
is no longer a fact about a remote ref - it is a fact about the working
tree: main's `0052-*.md` and the branch's `0052-*.md` are two files sitting
side by side in `docs/adr/`, and (in both recorded collisions) the README
table disagrees with the directory as well.

Constraints from the gate's own rules that any check must fit:

- `CLAUDE.md` classifies skipped stages, and its ExQuality section warns that
  the `^disabled in \.quality\.exs$` not-applicable pattern currently
  classifies exactly one stage (the ADR judge): "Disabling a second stage in
  `.quality.exs` changes what this pattern silently classifies, and obliges
  whoever does it to re-argue the classification". A second
  disabled-by-default stage is therefore a cost, not a free move.
- ADR-0011 makes gate-config edits a human's call with a ledger entry;
  st-wjg's precedent in `docs/quality-gate-changes.md` records that adding a
  check to the ADR guard is gate-relevant and gets a voluntary entry even
  though `lib/mix/statifier/adr_guard.ex` is not a guarded path.
- The bead's acceptance criterion: the check, if added, "is registered so it
  cannot report itself skipped silently."

## Decision

1. **The primary mechanism is a tree-local numbering invariant, enforced by
   the existing `ADR guard` stage.** Two conditions, both readable from the
   working tree alone:

   - every number prefix among `docs/adr/[0-9][0-9][0-9][0-9]-*.md` is
     unique - two files sharing `NNNN` is a finding naming both paths;
   - `docs/adr/README.md`'s table and the directory are in bijection - every
     record file has exactly one table row whose link resolves to it, and
     every row's link resolves to a file. A missing row, a duplicate row, or
     a dangling link is a finding.

   This is deliberately an invariant about the tree, not a comparison against
   a remote ref. Its pass claims only "this tree is internally consistent",
   which a stale `origin/main` cannot falsify - so it dodges the
   trusted-stale-pass trap entirely. Its bite point is supplied by the
   workflow rather than by the check: `wurk:mr` step 3's `git fetch origin`
   plus rebase materializes main's colliding file into the tree, and step 4's
   full `mix quality` (which runs the ADR guard) then fails with the
   collision named. Replayed against st-hbdr: after the rebase, main's
   `0052-chart-identity-...md` and the branch's `0052-...-test-helpers...md`
   both exist, duplicate-prefix fires, and the README bijection fires as
   well - the exact case the naive design misses.

2. **A secondary, base-ref half joins the same stage: a branch-added
   `docs/adr/NNNN-*.md` whose number exists on the base ref under a different
   filename is a finding.** *(Amended 2026-08-19, st-9vco - the original
   text said this half "merely moves detection earlier on whatever runs
   happen to have fresh refs". Measured against a faithful replay of the
   st-hbdr collision, that clause over-promises: fresh refs alone move
   nothing for that shape, because the comparison is against the merge-base.
   The corrected account is below.)*

   `collect/1` already resolves `opts[:base]` / `origin/main` / `main`; the
   addition is a `git ls-tree` listing of `docs/adr/` carried on `source` so
   `analyze/1` stays pure. The listing is taken at
   `git merge-base <ref> HEAD` - the same commit the diff is computed
   against - not at the ref tip. A merge-base by definition excludes
   anything that landed on main after the branch diverged, so for the
   st-hbdr collision shape (main gains a record after the branch picked its
   number) this half fires only once the branch's base ref actually
   contains the colliding record - in practice after the rebase, not merely
   after a fetch. Measured on 2026-08-19 with a replay of st-hbdr against a
   controllable remote (a branch grafted onto pre-0052 main, carrying the
   guard and its own `docs/adr/0052-*.md`): with a stale `origin/main` and
   no fetch, `mix adr.check` exits 0; after `git fetch origin` but before
   the rebase, still 0; after the rebase, exit 1 with
   `adr-0058-duplicate-number` (both paths), `adr-0058-readme-index`, and
   `adr-0058-base-number` all firing. By then the tree-local half of
   point 1 fires anyway, so for the concurrent-pick shape this half adds no
   earlier detection.

   What this half genuinely adds is a different shape, also observed in the
   same replay: a branch that renames or renumbers an on-main record -
   deleting main's `NNNN-old-name.md` and adding `NNNN-new-name.md` -
   leaves exactly one file per number in the tree, so the duplicate check
   stays silent, while the merge-base still holds that number under the old
   filename and `adr-0058-base-number` fires. Comparing against the ref tip
   instead of the merge-base was offered when this was measured and
   explicitly declined for this pass; open question 3 records it.

   The asymmetry stands as originally recorded: a finding from this half is
   always real (a collision it can see is a collision), but a pass from it
   promises nothing when `origin/main` is stale - and, per this amendment,
   promises nothing about post-divergence records even when it is fresh.
   The guarantee lives in point 1 at the post-fetch, post-rebase gate run.
   Recording that asymmetry here is what keeps the stale pass from being
   trusted: no document, skill, or report may cite a bare-gate ADR guard
   pass as evidence that no collision exists on the remote.

3. **No new stage, no fetch, no new skip line.** The check lands inside
   `mix adr.check` rather than as a second disabled-by-default stage, for
   three reasons. First, the stage already runs in every bare gate and in the
   post-rebase full gate `wurk:mr` performs, so the honest bite point is
   covered without touching `.quality.exs` - no ADR-0011 guarded-path edit is
   mechanically required, though the implementation records a voluntary
   ledger entry per st-wjg's precedent. Second, it avoids becoming the second
   stage matching `^disabled in \.quality\.exs$`, which CLAUDE.md warns would
   silently widen that not-applicable classification and oblige a re-argued
   entry. Third, the stage never fetches: a gate that opens a network
   connection would need an offline-skip, and a fetch-dependent stage that
   skips when offline is exactly the silently-self-skipping shape the bead's
   acceptance criterion forbids. Freshness is the mr flow's job
   (`git fetch origin` in step 3), not the gate's.

4. **Skip semantics: the tree-local half runs even when no base ref
   resolves.** Today `collect/1` returns `:no_base_ref` and the task's
   `skip_exit_code: 2` turns the whole stage into a reasoned skip. The
   tree-local invariant needs no base ref, so the implementation runs it
   regardless and reserves the skip for the diff-based and base-ref halves
   only. The stage therefore cannot report itself skipped while a visible
   collision sits in the tree. No `gate.project_level_skips` or
   `gate.not_applicable_skips` pattern changes, so ADR-0017 point 6's
   obligation to argue a reclassification is not triggered.

5. **`docs/adr/README.md`'s table becomes machine-read.** Point 1's bijection
   check is that decision: the table stops being prose that drifts and
   becomes a checked index. Both recorded collisions produced a README
   inconsistency as well as a filename one, and the bijection is also what
   makes a post-rebase collision fail even when the two files' README rows
   happen to merge cleanly. Consequence for authors: adding a record without
   its row, or renumbering without moving the row, is now a named gate
   failure rather than a review catch. The check parses only the number, the
   link target, and row uniqueness - the Decision and Status prose columns
   stay human-owned and unparsed.

6. **Authoring guidance moves to the source: pick the number against a
   freshly fetched `origin/main`.** The README footer's "New ADRs: next
   number" note gains one sentence directing authors to run
   `git fetch origin && git ls-tree origin/main --name-only docs/adr/` before
   choosing. This is prose guidance per ADR-0017 (a discipline stated where
   the author reads it), not a mechanism, and it does not claim to prevent
   the in-flight case - it only stops a branch from starting behind.

7. **The two cheaper alternatives are weighed and declined as the primary
   mechanism.** Reserving the number at plan-writing time moves the collision
   earlier without eliminating it - two concurrent plans reserve the same
   number for the same reason two branches pick it, and a reservation
   registry would need the very freshness this record locates in the mr
   flow's fetch. Accepting collisions and making the renumber cheap (a
   script that renames a record and repoints every citation - the st-hbdr
   sweep was 43 mechanical references) addresses cost rather than frequency
   and leaves the failure a human discovers at rebase time; three collisions
   in 55 records does not yet justify owning and testing a repo-wide
   rename-and-repoint tool. Neither is adopted here; the renumber script
   remains available to st-8d5e or a successor if collisions persist after
   this record's check lands, and nothing in this record forbids it.

## Consequences

- A concurrent ADR number collision becomes a named gate failure at the
  latest by `wurk:mr`'s post-rebase full gate, instead of a human catch. The
  resolution is still manual - a renumber, exactly as st-7wql and st-hbdr
  performed - but it happens before the push, with the gate naming both
  files, rather than being noticed or missed in review.
- What the mechanism does NOT catch, stated plainly:
  - **Two in-flight branches both picking the same number** see nothing until
    the first merges and the second fetches. No local check can see an
    unpushed sibling branch; point 6's fetch-before-picking narrows the
    window and nothing closes it short of a central reservation service this
    project does not want.
  - **The base-ref half (point 2) passes silently against a stale
    `origin/main`** in ordinary bare-gate runs. That pass is not evidence of
    anything and must never be cited as such; the honest run is the one the
    mr flow performs after its fetch.
  - **A hand-run `mix quality --profile merge` without a preceding fetch**
    has the same staleness as any bare run. The unconditional
    `.claude/wurk/mr.md` sequence (fetch, rebase, gate) is the guaranteed
    path; running the merge profile outside that flow buys the ADR judge,
    not collision freshness.
  - **Stale citations left by a past renumber** are st-8d5e's scope, not
    this check's - the bijection covers `docs/adr/` and its README only,
    not every file that cites an ADR path.
- Implementation shape for the follow-on bead: the invariant and base-ref
  checks join `Mix.Statifier.AdrGuard` as data gathered by `collect/1`
  (directory listing, README text, base-ref `ls-tree`) and findings computed
  in the pure `analyze/1`; `mix adr.check`'s no-base-ref path narrows so the
  tree-local half still runs (point 4); the README footer gains point 6's
  sentence; a voluntary `docs/quality-gate-changes.md` entry records the new
  check with a human's `Approved-by:` line, per st-wjg's precedent. Tests
  follow the guard's existing `opts[:runner]` / `opts[:reader]` seams and
  the sabotage discipline.
- This record's own number was chosen under the process it governs:
  `git fetch origin` succeeded and `git ls-tree origin/main docs/adr/`
  showed 0055 as the highest number on the remote at authoring time, so 0056
  was free on both the remote and this branch. It did not stay free. ADR-0056
  landed from st-8d5e and ADR-0057 from st-hz2a while this branch was in
  flight, and this record was renumbered to 0058 at merge time - the concurrent
  pick this record exists to catch, happening to this record. The guard caught
  it: the rebase put both files in `docs/adr/`, which is what
  `adr-0058-duplicate-number` fires on.

## Open questions

Recorded rather than guessed at; no maintainer was available when this record
was written. The first two are answerable at implementation time without
reopening the decision; the third arrived with the 2026-08-19 amendment.

1. **Should the base-ref half warn about ref age?** `.git/FETCH_HEAD`'s mtime
   could let the guard annotate a base-ref pass with "origin/main last
   fetched N hours ago". Declined by default here - an mtime heuristic can
   mislabel a fresh clone and adds a claim the check cannot fully stand
   behind - but a one-line advisory (never a failure, never a skip) would be
   consistent with this record if the implementer finds it cheap and honest.
2. **Does the bijection tolerate the README's non-record rows?** Today the
   table holds only record rows and the footer holds prose, so the bijection
   is clean. If the README ever grows a section listing superseded records
   separately or linking cross-repo ADRs (predicator-ex's, wurk's), the check
   must scope itself to rows whose link targets live in `docs/adr/` - the
   st-8d5e bead already documents cross-repo citations that a naive link
   check flags wrongly. The implementation should scope by link target from
   the start.
3. **Should the base-ref half compare against the ref tip instead of the
   merge-base?** *(Added by the 2026-08-19 amendment.)* Listing `docs/adr/`
   at the resolved ref itself would let a fetch alone surface a
   post-divergence collision, moving detection ahead of the rebase for the
   st-hbdr shape. It was offered during the st-9vco verify walk and
   explicitly declined for that pass - the amendment corrects the wording,
   not the behavior - but nothing in this record forbids a later change
   adopting it, provided the asymmetry prose in decision 2 is re-derived
   for the new semantics.
