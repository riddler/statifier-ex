---
name: merge-request
description: Run the full gate, push the worktree branch, open a PR against main, and record it on the bead
model: sonnet
argument-hint: ["optional: beads issue ID; omit to detect from the commits' Refs: trailers"]
---

# Merge Request

Take a finished worktree branch from local commits to an open pull request.

This is where the confirmation removed from `/commit --auto` (st2-qww.2) went.
A commit on a per-issue branch is private and undone with
`git reset --soft HEAD~1`; a push and a PR are visible to other people and
other machines, enter review queues, and send notifications. CLAUDE.md's
authority table puts the human gate here for exactly that reason, so this skill
confirms before pushing even when everything else it checks is green.

The bead is **not** closed here. It stays `in_progress` until the branch merges
into `origin/main` (st2-qww.4). A PR is a request, not an outcome.

## Input

`$ARGUMENTS` = optional beads issue ID. Omitted, the beads come from the `Refs:`
trailers on the branch's own commits, falling back to the branch prefix (step 2).

## Steps

1. **Establish where you are.**
   ```bash
   git branch --show-current
   git status --porcelain
   ```
   STOP if the branch is `main` - this skill operates on per-issue worktree
   branches only. STOP if the tree is dirty: an uncommitted change is either
   part of this work and belongs in a commit, or is unrelated and belongs
   somewhere else. Do not stage it here.

   Confirm there is something to push:
   ```bash
   git log origin/main..HEAD --oneline
   ```
   Empty means nothing to open a PR for. Say so and stop.

2. **Resolve the beads.** From `$ARGUMENTS` if given. Otherwise read the
   trailers the branch's own commits carry - the same anchored match
   `/cleanup-worktrees` closes on, so the PR body and the eventual closes agree:
   ```bash
   git log origin/main..HEAD --pretty=%B \
     | grep -E '^Refs:' \
     | grep -oE 'st2-[a-z0-9]+(\.[0-9]+)?' | sort -u
   ```
   Fall back to the branch prefix only when that finds nothing (a branch whose
   commits predate the `Refs:` convention). The prefix is a creation-time label
   and names at most one bead (ADR-0010), so a branch carrying several would
   otherwise reach the PR body naming only the first.

   Validate each with `bd show <id>`. STOP if none resolves. A PR that cannot be
   traced to a bead is work nobody can find later, and the `bd note` in step 7
   has nowhere to go.

3. **Run the full gate.**
   ```bash
   mix gate.verify
   ```
   It runs `mix quality` and attests that the run was a full one. Never truncate
   the output. **Refuse on red** - report the failing stages with their
   `file:line` findings and stop. Do not push a branch whose gate is red in the
   hope that CI disagrees.

   A narrowed run does not count: `--quick`, `--profile loop`, and
   `--test-scope changed` all skip checks a reviewer will assume ran, and
   `mix gate.verify` exits non-zero rather than attesting to one.

   **Carve-out**, matching `/commit` Step 0: if the diff touches nothing under
   `lib/`, `test/`, `config/`, and neither `mix.exs` nor `mix.lock`, there is no
   gate to run. Skip it and say so in the PR body and the final report, so a
   skipped gate is never mistaken for a green one.

4. **Check for a changelog fragment.** Only when the diff touches public API
   under `lib/`:
   ```bash
   git diff origin/main...HEAD --name-only
   ls changelog.d/
   ```
   `changelog.d/README.md` is the authority and most changes need none - test
   harness, corpus tooling, docs, ADRs, internal refactors, and agent tooling
   are all exempt, and while v2 is unreleased a fragment is warranted only where
   v2 **differs** from v1. Re-implementing something v1 already did is invisible
   to a user.

   If it does need one and `changelog.d/<issue-id>.md` is absent, **ask the
   user** what it should say. Do not invent it: a changelog entry is a promise
   to users about observable behavior, and guessing at one produces a release
   note describing something the code may not do.

5. **Confirm before pushing.** Show the user what is about to become public:

   ```
   Ready to open a PR for st2-xxx - "<issue title>"

   Branch:    st2-xxx-slug -> main
   Commits:   3
   Gate:      full mix quality green   (or: docs only, no gate applicable)
   Changelog: changelog.d/st2-xxx.md   (or: not needed - internal tooling)

   <proposed PR title>

   Push and open the PR?
   ```

   Wait for an answer. This is the one confirmation this skill does not skip,
   and there is no `--auto` for it.

6. **Push, then open the PR.**
   ```bash
   git push -u origin <branch>
   ```
   If the branch was rebased after a previous push (`/refresh-worktree` rewrites
   commits), the remote counterpart has diverged and the push needs
   `--force-with-lease` - never a bare `--force`, which discards commits pushed
   from elsewhere without telling you:
   ```bash
   git push --force-with-lease
   ```

   Then:
   ```bash
   gh pr create --base main --title "<title>" --body "<body>"
   ```

   PR title matches the commit style: present tense, s-form, under 50
   characters. The body carries what a reviewer needs and the commits do not:

   - **Why** - the problem, in the bead's terms
   - **What** - the shape of the change, not a file list; the diff has that
   - **Notes** - anything surprising, deliberately deferred, or worth a second
     opinion, plus which gate ran
   - The bead references: `Closes st2-xxx` for **every** bead the branch's
     trailers name, one per line (and the epic, if they share one)

   No AI attribution in the title or the body, same rule as commit messages
   (CLAUDE.md, and the override in `/commit`).

7. **Sync beads, then record the PR.**
   ```bash
   bd dolt push
   bd note <id> "PR: <url>"
   ```
   Run the `bd note` once per bead step 2 resolved - a bead whose PR URL was
   never recorded is one nobody can follow from the issue to the review.

   `bd dolt push` is not optional and not a nicety. Issue state travels over
   `refs/dolt/data` on the same remote as the code; a PR whose bead was never
   pushed is invisible to every other machine, so a reviewer pulling the branch
   sees work with no issue behind it. The git side has just reached `origin`,
   which is exactly the trigger CLAUDE.md's authority table names for this.

   Leave the bead `in_progress`. Do not close it.

8. **Report.**
   ```
   PR opened: <url>
   Branch:    st2-xxx-slug -> main (3 commits)
   Gate:      full mix quality green
   Bead:      st2-xxx in_progress, PR URL recorded, dolt pushed
   Next:      merge is a human decision; the bead closes on merge, not here
   ```

## Guidelines

- **The repo allows rebase merging only.** Do not offer or perform a squash
  merge, and do not restructure the branch's commits on the assumption they will
  be squashed. Rebase replays each commit onto `main` with its message intact,
  which is why `/commit --auto` producing several commits on a branch is fine
  and needs no cleanup pass. It also means the branch tip never becomes an
  ancestor of `main`, so merge detection anywhere downstream must use `gh` PR
  state rather than git ancestry (st2-qww.5).
- **Never close the bead here.** `bd close` fires on merge into `origin/main`,
  verified against the remote. Closing at PR-open time asserts to every other
  machine that the work landed when it has not.
- **Confirmation is not a formality.** If the user declines, the branch stays
  local and nothing is lost. That asymmetry is the whole argument for putting
  the gate at this step rather than at commit.
- **One bead per branch is the default, not a law.** Several small beads that
  touch the same files belong on one branch as separate commits; splitting them
  across parallel worktrees manufactures exactly the rebase conflicts the module
  boundaries exist to avoid. Group them when they are the same work, split them
  when they are not.

  This is safe because `/cleanup-worktrees` closes beads from the `Refs:`
  trailers in the merged PR's commits, not from the branch name, so every bead a
  branch carries gets closed. Keep one bead per **commit** so those trailers stay
  unambiguous, and name every bead the PR closes in its body.
- After the merge, the survivors need `/refresh-worktree`, and this branch's
  worktree and beads are handled by `/cleanup-worktrees`.
