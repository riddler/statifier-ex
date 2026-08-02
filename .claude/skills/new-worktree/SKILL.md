---
name: new-worktree
description: Create a per-issue worktree under ../statifier_2-worktrees/ with a new branch off main, then warm it (deps, _build, dialyzer PLT) so the first quality run is fast
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

5. **Report.** State the worktree path, the branch and what it was cut from,
   that caches were cloned (and whether the PLT came along), and the quality
   result. Remind that subsequent work on this issue happens **inside the
   worktree**, and the worktree is removed at merge
   (`git worktree remove ../statifier_2-worktrees/<name>`).

## Notes

- Worktree-local and push-safe: no upstream is set, nothing is pushed.
- `deps/` and `_build/` are gitignored; the clones never show up in `git status`.
- If OTP/Elixir versions differ from when the PLT was built, dialyxir rebuilds
  it automatically - the clone is a best-effort warm, never a correctness risk.
- The beads DB is shared across worktrees (Dolt-backed), so `bd` commands work
  identically from the worktree.
