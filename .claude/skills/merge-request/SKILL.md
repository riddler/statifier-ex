---
name: merge-request
description: Run the full gate, push the worktree branch, open a PR against main, and record it on the bead
model: sonnet
argument-hint: ["optional: beads issue ID; omit to detect from the commits' Refs: trailers"]
---

# Merge Request

Take a finished worktree branch from local commits to an open pull request.

This is where the confirmation removed from `/commit --auto` (st-qww.2) went.
A commit on a per-issue branch is private and undone with
`git reset --soft HEAD~1`; a push and a PR are visible to other people and
other machines, enter review queues, and send notifications. CLAUDE.md's
authority table puts the human gate here for exactly that reason, so this skill
confirms before pushing even when everything else it checks is green.

The bead is **not** closed here. It stays `in_progress` until the branch merges
into `origin/main` (st-qww.4). A PR is a request, not an outcome.

## Input

`$ARGUMENTS` = optional beads issue ID. Omitted, the beads come from the `Refs:`
trailers on the branch's own commits, falling back to the branch prefix (step 2).

## What to run

1. **Establish where you are.**
   ```bash
   ruby .claude/scripts/repo_state.rb
   ```
   STOP if `data.is_main` - this skill operates on per-issue worktree branches
   only. STOP if `data.dirty` - an uncommitted change is either part of this
   work and belongs in a commit, or is unrelated and belongs somewhere else.
   Do not stage it here.

   Confirm there is something to push:
   ```bash
   git log origin/main..HEAD --oneline
   ```
   Empty means nothing to open a PR for. Say so and stop. (`repo_state.rb`'s
   own `unpushed`/`commits_ahead` are relative to the branch's upstream, not
   `origin/main`, so this one check stays hand-run.)

2. **Resolve the beads.** From `$ARGUMENTS` if given. Otherwise read
   `data.refs_beads` from step 1's `repo_state.rb` output - the same anchored
   `Refs:` extraction (`lib/refs.rb`) that `/cleanup-worktrees` closes on via
   `pr_state.rb beads`, so the PR body and the eventual closes agree.

   `data.refs_beads` is computed over commits not yet on the branch's upstream.
   **If `data.upstream` is `null`** (the branch has never been pushed - the
   first `/merge-request` run for it) or `refs_beads` comes back empty, fall
   back to `data.branch_bead.id`. The prefix is a creation-time label and names
   at most one bead (ADR-0010), so a branch carrying several would otherwise
   reach the PR body naming only the first - this is the same limitation the
   original hand-written fallback carried, now triggered by the same
   condition.

   Validate each with `bd show <id>`. STOP if none resolves. A PR that cannot be
   traced to a bead is work nobody can find later, and the `bd note` in step 8
   has nowhere to go.

3. **Fetch and rebase onto `origin/main`.** The gate in step 4 only means
   something if it attests to the tree that will actually merge, not to branch
   + stale main. Rebase has to happen here, before the gate - rebasing between
   the confirmation in step 6 and the push in step 7 would invalidate the very
   attestation the gate exists to produce, which is the bug this step exists to
   close wearing a different hat.
   ```bash
   git fetch origin
   ruby .claude/scripts/rebase_onto.rb .
   ```
   `rebase_onto.rb` is the same shared rebase-with-repair block
   `/refresh-worktree` step 3d/3e uses (`RebaseOnto.perform`, not a prose
   cross-reference): it checks whether `origin/main` has moved before touching
   anything, rebases, repairs `mix.lock` drift (`mix deps.get`, then a
   best-effort PLT copy from the main checkout) only when the lockfile moved,
   and never re-clones `deps/` or `_build/` wholesale.

   Read `data.status`:
   - `"rebased"` - `data.target` (the `origin/main` sha rebased onto),
     `data.lock_changed`, `data.repaired` feed step 6's confirmation.
   - **`"conflict"`** (`blocked` code `rebase_conflict`, `needs: "human"`) -
     `data.files` (or the `blocked` message) names the conflicting files.
     **The script has already captured the files and aborted the rebase** -
     capture-then-abort is baked into `rebase_onto.rb` itself, the same order
     `/refresh-worktree` step 3d uses, since the abort clears the conflict
     state a report assembled afterward would otherwise have nothing left to
     name. Report the conflicting files and stop. Do not fall through to the
     gate or the push with the branch left un-rebased - **an aborted rebase
     ends this run.** There is no resolve path here or in the script: CLAUDE.md's
     authority table is explicit that resolving a rebase conflict unasked is
     unauthorized.

   **On the no-op case** (nothing to replay): `rebase_onto.rb` still ran; step
   4's gate still runs regardless. What the no-op case skips is the expensive
   parts (the rebase, the build repair), not the gate - `mix gate.verify`
   attests to *this* tree, and the simplest way to know the tree has not
   drifted since `/commit` last ran it is to ask again rather than track how
   long ago it was green and whether anything else touched the tree since.
   That bookkeeping would cost more reasoning than the redundant gate run
   costs seconds. One code path - the gate always runs at step 4 - beats two.

4. **Run the full gate.**
   ```bash
   ruby .claude/scripts/gate.rb
   ```
   Wraps `mix gate.verify` and `mix quality --format json --report -`. Never
   truncate `data.stages` or `data.attestation_message`. **Refuse on red** -
   `ok: false` means either `data.status != "ok"` or a stage came back
   skipped (`data.skipped_stages`); report the failing stages with their
   `file:line` findings and stop. Do not push a branch whose gate is red in
   the hope that CI disagrees.

   A narrowed run does not count - this script accepts no `--skip`, `--quick`,
   or narrowing `--profile`; passing one is a usage error, not a narrower run.
   `data.attested` mirrors `mix gate.verify`'s own attestation.

   **Carve-out**, matching `/commit` Step 0: `data.applicable` false means the
   diff touches nothing under `lib/`, `test/`, `config/`, `mix.exs`, or
   `mix.lock` - there is no gate to run. `data.carve_out_reason` explains why.
   Skip it and say so in the PR body and the final report, so a skipped gate
   is never mistaken for a green one.

   Then run the ADR judge - no script wraps this, since it makes real `claude`
   CLI calls and costs money and a network round trip, which is why it is
   disabled in the `gate.rb`/`mix gate.verify` run above and lives in its own
   profile instead:
   ```bash
   mix quality --profile merge
   ```
   It skips cleanly (no `claude` CLI on `PATH`, no `lib/statifier/` changes, no
   base ref) when it has nothing to check; a skip is fine to push through. A
   finding is not - refuse on one exactly as on a red gate, report it, and
   stop.

5. **Check for a changelog fragment.** Only when `data.touches_elixir` (from
   step 1's `repo_state.rb`) is true and the diff touches public API under
   `lib/`:
   ```bash
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

6. **Confirm before pushing.** Show the user what is about to become public,
   including what step 3 found on `origin/main`:

   ```
   Ready to open a PR for st-xxx - "<issue title>"

   Branch:    st-xxx-slug -> main
   Rebased:   origin/main was already current, no commits replayed
              (or: onto <sha>, N commits replayed)
   Commits:   3
   Gate:      full mix quality green   (or: docs only, no gate applicable)
   Changelog: changelog.d/st-xxx.md   (or: not needed - internal tooling)

   <proposed PR title>

   Push and open the PR?
   ```

   Wait for an answer. This is the one confirmation this skill does not skip,
   and there is no `--auto` for it.

7. **Push, then open the PR.** No script touches these - `.claude/scripts/`'s
   own contract bans a `git push` or `gh pr create` code path anywhere under
   it (`.claude/scripts/README.md`'s "Step-scoping" section), so this stays a
   hand-run command:
   ```bash
   git push -u origin <branch>
   ```
   If the branch had already been pushed before step 3 ran - the common case,
   since a worktree usually gets at least one push before its PR is ready - the
   rebase in step 3 rewrote commits the remote already has, and the remote
   counterpart has diverged. Same if `/refresh-worktree` rebased it independently
   between pushes. Either way the push needs `--force-with-lease` - never a bare
   `--force`, which discards commits pushed from elsewhere without telling you:
   ```bash
   git push --force-with-lease
   ```
   A branch that was rebased in step 3 but never pushed before (the first push
   for this branch) needs neither flag - there is nothing on the remote yet to
   diverge from.

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
   - The bead references: `Closes st-xxx` for **every** bead the branch's
     trailers name, one per line (and the epic, if they share one)

   No AI attribution in the title or the body, same rule as commit messages
   (CLAUDE.md, and the override in `/commit`).

8. **Sync beads, then record the PR.** Also hand-run - `bd close` is on the
   same banned-operation list, and this step never closes anything, but
   `bd dolt push`/`bd note` are ordinary bead commands no script wraps:
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

9. **Report.**
   ```
   PR opened: <url>
   Branch:    st-xxx-slug -> main (3 commits)
   Gate:      full mix quality green
   Bead:      st-xxx in_progress, PR URL recorded, dolt pushed
   Next:      merge is a human decision; the bead closes on merge, not here
   ```

## Guidelines

- **The repo allows rebase merging only.** Do not offer or perform a squash
  merge, and do not restructure the branch's commits on the assumption they will
  be squashed. Rebase replays each commit onto `main` with its message intact,
  which is why `/commit --auto` producing several commits on a branch is fine
  and needs no cleanup pass. It also means the branch tip never becomes an
  ancestor of `main`, so merge detection anywhere downstream must use `gh` PR
  state rather than git ancestry (st-qww.5) - which is exactly why `pr_state.rb`
  exists (see `/cleanup-worktrees`).
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
- See `.claude/scripts/README.md` for the envelope contract shared by every
  script this skill calls.
