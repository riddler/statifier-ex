# Development workflow

How work moves through this repo: who plans, who implements, how work is tracked,
and how parallel work is coordinated.

## Model roles

Three tiers, used deliberately ([ADR-0007](adr/0007-beads-for-issue-tracking.md) for
the tracking side):

- **Fable - direction.** Architecture, ADRs, spec interpretation questions, corpus
  strategy, review of plans and of finished phases. When a decision would create or
  amend an ADR, it goes through Fable.
- **Opus - planning.** `/create-plan` and `/iterate-plan` run on Opus: turning a
  beads epic into a phased implementation plan with verification steps.
- **Sonnet - implementation.** `/implement-plan` runs on Sonnet: executing an
  approved plan, keeping `mix quality --profile loop` green while iterating, full
  `mix quality` before commit.

The skills encode these defaults in their frontmatter; an explicit user request
overrides them.

## Issue tracking: beads

All task tracking is `bd` (beads). No markdown TODO lists, no GitHub issues for
working items (GitHub issues become the public intake channel only once the project
is published).

- `bd ready` - find unblocked work; `bd show <id>` before starting.
- Epics mirror the roadmap phases; issues link with dependencies so `bd ready`
  reflects the real build order (parser before interpreter features, etc.).
- Discovered work (a bug found mid-task, an upstream predicator seam) is captured
  with `bd q` immediately, linked with `discovered-from`, and not chased mid-task.
- Predicator/UXID upstream candidates get a `upstream` label so they can be swept
  into the other repos' trackers.

## Worktrees and parallel agents

Parallel implementation happens in git worktrees under the sibling folder
`../statifier_2-worktrees/` (same convention as other riddler projects):

    git worktree add ../statifier_2-worktrees/<issue-id>-<slug> -b <issue-id>-<slug>

Two skills automate the pickup-to-worktree path: `/next-issue` picks and claims
the next ready bead (presents choices by default; `--auto` lets an unattended
agent take the top item), then invokes `/new-worktree`, which creates the
worktree and warms its `deps/`, `_build/`, and dialyzer PLT from the main
checkout so the first quality run is fast.

Rules that make parallelism safe:

- **One issue, one worktree, one branch.** The worktree name carries the beads issue
  ID. Claim the issue (`bd update <id> --claim`) before creating the worktree.
- **Beads is the shared state.** The Dolt-backed DB is shared across worktrees, so
  claims, notes, and status changes are visible to every agent immediately. Use
  `bd note` for progress that another agent might need; use merge-slot gates
  (`bd merge-slot`) when several branches will land on the same files.
- **Parallelize across module boundaries, not within them.** Good splits: parser DOM
  vs corpus tooling; one interpreter function-family per plan phase; docs vs code.
  If two ready issues touch the same module, take them sequentially instead.
- **Every worktree runs the same gate.** `mix quality --profile loop` while
  iterating, full `mix quality` before the branch is pushed or merged.
- **Refresh the survivors when a branch lands.** A worktree is cut from
  `origin/main` and warmed from the main checkout at one moment in time; every
  merge after that leaves it behind. `/refresh-worktree` rebases the live
  worktrees onto the new `origin/main`, repairs `deps/` and the dialyzer PLT if
  `mix.lock` moved, and re-runs the loop profile. Run it after any merge, and
  without fail after one that touched `mix.lock`, `.quality.exs`, or
  `.credo.exs` - those move the gate itself, so an unrefreshed worktree goes red
  for reasons that have nothing to do with the work in it.
- **A rebase conflict is a process signal, not a chore.** It means two branches
  touched the same files, so the split was wrong. `/refresh-worktree` aborts and
  reports rather than resolving; resolve deliberately, one agent at a time,
  behind `bd merge-slot`.
- Merged worktrees are removed promptly (`git worktree remove`); the branch dies
  with the merge.

## Change flow

1. Issue exists in beads (epic -> issue, dependencies linked).
2. Plan (Opus) for anything non-trivial; plans live in `docs/plans/` and reference
   the issue ID.
3. Implement (Sonnet) in a worktree; ratchet additions (`mix test.baseline add`)
   ride in the same PR as the feature.
4. If the change is user-facing, write a changelog fragment
   (`changelog.d/<issue-id>.md`); see `changelog.d/README.md` for when one is
   needed. Most changes need none.
5. Full `mix quality` green (a change touching no Elixir code has no gate to run),
   then commit on the worktree branch (`/commit`, or `/commit --auto` to skip the
   approval prompt). An agent may take this step on its own - see the authority
   table in `CLAUDE.md`.
6. Push and open a PR against `main` when asked for it (`/merge-request`).
   Finishing the work is not itself a request to publish it, so this step and the
   merge keep a human gate.
7. `bd close` once the branch is merged into `origin/main`, not at commit or at
   PR-open time; `bd dolt push` follows, after the git side has reached `origin`.
8. Remove the merged worktree and let the branch die with the merge.
9. Decisions that surfaced during the work become ADR amendments (Fable).

## Versioning and the changelog

`mix.exs` holds `2.0.0-dev` for the whole rewrite. Nothing is published until
2.0.0 is complete - no alpha, beta, or release-candidate versions along the way,
because there is no audience for a pre-release of an engine that cannot yet run
a statechart. Progress is tracked by beads phases and by the regression ratchet,
which are better signals than a version number.

`CHANGELOG.md` carries v1's `0.1.0`-`1.9.0` history (same package continuing to
2.0.0, so upgraders keep one continuous record) under a single `[Unreleased]`
section that accumulates until release. Entries are never written into it
directly during development: each issue drops a fragment in `changelog.d/`,
which keeps concurrent worktrees from conflicting on the same block of the same
file, and release assembles them.

Because 2.0.0 replaces the entire engine, its eventual entry is written as a
migration document for 1.x users, not as a transcript of the rewrite. During the
rewrite a fragment is warranted only where v2 **differs** from v1.
