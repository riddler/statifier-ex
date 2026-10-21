# Development workflow

**Read this to:** pick up a bead, run it in a worktree, and land it without
colliding with parallel work.

**Short version:** `bd` tracks all work. Each issue gets a worktree. Beads
batch only when their `area:` label sets are disjoint. Merges are rebase-only,
so ask GitHub whether a branch landed, never git.

## Model roles

The repo uses three tiers.
Decision: [ADR-0007](adr/0007-beads-for-issue-tracking.md) (tracking side)

- **Fable (direction).** Architecture, ADRs, spec interpretation questions,
  corpus strategy, and review of plans and of finished phases. A decision that
  would create or amend an ADR goes through Fable.
- **Opus (planning).** `/wurk:plan` and `/wurk:iterate` run on Opus. They turn a
  beads epic into a phased implementation plan with verification steps.
- **Sonnet (implementation).** `/wurk:implement` runs on Sonnet. It executes an
  approved plan. It keeps `mix quality --profile loop` green while it iterates.
  It runs the full `mix quality` before commit.

The skills encode these defaults in their frontmatter. An explicit user request
overrides them. The tiers set the model of a skill and the model that an
orchestrator assigns to a stage it delegates.

`/wurk:work` is the orchestrator. It runs on Opus and drives the sequence as
subagents. It assigns Opus to research (`/wurk:research`) and planning
(`/wurk:plan`). It assigns Sonnet to implementation (`/wurk:implement --loop`).

**Frontmatter beats the Agent-call override.** The `model:` of a skill applies
for the turn in which the skill is active. A Sonnet subagent that invokes
`/wurk:plan` (frontmatter `opus`) runs that skill on Opus. The override governs
only the turns before the skill fires: the `bd show`, the file reads, the setup.
The per-stage model of an orchestrator must therefore match the frontmatter of
the stage skill. Where they differ, the frontmatter runs, and the table of the
orchestrator is wrong.

**CLI sessions.** `model:` does not govern a session that starts with the skill
as a prompt argument. For this reason `/wurk:branch` passes `--model opus`
explicitly on the `claude` command line.

**Worktree setting.** `parallelism.model` in `.claude/wurk.json` decides whether
`/wurk:branch` creates a worktree at all. It is `worktree-per-issue` here. The
generic skill also supports a `branch-in-place` model.

**Direction bucket.** The sizing step of `/wurk:work` has a Direction bucket for
ADR-shaped work, spec interpretation, and corpus strategy. It routes this work to
a Fable subagent.

- This subagent has no stage skill of its own. `/wurk:work` composes its prompt
  directly and does not dispatch it through the Skill tool, because none of the
  existing skills produce a decision. They produce a plan or an implementation.
  The prompt shape is in step 3 of the installed `wurk:work` skill.
- That prompt genericizes the project convention on one point: Statifier ADRs
  carry no `proposed` state. The author writes them directly as
  `Status: accepted (<date>)`. A second status would need something to sweep for
  drafts that were never promoted. The human gate is the review of the branch
  that the ADR lands on, not a separate promotion step.

## Issue tracking: beads

All task tracking uses `bd` (beads). Do not use markdown TODO lists or GitHub
issues for working items. GitHub issues become the public intake channel only
after the project is published.

- **Find work.** Run `bd ready` to find unblocked work. Run `bd show <id>` before
  you start.
- **Epics.** Epics mirror the roadmap phases. Issues link with dependencies, so
  `bd ready` reflects the real build order (parser before interpreter features,
  and so on).
- **Discovered work.** Capture it immediately with `bd q`. Examples are a bug
  found mid-task and an upstream predicator seam. Link it with
  `discovered-from`. Do not chase it mid-task.
- **Upstream candidates.** Give predicator and UXID upstream candidates an
  `upstream` label. The team can then sweep them into the trackers of the other
  repos.
- **Area label.** Every bead that changes files carries an `area:` label. See
  [Area labels](#area-labels) for the vocabulary and the batching rule.

## Worktrees and parallel agents

Parallel implementation happens in git worktrees under the sibling folder
`../statifier-ex-worktrees/` (the same convention as other riddler projects):

    git worktree add ../statifier-ex-worktrees/<issue-id>-<slug> -b <issue-id>-<slug>

One skill automates the path from pickup to worktree:

1. `/wurk:next` picks and claims the next ready bead. `n` defaults to 1. It
   presents choices by default. `--auto` lets an unattended agent take the top
   item.
2. It then invokes `/wurk:branch`. That skill creates the worktree. It warms the
   `deps/`, `_build/`, and dialyzer PLT of the worktree from the main checkout,
   so the first quality run is fast.

The picker does not size the job. Every seeded session launches `--model opus`
running `/wurk:work <id> --auto`, whichever bead was picked. `/wurk:work` then
sizes the job **in the worktree**, where the codebase is readable. It drives the
research, plan, and implement stages as subagents on the tiers above. The seed
is a constant for this reason: the decision that it used to carry needed a
checkout to make.

`/wurk:branch` appends a fixed instruction to every seeded prompt: finish with
`/wurk:commit --auto`, not with a raw `git commit`. The Refs-trailer and
unrelated-changes checks in `/wurk:commit` then fire, also for unattended
sessions.

**Batch form.** `n > 1` takes up to `n` ready beads (default 3, refused above 4)
whose [area label](#area-labels) sets are pairwise disjoint, highest priority
first. `/wurk:next` claims all of them. It then runs `/wurk:branch` once per
bead. `n` is a ceiling, not a target. A short batch means that the rest of the
ready queue collided. The skill reports what it skipped and why, so a short
batch does not look like an empty queue.

Rules that make parallelism safe:

- **One worktree, one branch, usually one issue.** The worktree name carries a
  beads issue ID. Claim the issue (`bd update <id> --claim`) before you create
  the worktree.
  - Several small issues that touch the same files can share a branch as
    separate commits, one issue per commit. This is often the better split.
    Forcing them into parallel worktrees creates the rebase conflicts that the
    module boundaries exist to prevent.
  - `/wurk:cleanup` closes beads from the `Refs:` trailers in the commits of the
    merged PR, not from the branch name. A branch that carries several beads
    closes all of them.
  - The name is fixed at creation. It names the bead that the worktree was cut
    for. Do not rename the branch or the worktree directory when it grows to
    carry several beads. A stale-looking name is expected, because the `Refs:`
    trailers close beads. Decision: ADR-0010.
- **Beads is the shared state.** The Dolt-backed DB is shared across worktrees.
  Claims, notes, and status changes are visible to every agent immediately. Use
  `bd note` for progress that another agent might need. Use `bd merge-slot` when
  several branches will land on the same files.
- **Parallelize across module boundaries, not within them.** Good splits: parser
  DOM and corpus tooling; one interpreter function-family per plan phase; docs
  and code. If two ready issues touch the same module, take them one after the
  other. The `area:` labels below make this a set intersection.
- **Every worktree runs the same gate.** Run `mix quality --profile loop` while
  you iterate. Run the full `mix quality` before you push or merge the branch.
- **The gate's own config is not agent-editable.** The `Gate guard` stage fails a
  full run when the branch changes what the gate checks without an entry in
  `docs/quality-gate-changes.md` that names the file. `mix gate.verify` proves
  that a run was full and not profiled or scoped. Decision: ADR-0011.
- **Refresh the survivors when a branch lands.** A worktree is cut from
  `origin/main` and warmed from the main checkout at one moment in time. Every
  later merge leaves it behind. `/wurk:refresh` rebases the live worktrees onto
  the new `origin/main`. It repairs `deps/` and the dialyzer PLT if `mix.lock`
  moved. It re-runs the loop profile.
  - Run it after any merge.
  - You must run it after a merge that touched `mix.lock`, `.quality.exs`, or
    `.credo.exs`. Those files move the gate itself, so an unrefreshed worktree
    goes red for reasons unrelated to its work.
- **A rebase conflict is a process signal, not a chore.** It means that two
  branches touched the same files, so the split was wrong. `/wurk:refresh` aborts
  and reports. It does not resolve. Resolve the conflict deliberately, one agent
  at a time, behind `bd merge-slot`.
- **Remove merged worktrees promptly.** The branch dies with the merge.
  `/wurk:cleanup` automates this. `/wurk:next` runs it at pickup, when the
  previous branch has usually landed.

### Area labels

Every bead that changes files carries at least one `area:` label. The label names
the part of the tree that the bead touches. A bead can carry several labels.

| Label | Covers |
|---|---|
| `area:interpreter` | `lib/statifier/interpreter/**` |
| `area:parser` | `lib/statifier/parser/**` |
| `area:datamodel` | `lib/statifier/datamodel/**` |
| `area:corpus` | `tools/corpus/**`, `test/scion_tests/**`, `test/scxml_tests/**` |
| `area:test-harness` | `test/support/**`, `lib/mix/tasks/test.*.ex`, `test/passing_tests.json` |
| `area:gate-tooling` | `lib/mix/statifier/**`, `lib/mix/tasks/adr.*.ex`, `lib/mix/tasks/gate.*.ex` |
| `area:skills` | `.claude/wurk.json`, `.claude/wurk/**`, `.claude/settings.json` |
| `area:docs` | `docs/**`, `CLAUDE.md`, `AGENTS.md`, `README.md`, `changelog.d/**` |
| `area:build` | `mix.exs`, `mix.lock`, `.quality.exs`, `.credo.exs`, `.gitignore` |

**Batch rule.** Two beads are batchable if and only if their area sets are
disjoint. This is the whole rule. It lets `/wurk:next` claim several beads at
once (`n > 1`) without a human who adjudicates each pair. `bd ready` already
filters natively on `-l/--label`, `--label-any`, and `--exclude-label`. A request
for a disjoint set is a flag, not an analysis.

**`area:build` is exclusive.** A bead that carries it batches with nothing and
lands on `main` alone. It moves `mix.lock` and the credo config. The warmed
`_build` and the quality gate of every other worktree depend on both. A parallel
branch does not only conflict with it. It goes red for reasons unrelated to its
work. `/wurk:refresh` repairs this failure.

**Why `area:gate-tooling` is separate.**

- It is not part of `area:test-harness`. That area covers the run of the SCXML
  conformance suite: fixtures, the passing-tests baseline, and the `test.*` mix
  tasks. `Mix.Statifier.AdrGuard`, `AdrJudge`, `GateGuard`, `RegressionRegistry`,
  and the `adr.*` and `gate.*` mix tasks that wrap them are gate machinery. They
  do not touch `test/support/**` or `test/passing_tests.json`. A merged area
  would predict collisions that do not exist.
- It is not part of `area:build`, although `.quality.exs` is conceptually next
  to `gate_guard.ex`. Gate-tooling code does not move `mix.lock` or the credo
  config. Making it exclusive would block batches for no file-level reason.

**Two clarifications:**

- **Areas are about file collision, not subject matter.** Two beads that are both
  "about the corpus" and touch disjoint files are batchable. Two beads in
  different subsystems that both edit `mix.exs` are not batchable. When in doubt,
  label by the paths that the acceptance criteria name.
- **The label is a prediction.** The author writes it before the work exists. It
  is not derived from a diff and must not be. At merge time, check whether a
  branch touches an area that it was not labeled with. If it does, the split of
  the batch was wrong.

**No area label.** `upstream` beads change no files in this repo. Their work
happens in predicator. They collide with nothing here, so they carry no area
label. A label on them would block batches for no reason. When such a bead lands and bumps `mix.lock`, that bump is `area:build`
work and gets its own bead.

## Wurk manifest decisions

This section records a review of the remaining schema fields of
`.claude/wurk.json` against the "Per-repo starting values" table in wurk
`docs/manifest.md`. It lets a future reader tell "we looked and chose the
default" from "nobody looked".

| Field | Decision | Reason |
|---|---|---|
| `rebase.auto_resolve_paths` | Leave absent (feature off) | wurk ADR-0010 biases hard toward stopping. The validator rejects any entry that is or is under `.claude/`, or that collides with `gate.build_paths`, `also_gated_paths`, `moving_files`, `guard_ledger`, or `parallelism.repair_when`. What is left is `docs/`. This repo's conflict-prone docs are already per-issue-named (`docs/plans/<date>-<id>-*.md`, `changelog.d/<id>.md`, `docs/research/*`), so two branches do not write the same file. wurk allows exactly `docs/plan.md`, a shared file this repo has no equivalent of. Opting in would buy model spend and a new failure surface for nothing. |
| `repo.default_branch` | Leave absent | The loader default is `main` and this repo's default branch is `main`. Setting it explicitly changes no behavior at any of the six sites `docs/manifest.md:141-151` lists. |
| `models.direction` | Keep `fable` | Landed by st-4i0, settled against the wu-ubm research; wurk `docs/manifest.md:383-390` records the resolution as yes. Unchanged. |
| `gate.sabotage` | **Add** | Was absent, contrary to wurk's per-repo table, which made `.claude/wurk/commit.md` Step 0 inert. `test_roots: ["test/"]`, `test_pattern: "\btest\s+\""`, `exempt_prefixes: ["test/scion_tests/", "test/scxml_tests/"]` - the last matches the exemption for generated corpus files in `.claude/wurk/commit.md` and `docs/testing.md`. |
| `gate.attest` | Keep `["mix", "gate.verify"]` | Matches the table; `mix gate.verify` is the tier-2 proof that a run was a full gate rather than a profiled or scoped one (ADR-0011). Unchanged. |
| `gate.guard_ledger` | Keep `docs/quality-gate-changes.md` | Matches the table and matches `Mix.Statifier.GateGuard`'s own `@ledger_path` (`lib/mix/statifier/gate_guard.ex:37`), which is the definition site the kit field has to agree with. Unchanged. |

This section does not decide `gate.also_gated_paths`, or whether
`.claude/wurk.json` belongs in it. That is the decision of st-29g and is still
open.

## Merge policy: rebase only

GitHub allows **rebase merging only**. This is not a style preference. It
determines how every downstream tool detects that a branch landed, so this
document records it and does not leave it in the repo settings.

Rebase replays the commits of a branch onto `main` as new SHAs. The branch tip
therefore **never becomes an ancestor of `main`**. Two results follow:

- **`git branch --merged origin/main` never lists a merged feature branch,** and
  `git merge-base --is-ancestor` never confirms one. Automation built on git
  ancestry silently does nothing, forever, while it appears to work. Verified on PRs #2, #3 and #6.
- **`git branch -d` refuses to delete a merged branch,** so deletion needs `-D`.
  `-D` also discards a branch that is genuinely unmerged, without warning.

Merge detection therefore asks GitHub and never git:
`gh pr list --state merged --head <branch>`. This check is required for safety,
not only for detection. `/wurk:cleanup` and the bead close-on-merge trigger share
it.

Rebase preserves every commit and its message. A branch can carry as many
commits as the work needed. `/wurk:commit --auto` works well with this. No squash or cleanup pass is required before you
open a PR.

## Change flow

1. **Issue.** The issue exists in beads (epic -> issue, dependencies linked).
2. **Plan (Opus).** Plan anything non-trivial. Plans live in `docs/plans/` and
   reference the issue ID.
3. **Implement (Sonnet).** Work in a worktree. Ratchet additions
   (`mix test.baseline add`) go in the same PR as the feature.
   - `/wurk:work` is the single entry point for steps 2 and 3. It sizes the job
     in the worktree. It spawns `/wurk:plan` and `/wurk:implement --loop` as
     subagents on the tiers in [Model roles](#model-roles). It runs
     `/wurk:research` first when the blast radius is unclear.
   - You can still invoke either skill directly for work that is already sized.
4. **Sabotage the new tests.** Break the `lib/` code that each one covers. Confirm
   that the test goes red. Revert. Record the mutation in a one-line comment above
   the test (`# sabotage: ... -> red`). See
   [Sabotage testing](testing.md#sabotage-testing) for the format and the
   exemptions. This step costs real time. It decides whether the internal suite
   is worth running.
5. **Changelog.** If the change is user-facing, write a fragment
   (`changelog.d/<issue-id>.md`). Most changes need none. See
   `changelog.d/README.md` for when a fragment is needed.
6. **Commit.** Run the full `mix quality` until it is green (a change that
   touches no Elixir code has no gate to run). Then commit on the worktree branch
   (`/wurk:commit`, or `/wurk:commit --auto` to skip the approval prompt).
   - An agent can take this step on its own. See the authority table in
     `CLAUDE.md`.
   - `/wurk:implement --loop` performs this step once per phase, not once at the
     end. See `## Looped execution mode` in the installed `wurk:implement` skill.
7. **Push and PR.** When asked, push and open a PR against `main` (`/wurk:mr`).
   Finishing the work is not a request to publish it. This step and the merge
   keep a human gate.
8. **Close.** Run `bd close` after the branch is merged into `origin/main`. Do
   not run it at commit time or at PR-open time. `bd dolt push` follows, after the
   git side has reached `origin`. `/wurk:cleanup` does both. It keys on the
   `Refs:` trailers in the commits of the merged PR, so it closes every bead that
   the branch carried.
9. **Clean up.** Remove the merged worktree and let the branch die with the merge
   (same skill, same detection). Refresh the surviving worktrees
   (`/wurk:refresh`).
10. **Record decisions.** Decisions that surfaced during the work become ADR
    amendments (Fable).

## Versioning and the changelog

From 2.0.0 on, releases follow SemVer and `CHANGELOG.md` is the upgrade
contract.
Decision: ADR-0066. ADR-0061's pre-release SHA-pinning contract ended with the
2.0.0 release.

Do not write entries into `CHANGELOG.md` during development. Each issue drops a
fragment in `changelog.d/`, so concurrent worktrees do not conflict on the same
block. `changelog.d/README.md` is the protocol. A release does these steps:

1. It assembles the fragments into the section of that version.
2. It deletes the fragments in the same commit.
3. It tags the release commit (`vX.Y.Z`).

A fragment is needed for any user-visible change:

- a public API addition, change, or removal
- a change in observable behavior
- an SCXML feature that becomes supported
- a bug fix that a user could have noticed
- anything breaking

`CHANGELOG.md` carries the `0.1.0` to `1.9.0` history, because the Hex package
is the same through 2.0.0, so upgraders keep one continuous record. The
`[2.0.0]` section is a migration document for 1.x users, not a transcript of
the rewrite. Later sections are ordinary release notes.

The release workflow publishes to Hex on the tag push. An agent or a session
never runs `mix hex.publish`. Re-run a failed workflow from its Actions page. A
release branch carries the version bump, the assembled changelog section, the
fragment deletions, and the release commit. The tag lands on `main` after the
merge. Decision: ADR-0077.
