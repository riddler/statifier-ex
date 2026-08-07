---
name: next-issue
description: Pick the next ready bead (choices by default, --auto lets an agent take the top item), claim it, and stand up its worktree via /new-worktree, seeded with /work to size and drive the job there
model: sonnet
argument-hint: ["optional: --auto, and/or bd ready filters (e.g. -l parser, -p 1)"]
---

# Next Issue

Pick the next unblocked, unclaimed bead, claim it so other worktrees skip it,
cut its worktree branch via `/new-worktree`, and hand the bead to `/work` in
that worktree. Beads is the only tracker here (ADR-0007) - there is no external
issue system to promote to or reconcile against. Issue state syncs across
machines through `refs/dolt/data` on git origin (`bd dolt pull` / `bd dolt
push`); `.beads/issues.jsonl` is a passive export, never the sync channel.

This is `/next-issues` at `n=1` with no picker needed for a single item, plus
the worktree-and-handoff steps `/next-issues` also uses. Both skills call
`.claude/scripts/select_batch.rb` for the mechanics; this one adds no judgment
step of its own beyond "never auto-select in manual mode."

## Modes

Parse `$ARGUMENTS`:

- **`--auto` present** -> **agent-auto mode**: atomically claim the top ready
  item and proceed without confirmations. For unattended agents.
- **Otherwise** -> **manual mode** (the default): always present choices and let
  the user pick. **Never auto-select in manual mode, even if only one item is
  ready** - show it and confirm.

Everything else in `$ARGUMENTS` maps to `bd ready`'s native filter flags
(`-p/--priority`, `-l/--label`/`--label-any`/`--exclude-label`,
`-t/--type`/`--exclude-type`, `--parent`, ...) and is passed through to
`select_batch.rb`, so both modes scope identically. Re-verify against
`bd ready --help` if these drift.

## Steps

0. **Refresh beads (best-effort).** The Dolt DB syncs via `refs/dolt/data` on
   git origin (github.com/riddler/statifier-ex), so pull the latest issue state
   before picking - another machine or agent may have claimed or closed work:
   ```bash
   ruby .claude/scripts/bead.rb sync pull
   ```
   Non-fatal if offline (`warnings` only); the local DB is then the best
   available view. On a fresh clone with no `.beads/embeddeddolt/`, run
   `bd bootstrap` instead - it clones the issue history from origin and wires
   the Dolt remote.

0.5. **Clean up merged worktrees (best-effort).** Invoke
   **`/cleanup-worktrees`**. Picking up new work is the natural moment for it:
   the previous branch has usually landed by now, and its worktree and local
   branch are still sitting there. Detection is GitHub PR state, never git
   ancestry - the repo allows rebase merging only, so a merged branch is never
   an ancestor of `main`.

   Like the sync steps, this must never gate the pickup. If `gh` is
   unauthenticated or offline, `/cleanup-worktrees` stops on its own and reports;
   carry on picking work regardless.

   **Run this every invocation, even if `/cleanup-worktrees` already ran earlier
   in the session.** "Already ran this session" is not the same claim as "ran
   immediately before this pickup" - a branch can land on `origin/main` in
   between. This skill has no live-worktree survey downstream to go stale from
   a skipped 0.5 (`/next-issues` does; see its step 1 for that hardening), but
   re-running here is still cheap and keeps a dead worktree from sitting
   alongside the one this step is about to create.

1. **Pick.**
   ```bash
   ruby .claude/scripts/select_batch.rb --n 1 [FILTERS]
   ```
   This is the same selection mechanics `/next-issues` uses, capped at one bead:
   it lists ready candidates (`bd ready --json [FILTERS]`), surveys live
   worktrees for area collisions, annotates each with a verdict, and runs the
   greedy walk. Read `data.candidates` for the full ranked list (id, title,
   priority, issue_type, verdict, reason) and `data.recommended` for the top
   pick - at most one id, since `n=1`.

   **`data.recommended` empty** (and `data.candidates` all skipped, or empty
   outright) -> nothing ready and unclaimed. Do not auto-file. Report it, show
   `bd blocked` so it is clear what is waiting on what, and stop (skip every
   step below). In manual mode, offer `/create-issue` as the way to file
   something new.

   **Manual mode:** present the top few rows of `data.candidates` (id, title,
   type, priority, verdict) and let the user pick or confirm the recommended
   one - **never auto-select, even when only one candidate is ready.** Then
   claim it:
   ```bash
   ruby .claude/scripts/bead.rb claim <id>
   ```

   **Agent-auto mode:** claim `data.recommended`'s id directly, no
   confirmation:
   ```bash
   ruby .claude/scripts/bead.rb claim <id>
   ```
   If the claim fails (`blocked` code `bd_claim_failed` - someone else got
   there between the select and the claim), report it and stop; do not retry
   silently against a different candidate.

1.5. **Publish the claim (best-effort).** The claim is the lock, but it only
   locks what other machines can see - push it right after claiming:
   ```bash
   ruby .claude/scripts/bead.rb sync push
   ```
   Non-fatal if offline (agents in the same checkout's worktrees share the DB
   directly and see the claim regardless); it publishes on the next push.

2. **Compute the branch name** `<id>-<slug>`. Kebab-case the bead title into a
   short slug - 2-4 distinctive words, not a full transcription
   (`/new-worktree` refuses to guess one, so this skill must produce the full
   name). Manual mode: present it for confirmation.

   The name is fixed at creation and never renamed afterwards, even if the
   branch grows to carry more beads (ADR-0010).

3. **Read the bead.**
   ```bash
   ruby .claude/scripts/bead.rb show <id>
   ```
   Description, acceptance, dependencies, notes. This still has to happen
   before the worktree is stood up: the branch slug in step 2 comes from the
   title, and an epic or a malformed bead is something to catch while the only
   cost is a claim to reverse, not after a worktree and a tmux window exist for
   it. **Sizing the work is not what this read is for** - that happens in the
   worktree, in `/work`.

4. **Stand up the worktree, seeded with `/work`.** Invoke
   **`/new-worktree <id>-<slug> -- /work <id> --auto`** - it cuts the branch off
   `main`, creates `../statifier-ex-worktrees/<id>-<slug>`, warms `deps/`,
   `_build/`, and the dialyzer PLT, verifies the loop profile is green, and
   opens a tmux window running a Claude session on that seed.

   **The seed is the same for every bead, by design.** It is uniform precisely
   *because* sizing is not this skill's job: choosing between research, a plan,
   and implementing directly needs the codebase, and this session has only the
   bead's description. The seeded session has the worktree - it can read the
   modules the bead names before it decides. `/work` sizes the job there and
   drives the stages, so nothing is lost by not deciding here; the decision is
   simply made where the evidence is.

5. **Hand off - do not do the work here.** The seeded session in the tmux
   window owns the issue from this point. Doing it in this session as well is
   two sessions editing one worktree.

   **Report**: the chosen bead, that it was claimed, the branch and worktree
   created, the quality-check result from `/new-worktree`, and the tmux window
   to jump to.

## Guidelines

- Claim before worktree, always - the claim is the lock (ADR-0010). Never
  create the worktree for an unclaimed bead.
- Sync and cleanup steps (0, 0.5 and 1.5) are best-effort and must never gate
  the claim: if `bead.rb sync pull`/`push` is slow, errors, or the machine is
  offline, proceed - they retry on the next run. **Never abort pickup on a
  sync failure.**
- Manual mode confirms the pick and the branch name before anything mutates the
  repo; the claim itself is cheap to reverse (`bd update <id> --status open`).
- Discovered work found while picking is filed with `bd q` (or
  `bead.rb create`) and linked `discovered-from`, not chased now.
- Compose with `/create-issue`, `/new-worktree` and `/work` rather than
  duplicating their logic.
- **This skill picks and claims; it neither sizes nor implements.** Selection
  is all that happens here. `/work`, in the worktree, sizes the job and drives
  it - research, plan, or straight to implementation - because that session is
  the one that can read the code. Doing any of that here as well is how one
  issue gets worked twice.
- Re-verify exact `bd` flags against `bd ready --help` if this drifts. See
  `.claude/scripts/README.md` for the envelope contract shared by every
  script this skill calls.
