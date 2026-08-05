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
`/next-issue` handles claim + naming and then invokes this skill; `/next-issues`
does the same for a batch of beads, once per bead.

## Input

`$ARGUMENTS` = the branch name, optionally followed by `--` and the command to
seed the new session with.

**Branch name** (or ask) is also the worktree folder name: `<beads-id>-<slug>`,
e.g. `st2-00p.3-regression-ratchet`. Keep the slug to 2-4 distinctive kebab-case
words from the issue title, not a full transcription. If given only a bead id,
ask for the slug - it matters and should not be guessed.

The name is fixed at creation and never renamed afterwards, even if the branch
grows to carry more beads (ADR-0010).

**Seed command** (optional) is what the tmux session in step 5 runs, e.g.:

```
/new-worktree st2-00p.3-regression-ratchet -- /work st2-00p.3 --auto
```

The seed names the *orchestrator*, not a stage: `/work` sizes the job in the
worktree, where the codebase is readable, and drives research / plan /
implement itself. This is how `/next-issue` and `/next-issues` hand a claimed
bead to the session that will act on it - all they pass is the id. Omitted -
someone invoking this skill directly - falls back to the same `/work` seed, so
a hand-made worktree behaves exactly like a routed one.

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

   Then trust the new worktree path:
   ```bash
   mise trust ../statifier_2-worktrees/<name>
   ```
   mise trusts `mise.toml` per directory path, not per repo, so the freshly
   created worktree path is untrusted even though it's the same repo content -
   without this, the first mise-managed command run there (step 4) prompts to
   trust the config and hangs a non-interactive agent session the same way an
   unaliased `-i` flag does (see CLAUDE.md's "Non-interactive shell commands"
   section).

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
   FINISH=" When the work is complete, finish with /commit --auto - it writes the Refs trailer and refuses if the tree carries changes unrelated to <id>. Do not run git commit directly."

   win=$(tmux new-window -d -P -F '#{window_id}' \
     -t '=statifier_2:' \
     -n '<name>' \
     -c "/Users/johnnyt/repos/github/statifier_2-worktrees/<name>")
   [ -n "$win" ] || { echo 'tmux window not created, skipping'; exit 0; }
   tmux send-keys -t "$win" \
     "claude --permission-mode auto --model opus '<seed>.$FINISH'" Enter
   ```

   `--model` is still passed explicitly, never left to whatever default the
   launched session would otherwise inherit (`~/.claude/settings.json`'s global
   default, which may not be Opus or Sonnet at all). It is now a *constant*
   because every seeded session runs `/work`, which orchestrates on Opus and
   assigns the implementation tier to its own subagents. The tier split did not
   disappear - it moved inside the session, where `docs/workflow.md`'s model
   roles are applied per stage instead of per launch. A skill's own `model:`
   frontmatter (e.g. `work`'s) governs that skill's invocation once the session
   is already running; it does not govern the CLI session itself, which is why
   this line exists at all and must not be "simplified" away.

   `<seed>` is the seed command from the input when one was given - pass it
   through verbatim, including the leading slash:

   ```
   claude --permission-mode auto --model opus '/work st2-00p.3 --auto.$FINISH'
   ```

   With no seed command, fall back to the same orchestrator:

   ```
   claude --permission-mode auto --model opus '/work <id> --auto.$FINISH'
   ```

   The finishing clause is appended unconditionally, to a given seed and to the
   fallback, because this step is the one place every caller
   (`/next-issue`, `/next-issues`, and a direct `/new-worktree` invocation)
   converges - editing it here reaches every seeded session without touching
   the calling skills themselves. It specifies `/commit --auto`
   rather than bare `/commit` because the tmux session runs unattended under
   `--permission-mode auto`: `/commit`'s interactive approval step would stall
   with nobody watching the window to answer it. This does not grant commit
   authority beyond what CLAUDE.md's authority table already grants (issue
   complete and full `mix quality` green) - it only routes that authority
   through the skill that performs the Refs-trailer and unrelated-changes
   checks, instead of a bare `git commit` that skips them.

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

   Both forms pass only the bead id, never a paraphrase of the work: the beads
   DB is shared across worktrees, so the new session reads the bead directly
   with `bd show`, while a restated description goes stale the moment the bead
   is updated.

   `--permission-mode auto` starts the seeded session in auto mode, so it makes
   routine calls without stopping to confirm each one - the point of fanning
   worktrees out is not to then babysit four sessions. It is `auto`, not
   `bypassPermissions`: the permission system still applies, and this repo's
   authority table (CLAUDE.md) still gates push, PR, and `bd close` on an
   explicit human ask.

6. **Report.** State the worktree path, the branch and what it was cut from,
   that caches were cloned (and whether the PLT came along), the quality
   result, **the tmux window** (its name and id, or why it was skipped), and
   **the model it launched with** (`opus`, per step 5)
   so the user can jump to it with the prefix key and knows which model is
   running there without switching to the window. Remind that subsequent work
   on this issue happens **inside the worktree**, and the worktree is removed
   at merge (`git worktree remove ../statifier_2-worktrees/<name>`).

## Notes

- Worktree-local and push-safe: no upstream is set, nothing is pushed.
- `deps/` and `_build/` are gitignored; the clones never show up in `git status`.
- If OTP/Elixir versions differ from when the PLT was built, dialyxir rebuilds
  it automatically - the clone is a best-effort warm, never a correctness risk.
- The beads DB is shared across worktrees (Dolt-backed), so `bd` commands work
  identically from the worktree.
- `/cleanup-worktrees` takes the window down at merge: it matches the window by
  **name and path together**, asks the session inside to `/exit`, and only then
  removes the directory and closes the window. Both halves of that match come
  from this step, so renaming the window or moving the worktree afterwards
  means cleanup will not find it and will leave it open rather than guess.
- A **busy** session blocks its own worktree's cleanup and is reported, so a
  sweep run while an agent is mid-turn is safe and re-running it later finishes
  the job.
- **A seeded session cannot spawn a nested `claude` session of its own.**
  `--permission-mode auto` (step 5) blocks `tmux send-keys ... 'claude' Enter`
  via the auto-mode classifier - observed live 2026-08-03 in the st2-5bk
  worktree, needed as a fixture for a bead whose acceptance criteria required
  observing a live session's terminal rendering. This is not model-specific;
  the classifier decision is the same regardless of which model is driving.
  If a bead needs a live Claude session to observe (spinner frames, dialog
  layout, the input box's suggested-prompt placeholder, or similar), do not
  try to launch one - use a **sibling worktree session** instead. `/next-issues`
  routinely stands up two or three seeded sessions in the same tmux server, so
  a batch run always has live sessions available to `tmux capture-pane`
  against, with nothing new to launch and nothing to clean up afterward. They
  are also more representative than a bare `claude` started in a scratch
  directory, since they are real sessions in real worktrees.
