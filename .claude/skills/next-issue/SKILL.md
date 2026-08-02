---
name: next-issue
description: Pick the next ready bead (choices by default, --auto lets an agent take the top item), claim it, stand up its worktree via /new-worktree, then triage to research, plan, or implement directly
model: sonnet
argument-hint: ["optional: --auto, and/or bd ready filters (e.g. -l parser, -p 1)"]
---

# Next Issue

Pick the next unblocked, unclaimed bead, claim it so other worktrees skip it,
cut its worktree branch via `/new-worktree`, and route the work to the right
follow-up. Beads is the only tracker here (ADR-0007) - there is no external
issue system to promote to or reconcile against. Issue state syncs across
machines through `refs/dolt/data` on git origin (`bd dolt pull` / `bd dolt
push`); `.beads/issues.jsonl` is a passive export, never the sync channel.

## Modes

Parse `$ARGUMENTS`:

- **`--auto` present** -> **agent-auto mode**: atomically claim the top ready
  item and proceed without confirmations. For unattended agents.
- **Otherwise** -> **manual mode** (the default): always present choices and let
  the user pick. Never auto-select in manual mode, even if only one item is
  ready - show it and confirm.

Everything else in `$ARGUMENTS` maps to `bd ready`'s native filter flags
(`-p/--priority`, `-l/--label`/`--label-any`/`--exclude-label`,
`-t/--type`/`--exclude-type`, `--parent`, ...) and is passed through to
whichever call runs, so both modes scope identically. Re-verify against
`bd ready --help` if these drift.

## Steps

0. **Refresh beads (best-effort).** The Dolt DB syncs via `refs/dolt/data` on
   git origin (github.com/riddler/statifier_2), so pull the latest issue state
   before picking - another machine or agent may have claimed or closed work:
   ```bash
   bd dolt pull 2>/dev/null || true
   ```
   Non-fatal if offline; the local DB is then the best available view. On a
   fresh clone with no `.beads/embeddeddolt/`, run `bd bootstrap` instead - it
   clones the issue history from origin and wires the Dolt remote.

1. **Pick and claim.**

   **Manual mode:**
   ```bash
   bd ready --json [FILTERS]
   ```
   Present the top few candidates (id, title, type, priority, one-line why-now
   drawn from its epic/dependencies if obvious) and let the user pick or confirm
   the top one. Then claim:
   ```bash
   bd update <id> --claim
   ```

   **Agent-auto mode** - one atomic call, no read-then-claim race:
   ```bash
   bd ready --claim --json [FILTERS]
   ```
   Non-empty -> `[0]` is the claimed bead (status already `in_progress`); read
   `.id` from it.

   **Empty (`[]`)** in either mode -> nothing ready and unclaimed. Do not
   auto-file. Report it, show `bd blocked` so it is clear what is waiting on
   what, and stop (skip every step below). In manual mode, offer
   `/create-issue` as the way to file something new.

1.5. **Publish the claim (best-effort).** The claim is the lock, but it only
   locks what other machines can see - push it right after claiming:
   ```bash
   bd dolt push 2>/dev/null || true
   ```
   Non-fatal if offline (agents in the same checkout's worktrees share the DB
   directly and see the claim regardless); it publishes on the next push.

2. **Compute the branch name** `<id>-<slug>`. Kebab-case the bead title into a
   short slug - 2-4 distinctive words, not a full transcription
   (`/new-worktree` refuses to guess one, so this skill must produce the full
   name). Manual mode: present it for confirmation.

3. **Stand up the worktree.** Invoke **`/new-worktree <id>-<slug>`** - it cuts
   the branch off `main`, creates `../statifier_2-worktrees/<id>-<slug>`, warms
   `deps/`, `_build/`, and the dialyzer PLT, and verifies the loop profile is
   green. Subsequent work on the issue happens inside that worktree.

4. **Seed context.** `bd show <id>` so the session opens already knowing the
   task: description, acceptance, dependencies, notes.

5. **Report**: the chosen bead, that it was claimed, the worktree/branch
   created, and the quality-check result from `/new-worktree`.

6. **Triage and launch the follow-up.** Do not reflexively research - judge
   what the issue needs from what is already in hand (type, description,
   priority, which module it touches), then route to exactly one path. The
   model roles come from docs/workflow.md.

   | Bucket | Route to | When |
   |---|---|---|
   | **Code-heavy** | **`/research-codebase <id>`** | Touches the interpreter core, parser, or another multi-module subsystem; blast radius unclear; existing structure (or the v1 reference at `../statifier`) must be mapped before planning. |
   | **Plan-only** | **`/create-plan <id>`** | Well-understood but multi-step or cross-cutting enough to deserve a plan in `docs/plans/`; a separate research doc would be redundant. Runs on Opus per its frontmatter. |
   | **Just-do-it** | *(implement inline, in the worktree)* | Bounded doc / chore / config / small utility with low blast radius. Skip the artifacts and start implementing immediately, keeping `mix quality --profile loop` green. |

   - When genuinely uncertain between two buckets, pick the heavier one
     (research > plan > just-do-it) - skipped diligence costs more than an
     unnecessary research pass.
   - **Manual mode:** state the chosen bucket and a one-line rationale, and let
     the user override before launching.
   - **Agent-auto mode:** announce bucket + rationale, then proceed.

## Guidelines

- Claim before worktree, always - the claim is the lock (ADR-0010). Never
  create the worktree for an unclaimed bead.
- Sync steps (0 and 1.5) are best-effort and must never gate the claim: if
  `bd dolt pull`/`push` is slow, errors, or the machine is offline, proceed -
  they retry on the next run. Never abort pickup on a sync failure.
- Manual mode confirms the pick and the branch name before anything mutates the
  repo; the claim itself is cheap to reverse (`bd update <id> --status open`).
- Discovered work found while triaging is filed with `bd q` and linked
  `discovered-from`, not chased now.
- Compose with `/create-issue` and `/new-worktree` rather than duplicating
  their logic.
- Re-verify exact `bd` flags against `bd ready --help` if this drifts -
  `bd ready --claim --json` and `bd update --claim` are confirmed current as of
  the bd version in use (2026-08).
