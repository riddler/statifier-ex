# Skill automation

**Historical record (as of 2026-08-08, `st-cex`).** This document was
`st-hzf`'s audit of the thirteen skills that lived under `.claude/skills/`
until `st-cex` retired that tree. Those skills, and the `.claude/scripts/`
tree they were extracted into, now live in the separate `wurk` repo and are
installed here as the generic `wurk:*` skills and `wurk:kit` scripts; the
statifier-specific judgment they carried was preserved in `.claude/wurk/*.md`.
The classification below is the record of that audit as it stood at the time,
and every line reference into `.claude/skills/*/SKILL.md` and
`.claude/scripts/` is to the tree as it stood then, not as it stands once
`st-cex` finishes removing it.

**The decision this record implements is ADR-0015** (skill mechanics live in
scripts, judgment lives in prose), which states the five constraints - step
scoping and the banned-operation list, one definition site for shared
mechanics, the JSON envelope, judgment stays in prose, and the gate must
measure the scripts. ADR-0015 is itself pending its own supersession record
now that the tree it describes has moved; consult it, and whatever
supersedes it, rather than re-arguing any of its constraints here. This
document records *what was classified how*, not *why the split exists*.

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

Landed for all 13 skills as of Phase 12 - the mapping below was the intended
target from Phase 1 onward, and every "Landing phase" now has a matching
`git log` commit on this branch.

Scripts a skill calls only indirectly (e.g. `worktree_cleanup.rb` requires
`worktree_survey.rb` and `pr_state.rb` internally; `select_batch.rb` requires
`bead.rb` and `worktree_survey.rb` internally) are named once, on the script
that composes them, rather than repeated on every skill downstream of it -
each script's own file lists its `require_relative`s.

| Skill | Scripts it calls | Landing phase | Status |
|---|---|---|---|
| `create-issue` | `bead.rb create\|link\|label` | 10 | landed |
| `next-issue` | `select_batch.rb` (n=1), `bead.rb sync\|claim\|show` | 10 | landed |
| `next-issues` | `select_batch.rb`, `bead.rb sync\|claim\|note` | 10 | landed |
| `new-worktree` | `worktree_create.rb`, `tmux_window.rb ensure-session\|open` | 9 | landed |
| `refresh-worktree` | `worktree_refresh.rb` (composes `worktree_survey.rb`, `rebase_onto.rb`) | 9 | landed |
| `cleanup-worktrees` | `worktree_cleanup.rb` (composes `worktree_survey.rb`, `pr_state.rb`), `tmux_window.rb find\|classify\|quiesce\|close` | 9 | landed |
| `merge-request` | `repo_state.rb`, `rebase_onto.rb`, `gate.rb` | 11 | landed |
| `commit` | `gate.rb`, `repo_state.rb`, `bead.rb resolve`, `commit_message.rb` | 12 | landed |
| `work` | `repo_state.rb`, `bead.rb show\|claim\|sync`, `work_state.rb` (composes `bead.rb show`, `plan_state.rb`) | 12 | landed |
| `research-codebase` | `doc_meta.rb`, `permalinks.rb` | 11 | landed |
| `create-plan` | `doc_meta.rb`, `plan_state.rb` | 11 | landed |
| `iterate-plan` | `plan_state.rb` | 11 | landed |
| `implement-plan` | `plan_state.rb`, `repo_state.rb`, `bead.rb claim\|note` | 12 | landed |

Every script under `.claude/scripts/*.rb` is named on at least one row above,
directly or as a parenthetical composed-by note: `bead.rb`, `commit_message.rb`,
`doc_meta.rb`, `gate.rb`, `permalinks.rb`, `plan_state.rb`, `pr_state.rb`,
`rebase_onto.rb`, `repo_state.rb`, `select_batch.rb`, `tmux_window.rb`,
`work_state.rb`, `worktree_cleanup.rb`, `worktree_create.rb`,
`worktree_refresh.rb`, `worktree_survey.rb`.

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

### The mechanism and its limit

A skill's `model:` frontmatter beats an Agent-call `model:` override for the
turn that skill is active (`docs/workflow.md:6-48`, `work/SKILL.md`'s Step 3
invariants). Haiku routing therefore applies **only** to a prompt composed
directly in an Agent call - never to a step dispatched through the Skill tool,
because the dispatched skill's own frontmatter would immediately override it.
This is why `/work`'s Direction stage (`work/SKILL.md`'s "Direction stage
prompt") composes its prompt inline rather than through a stage skill: it is
the one row in the Step 3 table with no skill to dispatch through at all, and
not coincidentally the shape every other Haiku delegation point below also
takes - a prompt built inline in the calling skill, never a subagent invoking
another skill.

No `.claude/agents/` definition exists or is being added for this. The bead
asks that delegation points be identified and recorded, not that a
speculative agent be built - see "Why no Haiku agent is being added" below.

### The 21 delegation points

Grouped into five kinds. Each traces to a real step in a real skill; none of
these are hypothetical.

1. **Branch slug generation** (4 points) - `next-issue/SKILL.md` step 2,
   `next-issues/SKILL.md` step 5, `work/SKILL.md` Step 0 ("compute the branch
   name `<id>-<slug>`"), `new-worktree/SKILL.md`'s Input section ("If given
   only a bead id, ask for the slug"). One bead title in, one 2-4-word
   kebab-case slug out. The cheapest and most frequently executed judgment in
   the set - every worktree creation touches one of these four call sites.
2. **Commit and PR body drafting** (2 points) - `commit/SKILL.md` Step 2 (the
   commit message body: what was done, why, technical notes), `merge-request/
   SKILL.md` step 7 (the PR body's Why/What/Notes). Prose only; the hard
   limits and the attribution check stay in `commit_message.rb`, which no
   drafting step may bypass - a drafted message still has to pass the
   validator before it is ever shown or committed.
3. **Diff and change summarization** (2 points) - `commit/SKILL.md` Step 1's
   "what features were added / what bugs were fixed / what was refactored"
   classification over the diff, and `next-issue/SKILL.md`'s one-line "why
   now" per ready-bead candidate.
4. **Bounded classification** (4 points) - `create-issue/SKILL.md`'s type and
   priority inference ("infer type and priority when obvious"),
   `iterate-plan/SKILL.md`'s "does this need new research" binary,
   `implement-plan/SKILL.md`'s refusal-reason classification (naming which of
   the loop's stop conditions fired, for the report), `create-plan/SKILL.md`'s
   unresolved-open-questions scan before a plan is finalized.
5. **Kebab description for artifact filenames** (1 point, called from 3
   sites) - the `description` slug in
   `docs/{plans,research}/YYMMDD-<id>-<description>.md`, composed inline
   wherever `research-codebase/SKILL.md`, `create-plan/SKILL.md`, or
   `iterate-plan/SKILL.md` calls `doc_meta.rb filename --description`.

The 21 is the sum of the classification summary table's (b) column above,
tallied per skill by the original audit: `create-issue` 2, `next-issue` 3,
`next-issues` 2, `new-worktree` 1, `merge-request` 2, `commit` 3, `work` 2,
`research-codebase` 2, `create-plan` 1, `iterate-plan` 1, `implement-plan` 2
(`refresh-worktree` and `cleanup-worktrees` carry none - both are ~85-100%
scriptable mechanics with no bounded-text step left over). Every one of those
falls into one of the five kinds above; a skill can carry more than one
instance of a kind, which is why the per-skill counts do not all match the
number of kinds a skill is listed under above. The five kinds are the durable
classification this section keeps current; the per-skill tally is the
original count from
`docs/research/260806-st-hzf-skill-mechanics-scripts.md`'s classification
table and "Haiku delegation candidates" section, which remains the place to
look for the full skill-by-skill breakdown behind this total.

### What is explicitly not routed to Haiku, and why

- **Phase sizing** (`create-plan/SKILL.md`) - "the smallest independently
  gate-verifiable and independently committable unit" needs the codebase in
  reach, not a title.
- **The `/next-issues` picker** - presents, does not impose; the choice
  belongs to whichever session has the authority to accept a collision risk,
  which a Haiku subagent does not hold.
- **"Changes unrelated to the claimed issue"** (`commit/SKILL.md`) - the one
  auto-refusal condition with no mechanical test at all; delegating it would
  just move the judgment call, not remove it.
- **The sabotage judgment** (`implement-plan/SKILL.md`, `commit/SKILL.md`) -
  confirming a mutation actually reddened the test for the right reason
  requires reading the diff against the code, not classifying text.
- **ADR-contradiction detection** (`iterate-plan/SKILL.md`) - flagging a plan
  edit that contradicts an accepted ADR needs the ADR corpus in context, not
  a bounded yes/no over the edit alone.
- **`/work`'s bucket choice** (Step 2) - sizing happens "with the codebase in
  reach", the same reason phase sizing stays off this list.
- **The candidate table's `summary` field** (`select_batch.rb`, decided by
  `st-sdv`) - the table is a decision input read across separate runs, and a
  model-written summary would make the same bead read differently run to run;
  the cost also scales with every ready candidate on an interactive path that
  blocks the picker, and since `bd` descriptions here already open with a
  topic sentence, a deterministic first-sentence cut mostly reproduces what a
  summarizer would have written anyway. Unlike the entries above, this one is
  excluded for determinism, not for a missing codebase or authority - and the
  door stays open regardless: a Haiku pass can be layered over the same
  envelope field later without an envelope or skill change.

Each of these needs either the codebase in reach or an authority a subagent
does not hold, except the candidate-table entry just above, which needs
determinism on an interactive path instead - the three disqualifying
properties this section's mechanism cannot supply no matter which model runs
the prompt.

### Why no Haiku agent is being added

The bead's acceptance criteria ask to "record which steps were routed to
Haiku and why" - identification and recording, not a new capability. A
`.claude/agents/` definition is a separate change with its own verification
(a tool roster to choose, a system prompt to write, its own test that it
actually improves on the session model for these bounded tasks), and adding
one speculatively ahead of that verification would put an unused agent in the
roster. The mechanism this section names (a per-call `model: haiku` on an
Agent call composed inline) needs no new agent type to use - `general-purpose`
already carries it - so nothing here is blocked on one existing.
