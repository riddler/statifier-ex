# /work Orchestrator Skill Implementation Plan

## Overview

Add a `/work` skill that owns triage, model selection, and the
research -> plan -> implement arc, and remove those concerns from `/next-issue`,
`/next-issues`, and `/new-worktree`. `/work` runs inside the worktree that will
carry the change, always on Opus, and drives each stage as a model-tiered
subagent rather than implementing anything itself.

Beads issue: `st2-ott` (labels `area:docs`, `area:skills`). Blocks `st2-ltj`
(the Fable/direction tier's missing route), which stays out of scope here.

## Current State Analysis

Triage happens today at pickup time, in the session that runs `/next-issue` or
`/next-issues`, and is shipped to a different process as a seed command.

- **`.claude/skills/next-issue/SKILL.md:109-131`** - step 4, the triage table.
  Three buckets (code-heavy / plan-only / just-do-it), each mapping to a seed
  command. The decision is made with the bead in hand but *not* the codebase.
- **`.claude/skills/next-issues/SKILL.md:271-284`** - step 7 repeats the same
  choice per bead, delegating the table itself to `/next-issue`.
- **`.claude/skills/new-worktree/SKILL.md:136-164`** - a `case` statement maps
  the seed command back to a `--model` flag
  (`/create-plan`|`/research-codebase` -> opus, everything else -> sonnet).
  This is st2-o9a's fix, and it is the second owner of the same rule: a skill's
  `model:` frontmatter does not govern a CLI session launched with that skill as
  a prompt argument.
- **`docs/workflow.md:6-21`** - the three tiers (Fable/direction, Opus/planning,
  Sonnet/implementation) describe *which model a skill runs on*. There is no
  statement about which model an orchestrator should assign to a delegated
  stage.

Three consequences, restating the bead:

1. The picker guesses blast radius from a description; the worktree session is
   the one that can actually look at the code.
2. The bucket -> model mapping lives in two places (skill frontmatter and
   `/new-worktree`'s `case`).
3. Triage picks exactly one bucket, but the real flow is a *sequence*
   (research, then plan, then implement). Nothing carries a bead across those
   handoffs, so each stage boundary re-derives the routing.

### Key Discoveries

- **A skill's `model:` frontmatter beats the Agent tool's `model` override.**
  Per the Claude Code skills reference, `model:` "applies for the rest of the
  current turn." So a Sonnet subagent that invokes `/create-plan` (frontmatter
  `opus`) runs `/create-plan` on Opus regardless of what `/work` passed. The
  Agent override governs only the subagent's turns *before* the skill fires -
  the `bd show`, the plan-file read, the triage.

  This does not bite today: `research-codebase: opus`, `create-plan: opus`,
  `implement-plan: sonnet` are exactly the tiers `/work` would assign. The two
  owners agree. It would bite the moment a stage wanted a non-frontmatter tier,
  so the plan resolves it by declaring **frontmatter the source of truth and
  `/work`'s table a mirror of it**, with `docs/workflow.md` recording that they
  must not diverge.

- **`/implement-plan --loop` is already a per-phase orchestrator**
  (`.claude/skills/implement-plan/SKILL.md:48-96`). It dispatches one
  `general-purpose` Agent per phase with a fully self-contained prompt, then
  runs `/commit --auto` *itself* as the advancement gate - deliberately
  independent of the subagent's self-report - and unchecks the phase's boxes on
  refusal. `/work` must not re-implement any of this.

- **Subagents may spawn subagents, three layers below the main conversation by
  default** (Claude Code sub-agents reference), and this repo sets no
  `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` (`.claude/settings.json` has only a
  `SessionStart` hook). So `/work` (main) -> implement subagent (layer 1) ->
  per-phase subagent (layer 2) is within the default limit.

- **A seeded session cannot spawn a nested `claude` CLI**
  (`new-worktree/SKILL.md:258-271`, st2-d9g): `--permission-mode auto`'s
  classifier blocks `tmux send-keys ... 'claude'`. In-process Agent subagents
  are unaffected. Whoever implements this will reach for tmux first unless told
  not to.

- **`general-purpose` is the right subagent type.** Its tool list is `*`, so it
  has both the Skill tool and the Agent tool. None of the stage skills set
  `disable-model-invocation`, so all three are Skill-tool invocable. No new
  `.claude/agents/` definitions are needed; the six that exist
  (`codebase-locator`, `codebase-analyzer`, ...) are the ones the stage skills
  already spawn internally.

- **Both dependencies have landed on this branch**: `st2-ns4` and `st2-d9g` are
  commits `0a35bfe`, and `st2-o9a` is `e60cc72`. The design note's sequencing
  hazard is already resolved.

## Desired End State

`/work` is the single entry point for working a bead:

    /work st2-abc            # interactive, in a worktree
    /work st2-abc --auto     # unattended, as seeded by /new-worktree
    /work "add retry backoff to the send queue"

- It accepts a bead id or free text; free text creates a bead with description,
  acceptance criteria and an `area:` label, then claims it, before any work.
- Run in the main checkout, it creates/claims and hands to `/new-worktree`,
  which seeds `/work <id> --auto` in the new window. Recursive but terminating:
  the second invocation lands in a worktree and takes the other branch.
- It sizes the job once, then drives `research-codebase` / `create-plan` /
  `implement-plan` as `general-purpose` subagents with per-stage model
  overrides, and edits no `lib/`, `test/` or `docs/` content itself.
- `/next-issue`'s step 4 and `/next-issues`' step 7 bucket choice are gone; both
  seed `/work <id> --auto` uniformly.
- `/new-worktree`'s `case` statement is gone; every seeded session launches
  `--model opus`.
- `docs/workflow.md` covers subagent model assignment and the
  frontmatter-wins-within-a-turn rule.
- `CLAUDE.md`'s authority table says explicitly that a delegated subagent holds
  none of the authority in it - the orchestrator that spawned it does.

Verify by reading the four skills and the two docs, and by one live end-to-end
run (Manual Verification, Phase 5).

## What We're NOT Doing

- **No route to the Fable/direction tier.** `st2-ltj` owns that. This plan
  leaves a *named seam* - a fourth row in the triage table, marked unrouted and
  citing the bead - rather than three hardcoded buckets.
- **No nested `claude` CLI sessions.** Subagents only (st2-d9g).
- **No changes to `/implement-plan`'s loop.** `/work` delegates to it whole.
- **No `disable-model-invocation` on `/work`.** No skill in this repo sets it;
  introducing it here would be a policy change beyond this bead, and
  `/next-issue` already carries the identical hazard (auto-invocation claiming
  beads).
- **No changelog fragment.** Agent workflow tooling is not user-facing per
  `changelog.d/README.md`.
- **No cost mitigation beyond keeping `/work` thin.** See below.
- **No changes to `/cleanup-worktrees`, `/refresh-worktree`, `/merge-request`,
  `/iterate-plan`, `/create-issue`, or `/commit`.**

## Implementation Approach

Five phases, ordered so that **every intermediate state is correct**, not merely
compiling:

1. `/work` is added first, referenced by nothing. Standalone and committable.
2. `/next-issue` and `/next-issues` switch to seeding `/work <id> --auto`.
   `/new-worktree`'s `case` still runs at this point and falls to its `sonnet`
   default for a `/work` seed - but `/work`'s own `model: opus` frontmatter
   overrides that for its turn, so the seeded session still orchestrates on
   Opus. The intermediate state is correct, not merely tolerable.
3. `/new-worktree` collapses the `case` to a constant now that every seed is
   `/work`, so the belt-and-braces stops being load-bearing.
4. `docs/workflow.md` records the resulting rules.
5. `CLAUDE.md`'s authority table gains the delegation clause. Last and separate,
   because an authority-table edit is the one change in this plan a human is
   most likely to want to review on its own.

Phases 2 and 3 are deliberately not merged: 3 is only *true* once 2 has landed,
and splitting them makes that dependency visible in the history. All five touch
no Elixir, so `mix quality` has no code to gate (CLAUDE.md's authority table
covers this case explicitly); it is still run per phase because the Gate guard
and format stages apply to the tree as a whole.

### Decisions settled before writing (no open questions remain)

| Question | Decision |
|---|---|
| Subagent mechanism | Agent tool, `subagent_type: general-purpose`, `run_in_background: false`, per-call `model`. Never a nested `claude` CLI. |
| Delegate or reimplement | Delegate. `/work` invokes the existing skills inside subagents. |
| Model ownership | Stage skills keep their `model:` frontmatter as the source of truth. `/work` passes the *same* tier as an Agent override, which governs the subagent's pre-skill turns. `docs/workflow.md` records that the two must not diverge. |
| Human checkpoints | Subagents are told explicitly that no human is available. `/work` surfaces each returned artifact and pauses at the artifact boundary - but only without `--auto`. Seeded sessions chain straight through. |
| Implement-stage shape | One Sonnet subagent runs `/implement-plan <path> --loop`; its own loop spawns one Sonnet subagent per phase and owns the per-phase `/commit --auto` gate. `/work` does not re-implement the loop. |
| Cost | Accepted. Every pickup is now Opus-priced, but `/work`'s own context stays minimal (a `bd show`, a triage decision, spawns, a report), and just-do-it work is handed to a Sonnet subagent immediately rather than done on the Opus turn. |
| Fable tier | Out of scope (`st2-ltj`), represented as an explicit unrouted row in the triage table. |

---

## Phase 1: Add the `/work` skill

### Overview

Create `.claude/skills/work/SKILL.md`. Nothing references it yet, so this phase
is standalone and reversible.

### Changes Required:

#### 1. New skill file

**File**: `.claude/skills/work/SKILL.md` (new)

**Frontmatter**:

```yaml
---
name: work
description: Single entry point for working a bead - creates or reads it, sizes the job, then drives research / plan / implement as model-tiered subagents. Never implements directly.
model: opus
argument-hint: ["a beads issue ID, or free text describing the work", "optional: --auto"]
---
```

`model: opus` is what makes "the orchestrator is always Opus" hold when `/work`
is typed into an already-running session, independent of that session's model.

**Body sections**, in order:

**`## Input`** - parse `$ARGUMENTS`:

- a token matching the `st2-` id shape -> **bead mode**
- `--auto` -> **unattended mode**: no checkpoint pauses, no questions. This is
  what `/new-worktree` seeds. Without it, `/work` pauses at each artifact
  boundary for review.
- anything else -> **intake mode**: the free text is the work description.

**`## Step 0: Locate self`** - the branch that decides everything downstream,
because CLAUDE.md forbids committing on `main`:

```bash
if [ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ]; then
  echo main-checkout
else
  echo worktree
fi
```

In the main checkout both resolve to `.git`; in a linked worktree `--git-dir` is
`.git/worktrees/<name>` while `--git-common-dir` is the shared `.git`. This is
more robust than comparing `git rev-parse --show-toplevel` against a hardcoded
path.

- **main checkout** -> do intake (Step 1) if needed, claim, then invoke
  `/new-worktree <id>-<slug> -- /work <id> --auto` and **stop**. Do not work the
  bead here. The seeded session's `/work` takes the worktree branch, so the
  recursion terminates at depth one.
- **worktree** -> continue to Step 1.

**`## Step 1: Get a claimed bead`**

- *Bead mode*: `bd show <id>`. If not claimed, `bd update <id> --claim`.
- *Intake mode*: compose with `/create-issue` rather than duplicating it. The
  bead **must** carry a description, acceptance criteria (`--acceptance`), and
  at least one `area:` label from `docs/workflow.md`'s vocabulary before it is
  claimed. State why in the skill: an unlabeled bead is what `/next-issues`
  skips as "blast radius undecided", so intake owes the label at creation rather
  than backfilling it. Then `bd update <id> --claim`, then
  `bd dolt push 2>/dev/null || true` (best-effort, never gating).

**`## Step 2: Size the job`** - the triage table, moved here from
`/next-issue` and reframed. Buckets are **entry points into one sequence**, not
terminal choices:

| Bucket | Enters at | Stages, in order | When |
|---|---|---|---|
| Code-heavy | research | `research-codebase` -> `create-plan` -> `implement-plan --loop` | Touches the interpreter core, parser, or another multi-module subsystem; blast radius unclear; existing structure (or the v1 reference at `../statifier`) must be mapped before planning. |
| Plan-only | plan | `create-plan` -> `implement-plan --loop` | Well understood but multi-step or cross-cutting enough to deserve a plan in `docs/plans/`; a research doc would be redundant. |
| Just-do-it | implement | one implementation subagent, no artifacts | Bounded doc / chore / config / small utility, low blast radius. |
| Direction | *(not routed)* | - | ADR-shaped work, spec interpretation, corpus strategy. `docs/workflow.md` names Fable for this; `/work` has no route to it yet. **Say so and stop rather than silently sizing it as code-heavy** - tracked by `st2-ltj`. |

Sizing happens **with the codebase in reach**, which is the whole reason this
moved: read the files the bead names before choosing. When genuinely uncertain
between two buckets, pick the heavier one.

**Skip stages already satisfied.** Before spawning, check for existing
artifacts - a `docs/research/` doc or a `docs/plans/` plan naming this bead, and
`bd show <id>`'s notes (`/implement-plan --loop` writes
`loop: Phase N complete, commit <sha>`). Enter the sequence at the first
unsatisfied stage. This is the seam that makes `/work` re-invocable after a
stopped loop.

**`## Step 3: Stage contract`** - one table, and the invariants every spawn
obeys:

| Stage | Skill | Agent type | `model` |
|---|---|---|---|
| Research | `/research-codebase <id>` | `general-purpose` | `opus` |
| Plan | `/create-plan <id>` | `general-purpose` | `opus` |
| Implement | `/implement-plan <path> --loop` | `general-purpose` | `sonnet` |

Invariants to state explicitly in the skill:

- **The model column mirrors each skill's `model:` frontmatter; it does not
  override it.** A skill's frontmatter wins for the turn it is active, so the
  override governs only the subagent's turns before the skill fires. Keeping
  them equal is the point - if they ever diverge, the frontmatter is right and
  this table is wrong.
- **`run_in_background: false`.** Each stage feeds the next.
- **The prompt must be fully self-contained**: the bead id, the artifact path
  when there is one, and the instruction to read the bead itself. The subagent
  has no memory of this conversation - the same rule
  `/implement-plan`'s loop already states at its step 2.
- **No human is available.** Tell the subagent so, and tell it what to do
  instead: record open questions *in the artifact it produces* and return them,
  never block on a question. `/create-plan` and `/research-codebase` are
  interactive by design; this is the instruction that makes them terminate.
- **Return the artifact path**, so `/work` can pass it to the next stage.
- **Never a nested `claude` CLI** - cite st2-d9g and
  `new-worktree/SKILL.md`'s note.

**`## Step 4: Implement stage`** - one Sonnet subagent running
`/implement-plan <path> --loop`. State plainly that its loop already dispatches
one subagent per phase and already runs `/commit --auto` itself as the
advancement gate, so `/work` must not re-implement either. Nesting is within the
default three-layer limit. On a stopped loop, `/work` reports the refusal reason
and the phase; re-running `/work <id>` resumes via the artifact scan in Step 2.

For just-do-it, the same shape without a plan: one Sonnet subagent implements
and is told **not** to commit; `/work` runs `/commit --auto` itself. This mirrors
the loop's deliberate split - the gate runs independent of the subagent's
self-report.

**`## Step 5: Checkpoints and report`**

- Without `--auto`: after each stage, print the artifact path and a one-line
  summary and pause for the user before the next stage.
- With `--auto`: chain straight through; report every artifact at the end.
- Always report: bucket + one-line rationale, each stage's model and artifact,
  and any deferred Manual Verification the loop surfaced.

**`## Guidelines`** - at minimum:

- **This skill orchestrates, it does not implement.** No `Edit`/`Write` to
  `lib/`, `test/`, or `docs/` content. The exceptions are `bd` calls, the
  `/commit --auto` gate, and its own report.
- Sizing happens here, in the worktree, because this is the session that can
  read the code - the reason this moved out of `/next-issue`.
- Sync steps are best-effort and never gate a claim.
- Discovered work goes to `bd q` with `discovered-from`, not chased now.
- Compose with `/create-issue`, `/new-worktree`, and the three stage skills
  rather than duplicating their logic.

### Success Criteria:

#### Automated Verification:
- [x] `.claude/skills/work/SKILL.md` exists with valid YAML frontmatter
      (`name: work`, `model: opus`, `description`, `argument-hint`)
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] The triage table has four rows and the Direction row names `st2-ltj` as
      the seam rather than routing ADR-shaped work to a code tier
- [ ] The stage table's `model` column matches each stage skill's `model:`
      frontmatter exactly (`research-codebase: opus`, `create-plan: opus`,
      `implement-plan: sonnet`)
- [ ] `/work` appears in the `/` menu with its description

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. In interactive execution, pause here for
manual confirmation before proceeding. In looped (`--loop`) execution, the
Automated Verification gates advancement and Manual items are deferred.

---

## Phase 2: Remove triage from `/next-issue` and `/next-issues`

### Overview

Both pickers stop deciding buckets and seed uniformly. This is a deletion, not a
relocation - the table now lives only in `/work`.

### Changes Required:

#### 1. `/next-issue`

**File**: `.claude/skills/next-issue/SKILL.md`
**Changes**:

- **Delete step 4 entirely** (lines 109-131, the triage table and its
  surrounding rules).
- **Step 3 ("Read the bead")**: it currently exists to feed the triage decision
  ("This is the input to the triage decision in step 4"). It still earns its
  place - the branch slug comes from the title, and an epic or a malformed bead
  should be caught before a worktree exists - so keep it and rewrite the
  justification.
- **Step 5**: the seed becomes the constant `/work <id> --auto`. Replace the
  "pass the bucket's command through" paragraph with the inverse rationale: the
  seed is uniform *because* sizing belongs in the worktree, where the codebase
  is readable, not here.
- **Step 6 report**: drop "the bucket and its one-line rationale".
- **Frontmatter `description`**: drop "then triage to research, plan, or
  implement directly"; replace with seeding `/work`.
- **Guidelines**: rewrite the "This skill dispatches, it does not implement"
  bullet. Its current argument ("Triage happens here because the bead is in
  hand") is exactly what this bead reverses. New form: this skill picks and
  claims; `/work` in the worktree sizes and drives.

#### 2. `/next-issues`

**File**: `.claude/skills/next-issues/SKILL.md`
**Changes**:

- **Step 7** (lines 271-284): delete the per-bead bucket choice and the
  "Pass the bucket's command through" paragraph. Every bead gets
  `/new-worktree <id>-<slug> -- /work <id> --auto`. Keep the one-at-a-time
  ordering rule and the cache-contention rationale unchanged.
- **Step 8 report table**: drop the `Bucket` column.
- **Guidelines**: the last bullet currently says "Compose with `/next-issue`'s
  triage table, `/new-worktree` and `/cleanup-worktrees`". Drop the triage
  table; the sentence "The only thing that lives here is selection" becomes
  literally true.
- **Frontmatter `description`**: unchanged (it never mentioned triage).

### Success Criteria:

#### Automated Verification:
- [x] No triage table remains in either file:
      `grep -rn "just-do-it\|Just-do-it" .claude/skills/next-issue*/` returns
      nothing
- [x] Both seed `/work`:
      `grep -n "work <id> --auto" .claude/skills/next-issue/SKILL.md .claude/skills/next-issues/SKILL.md`
      returns a hit in each
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] `/next-issue`'s step numbering still reads coherently with step 4 gone
      (steps 5 and 6 either renumber or the gap is deliberate and obvious)
- [ ] No dangling cross-reference to the removed table anywhere in
      `.claude/skills/` (`grep -rn "triage" .claude/skills/`)
- [ ] Reading `/next-issue` end to end, the seed is explained as uniform *by
      design*, not as an unexplained constant

**Implementation Note**: as Phase 1.

---

## Phase 3: Collapse `/new-worktree` to a constant model

### Overview

Every seed is now `/work`, so the seed -> model derivation has exactly one
input. This looks like a revert of st2-o9a and is not: st2-o9a is what makes
"always Opus" actually hold instead of inheriting the launching user's global
default. Say so in the commit body.

### Changes Required:

#### 1. The launch command

**File**: `.claude/skills/new-worktree/SKILL.md`
**Changes**: replace the `case` block (lines 138-141) and its explanatory
paragraph (lines 152-164).

```bash
FINISH=" When the work is complete, finish with /commit --auto - it writes the Refs trailer and refuses if the tree carries changes unrelated to <id>. Do not run git commit directly."

win=$(tmux new-window -d -P -F '#{window_id}' \
  -t '=statifier_2:' \
  -n '<name>' \
  -c "/Users/johnnyt/repos/github/statifier_2-worktrees/<name>")
[ -n "$win" ] || { echo 'tmux window not created, skipping'; exit 0; }
tmux send-keys -t "$win" \
  "claude --permission-mode auto --model opus '<seed>.$FINISH'" Enter
```

The replacement prose must keep st2-o9a's finding and add this bead's:

- `--model` is still passed explicitly, never left to the launched session's
  inherited default (`~/.claude/settings.json`), which may be neither Opus nor
  Sonnet.
- It is now a constant because every seeded session runs `/work`, which
  orchestrates on Opus and assigns the implementation tier to its own subagents.
  The tier split did not disappear; it moved inside the session, where
  `docs/workflow.md`'s roles are applied per stage.
- A skill's `model:` frontmatter governs a skill invocation inside a running
  session, not the CLI session itself - which is why this line still exists at
  all.

#### 2. Input and fallback seed

**Changes**:

- **`## Input`, seed command** (lines 34-44): the example becomes
  `-- /work st2-00p.3 --auto`. Rewrite "This is how `/next-issue` hands its
  triage decision (research / plan / implement)" - there is no decision to hand
  any more. The seed now names the *orchestrator*, and sizing happens inside it.
- **The no-seed fallback** (line 177): change from
  `'Work bead <id> in this worktree. Start with bd show <id>.'` to
  `'/work <id> --auto'`. A direct `/new-worktree` invocation with no seed then
  gets the same orchestrator as a routed one, and the generic
  read-the-bead-and-decide prompt - the last place where a session sized its own
  work ad hoc - goes away.
- **Step 6 report**: it reports "the model it launched with (`opus` or `sonnet`,
  from step 5's `case`)". Keep reporting the model (it is still useful) but drop
  the `case` reference.

### Success Criteria:

#### Automated Verification:
- [x] No `case`-based model derivation remains:
      `grep -n "MODEL=" .claude/skills/new-worktree/SKILL.md` returns nothing
- [x] `grep -n "model opus" .claude/skills/new-worktree/SKILL.md` shows the
      constant in the launch command
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] The prose explains why the explicit `--model` survives even as a constant
      (st2-o9a's finding), so a future reader does not "simplify" it away
- [ ] The no-seed fallback produces a valid `/work` invocation for a dotted bead
      id (`st2-00p.3`)
- [ ] The `$win` non-empty guard and the no-`;`-chaining rule are untouched

**Implementation Note**: as Phase 1.

---

## Phase 4: Document subagent model assignment

### Overview

`docs/workflow.md` is the doc of record for the tiers. It currently describes
which model a *skill* runs on; it gains the orchestrator dimension.

### Changes Required:

#### 1. Model roles

**File**: `docs/workflow.md`
**Changes**: extend the `## Model roles` section (lines 6-21).

- Keep the three tiers as written.
- Add that the tiers govern **two** things: which model a skill runs on, and
  which model an orchestrator assigns to a delegated stage. `/work` is the
  orchestrator; it runs on Opus and assigns Opus to research and planning
  stages, Sonnet to implementation.
- State the precedence rule found while planning this: **a skill's `model:`
  frontmatter wins for the turn it is active, over an Agent-call model
  override.** The override governs the subagent's turns before the skill fires.
  So an orchestrator's per-stage model must *mirror* the stage skill's
  frontmatter, not contradict it - if they diverge, the frontmatter is what
  runs.
- Note that Fable has no automated route yet (`st2-ltj`); `/work` names the
  bucket and stops rather than sizing ADR-shaped work at a code tier.

#### 2. Worktrees and parallel agents

**Changes**: update lines 47-61.

- `/next-issue` and `/next-issues` pick and claim; they no longer triage.
- Every seeded session launches `--model opus` running `/work <id> --auto`.
- `/work` sizes the job **in the worktree**, where the codebase is readable, and
  drives the stages as subagents.
- Keep the existing `/commit --auto` finishing-clause paragraph unchanged.

#### 3. Change flow

**Changes**: steps 2-3 (lines 183-186) name `/create-plan` and `/implement-plan`
directly. Note that `/work` is the entry point that reaches both, and that
`/implement-plan --loop` performs step 6 once per phase (already noted at line
201).

### Success Criteria:

#### Automated Verification:
- [x] `grep -n "work" docs/workflow.md` shows `/work` in the model-roles and
      worktrees sections
- [x] `grep -n "st2-ltj" docs/workflow.md` shows the Fable seam recorded
- [x] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] The frontmatter-vs-override precedence rule is stated in a way a future
      agent will find before assuming the override wins
- [ ] No section still describes `/next-issue` as triaging
- [ ] House style: `docs/workflow.md` is hyphen-only ASCII; the additions match

**Implementation Note**: as Phase 1.

---

## Phase 5: State that delegated subagents hold no authority

### Overview

`CLAUDE.md`'s authority table is written for the session doing the work. With
`/work`, the session doing the work is usually a subagent - and subagents read
that table.

This is the one phase whose subject is the repo's own authority rules, so it
lands as its own commit rather than folded into a docs sweep.

### Changes Required:

#### 1. The delegation clause

**File**: `CLAUDE.md`
**Changes**: add a paragraph after the `/implement-plan --loop` paragraph
(lines 45-50), before `## Non-interactive shell commands`. No row is added,
changed, or removed - every action `/work` takes is already covered by the
existing rows (bead create/claim by row 1's "any time"; the just-do-it
`/commit --auto` by row 3's plain trigger).

Draft:

```markdown
Authority in this table belongs to the session that owns the work, not to a
subagent it delegates to. A subagent spawned to implement a phase or a chore
does not commit, does not run the full gate as its own bar, and does not close
a bead - the orchestrator that spawned it runs `/commit --auto` afterwards, so
the gate is independent of the subagent's self-report. A subagent that believes
it has satisfied a trigger reports that; it does not act on it.
```

**Why this is needed, and why now**: a `general-purpose` subagent loads
`CLAUDE.md` (only the built-in `Explore` and `Plan` agents skip it). So a
per-phase subagent reads row 3, sees "work complete and full `mix quality`
green", and can reasonably conclude it may commit.
`.claude/skills/implement-plan/SKILL.md:70-72` already counteracts this by hand
in its spawn prompt - "**not** commit, **not** run the full `mix quality` as a
final gate, **not** close the beads issue". That makes the invariant a line of
prompt text in one skill. `/work` adds a second orchestrator following the same
rule and, with nesting, a third layer that can also read the table, so the
invariant belongs in the table itself.

Note the direction of travel: this clause **narrows** authority. It removes a
reading a subagent could otherwise act on. An edit widening the table would be
a human's call to make, not an agent's.

#### 2. Cross-reference

**Changes**: the existing `/implement-plan --loop` paragraph ends by pointing at
that skill's `## Looped Execution Mode`. Leave it as is - it is still accurate,
and the new paragraph generalizes it rather than replacing it.

### Success Criteria:

#### Automated Verification:
- [ ] The clause exists:
      `grep -n "belongs to the session that owns the work" CLAUDE.md`
- [ ] The table is unchanged - no row added, removed, or retriggered:
      `git diff CLAUDE.md` touches no line beginning with `| `
- [ ] Full quality gate passes: `mix quality`

#### Manual Verification:
- [ ] Read the authority section end to end: the new paragraph reads as a
      constraint on *who* may act, distinct from the `--loop` paragraph's
      constraint on *when*
- [ ] `.claude/skills/implement-plan/SKILL.md:70-72` still states its own
      not-commit instruction - the clause backstops that prompt text, it does
      not replace it
- [ ] House style: `CLAUDE.md` is hyphen-only ASCII; the addition matches

**Implementation Note**: as Phase 1. After this phase, run the end-to-end manual
check below before reporting the bead complete.

---

## Testing Strategy

There is no Elixir in this change, so `mix quality` gates the tree rather than
the change (CLAUDE.md's authority table covers the no-Elixir case explicitly).
Verification is textual plus one live run.

### Unit Tests:

None. No `lib/` behavior changes, so the sabotage rule does not apply.

### Conformance Tests:

None. No interpreter or parser behavior changes; no ratchet movement.

### Manual Testing Steps:

1. **Consistency sweep**: `grep -rn "triage\|bucket" .claude/skills/ docs/` and
   confirm every surviving hit is inside `.claude/skills/work/SKILL.md` or is
   the `docs/workflow.md` prose describing it.
2. **Cross-reference sweep**: `grep -rn "create-plan\|research-codebase" .claude/skills/`
   and confirm no picker still emits one as a seed.
3. **Live end-to-end, bead mode**: from the main checkout, run `/work` on a
   small real bead. Confirm it creates the worktree via `/new-worktree`, seeds
   `/work <id> --auto`, launches on `--model opus`, and stops without working
   the bead on `main`.
4. **Live end-to-end, seeded session**: in the resulting tmux window, confirm
   `/work` takes the worktree branch, sizes the bead, and spawns a subagent
   rather than editing files itself. Watch the subagent panel for the model of
   each spawned stage.
5. **Nesting check**: on a bead that reaches the implement stage, confirm the
   Sonnet implement subagent spawns per-phase subagents of its own (three-layer
   nesting works, and the `/commit --auto` gate still runs at the loop's layer).
6. **Intake mode**: `/work "some small chore"` and confirm the created bead
   carries a description, acceptance criteria and an `area:` label *before* the
   claim, and that `/next-issues` would not skip it as unlabeled.
7. **Direction bucket**: size an ADR-shaped bead and confirm `/work` names the
   Direction bucket and stops rather than routing it to research.
8. **Delegation clause**: on a run that reaches the implement stage, confirm no
   subagent commits, closes a bead, or reports a full-gate result as its own
   bar - every commit in the branch comes from an orchestrator's
   `/commit --auto`.

## References

- Beads issue: `st2-ott` (blocks `st2-ltj`; depends on closed `st2-ns4`,
  `st2-d9g`; related `st2-o9a`)
- `.claude/skills/next-issue/SKILL.md:109-131` - the triage table being removed
- `.claude/skills/next-issues/SKILL.md:271-284` - the per-bead bucket choice
- `.claude/skills/new-worktree/SKILL.md:136-164` - the seed -> model `case`
- `.claude/skills/new-worktree/SKILL.md:258-271` - the nested-`claude` limit
  (st2-d9g)
- `.claude/skills/implement-plan/SKILL.md:40-104` - `## Looped Execution Mode`,
  the per-phase orchestrator `/work` delegates to whole
- `docs/workflow.md:6-21` - model roles; `:47-61` worktrees; `:111-155` area
  labels
- `CLAUDE.md:27-50` - the agent authority table, its organizing principle, and
  the `/implement-plan --loop` granularity paragraph the new clause sits after
- `docs/adr/0010-*` - one issue, one branch, one worktree; the claim is the lock
- `docs/adr/0007-*` - beads as the only tracker
- Claude Code skills reference (`model:` applies for the rest of the current
  turn): https://code.claude.com/docs/en/skills
- Claude Code sub-agents reference (three-layer default spawn depth):
  https://code.claude.com/docs/en/sub-agents

## Deferred Manual Verification

### Phase 1

- [ ] The triage table has four rows and the Direction row names `st2-ltj` as
      the seam rather than routing ADR-shaped work to a code tier
- [ ] The stage table's `model` column matches each stage skill's `model:`
      frontmatter exactly (`research-codebase: opus`, `create-plan: opus`,
      `implement-plan: sonnet`)
- [ ] `/work` appears in the `/` menu with its description

### Phase 2

- [ ] `/next-issue`'s step numbering still reads coherently with step 4 gone
      (steps 5 and 6 either renumber or the gap is deliberate and obvious)
- [ ] No dangling cross-reference to the removed table anywhere in
      `.claude/skills/` (`grep -rn "triage" .claude/skills/`)
- [ ] Reading `/next-issue` end to end, the seed is explained as uniform *by
      design*, not as an unexplained constant

### Phase 3

- [ ] The prose explains why the explicit `--model` survives even as a constant
      (st2-o9a's finding), so a future reader does not "simplify" it away
- [ ] The no-seed fallback produces a valid `/work` invocation for a dotted bead
      id (`st2-00p.3`)
- [ ] The `$win` non-empty guard and the no-`;`-chaining rule are untouched

### Phase 4

- [ ] The frontmatter-vs-override precedence rule is stated in a way a future
      agent will find before assuming the override wins
- [ ] No section still describes `/next-issue` as triaging
- [ ] House style: `docs/workflow.md` is hyphen-only ASCII; the additions match
