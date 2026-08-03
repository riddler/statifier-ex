# Seed Commit Discipline Implementation Plan

## Overview

Every session `/new-worktree` seeds via tmux is told what to do (research,
plan, or "just implement") but never told how to finish. The gap surfaced on
PR #22 (st2-00p.5): a `/create-plan`-seeded session finished with a raw
`git commit` instead of the `/commit` skill, so the commit carried no `Refs:`
trailer and the branch picked up an unrelated second commit (a five-skill
filename-convention change with no bead of its own). This plan closes that gap
by appending a fixed finish-with-`/commit` instruction to every seed
`/new-worktree` constructs, regardless of bucket. Beads issue: st2-2ex.

## Current State Analysis

- `/new-worktree` (`.claude/skills/new-worktree/SKILL.md:121-142`) builds the
  seeded session's prompt in step 5. It sends either the caller-supplied seed
  command verbatim (`claude --permission-mode auto '<seed>'`) or, when none was
  given, a generic fallback (`'Work bead <id> in this worktree. Start with
  bd show <id>.'`). Neither string says anything about how the session should
  end its turn.
- `/next-issue` and `/next-issues` both route to exactly three buckets -
  `/research-codebase <id>`, `/create-plan <id>`, or the just-do-it fallback -
  and both hand the resulting command to `/new-worktree` unchanged
  (`.claude/skills/next-issue/SKILL.md:103-131`,
  `.claude/skills/next-issues/SKILL.md:130-143`). `/new-worktree` is the single
  place all three buckets funnel through before a session starts, so it is the
  one point of leverage that reaches every bucket without editing three files.
- The `/commit` skill (`.claude/skills/commit/SKILL.md`) already does the work
  a finishing session needs: it detects the issue from the branch name (Step
  1.5), writes the `Refs:` trailer (Step 2), and - in `--auto` mode - refuses
  to commit when "the working tree carries changes unrelated to the claimed
  issue" (line 34) or when no issue was detected (line 35-36). Both of PR #22's
  failures are conditions this skill already checks for; they just were not
  checked, because the session never called it.
- `--permission-mode auto` (the mode every seeded tmux session starts in) makes
  the session run unattended - nobody is watching the tmux window to answer a
  prompt. `/commit`'s interactive Step 3 ("Present for Approval") would stall
  such a session indefinitely, so the finishing instruction has to point at
  `/commit --auto`, not bare `/commit`.
- CLAUDE.md's authority table grants `git commit` on the worktree branch once
  "the claimed issue's work is complete **and** full `mix quality` is green" -
  it names the git action, not the skill. A session that runs `git commit`
  directly instead of `/commit --auto` is technically inside that authority
  grant while still skipping the Refs trailer, the unrelated-changes check,
  and the changelog-fragment check that only the skill performs.
- `docs/workflow.md`'s Change Flow (step 6) already tells a *human reader*
  to finish via `/commit` or `/commit --auto`; nothing carries that
  instruction to an unattended seeded session, which never reads
  `docs/workflow.md` unless it happens to open it.

### Key Discoveries:
- Single point of leverage: `.claude/skills/new-worktree/SKILL.md:121-142`
  (step 5, the `tmux send-keys` construction) is reached by every bucket from
  both `/next-issue` and `/next-issues`, and by anyone invoking
  `/new-worktree` directly.
- `/commit --auto`'s existing refusal conditions (`.claude/skills/commit/SKILL.md:27-36`)
  already cover both observed PR #22 failures (missing `Refs:`, unrelated
  changes in the tree) - no new checks need to be invented, only triggered.
- The fix is prompt text, not code: nothing under `lib/`, `test/`, `mix.exs`,
  or `mix.lock` is touched, so the `mix quality` carve-out in `/commit`
  Step 0 applies to this change itself.

## Desired End State

Every tmux session `/new-worktree` starts - whatever bucket routed it there,
including the case where it's invoked directly with no seed command at all -
receives a prompt that ends with an explicit instruction to finish with
`/commit --auto` instead of a raw `git commit`. Verify by:

- Reading the constructed `send-keys` string in `/new-worktree` step 5 for
  both the caller-supplied-seed and fallback-seed branches, confirming both
  end with the finishing instruction.
- Standing up one real worktree via `/next-issue` (or `/new-worktree` directly)
  and reading the exact command sent to the tmux pane
  (`tmux send-keys` history is visible; or inspect the constructed string
  before it's sent) to confirm the finishing clause is present verbatim.

## What We're NOT Doing

- Not building the `/implement-bead` skill this issue's description
  considered and rejected - the notes' own conclusion is that the fix belongs
  in `/new-worktree`'s seed construction, not a new skill, and nothing
  observed since changes that conclusion.
- Not adding new refusal logic to `/commit` - the unrelated-changes and
  missing-`Refs:` checks already exist in `--auto` mode; this plan only makes
  sure seeded sessions reach them.
- Not changing `/commit`'s interactive mode, or forcing `--auto` on
  human-invoked commits - the instruction added here only shapes the text of
  the seed prompt for unattended tmux sessions.
- Not retrofitting already-merged PRs (like #22) - no bead-close or history
  rewrite is in scope.
- Not adding a lint/CI check that greps merged commits for `Refs:` trailers.
  That would catch the symptom after the fact; this plan fixes the session
  behavior that produces it. Worth revisiting only if the seed-text fix turns
  out not to hold.

## Implementation Approach

Append one fixed sentence to the prompt `/new-worktree` sends, after the
bucket-specific (or fallback) seed content, so it rides along regardless of
which bucket routed the session there. This keeps the three bucket-selection
skills (`/next-issue`, `/next-issues`, and `/new-worktree`'s own fallback)
untouched - none of them need to know the finishing instruction exists, since
`/new-worktree` appends it after receiving whatever they hand it. One file
changes; the mechanism is a string concatenation, not new control flow.

## Phase 1: Append the finishing instruction in `/new-worktree`

### Overview
Change step 5 of `.claude/skills/new-worktree/SKILL.md` so both the
caller-supplied-seed path and the fallback path end with an instruction to
finish via `/commit --auto`, and document why `--auto` specifically is
required for an unattended tmux session.

### Changes Required:

#### 1. `.claude/skills/new-worktree/SKILL.md`
**File**: `.claude/skills/new-worktree/SKILL.md`
**Changes**: In step 5, define the finishing clause once and append it to
both the seed and fallback prompts before they're sent.

Replace the current two send-keys examples:

```
tmux send-keys -t "$win" \
  "claude --permission-mode auto '<seed>'" Enter
```

```
claude --permission-mode auto 'Work bead <id> in this worktree. Start with bd show <id>.'
```

with a single finishing clause appended to whichever prompt applies:

```
FINISH=" When the work is complete, finish with /commit --auto - it writes the Refs trailer and refuses if the tree carries changes unrelated to <id>. Do not run git commit directly."

tmux send-keys -t "$win" \
  "claude --permission-mode auto '<seed>.$FINISH'" Enter
```

and, for the fallback:

```
claude --permission-mode auto 'Work bead <id> in this worktree. Start with bd show <id>.$FINISH'
```

Add a short paragraph after the existing seed-command examples explaining:
- the clause is appended unconditionally, to every bucket's seed and to the
  fallback, because step 5 is the one place all three buckets and a direct
  invocation converge;
- `--auto` (not bare `/commit`) is required because the tmux session runs
  unattended under `--permission-mode auto` - `/commit`'s interactive
  approval step would stall with nobody to answer it;
- this does not grant commit authority beyond what CLAUDE.md's authority
  table already grants (issue complete + full `mix quality` green) - it
  only routes that authority through the skill that performs the Refs-trailer
  and unrelated-changes checks instead of a bare `git commit`.

### Success Criteria:

#### Automated Verification:
- N/A - this phase touches only `.claude/skills/**` (`area:skills`), no
  `lib/`, `test/`, `mix.exs`, or `mix.lock` file changes, so `/commit`'s
  Step 0 carve-out applies and there is no `mix quality` gate to run.

#### Manual Verification:
- [x] Read the edited step 5 in `.claude/skills/new-worktree/SKILL.md` and
      confirm both the seeded-command branch and the fallback branch end with
      the finishing clause.
- [x] Run `/new-worktree` directly (no seed command) for a scratch bead or a
      throwaway branch name, and read the exact string handed to
      `tmux send-keys` before/as it fires, confirming the finishing clause is
      present and grammatically attached (no double periods, no missing
      space).
- [x] Run `/next-issue` (or `/next-issues`) once end-to-end against a real
      ready bead and confirm the tmux window's seeded prompt carries the
      finishing clause after the bucket's seed command.
- [x] Confirm the clause references `<id>` correctly in both branches (the
      bead id the fallback already computes, and the id embedded in the
      caller-supplied seed command for the other two buckets).

**Implementation Note**: This is a single-file, prompt-text change with no
build to break; there is no loop-profile iteration step. Pause here for
manual confirmation that a live `/new-worktree` (or `/next-issue`) run
produces the expected seeded prompt before considering the phase done.

---

## Phase 2: Cross-reference in `docs/workflow.md`

### Overview
`docs/workflow.md`'s Change Flow already tells a human reader to finish via
`/commit` (step 6). Add one sentence noting that seeded sessions get this
instruction automatically from `/new-worktree`, so a reader auditing the
worktree-to-commit path doesn't have to rediscover it by reading the skill
file.

### Changes Required:

#### 1. `docs/workflow.md`
**File**: `docs/workflow.md`
**Changes**: In the "Worktrees and parallel agents" section, after the
existing description of `/new-worktree` warming caches and opening a tmux
session, add one sentence: `/new-worktree` appends a fixed instruction to
every seeded prompt telling the session to finish with `/commit --auto`
rather than a raw `git commit`, so the Refs-trailer and unrelated-changes
checks in `/commit` fire even for unattended sessions.

### Success Criteria:

#### Automated Verification:
- N/A - docs-only change, no Elixir code touched.

#### Manual Verification:
- [x] The added sentence reads correctly in context and does not restate
      `/commit`'s own logic (cite it, don't duplicate it).

**Implementation Note**: Small enough to fold into the same commit as Phase 1
if the human reviewer agrees; kept as a separate phase here only so the
doc-cross-reference change is easy to skip if it turns out redundant with the
skill file itself.

---

## Testing Strategy

### Unit Tests:
None - no `lib/` or `test/` code is touched. `mix quality` has nothing to
measure for this change (per `/commit`'s Step 0 carve-out).

### Conformance Tests:
Not applicable - no SCION/W3C interpreter behavior changes.

### Manual Testing Steps:
1. Run `/new-worktree` directly for a scratch branch name with no seed
   command; inspect the tmux pane's seeded prompt for the finishing clause.
2. Run `/new-worktree <name> -- /create-plan <id>` (or reuse an existing
   ready bead via `/next-issue`) and confirm the finishing clause is appended
   after the plan seed command, not instead of it.
3. Optionally, let one real seeded session run to completion and confirm its
   final commit (via `git log -1 --pretty=format:"%B"` in that worktree)
   carries a `Refs:` trailer - the end-to-end confirmation that the seed text
   change actually changes session behavior, not just prompt wording.

## Performance Considerations

None - this is a one-line string change to a prompt template.

## Corpus/Ratchet Notes

Not applicable.

## References

- Beads issue: `st2-2ex`
- Observed failure: PR #22 (st2-00p.5) - two commits, neither carrying a
  `Refs:` trailer; second commit unrelated to the seeded bead
- `.claude/skills/new-worktree/SKILL.md:121-142` - seed construction (the
  single point of leverage this plan edits)
- `.claude/skills/commit/SKILL.md:27-36` - `/commit --auto`'s existing
  refusal conditions (missing issue, unrelated changes) that this plan
  routes seeded sessions into
- `.claude/skills/next-issue/SKILL.md:103-131`,
  `.claude/skills/next-issues/SKILL.md:130-143` - the three-bucket triage
  that all converges on `/new-worktree`
- `docs/workflow.md` - "Worktrees and parallel agents" section (Phase 2) and
  Change Flow step 6 (existing human-facing finish-via-`/commit` guidance)
- ADR-0010 (`docs/adr/0010-worktree-parallel-development.md`) - one issue,
  one branch, one worktree
