---
name: cleanup-worktrees
description: Remove worktrees and local branches whose PRs have merged, using GitHub PR state rather than git ancestry
model: sonnet
argument-hint: ["optional: one worktree/branch name; omit to sweep all"]
---

# Cleanup Worktrees

Remove the worktrees and local branches left behind by merged work. ADR-0010
says worktrees are removed at merge; nothing automated that, so they accumulate
until someone notices.

## Why detection must not use git ancestry

**This repo is configured to allow rebase merging only.** Rebase replays a
branch's commits onto `main` as new SHAs, so **the branch tip never becomes an
ancestor of `main`**. Two consequences, and both are traps:

1. `git branch --merged origin/main` never lists a merged feature branch. A
   cleanup built on it silently no-ops forever while looking like it works -
   the worst kind of broken, because nothing ever reports a problem. Verified
   on PRs #2, #3 and #6: `main` carried `b5e9104`, `873aa20` and `96dda3e`
   while the branch tips were `53b5ede`, `638f29c` and `62f9875`, and
   `--merged` listed only `main`.

2. `git branch -d` refuses for the same reason, so deletion needs `-D`. That
   makes the PR-state check **load-bearing for safety, not just detection**:
   `-D` on an unmerged branch discards commits with no recovery path short of
   the reflog. Never force-delete a branch without a confirmed `MERGED` state
   from `gh`.

So: ask GitHub, never git.

```bash
gh pr list --state merged --head <branch> --json number,mergedAt
gh pr view <branch> --json state,mergedAt
```

## Input

`$ARGUMENTS` = optional worktree or branch name to clean just that one. Omitted,
sweep every worktree under `../statifier_2-worktrees/`.

## Steps

1. **Enumerate worktrees.**
   ```bash
   git worktree list --porcelain
   ```
   Parse into `(path, branch)` pairs and **drop the main checkout**
   (`/Users/johnnyt/repos/github/statifier_2`). Removing it would take the
   repository with it.

   No worktrees is a normal outcome. Say so and stop.

2. **Per worktree, ask GitHub whether its branch merged.**
   ```bash
   gh pr list --state merged --head <branch> --json number,mergedAt,headRefOid --jq '.[0]'
   ```
   - **A merged PR** -> eligible for cleanup. Carry the PR number **and
     `headRefOid`** forward: that SHA is the branch tip GitHub actually merged,
     and step 3 needs it.
   - **No PR, or a PR that is open or closed-unmerged** -> leave everything
     alone and record why. An open PR means work in review; a closed-unmerged
     one means work someone abandoned but did not delete, which is theirs to
     decide about, not this skill's.
   - **`gh` fails or is unauthenticated** -> STOP the whole sweep. Without PR
     state there is no safe signal, and falling back to ancestry would delete
     nothing (case 1) or the wrong thing. Report the error.

3. **Refuse if the worktree is dirty.**
   ```bash
   git -C <path> status --porcelain
   ```
   Any output means uncommitted work. Report it as `dirty, skipped` and move on.
   **Never pass `--force` to `git worktree remove`** - it discards those changes.
   `git worktree remove` already refuses on a dirty tree; that refusal is a
   feature, so do not route around it.

   Also check for commits made after the push, by comparing the local tip to
   the SHA GitHub merged (`headRefOid` from step 2):
   ```bash
   git -C <path> rev-parse HEAD
   ```
   Equal means nothing was committed after the push and the worktree is safe to
   remove. Different means someone committed on top after the merge; those
   commits are on no remote and nowhere in `main`, so skip the worktree and
   report the SHAs.

   **Do not use `git log @{upstream}..HEAD` for this.** The upstream ref is
   gone precisely when this skill runs: GitHub deletes the remote branch on
   merge, so `@{upstream}` does not resolve and the command exits with
   `fatal: ambiguous argument`, not empty output. Read literally, that fatal
   looks like unpushed commits and skips **every** merged worktree - the same
   silent no-op this skill exists to prevent, arriving by a different route.
   Observed live cleaning up PRs #8 and #9.

   `git log origin/main..HEAD` is not a substitute either: rebase merging
   replays commits under new SHAs, so it reports commits for every merged
   branch. `headRefOid` is the only local-vs-merged comparison that holds here.

4. **Remove, in this order.** Order matters: the branch cannot be deleted while
   a worktree has it checked out.
   ```bash
   git worktree remove <path>
   git worktree prune
   git branch -D <branch>
   ```
   `-D` is correct here and only here - step 2 confirmed the merge, so the
   commits are on `main` under different SHAs.

5. **Prune remote-tracking refs once**, after the loop:
   ```bash
   git fetch --prune
   ```
   Remote branches are usually already gone: GitHub deletes them on merge.
   Cleanup here is purely local, which is the whole reason it needs automating -
   nothing else was ever going to do it.

6. **Report** one line per worktree:

   | Worktree | Result |
   |---|---|
   | `st2-qww.1-team-maintainer-optin` | merged in PR #6, removed, branch deleted |
   | `st2-00p.3-regression-ratchet` | open PR #9, kept |
   | `st2-vbu-strict-credo` | no PR, kept |
   | `st2-92f-area-labels` | dirty, skipped |

   **Nothing to clean is a success, and must say so explicitly** - "no merged
   worktrees found, 3 live worktrees kept" rather than silence. A silent sweep
   is indistinguishable from the ancestry bug this skill exists to avoid.

## Guidelines

- **PR state or nothing.** If `gh` cannot answer, stop. Do not substitute
  `git branch --merged`, `git merge-base --is-ancestor`, or a commit-message
  comparison; under rebase merging none of them are sound.
- **Never `--force` a worktree removal, never `-D` an unmerged branch.** Both
  destroy work that exists nowhere else. Every skip is reported so a human can
  deal with it.
- Pairs with `/refresh-worktree`: same moment, opposite direction. That one
  rebases the survivors onto the new `origin/main`; this one removes the
  worktree of the branch that just landed. Run this first - refreshing a
  worktree that is about to be deleted is wasted work.
- Shares its merge-detection step with the bead close-on-merge trigger
  (st2-qww.4). Both answer "did this branch land", and both must answer it the
  same way.
- Safe to re-run: worktrees with no merged PR are kept, and a clean sweep is a
  no-op.
