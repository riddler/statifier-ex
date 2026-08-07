---
name: next-issues
description: Pick up to n ready beads whose area labels are pairwise disjoint, claim them all, and stand up a worktree and tmux window for each via /new-worktree - the batch form of /next-issue, for fanning out to several parallel worktrees in one pass
model: sonnet
argument-hint: ["optional: n (default 3, max 4), --auto, one or more bead IDs, and/or bd ready filters (e.g. -l parser, -p 1)"]
---

# Next Issues

Fan out. Pick several ready beads that are safe to work on at the same time,
claim all of them, and give each its own branch, worktree and tmux window.

`/next-issue` is the one-at-a-time form of this: pick, claim, one worktree, one
seeded session. Running it three times gets three worktrees, but nothing checks
that those three beads can coexist - that judgment lands on whoever is watching,
once per run. This skill makes the collision check the mechanism: two beads are
batchable iff their `area:` label sets are disjoint (docs/workflow.md), so a
batch is a set intersection rather than an opinion.

In manual mode this skill **presents choices, it does not decide for you.**
Every candidate's constraints go on screen - including collisions with beads
already in a live worktree elsewhere - before anything is claimed, and the
greedy pick is offered as the *recommended* option among the legal ones, not
as the outcome. A user who understands a collision's risk can still take it,
deliberately, through the override path; an unattended agent (`--auto`) never
can.

This skill **composes**, it does not fork. Selection is the only thing it adds;
everything downstream is `/new-worktree`, exactly as `/next-issue` uses it. The
mechanics - listing candidates, surveying live worktrees, annotating verdicts,
running the greedy walk - live in `.claude/scripts/select_batch.rb`; this skill
supplies the judgment that script deliberately leaves out: the picker.

## Input

`$ARGUMENTS` is passed straight through to `select_batch.rb`, which parses it
itself:

- **A bare integer** -> `n`, the ceiling on batch size. Default `3`.
  **The script refuses `n > 4`** (`blocked` code `n_too_large`): relay its
  message as-is - beyond four the merge queue is the constraint, not the
  picking, and every extra worktree is another branch that has to rebase past
  the ones that land first. Offer to run with 4. This is a refusal, not a
  clamp: someone asking for 8 has a wrong model of where the constraint is,
  and silently giving them 4 would hide that.
- **`--auto` present** -> **agent-auto mode**: select and claim without
  confirmation. For unattended agents.
- **One or more bead IDs** (tokens matching the `st-` id shape) ->
  **explicit-selection mode**: "consider exactly these", not a `bd ready`
  filter. The script validates each with `bd show <id>`; an unknown id comes
  back as a `warnings` entry (`unknown_id`), not silently dropped from the
  report. `n` defaults to the count of listed ids in this mode (still capped
  at 4). **Mixing bead IDs with `bd ready` filter flags is refused**
  (`blocked` code `ambiguous_input`) - the user gets one input form per
  invocation.
- **Otherwise** -> **manual mode** (the default): present the candidates,
  their constraints, and the legal batch options; let the user pick before
  claiming anything.

Everything else maps to `bd ready`'s native filter flags (`-p/--priority`,
`-l/--label`/`--label-any`/`--exclude-label`, `-t/--type`/`--exclude-type`,
`--parent`, ...) and is passed straight through by the script. Re-verify
against `bd ready --help` if these drift.

**`--label-any` is broken upstream as of bd 1.1.2** (filed
[beads#5358](https://github.com/gastownhall/beads/issues/5358)) - it is
silently ignored in embedded-Dolt workspaces, so passing it straight through
to `bd ready` returns the *unfiltered* ready set with no error.
`bead.rb ready` (which `select_batch.rb` calls internally) already carries the
workaround: it splits `--label-any l1,l2,...` into one `bd ready --json -l
<label>` call per label and unions the results by id before anything else
runs. `-l`/`--label` (AND) passes straight through, unaffected. **Do not
quietly drop this note on a future re-verification pass without checking
whether beads#5358 has closed** - if it has, the workaround (and this
paragraph) can go.

`n` is a **ceiling, not a target.** Returning two when three were asked for is
the right outcome when the third collides. `select_batch.rb`'s `data.skipped`
and `data.ceiling_hit` make this explicit - relay it in the report; a silently
short batch reads as "there was no more work", which is a different and much
more alarming fact. In manual mode this is what the picker exists to prevent:
the ceiling being hit is shown as a constraint before the batch is finalized,
not discovered afterward in a report.

## Steps

0. **Refresh beads (best-effort).**
   ```bash
   ruby .claude/scripts/bead.rb sync pull
   ```
   `data.succeeded` may be `false`; that only produces a `warnings` entry, never
   a `blocked` one - non-fatal if offline, the local DB is then the best
   available view. On a fresh clone with no `.beads/embeddeddolt/`, run
   `bd bootstrap` instead (outside this script's scope).

0.5. **Clean up merged worktrees (best-effort).** Invoke
   **`/cleanup-worktrees`**. This matters more here than in `/next-issue`: about
   to stand up three or four worktrees is exactly the wrong moment to be carrying
   three or four dead ones. Never let it gate the pickup - if `gh` is
   unauthenticated or offline it stops on its own and reports; carry on.

   **Run this every invocation, even if `/cleanup-worktrees` already ran earlier
   in the session.** Step 1's live-worktree survey is only sound for the window
   "since the last sweep", and a fanned-out session can land on `origin/main`
   in the minutes between an earlier cleanup and this run - "cleanup already ran
   this session" is not the same claim as "cleanup ran immediately before this
   survey". Re-running is never wasted: the cost is one `gh` call per worktree,
   against a survey that reports a collision that has already resolved.

1. **Select the batch.**
   ```bash
   ruby .claude/scripts/select_batch.rb $ARGUMENTS
   ```
   One call replaces what used to be three separate steps: it lists candidates
   (`bd ready --json`, or `bd show <id>` per id in explicit-selection mode),
   surveys live worktrees for the areas they already hold, annotates every
   candidate with a verdict, and runs the greedy priority-ordered walk. Select
   nothing is claimed by this call - it only reports.

   The live-worktree survey (`worktree_survey.rb`, reused here) does not
   simply trust that step 0.5 ran and succeeded: for every live worktree it
   also checks whether its branch already merged
   (`gh pr list --state merged --head <branch> ...`), and if so treats it as
   holding no areas regardless of *why* it survived cleanup - 0.5 skipped, `gh`
   briefly down, or the session inside it busy. This is the fix for the
   failure mode observed live 2026-08-05, where a merged-but-not-removed
   worktree for st-o9a caused st-d9g to be reported as colliding with work
   that had already landed on `main` minutes earlier. If `gh` itself is
   unavailable, the survey degrades and the script emits `warnings` code
   `survey_degraded` - relay that as "possibly stale, `gh` was unavailable to
   confirm" next to any `collides-with-live-worktree` verdict it produced, not
   as a hard fact.

   Read `data`:

   - **`data.mode`** - `"auto"` or `"manual"`, echoing which mode was parsed.
   - **`data.candidates`** - one row per candidate: `id`, `title`, `summary`,
     `priority`, `issue_type`, `areas`, `verdict`, `reason`. `summary` is the
     bead's first sentence, truncated - deterministic, produced by
     `lib/summary.rb`, not model-written (docs/skill-automation.md explains
     why). This is the candidate table - show it in full before asking
     anything (step 2). Verdicts:

     | Verdict | Meaning |
     |---|---|
     | `epic` | work its children instead |
     | `unlabeled` | no `area:` label and no `upstream` label - blast radius undecided. Nobody has decided this bead's blast radius; skipping it is not a failure of this skill, it is the label being missing. Say which beads were skipped for this so they can be labeled and re-run. The one exception is `upstream` beads, which change no files in this repo by definition (docs/workflow.md) - they need no area label and are always batchable. |
     | `lands-alone` | `area:build` - takes the batch alone |
     | `collides-with-live-worktree` | its areas intersect a live worktree's held areas - names the area(s) and the worktree/bead holding them |
     | `free` | none of the above |

     `bd ready` already serializes `blocks`/`depends-on`, but a parent epic and
     its child can both be ready - that is what the `epic` verdict is for; do
     not batch across that dependency edge.
   - **`data.recommended`** - the greedy pick (highest priority first, skip
     epic/unlabeled/live-collision, `area:build` takes the batch alone,
     otherwise take and union in areas, skip on in-batch collision, stop at
     `n` or end of list). Label this the **recommended batch**: an option to
     present, not the outcome to report.
   - **`data.skipped`** - id + reason for everything not recommended,
     including explicit ceiling-hit reasoning ("asked for 4, took 2" belongs
     here).
   - **`data.ceiling_hit`** - `true` when more legal candidates existed than
     `n` allowed. Surface this explicitly in the report.
   - **`data.alternatives`** - override options (manual mode only; always `[]`
     under `--auto` - an unattended agent cannot knowingly accept a risk on
     someone's behalf). Each names the specific collision it would accept.
   - **`data.requires_user_choice`** - `true` in manual mode; your signal to
     run the picker (step 2) rather than proceeding straight to claiming.

   `blocked` codes to handle:
   - `n_too_large`, `ambiguous_input` - covered under Input above; report and
     stop.
   - `bd_ready_failed` - report and stop.
   - `unverified_filter` - **do not trust a label filter you cannot verify.**
     The script already compares the filtered and unfiltered `bd ready` counts
     whenever a label flag is present; equal counts with a nonempty unfiltered
     set is exactly the symptom of a `bd` flag being silently ignored
     (the `--label-any` exception above). Report the mismatch and stop rather
     than building a candidate table from a set that was never actually
     filtered.

   **Explicit-selection mode** runs through the same candidate table and
   greedy walk as the default form, over exactly the requested ids - the
   largest legal subset ends up in `data.recommended`, with the rest in
   `data.skipped` alongside their reasons (a collision, an epic, unlabeled,
   ...). Present that the same way as any other run.

2. **Present the picker (manual mode).** Show the full candidate table first,
   with these columns, so every constraint - and every subject - is on screen
   before any question is asked:

   | Column | Source | Required |
   |---|---|---|
   | Bead | `id` | always |
   | Title | `title` | always |
   | What it is | `summary` (`-` when null) | always |
   | Pri / Type | `priority`, `issue_type` | always |
   | Areas | `areas` | always |
   | Verdict | `verdict` + `reason` | always |

   **Title and summary are not optional columns and are not dropped for
   width.** The constraint columns (priority, areas, verdict) are what a
   reader can reconstruct from `bd ready`; the subject matter (title,
   summary) is what they cannot. If the table is too wide, wrap the summary,
   do not drop it. "Why did it only take two" is the question this skill will
   be asked most often, and the answer has to be visible before anyone asks
   it. Then offer the choice:

   - Where the **AskUserQuestion** tool is available, use it. Options:
     1. **The recommended batch** (marked as such).
     2. **Legal alternatives**, when meaningfully different from the
        recommendation - explicit-list subsets, sequencing splits.
     3. **Override**: take a bead despite a named live-worktree or in-batch
        collision. The option text names the specific risk it accepts (e.g.
        "take st-qww.7 despite area:skills collision with worktree
        st-abc-slug").

     Every option's text must name what its beads are about, not just their
     ids and areas: one clause per bead, `<id>: <short summary>`, trimmed to
     fit the option's text budget. The override example above names the risk
     but not the subject; state both - "take st-qww.7 (branch-naming
     decision) despite area:skills collision with worktree st-abc-slug".
   - Where it is not available, present the same options as a plain-text list
     and ask for a reply.

   Nothing is claimed until the user picks. Branch-name confirmation (step 3)
   folds into the same presentation.

   **Agent-auto mode:** skip the picker. Take `data.recommended` as-is -
   `collides-with-live-worktree` is already a hard skip alongside
   epic/unlabeled/in-batch-collision inside the script's walk, and
   `data.alternatives` is always empty, so there is no override to consider.
   Explicit-selection input combined with `--auto` takes the largest legal
   subset of the requested ids the same way, and reports the rest as skipped
   without stopping to ask. Print the picked and skipped lists and proceed
   without confirming.

3. **Compute a branch name per bead**: `<id>-<slug>`, the slug 2-4 distinctive
   kebab-case words from the title, not a full transcription. `/new-worktree`
   refuses to guess one, so this skill produces the full name. Manual mode:
   the names ride along in the step 2 presentation, confirmed at the same
   time as the batch choice.

   Each name is fixed at creation and never renamed afterwards, even if the
   branch grows to carry more beads (ADR-0010).

4. **Claim every bead in the chosen batch - all of them, before any worktree
   exists.**
   ```bash
   ruby .claude/scripts/bead.rb claim <id>   # once per bead in the batch
   ```
   The claim is the lock (ADR-0010), and the ordering here is deliberate:
   claimed-with-no-worktree is a cheap, recoverable state
   (`bd update <id> --status open`), while a worktree for an unclaimed bead is
   another agent's collision waiting to happen. If a claim fails
   (`blocked` code `bd_claim_failed` - someone else got there between step 1
   and now), drop that bead from the batch, keep the rest, and say so.

   **If the chosen batch includes an override** (manual mode only - `--auto`
   never takes one), record it on each affected bead at claim time:
   ```bash
   ruby .claude/scripts/bead.rb note <id> "$(date +%F): claimed over area:<x> collision with <worktree/bead> - deliberate override via /next-issues"
   ```
   (`bead.rb note` is append semantics over `bd note`/`bd update
   --append-notes`; never `bd edit`.) This is the record that lets
   `/refresh-worktree` and future selection runs see that the collision was
   accepted on purpose, not missed.

   Then publish the claims (best-effort), once for the batch:
   ```bash
   ruby .claude/scripts/bead.rb sync push
   ```
   Non-fatal if offline (`warnings` only); agents in this checkout's worktrees
   share the DB directly and see the claims regardless.

5. **Stand up a worktree per bead.** For each bead in the batch, invoke:

   **`/new-worktree <id>-<slug> -- /work <id> --auto`**

   which cuts the branch off `main`, warms `deps/`, `_build/` and the PLT,
   verifies the loop profile is green, and opens a tmux window running a Claude
   session seeded on that command. The seed is the same for every bead: sizing
   the job needs the codebase, so `/work` does it in the worktree, not here.

   Worktrees are created **one at a time, in batch order.** Each one clones
   `deps/` and `_build/` from this checkout and then runs a quality gate; running
   several at once contends on the same caches for no gain. If one fails, report
   it, leave its bead claimed, and continue with the rest - a failed worktree is
   not a reason to abandon the ones that worked.

6. **Report the batch.** One row per bead:

   | Bead | Branch | Worktree | tmux window |
   |---|---|---|---|
   | `st-abc` | `st-abc-slug` | `../statifier-ex-worktrees/st-abc-slug` | `st-abc-slug` (`@42`) |

   Then, always and separately:

   - **what was skipped and why**, bead by bead - including "asked for 4, took 2"
     stated as such
   - **what was overridden and why**, bead by bead, when the chosen batch took
     one - the same collision named in the picker, now recorded as accepted
   - any bead left **claimed without a worktree**, with the release command
   - the quality result from each `/new-worktree`
   - a reminder that each issue is worked **inside its own worktree**, in its own
     tmux window - not here

7. **Hand off - do not do any of the work here.** Each seeded session owns its
   issue from this point. This session picked and dispatched; that is the whole
   job.

## Guidelines

- **Manual mode presents, it does not impose.** The picker in step 2 is the
  point of this skill; a run that claims before the user has seen the
  candidate table and chosen among the legal options has skipped the part
  that matters.
- **The candidate table is a menu of work, not a constraint report.** A run
  that presents constraints (priority, areas, verdict) without subjects
  (title, summary) has failed the same way a run that claims before
  presenting has.
- **Claim the whole batch before creating any worktree.** Not per-bead
  claim-then-worktree - that leaves worktrees for beads whose claim later fails.
- Sync steps (0, 4's publish) and cleanup (0.5) are best-effort and must never
  gate a claim. Offline is not a reason to abort a pickup.
- **Areas are about file collision, not subject matter** (docs/workflow.md). Two
  beads both "about the corpus" touching disjoint files are batchable; two beads
  in different subsystems that both edit `mix.exs` are not.
- **An `area:` label is a prediction, written before the work exists.** A batch
  built on a wrong label produces the rebase conflict the labels exist to
  prevent. When `/refresh-worktree` hits one, that is feedback about this skill's
  input, not just a chore.
- **Live worktrees are part of the collision surface, not just the batch being
  formed.** A candidate whose areas are held by another worktree is a
  constraint exactly like an in-batch collision; the only difference is who
  is allowed to override it (a user, deliberately - never `--auto`).
- `n > 4` is refused, not silently clamped. Someone asking for 8 has a wrong
  model of where the constraint is, and clamping hides that. The same applies
  to more than four explicit bead ids.
- Discovered work found while picking is filed with `bd q` (or
  `bead.rb create`) and linked `discovered-from`, not chased now.
- Compose with `/new-worktree`, `/cleanup-worktrees` and `/work` rather than
  duplicating their logic. The only thing that lives here is selection - and
  even selection's mechanics live in `select_batch.rb`; this skill supplies
  the picker.
- Re-verify exact `bd` flags against `bd ready --help` if this drifts. See
  `.claude/scripts/README.md` for the envelope contract shared by every
  script this skill calls.
