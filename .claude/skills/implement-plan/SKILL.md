---
name: implement-plan
description: Implement technical plans from docs/plans with verification
model: sonnet
argument-hint: ["path to plan file"]
---

# Implement Plan

You are tasked with implementing an approved technical plan from `docs/plans/`. These plans contain phases with specific changes and success criteria.

Implementation runs on the Sonnet tier per docs/workflow.md (planning runs on Opus via /create-plan and /iterate-plan).

## Before You Start: Claim the Issue and Pick a Worktree

- The plan references a beads issue ID. Claim it before touching code:

  ```bash
  bd update <id> --claim
  ```

- **When working in parallel with other agents**, do the work in a git worktree
  under `../statecharts_2-worktrees/` named `<beads-id>-<slug>` per ADR-0010:

  ```bash
  git worktree add ../statecharts_2-worktrees/<beads-id>-<slug> -b <beads-id>-<slug>
  ```

  One issue = one branch = one worktree. Run the same quality gates inside the
  worktree (`mix quality --profile loop` while iterating, full `mix quality`
  before the branch is pushed or merged). Use `bd note` for progress other agents
  might need.

- Working solo directly in the repo is fine; the claim still happens first.

## Getting Started

When given a plan path:

- Read the plan completely and check for any existing checkmarks (- [x])
- Read the beads issue (`bd show <id>`) and all files mentioned in the plan
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
- Keep `mix quality --profile loop` green between edits; run `mix format` after
  writing any Elixir file

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

- Run the success criteria checks: `mix quality --profile loop` while iterating,
  then the full `mix quality` gate for the phase (this is also the pre-commit
  bar). Use `mix quality --format json --report -` if you need to route on the
  results programmatically.
- Fix any issues before proceeding
- Update your progress in both the plan and your todos
- Check off completed items in the plan file itself using Edit
- **Pause for human verification**: After completing all automated verification for a phase, pause and inform the human that the phase is ready for manual testing. Use this format:

  ```
  Phase [N] Complete - Ready for Manual Verification

  Automated verification passed:
  - [List automated checks that passed]

  Please perform the manual verification steps listed in the plan:
  - [List manual verification items from the plan]

  Let me know when manual testing is complete so I can proceed to Phase [N+1].
  ```

If instructed to execute multiple phases consecutively, skip the pause until the last phase. Otherwise, assume you are just doing one phase.

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
  status; close the issue (`bd close <id>`) per the active agent profile in
  CLAUDE.md
- Capture discovered work immediately with `bd q` and link it with
  `discovered-from` rather than chasing it mid-task
- If working in a worktree, leave commit/push/merge decisions to the user unless
  explicitly instructed otherwise

## Resuming Work

If the plan has existing checkmarks:

- Trust that completed work is done
- Pick up from the first unchecked item
- Verify previous work only if something seems off

Remember: You're implementing a solution, not just checking boxes. Keep the end goal in mind and maintain forward momentum.
