---
name: implement-plan
description: Implement technical plans from docs/plans with verification
model: sonnet
argument-hint: ["path to plan file", "--loop", "--from-phase N"]
---

# Implement Plan

You are tasked with implementing an approved technical plan from `docs/plans/`. These plans contain phases with specific changes and success criteria.

Implementation runs on the Sonnet tier per docs/workflow.md (planning runs on Opus via /create-plan and /iterate-plan).

For an unattended, phase-by-phase run with no human confirmation between
phases, pass `--loop` - see `## Looped Execution Mode` below. Everything else
in this document describes the default, interactive mode.

See `.claude/scripts/README.md` for the envelope contract shared by every
script this skill calls.

## Before You Start: Claim the Issue and Pick a Worktree

- The plan references a beads issue ID. Claim it before touching code:

  ```bash
  ruby .claude/scripts/bead.rb claim <id>
  ```

- **When working in parallel with other agents**, do the work in a git worktree
  under `../statifier-ex-worktrees/` named `<beads-id>-<slug>` per ADR-0010:

  ```bash
  git worktree add ../statifier-ex-worktrees/<beads-id>-<slug> -b <beads-id>-<slug>
  ```

  One issue = one branch = one worktree. Run the same quality gates inside the
  worktree (`mix quality --profile loop` while iterating, full `mix quality`
  before the branch is pushed or merged). Use
  `ruby .claude/scripts/bead.rb note <id> "..."` for progress other agents
  might need.

- Working solo directly in the repo is fine; the claim still happens first.

## Looped Execution Mode

**Trigger**: `/implement-plan <path> --loop` or `/implement-plan <path> --loop --from-phase N`.

**Preconditions**: the beads issue is claimed (same as above); the tree is
clean. Check both with:

```bash
ruby .claude/scripts/repo_state.rb
```

`data.branch_bead` (or the id you already claimed) covers the claim check;
`data.dirty` covers the tree check. If `data.dirty` is true, stop and report
rather than looping over an already-dirty tree.

**Per-phase procedure**, repeated for each phase from the first with an
unchecked Automated Verification box (or from `--from-phase N`) through the
last phase in the plan:

1. Identify the phase's full text:
   ```bash
   ruby .claude/scripts/plan_state.rb validate <path>
   ```
   `data.next_phase` is the phase to run (or use `--from-phase N`'s N
   directly). `data.phases` names each phase's `line_start`/`line_end` - read
   those lines from the plan file yourself to get the phase's complete text,
   heading through its Success Criteria.
2. Dispatch one `Agent` call (`subagent_type: general-purpose`,
   `run_in_background: false`) with a **fully self-contained prompt**: the
   plan file path, the phase number and its complete text, the beads issue
   id, and explicit instructions to:
   - read the plan and the beads issue itself (it has no memory of this
     conversation),
   - implement only this phase, following the plan's intent and this
     project's conventions (Appendix D naming, errors-as-events, sabotage
     every new/changed `lib/`-asserting test),
   - keep `mix quality --profile loop` green while iterating,
   - check off this phase's Automated Verification boxes in the plan file:
     ```bash
     ruby .claude/scripts/plan_state.rb check <path> <phase-n>
     ```
     once satisfied - never check off Manual Verification boxes (the script
     itself refuses a `--line` targeting a Manual box; the bulk form used here
     only ever touches Automated boxes to begin with),
   - append any Manual Verification items from this phase, verbatim, to a
     running `## Deferred Manual Verification` section at the bottom of the
     plan file:
     ```bash
     ruby .claude/scripts/plan_state.rb defer <path> <phase-n>
     ```
     (creates the section, with its standard intro paragraph, on first use)
     instead of blocking on them,
   - **not** commit, **not** run the full `mix quality` as a final gate (the
     orchestrator does both), **not** close the beads issue,
   - **implement this phase itself**: this loop is already the per-phase
     orchestrator, so do not delegate the phase to a further subagent and do
     not invoke `/implement-plan` (or `/work`) itself - either one would
     re-dispatch phases a level down, outside this orchestrator's
     `/commit --auto` advancement gate, and past the spawn depth this design
     intends. A narrowly-scoped sub-task for debugging or exploring
     unfamiliar territory (per `## If You Get Stuck` below) is still fine -
     the rule is against delegating the phase itself, not against every use
     of a subagent,
   - end by reporting what changed and whether it believes the phase is
     complete.

   (`general-purpose` stays the agent type here rather than a narrower one:
   the "use sub-tasks sparingly" allowance below means the phase subagent
   still legitimately needs the Agent tool for a targeted debugging or
   exploration sub-task, and no project-defined agent type under
   `.claude/agents/` combines Edit/Write/Bash with a trimmed-down Agent/Skill
   set - building one is out of scope for the bug the instruction above
   fixes and is filed separately rather than done here. The prompt
   instruction above is therefore the fix, not a tool restriction.)
3. The orchestrator - not the subagent - runs `/commit --auto`. This is the
   automated advancement gate: full `mix quality`, the sabotage-note check,
   the unrelated-changes check, and the branch/issue checks all run for real,
   independent of the subagent's self-report.
   - **Refused** (red gate, narrowed gate, missing sabotage note, unrelated
     changes, no issue detected): stop the loop immediately - no retry.
     **Uncheck this phase's Automated Verification boxes in the plan file**
     if the subagent checked any before the gate ran:
     ```bash
     ruby .claude/scripts/plan_state.rb uncheck <path> <phase-n>
     ```
     the resume scan below keys off those boxes, and a refusal means this
     phase's work never actually landed, whatever the subagent's own
     checklist says. Leave every other file exactly as the subagent left it -
     the refusal is diagnostic information for the human or the next resume,
     not something to clean up. Run
     `ruby .claude/scripts/bead.rb note <id> "loop stopped at Phase N: <refusal reason>"`.
     Report the refusal reason and which phase it happened in, then end the
     turn.
   - **Committed**: run
     `ruby .claude/scripts/bead.rb note <id> "loop: Phase N complete, commit <sha>"` -
     this is the state handoff a later invocation (or a human) reads to see
     what happened in a session that no longer exists. Advance to the next
     phase.
4. After the last phase commits successfully, print the accumulated
   `## Deferred Manual Verification` section (if non-empty) as the final
   report, the same way non-loop mode reports Manual Verification items -
   just batched instead of per-phase. `plan_state.rb validate <path>`'s
   `data.deferred_manual_section` confirms it is present. Do not remove the
   section from the plan file; a human confirming it later can check items
   off the same way non-loop mode does today.

**Resuming after a stop**: re-running `/implement-plan <path> --loop`
re-runs `plan_state.rb validate <path>` and reads `data.next_phase` - the
first phase with an unchecked Automated Verification box - same as
`## Resuming Work` below already describes for interactive mode. Pass
`--from-phase N` to force starting at a specific phase (e.g. after a human
fixes the failure by hand and wants to skip re-dispatching a phase that's
actually done but whose boxes weren't checked).

## Getting Started

When given a plan path:

- Read the plan completely and check for any existing checkmarks (- [x])
- Read the beads issue (`ruby .claude/scripts/bead.rb show <id>`) and all files
  mentioned in the plan
- **Read files fully** - never use limit/offset parameters, you need complete context
- Think deeply about how the pieces fit together
- Create a todo list to track your progress
- Start implementing if you understand what needs to be done

If no plan path provided, ask for one.

## Implementation Philosophy

Plans are carefully designed, but reality can be messy. Your job is to:

- Follow the plan's intent while adapting to what you find
- Implement each phase fully before moving to the next
- Verify your work makes sense in the broader codebase context
- Update checkboxes in the plan as you complete sections
- Keep `mix quality --profile loop` green between edits; the gate's Format stage
  formats for you, so do not run `mix format` as a separate step

When things don't match the plan exactly, think about why and communicate clearly. The plan is your guide, but your judgment matters too.

### When Implementing Interpreter Changes

If the plan touches the Appendix D interpreter functions:

- Keep the spec's function names and pseudocode structure (ADR-0002); a deviation
  needs an inline comment citing the mechanical reason
- Return effects, never perform side effects in the core (ADR-0003)
- Return `{:ok, v} | {:error, e}` from evaluations; only the interpreter maps
  errors to `error.execution` - never rescue-to-default at a leaf
- If conformance tests start passing, ratchet them (`mix test.baseline add`) in
  the same change

If you encounter a mismatch:

- STOP and think deeply about why the plan can't be followed
- Present the issue clearly:

  ```
  Issue in Phase [N]:
  Expected: [what the plan says]
  Found: [actual situation]
  Why this matters: [explanation]

  How should I proceed?
  ```

## Verification Approach

After implementing a phase:

- **Sabotage every new or changed test that asserts `lib/` behavior.** A test that
  passed on its first run has not been verified yet, only observed. For each one:
  break the `lib/` code it covers with a single plausible mutation (invert a
  condition, drop a clause, skip a recursive call, return the input unchanged),
  run that test, confirm it fails *for the right reason*, revert the mutation,
  confirm green. Then record it in one line directly above the test:

  ```elixir
  # sabotage: enter_states/2 skips the initial child -> red
  test "compound state enters its initial descendant" do
  ```

  Rules that matter here:
  - A test that stays green under sabotage is broken. Fix the test - never weaken
    the mutation until it reddens.
  - Deleting a function body or raising is not a mutation; everything fails, so
    nothing is learned.
  - Generated corpus files (`test/scion_tests/`, `test/scxml_tests/`) are exempt.
    Harness plumbing that asserts no `lib/` behavior is exempt too, but says so:
    `# sabotage: n/a - <why>`. Never leave the line off silently.
  - This is slow on purpose. Budget for it in the phase rather than deferring it;
    /commit checks for the notes and will refuse the commit without them.

  See `docs/testing.md` for the full rationale.
- Run the success criteria checks: `mix quality --profile loop` while iterating,
  then the full quality gate for the phase (this is also the pre-commit bar) -
  `ruby .claude/scripts/gate.rb` wraps `mix gate.verify` and
  `mix quality --format json --report -` if you need to route on the results
  programmatically.
- Fix any issues before proceeding
- Update your progress in both the plan and your todos
- Check off completed items in the plan file itself using
  `ruby .claude/scripts/plan_state.rb check <path> <phase-n>`
- **In interactive (non-`--loop`) mode: pause for human verification**. After
  completing all automated verification for a phase, pause and inform the
  human that the phase is ready for manual testing. Use this format:

  ```
  Phase [N] Complete - Ready for Manual Verification

  Automated verification passed:
  - [List automated checks that passed]

  Please perform the manual verification steps listed in the plan:
  - [List manual verification items from the plan]

  Let me know when manual testing is complete so I can proceed to Phase [N+1].
  ```

  In `--loop` mode, see `## Looped Execution Mode` above instead - automated
  verification gates advancement and Manual Verification items are deferred
  to a batched report at the end.

do not check off items in the manual testing steps until confirmed by the user.


## If You Get Stuck

When something isn't working as expected:

- First, make sure you've read and understood all the relevant code
- For interpreter behavior, diff the function against the Appendix D pseudocode
  before anything else - that is the debugging move in this project
- Consider if the codebase has evolved since the plan was written
- Present the mismatch clearly and ask for guidance

Use sub-tasks sparingly - mainly for targeted debugging or exploring unfamiliar territory.

## Wrapping Up

- When all phases are complete and the full `mix quality` gate is green, report
  status. **Do not close the issue here** - `bd close` fires only on a verified
  merge into `origin/main` (CLAUDE.md's authority table), and this skill never
  pushes or merges anything, so that trigger has not fired yet. The bead stays
  `in_progress`; see below.
- Capture discovered work immediately with `bd q` and link it with
  `discovered-from` rather than chasing it mid-task
- If working in a worktree, leave commit/push/merge decisions to the user unless
  explicitly instructed otherwise
- In `--loop` mode, this wrapping-up happens once, after the last phase's
  commit - not per phase. The bead stays `in_progress` (it still closes on
  merge, per CLAUDE.md's authority table) and discovered work still goes to
  `bd q` as it's found, rather than being batched to the end.

## Resuming Work

If the plan has existing checkmarks:

- Trust that completed work is done
- Pick up from the first unchecked item
- Verify previous work only if something seems off

Remember: You're implementing a solution, not just checking boxes. Keep the end goal in mind and maintain forward momentum.

## Model routing

The refusal-reason classification the loop reports on a stopped `/commit --auto`
is Haiku-eligible; phase sizing and the sabotage judgment are not. See
`docs/skill-automation.md`'s Model routing section for the full record and why.
