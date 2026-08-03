---
name: new-worktree
description: Create a per-issue worktree under ../statifier_2-worktrees/ with a new branch off main, warm it (deps, _build, dialyzer PLT) so the first quality run is fast, and open a tmux window there with a Claude session seeded on the bead
model: sonnet
argument-hint: ["branch/worktree name, e.g. st2-00p.3-regression-ratchet"]
---

# New Worktree

Stand up a fresh worktree for one beads issue, per ADR-0010: one issue, one
branch, one worktree under `../statifier_2-worktrees/`, named `<beads-id>-<slug>`.
Then warm the worktree's build caches by cloning `deps/` and `_build/` from this
checkout - that carries the compiled beams and the dialyxir PLT, so the first
`mix quality` there recompiles only the delta instead of rebuilding the world.

The beads issue should already be claimed (`bd update <id> --claim`) before the
worktree exists - the claim is the lock, the worktree is just the workspace.
`/next-issue` handles claim + naming and then invokes this skill.

## Input

`$ARGUMENTS` (or ask) = the branch name, which is also the worktree folder name:
`<beads-id>-<slug>`, e.g. `st2-00p.3-regression-ratchet`. Keep the slug to 2-4
distinctive kebab-case words from the issue title, not a full transcription. If
given only a bead id, ask for the slug - it matters and should not be guessed.

## Steps

1. **Guard.** From the main checkout (`/Users/johnnyt/repos/github/statifier_2`):
   - `git branch --list <name>` - if the branch already exists, STOP and report.
     Offer a different name or let the user delete the old one. Never force.
   - `ls ../statifier_2-worktrees/<name>` - same rule if the folder exists.
   - `git fetch origin` so the branch is cut from the latest `origin/main`
     (github.com/riddler/statifier_2), not a stale local copy. If the fetch
     fails (offline) or `origin/main` does not exist yet, fall back to local
     `main` and say so in the report.

2. **Create the worktree + branch.**
   ```bash
   mkdir -p ../statifier_2-worktrees
   git worktree add ../statifier_2-worktrees/<name> -b <name> --no-track origin/main
   ```
   (`--no-track` keeps the new branch push-safe; drop to `main` only in the
   offline/fallback case above.)

3. **Warm the caches.** Clone `deps/` and `_build/` from this checkout into the
   worktree. On APFS `cp -Rc` uses copy-on-write clonefiles, so this is nearly
   instant and costs almost no disk:
   ```bash
   cp -Rc deps _build ../statifier_2-worktrees/<name>/ 2>/dev/null \
     || cp -R deps _build ../statifier_2-worktrees/<name>/
   ```
   This carries:
   - compiled dep and app beams (incremental recompile only for changed files)
   - the dialyzer PLT: `_build/dev/dialyxir_erlang-*_elixir-*_deps-dev.plt` and
     its `.hash` - dialyxir keys the PLT on OTP/Elixir versions and the dep set,
     so a cloned PLT is picked up as-is and full `mix quality` skips the
     multi-minute PLT build.

   If `_build` here has no PLT yet (fresh clone), note it and suggest running
   `mix quality.plt` once - in either checkout, then re-clone or let the
   worktree build it.

4. **Verify the worktree is green.** In the worktree:
   ```bash
   cd ../statifier_2-worktrees/<name>
   mix deps.get        # no-op unless mix.lock changed since the clone
   mix quality --profile loop
   ```
   A warm worktree should pass this in seconds. Never truncate the output.

5. **Open a tmux window for the worktree.** Reporting a path and leaving the
   user to `cd` there by hand is the step that makes fan-out feel expensive,
   and the step most likely to be done wrong: a session started in the main
   checkout instead of the worktree silently edits the wrong tree.

   **This step is optional and never fatal.** If `tmux` is not installed, or
   `$TMUX` is unset and no server is running, skip it with a note and go to the
   report. The worktree is the deliverable; the window is convenience. Never
   fail worktree creation because the window could not be made.

   Windows live in the existing per-project session (`statifier_2`), matching
   the convention already in use - one session per project, windows within it.
   Do not create a session per worktree.

   ```bash
   # exact-match target (=): a sibling session named statifier exists for v1.
   # ALWAYS quote a '=' target - fish and zsh expand a leading = as a command
   # path (equals-expansion), so bare -t =statifier_2: dies with
   # "statifier_2: not found" before tmux ever sees it. Verified 2026-08-02.
   tmux has-session -t '=statifier_2' 2>/dev/null \
     || tmux new-session -d -s statifier_2 -c /Users/johnnyt/repos/github/statifier_2
   ```

   **Guard on the window name** before creating anything, the same way steps 1
   and 2 refuse an existing branch or worktree directory. Two windows with the
   same name in one session is exactly the state where the wrong one gets typed
   into:
   ```bash
   tmux list-windows -t '=statifier_2' -F '#{window_name}' | grep -Fxq '<name>'
   ```
   A hit means the window already exists - report it and skip the rest of this
   step. Do not create a second one.

   ```bash
   win=$(tmux new-window -d -P -F '#{window_id}' \
     -t '=statifier_2:' \
     -n '<name>' \
     -c "/Users/johnnyt/repos/github/statifier_2-worktrees/<name>")
   [ -n "$win" ] || { echo 'tmux window not created, skipping'; exit 0; }
   tmux send-keys -t "$win" \
     "claude --permission-mode auto 'Work bead <id> in this worktree. Start with bd show <id>.'" Enter
   ```

   **Check `$win` is non-empty before any command that targets it, and never
   chain a follow-up with `;`.** An empty `-t ""` does not error - tmux resolves
   it to the *current* window, so `kill-window` or `send-keys` lands on whatever
   the user is sitting in. A `;` after a failed `new-window` is enough to do it:
   this cost a live window during development of this step (2026-08-02).

   `<id>` is the bead id at the front of the branch name (`st2-lzn` from
   `st2-lzn-tmux-window-per-worktree`, `st2-00p.3` from
   `st2-00p.3-regression-ratchet`).

   Two details are load-bearing:

   - **Capture the window id (`-P -F '#{window_id}'`, giving `@42`) and target
     that for every follow-up command.** It is stable under
     `renumber-windows on` (which renumbers every window whenever one is
     closed), unambiguous against a session or window whose name shares a
     prefix, and it sidesteps `session:window.pane` parsing entirely for the
     dotted bead ids this repo uses (`st2-00p.3-...`).

     Note: tmux 3.6b does in fact resolve
     `statifier_2:st2-00p.3-regression-ratchet` to the right window - the
     dotted name is not ambiguous in practice, tested 2026-08-02. Window id is
     still what to use, but for renumbering stability, not because name
     targeting is broken.
   - **`-d` on `new-window`** so creating three worktrees in a row does not yank
     focus three times. The user jumps to the one they want when they are ready.

   The seeded prompt points at `bd show` rather than restating the bead: the
   beads DB is shared across worktrees, so the new session reads it directly,
   and a restated description goes stale.

   `--permission-mode auto` starts the seeded session in auto mode, so it makes
   routine calls without stopping to confirm each one - the point of fanning
   worktrees out is not to then babysit four sessions. It is `auto`, not
   `bypassPermissions`: the permission system still applies, and this repo's
   authority table (CLAUDE.md) still gates push, PR, and `bd close` on an
   explicit human ask.

6. **Report.** State the worktree path, the branch and what it was cut from,
   that caches were cloned (and whether the PLT came along), the quality
   result, and **the tmux window** (its name and id, or why it was skipped) so
   the user can jump to it with the prefix key. Remind that subsequent work on
   this issue happens **inside the worktree**, and the worktree is removed at
   merge (`git worktree remove ../statifier_2-worktrees/<name>`).

## Notes

- Worktree-local and push-safe: no upstream is set, nothing is pushed.
- `deps/` and `_build/` are gitignored; the clones never show up in `git status`.
- If OTP/Elixir versions differ from when the PLT was built, dialyxir rebuilds
  it automatically - the clone is a best-effort warm, never a correctness risk.
- The beads DB is shared across worktrees (Dolt-backed), so `bd` commands work
  identically from the worktree.
- The tmux window outlives the worktree: `/cleanup-worktrees` removes the
  directory and branch at merge but does not close the window, which is then
  sitting in a path that no longer exists. Close it by hand for now.
