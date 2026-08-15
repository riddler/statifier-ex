---
date: 2026-08-15T05:16:27-0600
researcher: Claude
git_commit: baedffc10d695da3f682b4c9a65b188d13c78fff
branch: st-0ej-adrguard-heredoc
repository: statifier-ex
beads_issue: st-0ej
topic: "Whether ADR-0018's allowed list should admit bench/results captures cited by filename from lib/"
tags: [research, decision, gate-tooling, adr-0018, bench]
status: complete
last_updated: 2026-08-15
last_updated_by: Claude
---

# Decision note: `bench/results/` captures under ADR-0018 - no amendment

**Date**: 2026-08-15T05:16:27-0600
**Git Commit**: baedffc10d695da3f682b4c9a65b188d13c78fff
**Branch**: st-0ej-adrguard-heredoc
**Bead**: st-0ej

This note settles the decision st-0ej's description couples to closing the
AdrGuard heredoc blind spot, deferred to this bead during st-59d's review:
whether a `bench/results/` capture is a durable artifact that ADR-0018's
allowed list (its point 2) should admit, or a dated snapshot the ban already
covers. It is written as a research-directory note rather than an ADR
because the outcome changes no normative text - it is an application of
ADR-0018 as written, not an amendment to it.

## Decision

**ADR-0018 is not amended.** A `bench/results/` capture is a dated snapshot -
the same genre as a `docs/plans/` document - and ADR-0018's existing ban
already covers a bead-id-bearing capture filename appearing in `lib/` or
`test/` doc text. The two `lib/statifier/evaluator.ex` moduledoc citations
(`bench/results/260814-st-l0t-provider-host-seam.md` at line ~93,
`bench/results/260815-st-59d-predicator-8-0.md` at line ~115) are reworded by
the implementation stage to drop the bead-id-bearing filenames and cite the
durable homes that already name those files - ADR-0030 and `bench/README.md` -
instead. No `ADR-0018-exempt` markers are added.

## Why not admit them (the merits, not just the authority)

1. **The filename is not load-bearing.** Both captures are cited, by full
   path, from homes ADR-0018 point 2 already allows code to cite:
   ADR-0030 names both (its Context, "Three measured facts bound the
   decision, all from `bench/results/260814-st-l0t-provider-host-seam.md`",
   with the parenthetical naming the 8.0 restatement; its evidence list
   repeats the first), and `bench/README.md` names the 8.0 capture as "the
   current capture of both scripts". The evaluator moduledoc already states
   every measured number inline; the filename's only job there is
   provenance, and `Measured (ADR-0030)` reaches the same file in one hop
   through an artifact that is never deleted or renumbered. Nothing else in
   `lib/` or `test/` depends on either filename.

2. **The captures fail point 2's own test.** The allowed list's line is
   "as durable as the code and normative for it". A capture is dated by
   filename, records one machine and one timing config on one day, and is
   never updated afterward. The 8.0 capture says this about itself: "Do not
   compare this file's numbers against ADR-0030's original figures without
   accounting for this", and shows the 260814 capture's `T_fixed`/`T_full`
   ratio already "belongs to the pre-hoist world and stays there". That is
   exactly the failure mode ADR-0018's Context assigns to plan documents -
   "a record of what was intended on one date ... a document nobody updates
   when the code changes" - with "measured" substituted for "intended".
   Captures are evidence *for an ADR*; the ADR is the durable, citable
   surface over them.

3. **Admitting them re-opens the accidental-clearing shape ADR-0018's
   Consequences warn about.** The narrowest mechanical carve-out - clear a
   bead id when it sits inside a `bench/results/...` path token - makes
   "mention the path" clear the check, which is the same
   clears-itself-by-accident failure that forced the ADR-0018 check off the
   shared `ADR-0\d{3}|deviation` escape pattern in the first place, now one
   directory mention away. A prose-level admission is wider still: the bead
   id *is* part of the filename, so admitting the filename admits the id.

4. **The per-line hatch already exists and is the better shape.** If a
   future capture filename ever is genuinely load-bearing in code, the
   `ADR-0018-exempt` marker clears exactly that line as a deliberate,
   reviewable act. An allowed-list amendment would trade that deliberate act
   for a standing class exemption nobody reviews per use.

5. **Authority runs the same direction (ADR-0011's reasoning).** Widening
   what the gate permits is a human's call - st-0ej's own notes say the
   ADR-0018 amendment "is a human's call, not this bead's to make
   unilaterally". Not amending, plus rewording two lines into compliance,
   only strengthens what the gate holds, needs no
   `docs/quality-gate-changes.md` ledger entry, and stays fully reversible:
   a human who disagrees can amend ADR-0018 by new record at any time, and
   the reworded lines lose no information meanwhile.

## What needs no change to be true

- **The captures' own content is already out of scope.** ADR-0018 point 1
  binds `lib/`, `test/`, and the four maintained guides; `bench/` is in
  none of those, just as it is outside every gate stage
  (`bench/README.md`, "`bench/` is outside every gate stage, on purpose")
  and outside the guard's `bead_id_in_scope?/1`. Inside a capture, the bead
  id is the entry's identity - the same reasoning point 4 gives the dated
  records under `docs/plans/` and `docs/research/`. No exempt-list edit is
  needed to keep writing captures the way the four existing ones are
  written.
- **Bead-id-free capture filenames are untouched by the mechanical check.**
  `lib/statifier/machine/content/foreach.ex` (line ~255) cites
  `bench/results/260814-macrostep.md`, which carries no bead id; the guard's
  ADR-0018 check is bead-IDs-only by design, so that line is legal today and
  stays legal after the blind spot closes. This note does not change that.

## What the implementation stage does

1. Reword `lib/statifier/evaluator.ex` line ~93: drop
   `bench/results/260814-st-l0t-provider-host-seam.md` from the
   parenthetical, keeping `Measured (ADR-0030):` - ADR-0030's Context and
   evidence list name that capture as the source of every figure the
   paragraph quotes.
2. Reword `lib/statifier/evaluator.ex` line ~115: replace
   `bench/results/260815-st-59d-predicator-8-0.md` with a pointer through a
   durable home, e.g. "Measured (the predicator 8.0 capture that ADR-0030's
   amendment note and `bench/README.md` cite):" - exact wording is the
   implementation's call, the constraint is no bead id and no dated
   filename. All quoted numbers stay.
3. Add no `ADR-0018-exempt` markers, edit no ADR, write no ledger entry.
4. Then close the heredoc blind spot in `Mix.Statifier.AdrGuard` per the
   bead's acceptance criteria; with the rewording done first (or in the same
   change), the guard going able-to-see turns nothing red.

## Open question (recorded, not settled)

ADR-0018 point 1's banned table lists "Plan or research filenames"; a dated
bench capture filename *without* a bead id (the `foreach.ex` citation above)
is arguably the same genre and arguably against the ADR's spirit. The guard
cannot and should not police it - the check is bead-IDs-only for the same
reason it skips "Phase N" - so it stays a review matter, and whether the
banned table's row should be read (or amended) to cover it is left for a
human. Nothing in this note widens the ban to cover that case.

## References

- `docs/adr/0018-no-process-jargon-in-code-comments.md` - points 1, 2, 4;
  Consequences (the accidental-clearing analysis and the guard's dedicated
  marker).
- `docs/adr/0011-quality-gate-config-not-agent-editable.md` - who may change
  what the gate permits.
- `docs/adr/0030-in1-becomes-a-provider-context-stays-off-machinestate.md` -
  the durable home citing both captures.
- `bench/README.md` - `bench/` outside the gate; names the current capture.
- `bench/results/260815-st-59d-predicator-8-0.md` - the capture's own
  do-not-compare caveat and pre-hoist-world note, the evidence it is a
  snapshot.
- `lib/mix/statifier/adr_guard.ex` - the check's scope, its dedicated
  `ADR-0018-exempt` marker, and the heredoc blind spot st-0ej closes.
- Bead: st-0ej (this decision); st-59d and st-l0t (the two citations'
  origins).
