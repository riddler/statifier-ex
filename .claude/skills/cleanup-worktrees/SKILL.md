---
name: cleanup-worktrees
description: Land merged work - close the beads whose PRs have merged, remove their worktrees and local branches, using GitHub PR state rather than git ancestry
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

So: ask GitHub, never git - `pr_state.rb` (via `worktree_survey.rb` and
`worktree_cleanup.rb`) is the one place that encodes this. **Do not use
`git log @{upstream}..HEAD` or `git log origin/main..HEAD` as a substitute
either**: the upstream ref is gone precisely when this skill runs (GitHub
deletes the remote branch on merge, so `@{upstream}` fails with `fatal:
ambiguous argument`, which reads like "unpushed commits" and skips **every**
merged worktree - observed live cleaning up PRs #8 and #9), and
`origin/main..HEAD` reports commits for every merged branch under rebase
merging regardless, since it replays under new SHAs. `headRefOid` from `gh` is
the only local-vs-merged comparison that holds here.

## Input

`$ARGUMENTS` = optional worktree or branch name to clean just that one. Omitted,
sweep every worktree under `../statifier-ex-worktrees/`.

## What to run

1. **Check phase.**
   ```bash
   .claude/scripts/worktree_cleanup.rb --dry-run [name]
   ```
   This enumerates worktrees (dropping the main checkout - removing it would
   take the repository with it), asks GitHub whether each branch's PR merged,
   refuses on a dirty tree, and compares the local `HEAD` to the SHA GitHub
   actually merged (`headRefOid`) to catch commits made after the push. Read
   `data.results[].result` per worktree - `"merged in PR #<n>, would remove"`
   marks a cleanup candidate; anything else (`"not merged ... kept"`,
   `"dirty, skipped"`, `"commits after merge (...), skipped"`) is not touched
   this run.

2. **Quiesce each candidate's session**, before touching anything on disk -
   see Judgment below for why this order matters:
   ```bash
   .claude/scripts/tmux_window.rb find <name> <path>
   ```
   - `data.found: false` - no window for this worktree. Nothing to quiesce;
     go straight to removal (step 3) for this candidate.
   - `blocked` `ambiguous_window_match` - more than one window claims this
     worktree. Skip the quiesce **and** the removal for this candidate; report
     it. Two windows claiming one worktree is a state a human should look at.
   - Otherwise `data.window_id` - continue:
   ```bash
   .claude/scripts/tmux_window.rb classify <window_id>
   ```
   `data.status: "busy"` - skip this worktree's removal entirely, report
   `"session busy, skipped"`, leave the worktree, branch, and window alone.
   `data.status: "exited"` - the pane is not running claude at all (checked
   via `pane_current_command` before the byte-level idle/busy classifier
   ever runs - a bare shell prompt is not "idle", it is already down).
   Skip quiesce entirely - there is no claude session to ask to `/exit` -
   and carry `window_id` straight to step 3's close, exactly like quiesce's
   own `"exited"` below.
   `data.status: "idle"` - continue:
   ```bash
   .claude/scripts/tmux_window.rb quiesce <window_id>
   ```
   `blocked` `quiesce_timeout` - skip this worktree's removal, report it. Never
   escalate past this. `data.status: "exited"` - the session is down; carry
   `window_id` forward to step 3's close.

3. **Remove, per candidate that passed step 2** (no window, classify already
   `"exited"`, or quiesced):
   ```bash
   .claude/scripts/worktree_cleanup.rb <name>
   ```
   Invoked by name so a busy-skipped candidate is never touched. Reads
   `data.results[0].result` for the report line and `data.beads_to_close` for
   step 4. This call also handles `git worktree remove`, `git worktree prune`,
   `git branch -D`, and a `git fetch --prune` of its own - see "How to read
   the result" for what each result string means.

   If step 2 found a `window_id` (classify already `"exited"`, or quiesce
   reached `"exited"`), close its window now that removal succeeded:
   ```bash
   .claude/scripts/tmux_window.rb close <window_id>
   ```
   `data.closed: false, reason: "window kept, other panes busy"` is a normal
   outcome - report `"window kept, other panes busy"` and move on; the
   worktree removal already happened and stands regardless.

4. **Close the beads that just landed.** *(stays a literal instruction in this
   skill - see Judgment.)* Union `data.beads_to_close` across every
   `worktree_cleanup.rb` call this sweep made. For each id:
   ```bash
   bd show <id>          # confirm it exists and is not already closed
   bd close <id> --reason="Merged to origin/main via PR #<number>"
   ```
   Already-closed is a no-op, not an error - say so and move on. An id that
   does not resolve is worth reporting rather than swallowing.

5. **Publish the closes**, only if step 4 closed at least one bead:
   ```bash
   bd dolt push
   ```
   Non-fatal if offline; report that the closes are local and will publish on
   the next push.

## How to read the result

- `blocked` `gh_unavailable` on `worktree_cleanup.rb` (check phase or removal)
  - **STOP the whole sweep.** Without PR state there is no safe merge signal,
    and this is the script that deletes branches on the strength of that
    signal. Report the error; do not fall back to any git-only check.
- `blocked` `no_matching_worktree` - report what is live instead.
- `data.results` empty and `ok: true` - no worktrees at all. Say so and stop.
- `worktree_cleanup.rb`'s result strings are the report vocabulary directly:
  `"not merged (no PR, open, or closed unmerged), kept"`, `"dirty, skipped"`,
  `"commits after merge (<sha> != <sha>), skipped"`, `"merged in PR #<n>,
  removed"`, `"merged in PR #<n>, would remove"` (dry-run only), `"remove
  failed, skipped"`.
- `data.beads_to_close` is already deduped and sorted per call - union across
  calls before step 4, don't re-derive it from `gh` yourself.

## Report

One line per worktree, naming the beads closed and what happened to the
session and window:

| Worktree | Result |
|---|---|
| `st-qww.1-team-maintainer-optin` | merged in PR #6, closed st-qww.1, session exited, removed, branch deleted, window closed |
| `st-qww.4-close-on-merge` | merged in PR #10, closed st-qww.4 + st-qww.6, no window, removed |
| `st-00p.3-regression-ratchet` | open PR #11, kept |
| `st-vbu-strict-credo` | no PR, kept |
| `st-92f-area-labels` | dirty, skipped |
| `st-8k2-send-queue` | merged in PR #13, **session busy, skipped** |
| `st-lzn-tmux-windows` | merged in PR #12, **no `Refs:` trailer, no bead closed** |

**A busy session is a skip worth naming, not a footnote.** It is the one
outcome where re-running the sweep later finishes the job on its own, and the
user needs to know there is a job left to finish.

**Nothing to clean is a success, and must say so explicitly** - "no merged
worktrees found, 3 live worktrees kept, no beads closed" rather than silence.
A silent sweep is indistinguishable from the ancestry bug this skill exists to
avoid.

## Judgment

- An **open PR** means work in review; a **closed-unmerged** one means work
  someone abandoned but did not delete - both are theirs to decide about, not
  this skill's, so both are left alone.
- **Never `--force` a worktree removal, never `-D` an unmerged branch.** Both
  destroy work that exists nowhere else. `git worktree remove` already refuses
  on a dirty tree; that refusal is a feature, and neither script routes around
  it. Every skip is reported so a human can deal with it.
- **Quiesce comes after the dirty and SHA checks, not before.** A worktree
  that is about to be skipped should keep its session running; shutting one
  down and then deciding not to clean up is pure loss. The residual race - the
  session dirties the tree between the check and the removal - costs nothing,
  because `git worktree remove` refuses on a dirty tree anyway. That refusal
  is the backstop, so it stays a reported error rather than lost work.
- **Match the window on name and path together, and send ambiguity to a
  human.** `/new-worktree` sets the window name to the worktree directory name
  and opens it with `-c <worktree path>`, so a real match agrees on both.
  Matching on name alone would close a window a human renamed onto something
  else; matching on path alone would close a stray shell someone happened to
  `cd` there. More than one match is a state a human should look at, not
  something to guess through.
- **Busy means skip, the same stance as a dirty tree.** Report it and leave
  the worktree, branch, and window alone; do not force a decision the running
  session hasn't finished making.
- **Never kill a Claude session, only ask it to exit.** `/exit` and a timeout,
  never a signal, never `kill-pane`, never `kill-window` on a live session. A
  session that will not take `/exit` is one that is doing something, and the
  point of this step is to not be the thing that interrupts it. Idleness is
  determined by a byte-level classifier (`tmux_window.rb classify`) that
  samples twice, ~3s apart, and requires idle both times - one capture can
  land in the gap between a turn ending and the next tool call starting; the
  classifier's own comments carry the ANSI/dim-span mechanics.
- **A bead closes at merge and nowhere else.** A closed bead is a claim about
  `main`, not about a green branch. Closing at commit or PR-open time makes
  `bd ready` offer downstream work against code that is not on `main` yet, and
  `refs/dolt/data` propagates that wrong state to other machines within
  minutes - the collision ADR-0010 makes beads the coordination bus to
  prevent. The merge is the moment that claim becomes true, so it is the
  moment to close.
- **The `^Refs:` anchor is required, not tidiness.** Commit bodies here
  routinely name other beads in prose - citing a design note, crediting a
  discovery, explaining a deviation - and an unanchored match closes every one
  of them. Fixture on `main`: `146c69f` names `st-00p.1` and `st-gnr` in its
  body and carries no `Refs:` line at all, so without the anchor a merge
  containing it would close two unrelated beads. Anchored, it correctly closes
  nothing. `pr_state.rb beads` (used internally by `worktree_cleanup.rb`) is
  the single definition site for this extraction, shared with
  `/merge-request`.
- **A merged PR whose commits carry no `Refs:` line closes nothing - report
  that, do not pass over it.** It means either work that skipped `/commit`, or
  trailers forgotten on a grouped branch. Both leave beads open that a human
  expected closed, and silence here is indistinguishable from success.
- **Close before removing** (already sequenced above by running the closes
  after the removal calls report their `beads_to_close`) **but do not let a
  `bd` failure block cleanup**, and never close a bead for a branch whose
  merge was not confirmed by the check phase.
- **`bd close` stays a literal instruction in this skill, never routed through
  a script.** No script under `.claude/scripts/` may contain a code path that
  runs `bd close` (`.claude/scripts/README.md`'s banned-operation list); this
  is the one place in the whole worktree lifecycle that call is authorized,
  and keeping it visible here is what keeps the trigger (a verified merge)
  auditable.
- **PR state or nothing.** If `gh` cannot answer, stop. Do not substitute
  `git branch --merged`, `git merge-base --is-ancestor`, or a commit-message
  comparison; under rebase merging none of them are sound.
- **`tmux` is convenience, never a gate.** No `tmux`, no server, no window, a
  window with no session in it - all of them are normal and none of them are
  errors. `/new-worktree` treats the window as optional on the way up; this
  skill treats it as optional on the way down. The worktree and the bead are
  the work; the window is a place to sit.
- **Pairs with `/refresh-worktree`: same moment, opposite direction.** That one
  rebases the survivors onto the new `origin/main`; this one removes the
  worktree of the branch that just landed. Run this first - refreshing a
  worktree that is about to be deleted is wasted work.
- **A branch may carry several beads.** Trailer-driven closing is what makes
  that safe, so grouping related beads onto one branch is a real option rather
  than something the tooling punishes. See the note in `/merge-request`.
- **Safe to re-run:** worktrees with no merged PR are kept, already-closed
  beads are a no-op, and a clean sweep changes nothing.
