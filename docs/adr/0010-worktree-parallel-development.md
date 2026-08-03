# ADR-0010: Parallel development via worktrees, coordinated through beads

Status: accepted (2026-08-02)

## Context

Multiple AI agents (and the maintainer) will work concurrently. In-place parallel
edits to one checkout collide; long-lived feature branches drift. Git worktrees
give each work stream an isolated checkout of the same repo, and the sibling
`-worktrees` folder convention is already used by other riddler projects. Beads'
Dolt-backed DB is shared across worktrees of a repo, making it a natural
coordination bus (ADR-0007).

## Decision

Parallel work happens in worktrees under `../statifier_2-worktrees/`, one issue
per worktree per branch, named `<beads-id>-<slug>`. An agent claims the beads issue
before creating the worktree, posts progress via `bd note`, and uses merge-slot
gates when branches will touch the same files. Work is split along module
boundaries (parser vs corpus vs docs vs distinct interpreter areas); two ready
issues in the same module are taken sequentially. Every worktree runs the same
quality gate (ADR-0009) before pushing. Worktrees are removed at merge, by
`/cleanup-worktrees`, which detects the merge from GitHub PR state rather than
git ancestry - the repo allows rebase merging only, so a merged branch is never
an ancestor of `main` (see docs/workflow.md, "Merge policy: rebase only").

## Consequences

- N agents can run without stepping on each other's build artifacts or edits.
- The beads claim is the lock; the worktree is just the workspace.
- Merge order for overlapping work is explicit (gates) instead of accidental.
- Discipline required: stale worktrees and unclaimed work are process bugs.
