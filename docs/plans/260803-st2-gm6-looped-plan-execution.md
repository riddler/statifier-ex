# Looped Plan Execution Implementation Plan

## Overview

Add an unattended, phase-by-phase execution mode to `/implement-plan` so an
agentic run can drive a whole plan to completion without a human confirming
between phases, while each phase still runs in a fresh, small context and is
gated by automated checks rather than a human. Update `/create-plan` (and
`/iterate-plan` where it authors phase text) so newly written plans work
correctly in both the existing interactive mode and the new looped mode.
Beads issue: st2-gm6.

## Current State Analysis

- `implement-plan/SKILL.md:123-137` (`## Verification Approach`) hard-codes a
  pause after every phase: "Pause for human verification ... Let me know when
  manual testing is complete so I can proceed to Phase [N+1]." Line 137 has a
  partial escape hatch ("If instructed to execute multiple phases
  consecutively, skip the pause until the last phase") but nothing decides
  *when* to skip it, and skipping still means one long-lived session
  accumulating every phase's context, not fresh sessions per phase.
- `create-plan/SKILL.md`'s mandatory Phase template ends every phase with:
  "**Implementation Note**: ... After completing this phase and all automated
  verification passes, pause here for manual confirmation from the human
  ..." - the same assumption is baked into what plans are written to say.
- `commit/SKILL.md` already implements an automated, refuse-and-report gate
  suitable for reuse: `/commit --auto` runs the full `mix quality` gate,
  checks every new/changed test carries a sabotage note, detects the beads
  issue from the branch name, and refuses (rather than falling back to
  asking) on a red gate, a narrowed gate run, unrelated changes in the tree,
  or a missing issue. This is exactly the "automated verification gates
  advancement" mechanism the bead asks for - no new gate needs to be
  invented.
- `new-worktree/SKILL.md:120-157` already has the only existing "fresh,
  unattended session" pattern in this repo: a tmux window running
  `claude --permission-mode auto '<seed>.<FINISH>'`, where `<FINISH>` appends
  `/commit --auto` as the completion instruction. That pattern is scoped to
  one *issue*, spawned once, and is a real OS process in a tmux window - not
  something to spin up per phase.
- The `Agent` tool is the delegation mechanism already used throughout
  `create-plan` (`codebase-locator`, `codebase-analyzer`, etc.): each call
  starts a subagent with **no memory of the parent conversation** and can be
  awaited synchronously (`run_in_background: false`). This gives a genuinely
  fresh context per call without spawning an OS process or a tmux window.
- The `Workflow` tool gives the same fresh-subagent-per-step property (and
  adds pipelining/parallelism this task doesn't need, since phases are
  strictly sequential - phase N's code depends on phase N-1's committed
  state). It also requires explicit user opt-in wording per its own tool
  contract, and nothing in this repo currently uses it. Introducing it here
  would add a second, parallel "how agents get dispatched" idiom alongside
  the `Agent` tool that `create-plan` already relies on.
- `bd formula list` / `bd mol` (beads' structured-workflow layer) exist as
  infrastructure but **no formulas are defined anywhere in this project's
  search paths** (checked: repo-local, user, and shared-workspace paths are
  all empty). Building the phase-gate state machine on an unused subsystem
  would add a dependency this project has no track record with, for no
  capability the plan/checkbox/bd-note combination doesn't already give.
- CLAUDE.md's authority table gates `git commit` on "the claimed issue's work
  is complete **and** full `mix quality` is green," written with a
  single-commit-at-the-end mental model (`docs/workflow.md`'s Change Flow
  step 6 says the same). Looped mode deliberately commits once per phase, so
  this reading needs an explicit amendment: a phase, once its own automated
  criteria are green, counts as a complete increment of "the claimed issue's
  work" for commit purposes. This still keeps the same two gates the table
  already enforces (green `mix quality`, sabotage notes) - it only changes
  the granularity at which "complete" is evaluated in this one mode.
- Docs/workflow.md's Change Flow (step 6) and `docs/testing.md`'s sabotage
  rules are otherwise unaffected: they already describe per-change gating
  requirements that a per-phase commit satisfies identically to a
  per-feature one.

## Desired End State

`/implement-plan <path> --loop [--from-phase N]` drives every remaining
phase in a plan to completion unattended:

- Each phase's implementation work happens in a fresh `Agent` subagent (no
  memory of prior phases' conversation).
- The orchestrating session re-runs the gate itself via `/commit --auto`
  after each phase - never trusts the subagent's self-report - and only
  advances when that gate is green.
- On a gate refusal, the loop stops immediately (no retry), leaves the tree
  as the failing subagent left it, records a `bd note` describing the
  failure, and reports back. A later `/implement-plan <path> --loop`
  invocation resumes from the first phase with unchecked Automated
  Verification boxes.
- Manual Verification items are collected across phases and surfaced once,
  after the last phase, instead of blocking each phase.
- `/implement-plan` without `--loop` is unchanged: still one interactive
  session, still pauses for human confirmation between phases.
- New plans written by `/create-plan` (and edits made by `/iterate-plan`)
  produce phase text and Success Criteria that work correctly read either
  way - interactively or under `--loop`.

Verification: run `/implement-plan --loop` against a small throwaway
two-phase test plan (one phase that passes cleanly, one seeded to fail
`mix quality`) in a scratch worktree and confirm: phase 1 produces its own
commit and a `bd note`; phase 2 stops the loop, leaves the tree uncommitted,
and the failure is reported with a `bd note`, without a retry attempt.

### Key Discoveries

- `commit/SKILL.md`'s existing refusal conditions (red gate, narrowed gate,
  missing sabotage note, unrelated changes, no issue detected) are already
  the right refuse-and-report contract for a loop's gate - see Current State
  Analysis above.
- `new-worktree/SKILL.md`'s `FINISH` clause pattern (append a fixed
  instruction to every seeded prompt, in one place, so it reaches every
  caller) is the right model for how `--loop` should be threaded through: one
  place in `implement-plan/SKILL.md` decides per-phase behavior, rather than
  every caller needing to know about it.
- The `Agent` tool's `run_in_background: false` mode gives a synchronous,
  fresh-context call - no polling, no background-notification plumbing
  needed for this use case, since phases are strictly sequential.

## What We're NOT Doing

- Not building on the `Workflow` tool or on `bd mol`/`bd formula` - both
  would add an orchestration idiom with no existing usage in this repo, for
  no capability the `Agent` tool + `/commit --auto` + `bd note` combination
  doesn't already provide.
- Not adding automatic retry-with-fix-on-failure. A red gate stops the loop;
  it does not spawn a second attempt.
- Not supporting parallel phase execution. Phases in a plan are assumed
  sequential (phase N depends on phase N-1's committed state), matching how
  plans are already written.
- Not changing `/implement-plan`'s default (non-`--loop`) behavior.
- Not building a new phase-grouping annotation syntax in the plan template.
  Small phases are combined at authoring time (an updated sizing rule in
  `/create-plan`) rather than grouped at execution time.
- Not touching `/merge-request`, `/cleanup-worktrees`, `/next-issue(s)`, or
  `/new-worktree` - those operate at the issue/worktree level, one level
  above what this bead scopes.
- Not changing the beads issue's own state machine (`bd claim`/`bd close`
  timing is unaffected; still closes on merge, per CLAUDE.md's authority
  table).

## Implementation Approach

Extend `/implement-plan` in place with a `--loop` mode rather than writing a
parallel skill, since the two modes share almost everything (reading the
plan, understanding the phase, implementing it, verifying it) and only
differ in who confirms advancement and where each phase's work-context lives.
The mode dispatches each phase's actual implementation to a fresh `Agent`
call and keeps the orchestrating session itself limited to: pick next phase
-> dispatch -> gate via `/commit --auto` -> `bd note` -> advance or stop. That
keeps the orchestrator's own context from accumulating implementation detail
even though, unlike a literal new OS process, the orchestrating session
technically persists across phases - the design goal ("keep in-context work
small") is met by never routing phase-level work through that persisting
context, not by ending the process.

`/create-plan`'s template changes are additive: existing plans keep working,
new plans get phase text and sizing guidance that read correctly in both
modes.

## Phase 1: Add `--loop` mode to `/implement-plan`

### Overview

The core mechanism: a documented, repeatable procedure the orchestrating
session follows to drive all remaining phases of a plan to completion,
dispatching each phase's work to a fresh subagent and gating advancement on
`/commit --auto`.

### Changes Required:

#### 1. `implement-plan/SKILL.md` frontmatter and intro

**File**: `.claude/skills/implement-plan/SKILL.md`
**Changes**: Add `--loop` and `--from-phase N` to `argument-hint`. Add one
sentence in the intro pointing at the new `## Looped Execution Mode` section
for `--loop` runs, so a plain `/implement-plan <path>` reader isn't forced to
read the loop section to understand the default flow.

#### 2. New section: Looped Execution Mode

**File**: `.claude/skills/implement-plan/SKILL.md`
**Changes**: Insert a new top-level section (after "Before You Start", before
"Getting Started") covering:

- **Trigger**: `/implement-plan <path> --loop` or `--loop --from-phase N`.
- **Preconditions**: the beads issue is claimed (same as today); the tree is
  clean (`git status --porcelain` empty) before the loop starts - if not,
  stop and report rather than looping over an already-dirty tree.
- **Per-phase procedure**, repeated for each phase from the first with an
  unchecked Automated Verification box (or from `--from-phase N`) through the
  last phase in the plan:
  1. Identify the phase's full text (heading through its Success Criteria)
     from the plan file.
  2. Dispatch one `Agent` call (`subagent_type: general-purpose`,
     `run_in_background: false`) with a **fully self-contained prompt**:
     the plan file path, the phase number and its complete text, the beads
     issue id, and explicit instructions to:
     - read the plan and the beads issue itself (it has no memory of this
       conversation),
     - implement only this phase, following the plan's intent and this
       project's conventions (Appendix D naming, errors-as-events, sabotage
       every new/changed `lib/`-asserting test),
     - keep `mix quality --profile loop` green while iterating,
     - check off this phase's Automated Verification boxes in the plan file
       (Edit) once satisfied - never check off Manual Verification boxes,
     - append any Manual Verification items from this phase, verbatim, to a
       running `## Deferred Manual Verification` section at the bottom of
       the plan file (create it on first use) instead of blocking on them,
     - **not** commit, **not** run the full `mix quality` as a final gate
       (the orchestrator does both), **not** close the beads issue,
     - end by reporting what changed and whether it believes the phase is
       complete.
  3. The orchestrator - not the subagent - runs `/commit --auto`. This is
     the automated advancement gate: full `mix quality`, the sabotage-note
     check, the unrelated-changes check, and the branch/issue checks all run
     for real, independent of the subagent's self-report.
     - **Refused** (red gate, narrowed gate, missing sabotage note,
       unrelated changes, no issue detected): stop the loop immediately - no
       retry. Run `bd note <id> "loop stopped at Phase N: <refusal
       reason>"`. Leave the tree exactly as the subagent left it. Report the
       refusal reason and which phase it happened in, then end the turn.
     - **Committed**: run
       `bd note <id> "loop: Phase N complete, commit <sha>"` - this is the
       state handoff a later invocation (or a human) reads to see what
       happened in a session that no longer exists. Advance to the next
       phase.
  4. After the last phase commits successfully, print the accumulated
     `## Deferred Manual Verification` section (if non-empty) as the final
     report, the same way the non-loop path already reports Manual
     Verification items - just batched instead of per-phase. Do not remove
     the section from the plan file; a human confirming it later can check
     items off the same way non-loop mode does today.
- **Resuming after a stop**: re-running `/implement-plan <path> --loop`
  re-scans the plan for the first phase with an unchecked Automated
  Verification box and continues from there, same as the existing
  "Resuming Work" section already describes for interactive mode. Pass
  `--from-phase N` to force starting at a specific phase (e.g. after a human
  fixes the failure by hand and wants to skip re-dispatching a phase that's
  actually done but whose boxes weren't checked).

#### 3. Update `## Verification Approach`

**File**: `.claude/skills/implement-plan/SKILL.md`
**Changes**: The existing "Pause for human verification" text (current lines
123-137) is scoped explicitly to non-`--loop` runs: prefix it with "In
interactive (non-`--loop`) mode:" and remove the now-superseded "If
instructed to execute multiple phases consecutively, skip the pause until
the last phase" line, since `--loop` mode is the real answer to "run several
phases without stopping" and the ad hoc version of it is no longer needed.

#### 4. Update `## Wrapping Up`

**File**: `.claude/skills/implement-plan/SKILL.md`
**Changes**: Note that in `--loop` mode, closing out happens once after the
last phase's commit (bead stays `in_progress`, discovered work still goes to
`bd q`), rather than per phase.

### Success Criteria:

#### Automated Verification:
- [x] Diff touches only `.claude/skills/implement-plan/SKILL.md` (docs-only;
      the `mix quality` carve-out in `commit/SKILL.md` Step 0 applies -
      confirm with `git diff main...HEAD --name-only`)
- [x] `grep -n '^## Looped Execution Mode' .claude/skills/implement-plan/SKILL.md`
      finds the new section
- [x] `grep -n -- '--loop' .claude/skills/implement-plan/SKILL.md` shows the
      flag documented in both the argument-hint and the new section

#### Manual Verification:
- [x] Dry run: with a throwaway 2-phase test plan in a scratch worktree
      (phase 1 trivially satisfiable, phase 2 seeded to fail `mix quality`),
      `/implement-plan <path> --loop` produces one commit + one `bd note`
      for phase 1, then stops before phase 2 with a `bd note` describing the
      failure and an uncommitted, unmodified-since-failure tree
- [x] Re-running `/implement-plan <path> --loop` after manually fixing the
      seeded failure resumes at phase 2 rather than re-doing phase 1
- [x] `--from-phase N` correctly skips ahead (verified by inspection - a
      straightforward "start here" override with no state-tracking logic to
      break; not separately exercised in the dry run)

---

## Phase 2: Update `/create-plan` (and `/iterate-plan`) for loop-compatible phase text

### Overview

Plans written from today's template assume a human is always present between
phases. Update the template and authoring guidance so new plans read
correctly under both interactive and `--loop` execution, and size phases so
small ones don't need a separate grouping mechanism.

### Changes Required:

#### 1. Phase template's Implementation Note

**File**: `.claude/skills/create-plan/SKILL.md`
**Changes**: In the mandatory Phase template (`## Phase N` example), replace
the note that assumes a mandatory human pause:

```
**Implementation Note**: Use `mix quality --profile loop` between edits
while iterating; run the full `mix quality` as the phase gate. In
interactive execution, pause here for manual confirmation from the human
that the manual testing was successful before proceeding to the next phase.
In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/commit --auto`); Manual Verification items
are deferred and surfaced once at the end instead of blocking here.
```

Apply the same wording change to the worked example under "Step 4: Detailed
Plan Writing" so the two don't drift apart.

#### 2. Phase-sizing guidance (replaces a grouping mechanism)

**File**: `.claude/skills/create-plan/SKILL.md`
**Changes**: In "Step 3: Plan Structure Development," add to the existing
phase-splitting guidance ("Phases should split along module boundaries...")
one more sizing rule: a phase should be the smallest unit that is
independently gate-verifiable and independently committable - if two
candidate phases would leave an intermediate `mix quality` gate red on their
own (e.g. a struct field added in one phase, consumed in the next, with
nothing exercising it in between), combine them into one phase rather than
splitting. This is the answer to "grouping small phases together" from the
bead: sizing at authoring time, not a runtime grouping annotation (see What
We're NOT Doing).

#### 3. `/iterate-plan` consistency note

**File**: `.claude/skills/iterate-plan/SKILL.md`
**Changes**: In "Step 4: Update the Plan," add one bullet to the existing
"Ensure consistency" list: if a phase's Implementation Note or sizing is
edited, keep it consistent with the interactive/`--loop` wording introduced
in `/create-plan`'s template (link by name, don't restate the wording) -
this is a one-line pointer, not new process for `/iterate-plan`.

### Success Criteria:

#### Automated Verification:
- [x] Diff touches only `.claude/skills/create-plan/SKILL.md` and
      `.claude/skills/iterate-plan/SKILL.md` (docs-only; gate carve-out
      applies)
- [x] `grep -n 'looped' .claude/skills/create-plan/SKILL.md` finds the
      updated Implementation Note wording in both the template and the
      worked example
- [x] The old unconditional "pause here for manual confirmation" sentence no
      longer appears unqualified:
      `grep -n 'pause here for manual confirmation' .claude/skills/create-plan/SKILL.md`
      only matches text that is now prefixed with "In interactive execution,"

#### Manual Verification:
- [x] Run `/create-plan` on a small throwaway task and confirm the generated
      plan's phase template reads sensibly for a human skimming it
      interactively (the loop-mode sentence shouldn't read as noise in the
      common interactive case)

---

## Phase 3: Reconcile the authority table and workflow docs with per-phase commits

### Overview

`--loop` mode commits once per phase, which is a new reading of "the
claimed issue's work is complete" in CLAUDE.md's authority table. Make that
reading explicit rather than leaving it to be inferred from the skill text.

### Changes Required:

#### 1. CLAUDE.md authority table

**File**: `CLAUDE.md`
**Changes**: Add one sentence directly under the authority table (near the
existing "organizing principle" paragraph): in `/implement-plan --loop`
mode, each phase's own green automated gate counts as "the claimed issue's
work is complete" for that increment's commit - the table's existing
conditions (worktree branch, green gate, no unrelated changes) apply
identically per phase, this only changes the granularity at which
completeness is judged.

#### 2. docs/workflow.md Change Flow

**File**: `docs/workflow.md`
**Changes**: In step 6 of "Change flow," add a parenthetical noting that
`/implement-plan --loop` performs this step (green gate, then commit) once
per phase rather than once at the end, pointing at
`.claude/skills/implement-plan/SKILL.md`'s `## Looped Execution Mode` rather
than restating it.

### Success Criteria:

#### Automated Verification:
- [x] Diff touches only `CLAUDE.md` and `docs/workflow.md` (docs-only; gate
      carve-out applies)
- [x] `grep -n 'loop' CLAUDE.md docs/workflow.md` shows both new references

#### Manual Verification:
- [x] Re-read the amended authority-table paragraph and confirm it doesn't
      accidentally widen commit authority outside `--loop` mode (a plain
      `/implement-plan` run without `--loop` should read exactly as it does
      today)

---

## Testing Strategy

### Unit Tests:
None - this bead changes only `.claude/skills/**`, `CLAUDE.md`, and
`docs/workflow.md`. No Elixir code changes, so no unit or conformance tests
apply; per `commit/SKILL.md` Step 0's carve-out, `mix quality` is not run for
this change - the diff is reviewed directly instead.

### Conformance Tests:
Not applicable (no interpreter/parser code touched).

### Manual Testing Steps:
1. In a scratch worktree, write a throwaway 2-phase plan (phase 1: add a
   trivial doc comment somewhere harmless; phase 2: seeded to fail, e.g. an
   Automated Verification step that asserts a file exists that the phase
   deliberately doesn't create).
2. Run `/implement-plan <path> --loop` and confirm: phase 1 dispatches a
   fresh `Agent`, checks off its boxes, commits via `/commit --auto`, and
   writes a `bd note`; phase 2 dispatches, then `/commit --auto` refuses (or
   the phase's own Automated Verification fails), the loop stops, a `bd
   note` records the failure, and the tree is left as-is.
3. Fix the seeded failure by hand, re-run `/implement-plan <path> --loop`,
   and confirm it resumes at phase 2 without re-dispatching phase 1.
4. Confirm the final report lists any Deferred Manual Verification items
   collected across both phases.
5. Run a plain `/implement-plan <path>` (no `--loop`) against a small
   interactive plan and confirm the pause-between-phases behavior is
   unchanged from today.

## Performance Considerations

None beyond the obvious: looped mode trades one long-context session for N
short-context `Agent` dispatches plus N `/commit --auto` gate runs (each a
full `mix quality`). For plans with many small phases this means more total
gate runs than a single end-of-plan gate; Phase 2's sizing rule (combine
phases that would otherwise leave an intermediate gate red) also keeps the
gate count proportional to real units of work rather than to artificially
fine-grained phases.

## Corpus/Ratchet Notes

Not applicable - no test corpus or `passing_tests.json` changes in this
bead.

## References

- Beads issue: `st2-gm6`
- Parent epic: `st2-qww` (Automate the commit-to-merge agent workflow)
- Current pause behavior: `.claude/skills/implement-plan/SKILL.md:123-137`
- Current phase template note:
  `.claude/skills/create-plan/SKILL.md` (Phase template's Implementation
  Note, and the "Step 4: Detailed Plan Writing" worked example)
- Automated gate to reuse: `.claude/skills/commit/SKILL.md` (`--auto` mode
  and its refusal conditions)
- Existing fresh-unattended-session pattern (issue-level, not phase-level):
  `.claude/skills/new-worktree/SKILL.md:120-157`
- Authority table and per-action triggers: `CLAUDE.md`
- Change flow step 6 (commit timing): `docs/workflow.md`
- Sabotage testing rules: `docs/testing.md`
- ex_quality gate contract: `docs/adr/0009-ex-quality-as-quality-gate.md`
