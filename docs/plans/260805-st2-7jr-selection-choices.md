# Next-Issues Selection Choices Implementation Plan

## Overview

Reshape `/next-issues` manual mode from "here is the batch I decided on" into a
constraint-aware picker: enumerate the candidates, compute the constraints that
bind them (within-batch area intersections, lands-alone, epic, unlabeled, and
collisions with live worktrees), and present legal batch options the user picks
from - with an explicit, recorded override path. Also document bare bead-ID
lists as a first-class input form. Beads issue: st2-7jr.

## Current State Analysis

All logic lives in `.claude/skills/next-issues/SKILL.md`; no Elixir code is
involved.

- **Selection decides before presenting.** Step 2 (`SKILL.md:69-98`) runs the
  greedy walk to a finished batch; step 3 (`SKILL.md:100-105`) presents that
  batch as a fait accompli. The user's only lever is accept or re-invoke.
- **The selection rules themselves are sound** and stay unchanged: epics are
  skipped, unlabeled beads are skipped (except `upstream`), `area:build` lands
  alone, areas must be pairwise disjoint, greedy by priority rather than
  optimal.
- **Live worktrees are invisible to the skill.** Collisions are checked only
  within the batch being formed. The motivating session (four consecutive runs,
  2026-08-05, recorded on the bead) skipped st2-qww.7 for colliding with a live
  worktree - a judgment the skill's text never authorized or explained.
  Worktree names carry the bead id prefix (e.g. `st2-7jr-selection-choices`),
  so a live worktree's areas are recoverable via `git worktree list` plus
  `bd show <parsed-id>`.
- **Bare bead-ID lists are undefined input.** The input contract
  (`SKILL.md:36-39`) routes everything that is not an integer or `--auto` to
  `bd ready` filter flags, so `/next-issues st2-meo st2-21b` has no defined
  meaning. In practice it was interpreted as an explicit selection request,
  which is what was meant, but the skill should say so.
- **`--auto` mode** (`SKILL.md:31-32,105`) selects and claims without
  confirmation for unattended agents; the bead requires this to stay true.

## Desired End State

`/next-issues` in manual mode presents candidates and their constraints
*before* anything is claimed, offers the legal batch options (including
sequencing suggestions when the requested set is not legal all at once), and
supports a deliberate, recorded override. Bare bead-ID lists mean "consider
exactly these". `--auto` still selects and claims without confirmation, with
live-worktree collisions added as a hard skip.

Verification: dry-read the rewritten skill against the four motivating
scenarios recorded on the bead and confirm each would have resolved in a
single run.

### Key Discoveries:

- Greedy walk and presentation: `.claude/skills/next-issues/SKILL.md:69-105`
- Input contract gap: `.claude/skills/next-issues/SKILL.md:36-39`
- Area labels are about file collision, not subject matter, and batchability is
  set-disjointness: `docs/workflow.md:111-155`
- Worktree naming convention (bead id prefix, fixed at creation, ADR-0010):
  `docs/workflow.md:65-79`
- `bd update <id> --notes` appends notes without opening `$EDITOR` (CLAUDE.md,
  Non-interactive shell commands) - the vehicle for recording overrides

## What We're NOT Doing

- **Not touching `/next-issue`'s manual mode.** Its single-pick flow already
  presents choices; the bead names only `/next-issues`.
- **Not changing the selection rules.** Epic/unlabeled/lands-alone/disjointness
  and greedy-by-priority all stand; only when and how their verdicts are
  surfaced changes.
- **Not changing `--auto`'s no-confirmation contract** for unattended agents.
- **Not changing `/new-worktree`, `/cleanup-worktrees`,** or the
  claim-before-worktree ordering (ADR-0010).
- **Not fixing the seeded-session model selection** (`/new-worktree` launching
  `claude` without `--model`) - separate concern, separate bead.

## Implementation Approach

Single-file rewrite of `.claude/skills/next-issues/SKILL.md`. The structural
move is to split "compute constraints" from "choose the batch": the greedy walk
stops being the decision and becomes the *recommendation*, one option among the
legal ones the user picks from. Six concerns, all landing in one phase because
they edit one file and are only meaningful together:

1. Input contract: bare bead-ID lists become a documented form.
2. A new live-worktree survey step feeds the constraint computation.
3. Selection becomes constraint annotation - every candidate gets a verdict
   before anything is claimed.
4. Manual mode presents options via AskUserQuestion (plain-text fallback).
5. Overrides are recorded on the bead via `bd update --notes`.
6. `--auto` gains the live-worktree hard skip, nothing else.

## Phase 1: Rewrite the next-issues skill

### Overview

Rewrite `.claude/skills/next-issues/SKILL.md` end to end: input contract,
steps, and guidelines. No other file changes.

### Changes Required:

#### 1. Input contract - bead-ID list form

**File**: `.claude/skills/next-issues/SKILL.md` (Input section)
**Changes**: Add a third input form between the integer and the filter
fallthrough:

- **One or more bead IDs** (tokens matching the `st2-` id shape) -> **explicit
  selection mode**: "consider exactly these". Validate each with `bd show`;
  unknown ids are reported, not silently dropped. Explicit selection skips the
  `bd ready` listing as the candidate source but still checks readiness -
  a blocked or claimed bead is a constraint to surface, not to silently obey.
  Mixing bead IDs with `bd ready` filter flags is refused as ambiguous.
- `n` defaults to the count of listed ids in this mode (still capped at 4).

#### 2. New step - live worktree survey

**File**: `.claude/skills/next-issues/SKILL.md` (new step between candidate
listing and constraint annotation)
**Changes**: Enumerate live worktrees and their held areas:

```bash
git worktree list --porcelain
```

For each worktree other than the main checkout, parse the leading bead id from
the directory/branch name (`<id>-<slug>`, per ADR-0010 naming), then
`bd show <id> --json` to collect its `area:` labels. The result is a map of
area -> holding worktree. Worktrees whose name does not parse to a bead id, or
whose bead cannot be fetched, are reported and treated as holding no areas
(best-effort, never fatal). `upstream`-labeled beads hold no areas, as in
batching.

#### 3. Selection becomes constraint annotation

**File**: `.claude/skills/next-issues/SKILL.md` (rework of current step 2)
**Changes**: Keep the existing verdict table but change what it produces: walk
the candidates (from `bd ready` or the explicit list) and annotate each with
its verdict *without claiming anything*:

- **free** - no constraint
- **epic** - work its children
- **unlabeled** - blast radius undecided (`upstream` exempt)
- **lands-alone** - `area:build`
- **collides in-batch** - names the area(s) and the candidate holding them
- **collides with live worktree** - names the area(s) and the worktree/bead
  holding them *(new)*

The greedy-by-priority walk still runs, over beads not excluded by hard
constraints, and its result is labeled the **recommended batch** - an option,
not the outcome. When the input was an explicit bead list, legal options are
built around the requested set: largest legal subset now, plus sequencing
suggestions for the remainder (e.g. "st2-meo alone now, st2-qww.7 after it
lands").

#### 4. Manual-mode picker

**File**: `.claude/skills/next-issues/SKILL.md` (rework of current step 3)
**Changes**: Present the full candidate table (id, title, priority, verdict)
so the constraints are on screen before any question is asked, then offer the
choice via **AskUserQuestion** where the tool is available, plain-text list
otherwise. Options:

1. The recommended batch (marked as such)
2. Legal alternatives, when meaningfully different (explicit-list subsets,
   sequencing splits)
3. **Override**: take a bead despite a named live-worktree or in-batch
   collision - the option text names the risk it accepts

Nothing is claimed until the user picks. Branch-name confirmation folds into
the same presentation, as today.

#### 5. Override recording

**File**: `.claude/skills/next-issues/SKILL.md` (claim step + report)
**Changes**: When the chosen batch includes an override, record it at claim
time on each affected bead:

```bash
bd update <id> --notes "$(date +%F): claimed over area:<x> collision with <worktree/bead> - deliberate override via /next-issues"
```

(append semantics; never `bd edit`). The report's skipped/why section gains an
"overridden" entry stating the same. An override is user-only: `--auto` never
takes one.

#### 6. --auto mode

**File**: `.claude/skills/next-issues/SKILL.md` (mode description + steps)
**Changes**: `--auto` keeps select-and-claim-without-confirmation. The only
behavior change: **collides with live worktree** is a hard skip, reported with
the same wording manual mode uses. An unattended agent cannot knowingly accept
risk, so the override path does not exist for it. Explicit bead-list input
combined with `--auto` takes the largest legal subset and reports the rest.

#### 7. Guidelines and drift notes

**File**: `.claude/skills/next-issues/SKILL.md` (Guidelines section)
**Changes**: Update the guidelines to match: selection is presented, not
imposed; overrides are recorded on the bead; live worktrees are part of the
collision surface; the `bd` flag drift note gains `git worktree list
--porcelain` and `bd update --notes`.

### Success Criteria:

#### Automated Verification:

- [ ] `/commit --auto` succeeds (no Elixir touched, so the quality gate has
      nothing to run; the change commits on diff review per CLAUDE.md, and
      `/commit --auto` writes the Refs trailer and refuses unrelated changes)
- [ ] `docs/plans/260805-st2-7jr-selection-choices.md` and the rewritten
      `.claude/skills/next-issues/SKILL.md` are the only changes in the tree

#### Manual Verification:

- [ ] Dry-read the rewritten skill against the four motivating runs from the
      bead; each resolves in a single invocation:
      1. Default n=3 with area:build beads present -> build beads shown as
         lands-alone options, not silently dropped
      2. `st2-meo st2-21b st2-qww.7` -> explicit-selection mode, constraints
         shown, sequencing alternative offered
      3. `st2-21b st2-qww.7` -> lands-alone surfaced as a choice
      4. `st2-qww.7` -> live-worktree collision surfaced with override option
- [ ] All six acceptance criteria on st2-7jr are satisfied by the new text
- [ ] `--auto` path reads as claim-without-confirmation end to end, with the
      live-worktree skip reported
- [ ] The skill still composes (selection only; `/new-worktree`,
      `/cleanup-worktrees`, triage table untouched)

**Implementation Note**: No Elixir is touched, so `mix quality --profile loop`
has nothing to check here; the gate is diff review plus the dry-read above.
Finish with `/commit --auto` - never raw `git commit`.

---

## Testing Strategy

### Unit Tests:

None - the change is skill prose under `.claude/skills/`; there is no
`lib/` behavior to cover and the sabotage rule does not apply.

### Conformance Tests:

Not applicable; no interpreter or corpus impact.

### Manual Testing Steps:

1. Re-run the four motivating scenarios (see Manual Verification) as tabletop
   walkthroughs against the new text.
2. On next real use of `/next-issues`, confirm the picker presents constraints
   before claiming and that an override, if taken, lands as a bead note.
3. Confirm `/next-issues --auto` in an unattended session still claims without
   pausing.

## Corpus/Ratchet Notes

None - `test/passing_tests.json` and the corpus are untouched.

## References

- Beads issue: `st2-7jr` (motivating evidence and acceptance criteria in its
  description)
- Current skill: `.claude/skills/next-issues/SKILL.md:36-39` (input contract),
  `:69-105` (selection and presentation)
- Single-pick sibling: `.claude/skills/next-issue/SKILL.md:19-31` (mode
  parsing pattern to mirror)
- Area labels and batching rule: `docs/workflow.md:111-155`
- Worktree naming, claim-is-the-lock: `docs/workflow.md:65-79`, ADR-0010
