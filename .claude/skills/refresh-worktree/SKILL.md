---
name: refresh-worktree
description: Rebase live worktrees onto the latest origin/main after a branch lands, repair their build caches if mix.lock moved, and confirm each is green again
model: sonnet
argument-hint: ["optional: one worktree/branch name, e.g. st-uot-refresh-worktree; omit to sweep all"]
---

# Refresh Worktree

Bring live worktrees back in line with `origin/main` after a sibling branch
lands. `/new-worktree` cuts a branch off `origin/main` and clones `deps/` and
`_build/` from the main checkout; both are point-in-time. Once another branch
merges, every other worktree is behind, and if the landed change moved
`mix.lock` their cloned `_build` and dialyzer PLT are stale as well.

That staleness is the failure mode this skill exists to prevent: a worktree that
was green when created goes red for reasons that have nothing to do with the
work inside it, and the agent working there starts debugging its own change.

Pairs with the merge-time cleanup in `/cleanup-worktrees` - same moment,
opposite direction: that one removes the worktree of the branch that just
landed, this one refreshes the survivors.

## Input

`$ARGUMENTS` = optional. One worktree or branch name refreshes just that
worktree. No argument sweeps every live worktree under
`../statifier-ex-worktrees/`. The main checkout is never a target - it is not a
feature branch and is not rebased.

## What to run

```bash
.claude/scripts/worktree_refresh.rb [name]
```

This is the whole sweep: enumerate live worktrees (dropping the main
checkout), fetch `origin` once, then per worktree - skip if `origin/main` is
already an ancestor, refuse if dirty, rebase onto `origin/main` (capturing
conflicting files before aborting), repair the build only if `mix.lock` moved,
and confirm green with `mix quality --profile loop`. Run it for real; do not
`--dry-run` a refresh you intend to act on, since the report needs the actual
rebase and gate outcome, not a preview.

## How to read the result

- `blocked` `no_matching_worktree` - the given name/branch matched nothing
  live. STOP and report what is live instead.
- `blocked` `offline` (`git fetch origin` failed) - STOP entirely. Refreshing
  against a stale `origin/main` would rebase worktrees onto the commit they
  are already on and report success for nothing. This is a hard stop, not a
  per-worktree skip.
- `data.results` is empty and `ok: true` - no live worktrees. That is a normal
  outcome, not an error; say so and stop.
- Otherwise `data.results` is one entry per worktree, each already carrying the
  skill's own result vocabulary in `result`:
  - `"current, skipped"` - nothing to do, build untouched.
  - `"dirty, skipped"` - uncommitted work; the script never stashed, committed,
    or discarded it.
  - `"conflict in <files>, aborted, unchanged"` - the rebase was captured and
    aborted; the worktree is exactly as it was.
  - `"red"` - rebase and any lock repair succeeded, but `mix quality --profile
    loop` came back red.
  - `"rebased onto <sha>, lock unchanged, loop green"` or `"..., lock
    repaired, loop green"` - the success case.
- `data.origin_main` is what `origin/main` moved to; include it in the report
  header.

## Report

One line per worktree, using `data.results[].result` verbatim, plus what
`origin/main` moved to:

| Worktree | Result |
|---|---|
| `st-00p.3-regression-ratchet` | rebased onto 146c69f, lock unchanged, loop green |
| `st-00p.4-corpus-layout` | current, skipped |
| `st-qww.1-team-maintainer` | **conflict** in `docs/workflow.md`, aborted, unchanged |
| `st-vbu-strict-credo` | dirty, skipped |

End with the ones needing a human: conflicts, dirty worktrees, red gates.
**Silence about a skipped worktree reads as success** - name every one.

## Judgment

- **The staleness failure mode is why this skill exists**: a worktree that was
  green when created going red for reasons that have nothing to do with the
  work inside it, sending the agent there down a debugging path that is not
  theirs to walk.
- **The main checkout is never a target.** It is not a feature branch and is
  not rebased.
- **Offline is a hard stop**, not a per-worktree skip - see above.
- **Never stash, commit, or discard on the author's behalf.** Uncommitted work
  belongs to whoever is in that worktree, and a surprise stash during an
  unattended sweep is how it gets lost.
- **A rebase conflict is signal for a human, not something to paper over
  mid-sweep.** It means two branches touched the same files, which means the
  `area:` labels were wrong or the batch was picked badly. Aborting leaves the
  worktree exactly as it was; `bd merge-slot` is the coordination primitive for
  resolving it deliberately, one agent at a time. Name the conflicting files in
  the report.
- **A red gate is a real result, not a failure of the refresh.** The rebase
  was clean but the combination is not, which is exactly what the refresh is
  meant to surface early. Keep the worktree as-is - the agent working there
  needs to see it.
- **Silence about a skipped worktree reads as success.** Every worktree gets a
  reported line, always.
- **Rebase, never merge.** The repo allows rebase merging only, so keeping
  branches linear against `main` matches how they will land and avoids a merge
  commit the PR cannot use.
- **Nothing here is pushed.** Rebasing a branch rewrites its commits; if it has
  already been pushed, its remote counterpart now diverges and the eventual
  push needs `--force-with-lease`. That is `/merge-request`'s decision to make,
  not this skill's.
- **When to run:** after any branch merges into `origin/main`, and always after
  a change that moved `mix.lock`, `.quality.exs`, or `.credo.exs` - those move
  the gate every other worktree is measured against. Whatever closes the loop
  on a merge should invoke this so "a branch landed" and "everyone else is
  current" are one event.
- A sweep is safe to re-run: current worktrees are skipped, and the fast path
  costs a `merge-base` check.
