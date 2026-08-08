---
name: new-worktree
description: Create a per-issue worktree under ../statifier-ex-worktrees/ with a new branch off main, warm it (deps, _build, dialyzer PLT) so the first quality run is fast, and open a tmux window there with a Claude session seeded on the bead
model: sonnet
argument-hint: ["branch/worktree name, e.g. st-00p.3-regression-ratchet"]
---

# New Worktree

Stand up a fresh worktree for one beads issue, per ADR-0010: one issue, one
branch, one worktree under `../statifier-ex-worktrees/`, named `<beads-id>-<slug>`.
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
e.g. `st-00p.3-regression-ratchet`. Keep the slug to 2-4 distinctive kebab-case
words from the issue title, not a full transcription. If given only a bead id,
ask for the slug - it matters and should not be guessed.

The name is fixed at creation and never renamed afterwards, even if the branch
grows to carry more beads (ADR-0010).

**Seed command** (optional) is what the tmux session runs, e.g.:

```
/new-worktree st-00p.3-regression-ratchet -- /work st-00p.3 --auto
```

The seed names the *orchestrator*, not a stage: `/work` sizes the job in the
worktree, where the codebase is readable, and drives research / plan /
implement itself. This is how `/next-issue` and `/next-issues` hand a claimed
bead to the session that will act on it - all they pass is the id. Omitted -
someone invoking this skill directly - falls back to the same `/work` seed, so
a hand-made worktree behaves exactly like a routed one.

## What to run

1. Create and warm the worktree:
   ```bash
   .claude/scripts/worktree_create.rb <name>
   ```
   This covers the guard (existing branch or worktree directory), cutting the
   branch from `origin/main` (or local `main` if `git fetch` fails), trusting
   the new path with the toolchain manager before any managed command runs
   there, cloning the warm caches, and a final loop-profile gate run to
   confirm green. Every one of those - where the worktree goes, what trusts
   it, what gets cloned, which gate command runs - is read from
   `.claude/wurk.json`, so this prose deliberately does not restate the
   commands. Run it for real - do not `--dry-run` this one, since the point
   of the step is the worktree existing and warm. Never truncate its output
   if you surface `data.quality_output`.

2. Open the tmux window, only after step 1 reports `ok: true`:
   ```bash
   .claude/scripts/tmux_window.rb ensure-session
   .claude/scripts/tmux_window.rb open <name> <path> <id> <seed>
   ```
   `<path>` and `<id>` come from step 1's `data`; `<id>` is the bead id at the
   front of the branch name (`st-lzn` from `st-lzn-tmux-window-per-worktree`,
   `st-00p.3` from `st-00p.3-regression-ratchet`). `<seed>` is the seed command
   from the input when one was given, passed through verbatim including the
   leading slash (e.g. `/work st-00p.3 --auto`); with no seed command, fall
   back to `/work <id> --auto`. Pass only the bead id, never a paraphrase of
   the work: the beads DB is shared across worktrees, so the new session reads
   the bead directly with `bd show`, while a restated description goes stale
   the moment the bead is updated.

## How to read the result

`worktree_create.rb`:
- `blocked` (`branch_exists`, `worktree_dir_exists`) - STOP and report. Offer a
  different name or let the user delete the old one. **Never force** - this
  script has no path that deletes a branch or directory to make room for a
  new one, and neither should you.
- `warnings` worth surfacing in the report: `fetch_failed` (cut from local
  `main` instead of `origin/main` - say so), `trust_failed`,
  `cache_clone_failed`, `warm_failed`, `warm_cache_missing` (in this repo
  that is the dialyzer PLT - suggest `mix quality.plt` once, in either
  checkout).
- `blocked` `wrong_parallelism_model` or `missing_worktrees_dir` means the
  project's `.claude/wurk.json` does not describe a worktree-per-issue
  layout. Report it; do not work around it by creating a directory yourself.
- `data.quality_green` false (`ok: false`) means the warm worktree came up red;
  report `data.quality_output` in full, never truncated.
- `data.path`, `data.base_ref`, `data.name` feed the report and the tmux step.

`tmux_window.rb open`:
- **This step is optional and never fatal.** If `tmux` genuinely is not
  reachable (both calls error, not merely `blocked`), skip it with a note and
  go to the report. The worktree is the deliverable; the window is
  convenience. Never fail worktree creation because the window could not be
  made.
- `data.skipped: true` - a window with this name already exists. Report it and
  do not create a second one; the guard exists so two windows never claim the
  same name.
- `blocked` `window_id_empty` - the same empty-target hazard `/cleanup-worktrees`
  guards against; report it as the window step failing, not as worktree
  creation failing.
- On success, `data.window_id`, `data.name`, `data.path`, `data.model` feed the
  report directly.

## Judgment

- **`--model` is passed explicitly** by `tmux_window.rb`, never left to
  whatever default the launched session would otherwise inherit
  (`~/.claude/settings.json`'s global default, which may not be Opus or Sonnet
  at all). It is a *constant* because every seeded session runs `/work`, which
  orchestrates on Opus and assigns the implementation tier to its own
  subagents. The tier split did not disappear - it moved inside the session,
  where `docs/workflow.md`'s model roles are applied per stage instead of per
  launch. A skill's own `model:` frontmatter (e.g. `work`'s) governs that
  skill's invocation once the session is already running; it does not govern
  the CLI session itself, which is why this constant exists at all and must
  not be "simplified" away.

- **The finishing clause is appended unconditionally** by `tmux_window.rb`, to
  a given seed and to the fallback, because the tmux-open step is the one
  place every caller (`/next-issue`, `/next-issues`, and a direct
  `/new-worktree` invocation) converges - editing that one template reaches
  every seeded session without touching the calling skills themselves. It
  specifies `/commit --auto` rather than bare `/commit` because the tmux
  session runs unattended under `--permission-mode auto`: `/commit`'s
  interactive approval step would stall with nobody watching the window to
  answer it. This does not grant commit authority beyond what CLAUDE.md's
  authority table already grants (issue complete and full `mix quality`
  green) - it only routes that authority through the skill that performs the
  Refs-trailer and unrelated-changes checks, instead of a bare `git commit`
  that skips them.

- `--permission-mode auto` starts the seeded session in auto mode, so it makes
  routine calls without stopping to confirm each one - the point of fanning
  worktrees out is not to then babysit four sessions. It is `auto`, not
  `bypassPermissions`: the permission system still applies, and this repo's
  authority table (CLAUDE.md) still gates push, PR, and `bd close` on an
  explicit human ask.

- **A seeded session cannot spawn a nested `claude` session of its own.**
  `--permission-mode auto` blocks `tmux send-keys ... 'claude' Enter` via the
  auto-mode classifier - observed live 2026-08-03 in the st-5bk worktree,
  needed as a fixture for a bead whose acceptance criteria required observing
  a live session's terminal rendering. This is not model-specific; the
  classifier decision is the same regardless of which model is driving. If a
  bead needs a live Claude session to observe (spinner frames, dialog layout,
  the input box's suggested-prompt placeholder, or similar), do not try to
  launch one - use a **sibling worktree session** instead. `/next-issues`
  routinely stands up two or three seeded sessions in the same tmux server, so
  a batch run always has live sessions available to capture a pane against,
  with nothing new to launch and nothing to clean up afterward. They are also
  more representative than a bare `claude` started in a scratch directory,
  since they are real sessions in real worktrees.

## Report

State the worktree path, the branch and what it was cut from, that caches
were cloned (and whether the warm caches came along - `data.warm_caches_present`),
the quality result, **the tmux window** (its name and id, or why it was
skipped), and **the model it launched with** (`data.model`, from the
manifest's `tmux.model`) so the user can jump to it with the prefix key and
knows which model is running there without switching to the window. Remind that subsequent
work on this issue happens **inside the worktree**, and the worktree is
removed at merge (`/cleanup-worktrees`, or by hand:
`git worktree remove ../statifier-ex-worktrees/<name>`).

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
