# Development workflow

How work moves through this repo: who plans, who implements, how work is tracked,
and how parallel work is coordinated.

## Model roles

Three tiers, used deliberately ([ADR-0007](adr/0007-beads-for-issue-tracking.md) for
the tracking side):

- **Fable - direction.** Architecture, ADRs, spec interpretation questions, corpus
  strategy, review of plans and of finished phases. When a decision would create or
  amend an ADR, it goes through Fable.
- **Opus - planning.** `/wurk:plan` and `/wurk:iterate` run on Opus: turning a
  beads epic into a phased implementation plan with verification steps.
- **Sonnet - implementation.** `/wurk:implement` runs on Sonnet: executing an
  approved plan, keeping `mix quality --profile loop` green while iterating, full
  `mix quality` before commit.

The skills encode these defaults in their frontmatter; an explicit user request
overrides them.

The tiers govern two things, not one: **which model a skill runs on**, and
**which model an orchestrator assigns to a stage it delegates**. `/wurk:work` is the
orchestrator. It runs on Opus and drives the sequence as subagents, assigning
Opus to the research (`/wurk:research`) and planning (`/wurk:plan`) stages
and Sonnet to implementation (`/wurk:implement --loop`) - the same split the
frontmatter already encodes, applied per stage inside one session.

**Frontmatter beats the Agent-call override.** A skill's `model:` applies for
the turn the skill is active, so a Sonnet subagent that invokes `/wurk:plan`
(frontmatter `opus`) runs that skill on Opus regardless of what model the
spawning call passed. The override governs only the subagent's turns *before*
the skill fires - the `bd show`, the file reads, the setup. An orchestrator's
per-stage model must therefore **mirror** the stage skill's frontmatter rather
than contradict it: where the two diverge, the frontmatter is what runs and the
orchestrator's table is simply wrong.

A CLI session is the exception that proves the rule: `model:` does not govern a
session launched with the skill as a prompt argument, which is why
`/wurk:branch` passes `--model opus` explicitly on the `claude` command line.
Whether it stands up a worktree at all is itself a manifest setting -
`parallelism.model` in `.claude/wurk.json` is `worktree-per-issue` here,
distinct from the `branch-in-place` model the generic skill also supports.

`/wurk:work`'s sizing step carries a Direction bucket for ADR-shaped work, spec
interpretation, and corpus strategy, routed to a Fable subagent that has no
stage skill of its own - its prompt is composed directly in `/wurk:work` rather than
dispatched through the Skill tool, since none of the existing skills produce a
decision rather than a plan or an implementation. See the installed
`wurk:work` skill's step 3 for the prompt shape. That prompt genericizes the
project's own convention for one point: statifier ADRs carry no `proposed`
state. They are written directly as `Status: accepted (<date>)`, because a
second status would need something to sweep for drafts that were never
promoted, and the human gate here is the review of the branch the ADR lands
on - not a separate promotion step.

## Issue tracking: beads

All task tracking is `bd` (beads). No markdown TODO lists, no GitHub issues for
working items (GitHub issues become the public intake channel only once the project
is published).

- `bd ready` - find unblocked work; `bd show <id>` before starting.
- Epics mirror the roadmap phases; issues link with dependencies so `bd ready`
  reflects the real build order (parser before interpreter features, etc.).
- Discovered work (a bug found mid-task, an upstream predicator seam) is captured
  with `bd q` immediately, linked with `discovered-from`, and not chased mid-task.
- Predicator/UXID upstream candidates get a `upstream` label so they can be swept
  into the other repos' trackers.
- Every bead that changes files carries an `area:` label; see
  [Area labels](#area-labels) for the vocabulary and the batching rule it exists
  to make mechanical.

## Worktrees and parallel agents

Parallel implementation happens in git worktrees under the sibling folder
`../statifier-ex-worktrees/` (same convention as other riddler projects):

    git worktree add ../statifier-ex-worktrees/<issue-id>-<slug> -b <issue-id>-<slug>

One skill automates the pickup-to-worktree path: `/wurk:next` picks and claims
the next ready bead (`n` defaults to 1; presents choices by default; `--auto`
lets an unattended agent take the top item), then invokes `/wurk:branch`,
which creates the worktree and warms its `deps/`, `_build/`, and dialyzer PLT
from the main checkout so the first quality run is fast.

The picker only picks and claims; it does not size the job. Every seeded session
launches `--model opus` running `/wurk:work <id> --auto`, uniformly, whichever bead
was picked. `/wurk:work` then sizes the job **in the worktree**, where the codebase
is readable rather than merely described, and drives the research / plan /
implement stages as subagents on the tiers above. That is why the seed is a
constant: the decision it used to carry needed a checkout to make.

`/wurk:branch` appends a fixed instruction to every seeded prompt telling the
session to finish with `/wurk:commit --auto` rather than a raw `git commit`, so the
Refs-trailer and unrelated-changes checks in `/wurk:commit` fire even for unattended
sessions.

Passing `n > 1` is the batch form: `/wurk:next` then takes up to `n` ready beads
(default 3, refused above 4) whose [area label](#area-labels) sets are pairwise
disjoint, highest priority first, claims all of them, and then runs
`/wurk:branch` once per bead. `n` is a ceiling, not a target - a short batch
means the rest of the ready queue collided, and the skill reports what it
skipped and why rather than leaving that looking like an empty queue.

Rules that make parallelism safe:

- **One worktree, one branch - usually one issue.** The worktree name carries a
  beads issue ID. Claim the issue (`bd update <id> --claim`) before creating the
  worktree.

  Several small issues touching the same files may share a branch as separate
  commits, one issue per commit. That is often the better split: forcing them
  into parallel worktrees manufactures the rebase conflicts the module
  boundaries exist to prevent. `/wurk:cleanup` closes beads from the
  `Refs:` trailers in the merged PR's commits rather than from the branch name,
  so a branch carrying several closes all of them.

  The name is a label fixed at creation - it names the bead the worktree was
  cut for. When a branch grows to carry several beads, it keeps that name;
  neither the branch nor the worktree directory is renamed. A stale-looking
  name is the expected outcome, because the `Refs:` trailers are what close
  beads (ADR-0010).
- **Beads is the shared state.** The Dolt-backed DB is shared across worktrees, so
  claims, notes, and status changes are visible to every agent immediately. Use
  `bd note` for progress that another agent might need; use merge-slot gates
  (`bd merge-slot`) when several branches will land on the same files.
- **Parallelize across module boundaries, not within them.** Good splits: parser DOM
  vs corpus tooling; one interpreter function-family per plan phase; docs vs code.
  If two ready issues touch the same module, take them sequentially instead. The
  `area:` labels below make that a set intersection rather than a judgment call.
- **Every worktree runs the same gate.** `mix quality --profile loop` while
  iterating, full `mix quality` before the branch is pushed or merged.
- **The gate's own config is not agent-editable** (ADR-0011). The `Gate guard`
  stage fails a full run when the branch changes what the gate checks without an
  entry in `docs/quality-gate-changes.md` naming the file, and `mix gate.verify`
  is how a run proves it was full rather than profiled or scoped.
- **Refresh the survivors when a branch lands.** A worktree is cut from
  `origin/main` and warmed from the main checkout at one moment in time; every
  merge after that leaves it behind. `/wurk:refresh` rebases the live
  worktrees onto the new `origin/main`, repairs `deps/` and the dialyzer PLT if
  `mix.lock` moved, and re-runs the loop profile. Run it after any merge, and
  without fail after one that touched `mix.lock`, `.quality.exs`, or
  `.credo.exs` - those move the gate itself, so an unrefreshed worktree goes red
  for reasons that have nothing to do with the work in it.
- **A rebase conflict is a process signal, not a chore.** It means two branches
  touched the same files, so the split was wrong. `/wurk:refresh` aborts and
  reports rather than resolving; resolve deliberately, one agent at a time,
  behind `bd merge-slot`.
- Merged worktrees are removed promptly; the branch dies with the merge.
  `/wurk:cleanup` automates it, and `/wurk:next` runs it at pickup, which
  is when the previous branch has usually landed.

### Area labels

Every bead that changes files carries at least one `area:` label naming the part
of the tree it touches. A bead may carry several.

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

`area:gate-tooling` is a new row rather than a widened `area:test-harness`: the
two claim different machinery. `area:test-harness` is about running the SCXML
conformance suite - fixtures, the passing-tests baseline, the `test.*` mix
tasks that drive it. `Mix.Statifier.AdrGuard`, `AdrJudge`, `GateGuard`,
`RegressionRegistry` and the `adr.*`/`gate.*` mix tasks that wrap them are the
gate's own enforcement machinery - they do not touch `test/support/**` or
`test/passing_tests.json`, so folding them in would predict collisions that do
not exist. Folding them into `area:build` was also considered, since
`.quality.exs` sits right next to `gate_guard.ex` conceptually: `area:build`
is exclusive because it moves `mix.lock` and the credo config that every
worktree's warmed `_build` depends on, and gate-tooling code does not move
those files, so forcing it to land alone would block batches for no file-level
reason. It gets its own row, not exclusive.

**Two beads are batchable iff their area sets are disjoint.** That is the whole
rule, and it is what lets `/wurk:next` claim several beads at once (`n > 1`)
without a human adjudicating each pair: `bd ready` already filters natively on `-l/--label`,
`--label-any` and `--exclude-label`, so asking for a disjoint set is a flag, not
an analysis.

**`area:build` is exclusive: a bead carrying it batches with nothing** and lands
on `main` alone. It moves `mix.lock` and the credo config that every other
worktree's warmed `_build` and quality gate depend on, so a parallel branch does
not merely conflict with it - it goes red for reasons that have nothing to do
with the work in it (the same failure mode `/wurk:refresh` exists to repair).

Two clarifications that come up:

- **Areas are about file collision, not subject matter.** Two beads both "about
  the corpus" that touch disjoint files are batchable. Two beads in different
  subsystems that both edit `mix.exs` are not. When in doubt, label by the paths
  named in the acceptance criteria.
- **The label is a prediction, deliberately.** It is written before the work
  exists, so it is not derived from a diff and should not be. A branch that ends
  up touching an area it was not labeled with is worth noticing at merge time,
  not silently accepting - it means the split that the batch was built on was
  wrong.

The one class of bead with no area label is work that changes no files in this
repo: the `upstream` beads, whose work happens in predicator. They collide with
nothing here, so an area label on them would block batches for no reason. When
one lands and bumps `mix.lock`, that bump is `area:build` work and gets its own
bead.

## Wurk manifest decisions

A review pass over `.claude/wurk.json`'s remaining schema fields against wurk
`docs/manifest.md`'s "Per-repo starting values" table, recorded so a future
reader can tell "we looked and chose the default" from "nobody looked."

| Field | Decision | Reason |
|---|---|---|
| `rebase.auto_resolve_paths` | Leave absent (feature off) | wurk ADR-0010 biases hard toward stopping, and the validator rejects any entry that is or is under `.claude/`, or that collides with `gate.build_paths`, `also_gated_paths`, `moving_files`, `guard_ledger`, or `parallelism.repair_when`. What is left is `docs/`, and this repo's conflict-prone docs are already per-issue-named - `docs/plans/<date>-<id>-*.md`, `changelog.d/<id>.md`, `docs/research/*` - so two branches do not write the same file (`changelog.d/README.md` states that as the reason fragments exist). wurk allows exactly `docs/plan.md`, a single shared file this repo has no equivalent of. There is no incident to point at here and no file the allowlist would help; opting in would buy model spend and a new failure surface for nothing. |
| `repo.default_branch` | Leave absent | The loader default is `main` and this repo's default branch is `main`. Setting it explicitly changes no behavior at any of the six sites `docs/manifest.md:141-151` lists. |
| `models.direction` | Keep `fable` | Landed by st-4i0, settled against the wu-ubm research; wurk `docs/manifest.md:383-390` records the resolution as yes. Unchanged. |
| `gate.sabotage` | **Add** | Was absent, contrary to wurk's per-repo table. Its absence made `.claude/wurk/commit.md` Step 0 inert. `test_roots: ["test/"]`, `test_pattern: "\btest\s+\""`, `exempt_prefixes: ["test/scion_tests/", "test/scxml_tests/"]` - the last matches `.claude/wurk/commit.md`'s exemption for generated corpus files and `docs/testing.md`'s exemption rule. |
| `gate.attest` | Keep `["mix", "gate.verify"]` | Matches the table; `mix gate.verify` is the tier-2 proof that a run was a full gate rather than a profiled or scoped one (ADR-0011). Unchanged. |
| `gate.guard_ledger` | Keep `docs/quality-gate-changes.md` | Matches the table and matches `Mix.Statifier.GateGuard`'s own `@ledger_path` (`lib/mix/statifier/gate_guard.ex:37`), which is the definition site the kit field has to agree with. Unchanged. |

Deliberately not decided here: `gate.also_gated_paths`, and whether
`.claude/wurk.json` belongs in it, is st-29g's call, still open.

## Merge policy: rebase only

GitHub is configured to allow **rebase merging only**. This is not a style
preference - it determines how every downstream tool detects that a branch
landed, so it is written here rather than left in the repo settings.

Rebase replays a branch's commits onto `main` as new SHAs. The branch tip
therefore **never becomes an ancestor of `main`**, and two things follow:

- **`git branch --merged origin/main` never lists a merged feature branch**, and
  `git merge-base --is-ancestor` never confirms one. Any cleanup or close-on-
  merge automation built on git ancestry silently does nothing, forever, while
  appearing to work. Verified on PRs #2, #3 and #6.
- **`git branch -d` refuses to delete a merged branch**, so deletion needs `-D` -
  which would also discard a genuinely unmerged branch without warning.

So merge detection asks GitHub, never git: `gh pr list --state merged --head
<branch>`. That check is load-bearing for safety, not just for detection, and it
is shared by `/wurk:cleanup` and by the bead close-on-merge trigger.

The upside: rebase preserves every commit and its message, so a branch may carry
as many commits as the work needed. `/wurk:commit --auto` composes cleanly with this
and no squash or cleanup pass is required before opening a PR.

## Change flow

1. Issue exists in beads (epic -> issue, dependencies linked).
2. Plan (Opus) for anything non-trivial; plans live in `docs/plans/` and reference
   the issue ID.
3. Implement (Sonnet) in a worktree; ratchet additions (`mix test.baseline add`)
   ride in the same PR as the feature.

   Steps 2 and 3 are usually reached through `/wurk:work`, the single entry point for
   working a bead: it sizes the job in the worktree and spawns `/wurk:plan`
   and `/wurk:implement --loop` as subagents on the tiers in
   [Model roles](#model-roles), preceded by `/wurk:research` when the blast
   radius is unclear. Invoking either skill directly is still fine for work
   already sized.
4. Sabotage the new tests: break the `lib/` code each one covers, confirm it goes
   red, revert, and record the mutation in a one-line comment above the test
   (`# sabotage: ... -> red`). See
   [Sabotage testing](testing.md#sabotage-testing) for the format and the
   exemptions. This is a real cost in time and it is the step that decides whether
   the internal suite is worth running.
5. If the change is user-facing, write a changelog fragment
   (`changelog.d/<issue-id>.md`); see `changelog.d/README.md` for when one is
   needed. Most changes need none.
6. Full `mix quality` green (a change touching no Elixir code has no gate to run),
   then commit on the worktree branch (`/wurk:commit`, or `/wurk:commit --auto` to skip the
   approval prompt). An agent may take this step on its own - see the authority
   table in `CLAUDE.md`. (`/wurk:implement --loop` performs this step once per
   phase rather than once at the end - see the installed `wurk:implement`
   skill's `## Looped execution mode`.)
7. Push and open a PR against `main` when asked for it (`/wurk:mr`).
   Finishing the work is not itself a request to publish it, so this step and the
   merge keep a human gate.
8. `bd close` once the branch is merged into `origin/main`, not at commit or at
   PR-open time; `bd dolt push` follows, after the git side has reached `origin`.
   `/wurk:cleanup` does both, keyed on the `Refs:` trailers in the merged
   PR's commits, so every bead the branch carried is closed.
9. Remove the merged worktree and let the branch die with the merge (same skill,
   same detection); refresh the surviving worktrees (`/wurk:refresh`).
10. Decisions that surfaced during the work become ADR amendments (Fable).

## Versioning and the changelog

From 2.0.0 on, releases follow SemVer and `CHANGELOG.md` is the upgrade
contract (ADR-0066; the pre-release SHA-pinning contract of ADR-0061 ended
with the 2.0.0 release). Entries are never written into `CHANGELOG.md`
directly during development: each issue drops a fragment in `changelog.d/`,
which keeps concurrent worktrees from conflicting on the same block of the
same file, and a release assembles them into that version's section, deletes
them in the same commit, and tags it (`vX.Y.Z` on the release commit) -
`changelog.d/README.md` is the protocol. A fragment is warranted for any
user-visible change: a public API addition, change, or removal; a change in
observable behavior; an SCXML feature becoming supported; a bug fix a user
could have noticed; anything breaking.

`CHANGELOG.md` carries v1's `0.1.0`-`1.9.0` history (same Hex package
continuing through 2.0.0, so upgraders keep one continuous record). The
`[2.0.0]` section is written as a migration document for 1.x users rather
than a transcript of the rewrite; later sections are ordinary release notes.

Publishing to Hex (`mix hex.publish`) is a human action - the operator holds
the package credentials. A release branch carries the version bump, the
assembled changelog section, the fragment deletions, and the tag-worthy
release commit; the tag itself lands on `main` after the merge.

