---
date: 2026-08-07
researcher: Claude
git_commit: 6ac9ff1a318c494073f74f41a2f30ee8bbfa6a35
branch: st-ack-area-label-scripts
repository: statifier-ex
beads_issue: st-ack
topic: "Which area: label covers .claude/scripts/** - fold into area:skills or mint area:scripts"
tags: [research, decision, workflow, skills, tooling, labels]
status: complete
last_updated: 2026-08-07
last_updated_by: Claude
---

# Decision: `.claude/scripts/**` is covered by `area:skills` (st-ack)

**Date**: 2026-08-07
**Git Commit**: 6ac9ff1a318c494073f74f41a2f30ee8bbfa6a35
**Beads Issue**: st-ack

## Question

`docs/workflow.md`'s area label table scopes `area:skills` to
`.claude/skills/**` and names no label for `.claude/scripts/**`, so beads
editing scripts are either unlabeled (skipped by `/next-issues`) or labeled
`area:skills` by an unauthorized judgment call, and the collision check misses
them either way. st-ack lays out two options and says the choice is a human's.
No human was available; this record makes the call in their absence, on the
record, with the reasoning it rests on. It is deliberately a research-note
decision record rather than an ADR: every entry in `docs/adr/` commits to an
engineering direction, and a one-row label-vocabulary fix downstream of
ADR-0015 is process bookkeeping, not a new commitment.

The options, from the bead:

- **(a)** Extend `area:skills` to cover `.claude/skills/**` and
  `.claude/scripts/**`. One-line table edit; treats skill prose and the
  scripts implementing it as one blast radius.
- **(b)** Add a new `area:scripts` label for `.claude/scripts/**`. Lets prose
  and script code batch independently, at the cost of one more label and
  relabeling every scripts-touching bead.

## Decision

**Option (a). `area:skills` covers `.claude/skills/**` and
`.claude/scripts/**`.** No new label is minted. The label keeps its name; its
meaning widens from "the skill prose" to "the skill system - the SKILL.md
prose and the scripts that implement its mechanics", which is the unit
ADR-0015 defines.

## Why (a) over (b)

The bead calls (b) "the more accurate collision model", and file-for-file that
is true: a SKILL.md wording change does not textually conflict with a Ruby
refactor. But the area model is bead-level and predictive, not diff-level, and
at that level the accuracy claim inverts:

1. **The two trees co-vary by design, and the history shows it.** ADR-0015
   makes SKILL.md prose the reader of each script's JSON envelope: the prose
   says which script to run and how to act on its output. Any script change
   that moves the envelope, adds a status, or shifts a step across the
   script/judgment seam edits the prose too. Post-migration commits bear this
   out - `6ac9ff1` (st-zgf: `tmux_window.rb` + `cleanup-worktrees/SKILL.md`),
   `4b4cf3f` (`select_batch.rb` + summary lib, with `cd40b86` adjusting the
   next-issue/next-issues prose to match), `8ec8433` (`gate.rb` + commit and
   merge-request prose), `d85bcd8` (`work_state.rb`/`commit_message.rb` +
   three SKILL.mds). Script-only commits exist, but they cluster in the
   initial st-hzf build-out; behavior changes since then routinely touch both.

2. **Labels are predictions, and (b) manufactures a new way for the
   prediction to miss.** `docs/workflow.md` is explicit that the label is
   written before the work exists. Under (b), a bead predicted as script-only
   that grows a SKILL.md edit mid-implementation collides with a live prose
   bead that the batch picker cleared - the exact silent-collision failure
   st-ack was filed about, recreated one level down. Under (a) that drift
   class cannot exist inside the `.claude` tree: prose and scripts are one
   set element, so the collision check is conservative against the documented
   direction of drift.

3. **The parallelism (b) buys is small.** The only pairs (b) unlocks are a
   pure-prose skill bead batched against a pure-script bead. The history
   shows pure-prose skill beads are rare outside bulk rewrites, and
   `docs/workflow.md` already prefers sequential or shared-branch work for
   small same-area issues over manufacturing parallel worktrees. A false
   "collides" costs a bead a batch slot; a false "free" costs a rebase
   conflict and a wrong-split signal. The asymmetry favors the coarser label.

4. **(a) is also the cheaper move today.** Zero relabels: st-zgf is closed
   (merged via PR #67) and st-4o7 already carries `area:skills`, which (a)
   retroactively authorizes. The `create-issue` vocabulary list does not
   change, because the label set does not change. (b) would require the new
   label in two documents plus a relabel pass, permanently.

Considered and rejected: renaming the widened label (`area:claude`,
`area:automation`) to advertise the wider scope. The rename would force
exactly the relabel churn (a) avoids, and the table's Covers column - not the
label's name - is the authority on scope.

## What the implementer does

This is the complete list; nothing here is left to re-decide.

1. **`docs/workflow.md`, area label table**: change the `area:skills` row's
   Covers cell from `.claude/skills/**` to `.claude/skills/**`,
   `.claude/scripts/**`. No other prose in the file changes.
2. **`.claude/skills/create-issue/SKILL.md`**: no edit. The label vocabulary
   it lists is unchanged, and it already delegates path scoping to
   `docs/workflow.md#area-labels`. (The bead's acceptance criterion for this
   file applies only under option (b).)
3. **Bead relabels**: none required as of 2026-08-07. st-zgf is closed;
   st-4o7 already carries `area:skills`; a sweep of `bd list --status=open`
   and `--status=in_progress` found no other bead touching
   `.claude/scripts/**` (st-9u4 and st-laz are ADR-judge work under
   `lib/mix/**`, labeled `area:build`/`area:test-harness`). Re-run that sweep
   at implementation time; any scripts-touching bead found then gets
   `area:skills`.
4. **st-4o7's note**: it anticipates a possible label change from st-ack.
   Under (a) its label is already correct; a `bd note` on st-4o7 saying so
   closes that loop.

## Scope limits and open questions

- **Other `.claude/` paths are not decided here.** `.claude/settings.json`,
  `.claude/agents/*.md`, and `.claude/commands/` (if it appears) are still
  unnamed by the table. They change rarely and were not part of st-ack; if a
  bead ever targets them, that bead should surface the gap the way st-zgf
  surfaced this one rather than inheriting `area:skills` by adjacency.
- **Revisit trigger.** If the scripts tree grows a consumer other than the
  skills (for example CI invoking `gate.rb` directly) and script-only beads
  become the common case, the co-variation premise weakens and (b) becomes
  worth its cost. That would be a new bead citing this document, not a quiet
  table edit.

## References

- Bead st-ack - the two options and the observed st-zgf/st-4o7 false-free
  batch that motivated the fix.
- `docs/workflow.md#area-labels` - the table, the disjointness rule, and the
  "label is a prediction" clarification this decision leans on.
- `docs/adr/0015-skill-mechanics-in-scripts.md` - the prose/script split that
  makes the two trees one system.
- `.claude/skills/create-issue/SKILL.md` - the vocabulary agents read when
  labeling; unchanged by this decision.
- Commits `6ac9ff1`, `4b4cf3f`, `8ec8433`, `d85bcd8` - post-migration
  evidence that behavior changes edit both trees.
