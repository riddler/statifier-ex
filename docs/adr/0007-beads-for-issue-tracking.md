# ADR-0007: Beads for issue tracking

Status: accepted (2026-08-02)

## Context

Work needs a tracker that survives this repo's unusual lifecycle (statifier-ex
will eventually replace the statifier GitHub project, possibly via force-push or
repo recreation), works for multiple AI agents in parallel worktrees, and supports
dependency ordering across a long phased roadmap. GitHub issues are tied to the
hosted repo (they would not survive recreation), have no first-class dependencies,
and are slow for agents to query. Beads (`bd`) is git-synced, local-first, has
first-class dependency links, and its shared DB is visible across worktrees.

## Decision

All working items are tracked in beads: epics mirror roadmap phases, issues carry
dependency links so `bd ready` reflects real build order, discovered work is
captured with `bd q` and `discovered-from` links. Upstream candidates for
predicator/uxid carry an `upstream` label. GitHub issues are reserved for public
intake after the project is published; anything actionable gets mirrored into
beads. Conventions live in `docs/workflow.md`.

## Consequences

- The tracker travels with the git repo through rename/recreation.
- Parallel agents coordinate through claims, notes, and merge-slot gates instead
  of colliding.
- One more tool in the loop (`bd` CLI, its sync ref on the remote); contributors
  without beads see only `.beads/issues.jsonl`.
- A public-vs-working tracker split to manage once published.
