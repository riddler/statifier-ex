# Skill automation

The living, repo-side record of `st-hzf`'s audit of `.claude/skills/`: which
steps are deterministic mechanics extracted into `.claude/scripts/`, which
need a model but only a Haiku-sized one, and which need the session model.
The research document that produced the first snapshot of this table is
`docs/research/260806-st-hzf-skill-mechanics-scripts.md` - that document is
dated and stays as-is; this one is what future work reads and updates as
scripts land and skills get rewritten.

See `.claude/scripts/README.md` for the script contract itself (envelope
shape, Ruby version, test harness) and
`docs/plans/260806-st-hzf-skill-mechanics-scripts.md` for the phased
implementation plan.

## Classification summary

189 discrete steps across the 13 skills, decomposed and classified as (a)
scriptable deterministic mechanics, (b) needs a model but Haiku-sized would
do, or (c) needs the session model. A step that mixes a shell call with a
judgment call is counted once in each applicable class.

| Skill | Lines | frontmatter `model:` | (a) scriptable | (b) Haiku-able | (c) session-model |
|---|---:|---|---:|---:|---:|
| `create-issue` | 87 | *(none)* | 4 | 2 | 1 |
| `next-issue` | 155 | sonnet | 8 | 3 | 2 |
| `next-issues` | 338 | sonnet | 13 | 2 | 3 |
| `new-worktree` | 262 | sonnet | 8 | 1 | 1 |
| `refresh-worktree` | 159 | sonnet | 10 | 0 | 1 |
| `cleanup-worktrees` | 364 | sonnet | 12 | 0 | 2 |
| `merge-request` | 268 | sonnet | 11 | 2 | 3 |
| `commit` | 460 | sonnet | 13 | 3 | 5 |
| `work` | 282 | opus | 6 | 2 | 4 |
| `research-codebase` | 299 | *(none)* | 8 | 2 | 6 |
| `create-plan` | 552 | opus | 5 | 1 | 12 |
| `iterate-plan` | 271 | opus | 3 | 1 | 6 |
| `implement-plan` | 268 | sonnet | 14 | 2 | 7 |
| **Total** | **3,765** | | **115** | **21** | **53** |

The split is bimodal along the line the bead already drew: the six
worktree/bead-lifecycle skills (`create-issue` through `merge-request`) are
~85% scriptable, `new-worktree` and `refresh-worktree` close to 100%. The
four artifact skills (`research-codebase`, `create-plan`, `iterate-plan`, and
the judgment half of `implement-plan`) invert that ratio: mostly session
model, with a scriptable shell around them (metadata, filenames, frontmatter,
phase/checkbox parsing - Phase 8). `commit` and `work` sit in between.

## Skill-to-script map

Filled in as Phases 9-12 land. The mapping below is the intended target,
stated now so every later phase has a fixed destination; the "Status" column
is updated as each rewrite phase lands.

| Skill | Scripts it will call | Landing phase | Status |
|---|---|---|---|
| `create-issue` | `.claude/scripts/bead.rb create` | 10 | not started |
| `next-issue` | `select_batch.rb` (n=1), `worktree_survey.rb`, `bead.rb ready` | 10 | not started |
| `next-issues` | `select_batch.rb`, `worktree_survey.rb`, `bead.rb ready` | 10 | not started |
| `new-worktree` | `worktree_create.rb`, `tmux_window.rb open` | 9 | not started |
| `refresh-worktree` | `worktree_survey.rb`, `worktree_refresh.rb`, `rebase_onto.rb`, `gate.rb --profile loop` | 9 | not started |
| `cleanup-worktrees` | `worktree_survey.rb`, `pr_state.rb`, `tmux_window.rb find\|classify\|quiesce\|close`, `worktree_cleanup.rb` | 9 | not started |
| `merge-request` | `repo_state.rb`, `rebase_onto.rb`, `gate.rb`, `pr_state.rb`, `refs.rb` | 11 | not started |
| `commit` | `repo_state.rb`, `gate.rb`, `bead.rb resolve`, `refs.rb` | 12 | not started |
| `work` | `repo_state.rb`, `bead.rb show` | 12 | not started |
| `research-codebase` | `doc_meta.rb` | 11 | not started |
| `create-plan` | `doc_meta.rb`, `plan_state.rb` | 11 | not started |
| `iterate-plan` | `doc_meta.rb`, `plan_state.rb`, `permalinks.rb` | 11 | not started |
| `implement-plan` | `plan_state.rb`, `gate.rb` | 12 | not started |

## What must never be scripted

Each item is prose that carries judgment a script would silently drop -
ranked by risk in the source research (`docs/research/260806-st-hzf-skill-mechanics-scripts.md#risks`,
lines 521-570). Every entry below corresponds to one of that section's 12
risks.

1. **The sabotage protocol.** A script can assert a `# sabotage:` line
   exists; it cannot assert the mutation was plausible or that the test
   failed for the right reason. Automating the note's presence without
   keeping the paragraph in front of the model converts a verification
   discipline into a comment-formatting rule. Stays prose in
   `/implement-plan` and `/commit`.
   Reason: `docs/research/260806-st-hzf-skill-mechanics-scripts.md:525-532`,
   `CLAUDE.md` (Conventions, sabotage bullet).
2. **"Changes unrelated to the claimed issue."** The one auto-refusal with
   no mechanical test - a session-model gate, not something the other seven
   `/commit` conditions automating cleanly can absorb.
   Reason: `.claude/skills/commit/SKILL.md:37`.
3. **The ADR-0011 ledger entry.** `docs/quality-gate-changes.md` is a
   human's call on the record; no script may write it (`gate.rb` reports the
   guard's status only, per Phase 7).
   Reason: `CLAUDE.md` (ExQuality section), ADR-0011.
4. **`bd close` outside a confirmed merge.** `bd close` fires on merge into
   `origin/main` and nowhere else; `/cleanup-worktrees` is the only closer.
   A generic "finish the bead" helper is the most tempting and most wrong
   extraction available - no script under `.claude/scripts/` has a `close`
   subcommand (Phase 3).
   Reason: `CLAUDE.md` (authority table, `bd close` row),
   `docs/research/260806-st-hzf-skill-mechanics-scripts.md:540-543`.
5. **Phase sizing.** A phase is "the smallest unit that is independently
   gate-verifiable and independently committable"; a phase-splitting script
   produces syntactically valid phases that break `--loop`. No `split` or
   `size` subcommand exists on `plan_state.rb` (Phase 8).
   Reason: `.claude/skills/create-plan/SKILL.md:228-239`.
6. **Changelog-fragment invention.** Most work needs no fragment, and that
   is the expected outcome, not a skipped step. No script templates a
   fragment from a diff.
   Reason: `.claude/skills/merge-request/SKILL.md:157-160`,
   `.claude/skills/commit/SKILL.md:203-206`.
7. **The `/next-issues` picker's override option.** Manual mode presents, it
   does not impose - the envelope's `recommended` array is a recommendation,
   never an outcome a calling model can read as the decision; the picker
   itself stays in the skill (Phase 6).
   Reason: `.claude/skills/next-issues/SKILL.md:309-312`,
   `docs/research/260806-st-hzf-skill-mechanics-scripts.md:565-567`.
8. **The branch name as authority.** ADR-0010 makes it a creation-time
   label, not an authority; any `branch_bead`-shaped field ships with
   `strategy`/`confidence`/`warning`, never alone (Phase 2, Phase 3).
   Reason: ADR-0010,
   `docs/research/260806-st-hzf-skill-mechanics-scripts.md:553-555`.
9. **The rebase-before-gate ordering.** The gate must attest to the tree
   that will merge; no optimizer may reorder or skip the gate on a no-op
   fast path.
   Reason: `.claude/skills/merge-request/SKILL.md` (steps 3-4),
   `docs/research/260806-st-hzf-skill-mechanics-scripts.md:556-559`.
10. **`--auto` removes a prompt, not a bar.** A refusal is a report, not a
    fallback to interactive.
    Reason: `.claude/skills/commit/SKILL.md:20,44-45`.
11. **`/research-codebase`'s documentarian-not-critic stance.** `doc_meta.rb`
    emits frontmatter and filenames only; it never emits section headings or
    body scaffolding, since nothing in a skeleton stops a model filling it
    with recommendations (Phase 8).
    Reason: `docs/research/260806-st-hzf-skill-mechanics-scripts.md:562-564`.
12. **Flagging ADR contradictions.** `/iterate-plan` must flag a plan change
    that contradicts an accepted ADR rather than silently editing the plan;
    an Edit-applying script has no ADR awareness and never gets one.
    Reason: `.claude/skills/iterate-plan/SKILL.md:174-176`.

## Model routing

Placeholder - filled by Phase 12, which records which steps were routed to
Haiku via a per-call `model:` on an inline Agent prompt (the only mechanism
available, since a skill's own `model:` frontmatter beats an Agent-call
override for any step dispatched through the Skill tool - see
`docs/workflow.md:6-48`) and why.
