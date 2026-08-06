---
name: refresh-worktree
description: Rebase live worktrees onto the latest origin/main after a branch lands, repair their build caches if mix.lock moved, and confirm each is green again
model: sonnet
argument-hint: ["optional: one worktree/branch name, e.g. st2-uot-refresh-worktree; omit to sweep all"]
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

Pairs with the merge-time cleanup in st2-qww.5 - same moment, opposite
direction: that one removes the worktree of the branch that just landed, this
one refreshes the survivors.

## Input

`$ARGUMENTS` = optional. One worktree or branch name refreshes just that
worktree. No argument sweeps every live worktree under
`../statifier-ex-worktrees/`. The main checkout is never a target - it is not a
feature branch and is not rebased.

## Steps

1. **Enumerate targets.**
   ```bash
   git worktree list --porcelain
   ```
   Parse into `(path, branch)` pairs and drop the main checkout
   (`/Users/johnnyt/repos/github/statifier-ex`). With an argument, keep only the
   matching one; if it matches nothing, STOP and report what is live.

   No live worktrees is a normal outcome, not an error - say so and stop.

2. **Fetch once.**
   ```bash
   git fetch origin
   ```
   One fetch for the whole sweep. If it fails (offline), STOP - refreshing
   against a stale `origin/main` would rebase worktrees onto the very commit
   they are already on and report success for nothing.

   Record the target: `git rev-parse origin/main`.

3. **Per worktree, in order.** Each is independent; one failing does not stop
   the sweep. Report per worktree and continue.

   a. **Skip if already current.**
      ```bash
      git -C <path> merge-base --is-ancestor origin/main HEAD
      ```
      Exit 0 means `origin/main` is already in this branch's history - nothing
      to do. Record as `current` and move on without touching the build.

   b. **Refuse if dirty.**
      ```bash
      git -C <path> status --porcelain
      ```
      Any output means uncommitted work. STOP for this worktree and report it
      as `dirty, skipped`. **Never stash, commit, or discard on the author's
      behalf** - uncommitted work belongs to whoever is in that worktree, and a
      surprise stash during an unattended sweep is how it gets lost.

   c. **Record the pre-rebase tip** so the lockfile comparison in (e) has a
      base: `before=$(git -C <path> rev-parse HEAD)`.

   d. **Rebase onto origin/main.**
      ```bash
      git -C <path> rebase origin/main
      ```
      On conflict: **capture the conflicting files first, then abort.** The
      abort clears the conflict state, so a report assembled afterwards has
      nothing left to name:
      ```bash
      git -C <path> diff --name-only --diff-filter=U   # capture, then
      git -C <path> rebase --abort                     # abort
      ```
      A rebase conflict means two branches touched the same files, which means
      the `area:` labels were wrong or the batch was picked badly (st2-92f).
      That is signal for a human, not something to paper over mid-sweep;
      aborting leaves the worktree exactly as it was. Name the conflicting
      files in the report and mark it `conflict`. `bd merge-slot` is the
      coordination primitive for resolving it deliberately, one agent at a
      time.

   e. **Repair the build only if `mix.lock` moved.**
      ```bash
      git -C <path> diff --quiet $before HEAD -- mix.lock
      ```
      Exit 0 (unchanged) is the fast path: no `deps.get`, no PLT work, straight
      to (f). This is the common case and should stay cheap.

      Changed:
      ```bash
      cd <path> && mix deps.get
      ```
      Then the PLT. Dialyxir keys it on OTP/Elixir versions plus the dep set,
      so a lockfile change invalidates it. If the main checkout has already
      rebuilt its PLT for the new dep set, clone it rather than rebuilding
      here - the clone is a copy-on-write file operation against a multi-minute
      build:
      ```bash
      cp -c /Users/johnnyt/repos/github/statifier-ex/_build/dev/dialyxir_*.plt* \
            <path>/_build/dev/ 2>/dev/null || true
      ```
      If it is absent or also stale, note that the next full `mix quality` in
      that worktree will rebuild it, and move on. This step is an optimization;
      never fail a refresh on it.

      **Do not re-clone `deps/` and `_build/` wholesale.** That clone is a
      cold-start optimization for a worktree with no build state. A live
      worktree has its own incremental state, and clobbering it forces a full
      recompile - slower, not faster.

   f. **Confirm green.**
      ```bash
      cd <path> && mix quality --profile loop
      ```
      Never truncate the output. A failure here is a real result: the rebase
      was clean but the combination is not, which is exactly what the refresh
      is meant to surface early. Mark it `red` and keep the worktree as-is -
      the agent working there needs to see it.

4. **Report** one line per worktree, plus what `origin/main` moved to:

   | Worktree | Result |
   |---|---|
   | `st2-00p.3-regression-ratchet` | rebased onto 146c69f, lock unchanged, loop green |
   | `st2-00p.4-corpus-layout` | current, skipped |
   | `st2-qww.1-team-maintainer` | **conflict** in `docs/workflow.md`, aborted, unchanged |
   | `st2-vbu-strict-credo` | dirty, skipped |

   End with the ones needing a human: conflicts, dirty worktrees, red gates.
   Silence about a skipped worktree reads as success.

## Guidelines

- **Rebase, never merge.** The repo allows rebase merging only (st2-qww.5), so
  keeping branches linear against `main` matches how they will land and avoids
  a merge commit the PR cannot use.
- **Nothing here is pushed.** Rebasing a branch rewrites its commits; if it has
  already been pushed, its remote counterpart now diverges and the eventual
  push needs `--force-with-lease`. That is `/merge-request`'s decision to make
  (st2-qww.3), not this skill's.
- **When to run:** after any branch merges into `origin/main`, and always after
  a change that moved `mix.lock`, `.quality.exs`, or `.credo.exs` - those move
  the gate every other worktree is measured against. Once the merge path is
  automated (st2-qww.4), whatever closes the loop on a merge should invoke this
  so "a branch landed" and "everyone else is current" are one event.
- A sweep is safe to re-run: current worktrees are skipped, and the fast path
  costs a `merge-base` check.
