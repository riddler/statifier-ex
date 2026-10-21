# Family reference: what the sibling repos copy from here

**Read this to:** decide what to copy from this repo into a sibling repo, and
what to rewrite or leave out.
**Short version:** copy the `CLAUDE.md` shell-command section and the
ExQuality block verbatim. Adapt the authority, beads, and `.claude/wurk/`
sections. Copy none of the custom gate stages. Point `gate.attest` at
`mix quality.verify`.

This repo is the reference for the agent-facing conventions of the family:
`CLAUDE.md`, `.claude/wurk/`, and the quality-gate documentation. The copies
drift, so this document states what to copy.

The family is **seven published packages across seven repos**: `statifier`
(this repo), `predicator`, `statifier_ui`, `statifier_persistence`,
`statifier_oban`, `opentelemetry_statifier`, and `statifier_blocks`. All seven
are on Hex as of 2026-08-27.

Beads in the other repos say some version of "copy statifier-ex's, adapted
down". That instruction is safe only if this document records what to copy and
what not to copy. Cite this document from those beads. Do not name this repo
and hope.

## The two markings

- **copy-verbatim.** The text is the artifact. An adopting repo takes it byte
  for byte and changes nothing. A later diff between this repo and an adopter
  is drift. Reconcile it in the direction that the reasoning points.
- **adapt-per-repo.** The *structure* is the reference and the *content* is
  not. An adopter keeps the shape and rewrites the specifics. If an adopter
  copies the words, it silently changes something that it decided for itself.

A third marking is **not reference**. Such a section is machinery for this repo
only. An adopter that copies it takes on machinery that it has nothing to
protect with.

## The sections

| Section | Where | Marking |
|---|---|---|
| Agent authority in this repo | `CLAUDE.md` | reference, adapt-per-repo |
| Beads that span repositories | `CLAUDE.md` | reference, adapt-per-repo |
| Non-interactive shell commands | `CLAUDE.md` | reference, copy-verbatim |
| ExQuality (`mix quality`) marker block | `CLAUDE.md` | reference, copy-verbatim |
| The `deps/ex_quality/usage-rules.md` pointer | `CLAUDE.md`, inside that block | reference, copy-verbatim |
| The `.claude/wurk/` extension mechanism | `.claude/wurk/*.md` | reference, adapt-per-repo |
| The `gate.attest` manifest key | `.claude/wurk.json` | reference, adapt-per-repo - point it at ex_quality's `mix quality.verify`; see the caveat |
| `mix gate.verify` (this repo's local task) | `lib/mix/tasks/gate.verify.ex` | **not reference** - superseded upstream; see the caveat |
| The gate guard (`mix gate.check`) and its `guard_ledger` | `lib/mix/`, `.claude/wurk.json`, `docs/quality-gate-changes.md` | **not reference** |
| The ADR guard and the ADR judge | `lib/mix/` | **not reference** |
| The regression ratchet | `lib/mix/`, `test/passing_tests.json` | **not reference** |
| Which skipped stages are gaps and which will never apply | `CLAUDE.md` | **not reference** |

### Agent authority in this repo - adapt-per-repo

This section shows why the distinction matters. A verbatim copy does real
damage here.

**Two kinds of grant.**

| Kind | Repos |
|---|---|
| Standing team-maintainer grant | this repo, predicator-ex, statifier-ui |
| Consent-scoped grant | statifier_persistence, statifier_oban, opentelemetry_statifier, statifier_blocks |

A consent-scoped grant lets an agent commit, push, and open requests only
inside an orchestrated campaign that carries the explicit consent of the user
for that campaign.

- Copying this section into a consent-scoped repo silently widens its grant to
  standing.
- Copying the section of a consent-scoped repo into this repo silently
  narrows the grant.
- An agent must not make either change. Only the user can widen the section
  and record it.
- The split does not follow package maturity. statifier_blocks was added as
  consent-scoped at 0.1.0. Publication on Hex did not promote the other three.
  Read the kind of grant from the `CLAUDE.md` of the repo. Do not infer it
  from the release state.

**What all seven repos share.** The structure is the reference:

- The per-action table. Each row has a trigger and a "still unauthorized when"
  column.
- The anti-inference paragraph. Resemblance is not firing. The dispatch of
  another agent is not the words of the user.
- The two override paragraphs. A current "do not commit" or "do not push"
  instruction wins outright. Authority belongs to the session that owns the
  work, not to a subagent that the session delegates to.
- The reversibility principle. The human gate belongs where an action stops
  being reversible. It explains why the rows fall where they do.
- The closing line. Widening the section is a decision for the user to record.
  An agent can draft the change but cannot adopt it.

**An adopter must change:**

- The opening sentence that names the kind of grant.
- Every trigger in the table.
- The release/version-bump row, where the repo has one.

**Example to copy the structure from.** Use the `CLAUDE.md` of
`statifier_persistence` on its `main` branch. `riddler/statifier_persistence`
request #3 added it, and request #5 refined it. Read it from the branch, not
from a commit SHA. Non-fast-forward merges orphaned two SHAs that were written
down during the campaign of 2026-08-21.

### Beads that span repositories - adapt-per-repo

The reference is the `mirrors:` discipline:

- Both halves carry the line first in the description.
- The repository whose files change owns the decision.
- An unrefreshed reconciliation note is not a defect. Acting on one is a
  defect.
- A `mirrors:` id that no longer resolves is broken immediately. It is not
  stale.

An adopter must change:

- Which trackers touch the repo.
- Which artifacts the repo owns the decision for.
- The ADR citation.

The `upstream`-bead and `--external-ref` row applies to work in a monorepo that
this repo tracks. Do not copy it to other repos.

### Non-interactive shell commands - copy-verbatim

This section has no project-specific content. It covers `cp -f`, `mv -f`,
`rm -f`, `ssh -o BatchMode=yes`, and the rule to avoid `bd edit` because it
blocks on `$EDITOR`. Take it as it is.

### ExQuality (`mix quality`) and the usage-rules pointer - copy-verbatim

The marker-delimited block (`<!-- usage-rules-start -->` to
`<!-- usage-rules-end -->`) and the `deps/ex_quality/usage-rules.md` pointer at
its head are the same text in every repo that depends on ex_quality. The copy
in statifier-ui is byte-identical to this one today. This is the correct state.

- The dependency syncs the block, so an adopter takes the whole block.
- Do not paraphrase the four rules. A paraphrase makes a later sync look like
  a conflict.
- The pointer is the important part. An agent that needs the JSON report shape,
  or an explanation of a stage failure, reads the reference of the dependency.
  That reference matches the installed version of ex_quality.
- Every repo should adopt the block. It is the cheapest of these items.

An adopter must change nothing, except to depend on ex_quality.

### The `.claude/wurk/` extension mechanism - adapt-per-repo

The reference is the contract, stated in `CLAUDE.md`:

- `.claude/wurk.json` is the manifest. The generic `wurk:*` skills read it for
  every project-specific value.
- `.claude/wurk/<skill>.md` holds the judgment calls that only this project
  needs. It is **additive to and never overriding** the generic skill.

Decision: ADR-0016, ADR-0017. The contract holds in every repo.

The set of override files in a repo is not the reference. Do not level the
repos up to match. As of 2026-08-27, the counts are:

| Repo | Override files |
|---|---|
| predicator-ex | 12 |
| statifier-ex (this repo) | 7 |
| statifier-ui | 3 |
| statifier_persistence | 2 |
| statifier_oban | 2 |
| opentelemetry_statifier | 2 |
| statifier_blocks | 0 |

All of these counts are legitimate. An override has a place when the repo has a
judgment call that the generic skill cannot make. A repo with no such call
correctly has no file. If you copy an override across repos, you import a
judgment about another codebase.

Treat these numbers as a snapshot of the spread, not as a target. They go stale
sooner than anything else in this document. A count that is off by one is not a
finding.

An adopter must change everything inside the files. Two examples from this
repo:

- `mr.md` runs `mix quality --profile merge` for an ADR judge that no other
  repo has.
- `commit.md` has the v2/v1 changelog narrowing, which is a fact about the
  release state of this package.

## The custom gate stages are not the reference

Do not copy these items:

- the gate guard
- the ADR guard
- the ADR judge
- the regression ratchet
- `mix gate.check` with its `guard_ledger`

They protect a conformance corpus and an accepted ADR set that the other repos
do not have. The `.quality.exs` files of four repos (statifier_persistence,
statifier_oban, opentelemetry_statifier, and statifier_blocks) each carry a
comment. It says their gate is deliberately smaller than this one, for this
reason. **That decision stands.** This document does not reverse it. Nothing
here allows an adopter to adopt one of those stages by default. If a repo has
something for a stage to protect, adopting the stage is a decision to record.

`### Which skipped stages are gaps and which will never apply` is not reference
for the same reason. Its `gate.not_applicable_skips` patterns make claims about
*this* project:

- Gettext never applies to an SCXML engine library.
- `^disabled in \.quality\.exs$` matches only the ADR judge today.

A repo that copies these patterns asserts things that it has not checked. The
rule behind them does travel: to add a pattern to either list, write the
reason on the same branch.

Decision: ADR-0017 point 6.

### Attestation is the one exception - and it now lives upstream

**Do not copy `gate.verify.ex`. Point `gate.attest` at the `mix quality.verify`
task of ex_quality.** This is the whole instruction. The rest of this section
gives the reasons.

**Why attestation matters.** The wurk pipeline sets `attested: false` when a
project declares no attestation command. `/wurk:commit` then refuses to
proceed. A repo without attestation has a broken unattended commit path. This
is a mechanical problem, not a stylistic one. On 2026-08-22, the user ruled
that the other repos adopt attestation. The beads are px-591, sui-4py, sp-7cu,
sob-ehl, and ots-4l6.

**Why it is an exception.**

- `mix gate.check` is the config-change guard. It knows the guarded paths, the
  ledger, and the corpus registry of this repo. It is repo-specific machinery
  by construction.
- Attestation is a generic reader of the *own* report of ex_quality. It checks
  that the report has status ok, no profile, scope all, and no stage skipped
  for a reason that narrows the run. It has no statifier-ex specifics: no
  corpus, no ADRs, no ledger.
- Attestation **adds no stage to `.quality.exs`**. The statement "deliberately
  smaller than statifier-ex's gate" stays true in those repos after adoption.

**The current instruction: set `gate.attest` to `["mix", "quality.verify"]`.**
ex_quality 0.14 ships `Mix.Tasks.Quality.Verify`. Any repo on that version
already has the task and needs no local copy.

| Repo | `gate.attest` today | Action |
|---|---|---|
| statifier_persistence, statifier_oban, opentelemetry_statifier | `mix quality.verify` | none |
| this repo, predicator-ex | local `mix gate.verify` (legacy wiring, not a second approved pattern) | move to `quality.verify`. Do not copy the `.claude/wurk.json` of this repo for this key |
| statifier-ui, statifier_blocks | not declared | the unattended commit path is broken. This document names the problem. It does not allow you to fix it in passing. The change belongs to those repos and their own beads |

Bead `st-wgr0` planned the extraction of the task. It is **closed**. The
earlier advice to expect the local copy to be temporary no longer applies.

**The historical caveat (st-hcgl, closed 2026-08-22) no longer applies. You
must still understand why.**

- The problem. A consumer that takes statifier as a **git dep** compiles the
  whole `lib/` of this repo into its build. `Mix.Tasks.Gate.Verify` then lands
  on the code path of the consumer, whether or not its `.quality.exs` calls it.
  A verbatim local copy redefines a module that is already on the path. This
  causes a "redefining module" warning. `warnings_as_errors` turns the warning
  into a red gate. The four consumer adoptions hit this collision on
  2026-08-22/23.
- Why it is gone. First, ADR-0066 published 2.0.0 and ended the SHA-pinning
  contract that ADR-0061 had set up "pending Hex". Every sibling that depends
  on statifier (statifier-ui, statifier_persistence, statifier_oban,
  opentelemetry_statifier, statifier_blocks) now takes it from Hex as
  `{:statifier, "~> 2.x"}`. Second, the `files:` list of the Hex package
  excludes `lib/mix`, so a Hex consumer never sees these tasks.
- Cite ADR-0066 for the current state. ADR-0061 is the superseded record, and
  its git-dep pin is not a live instruction.

**One edge case remains.** It is the same hazard in a different form. The
`mix.exs` of each sibling keeps a `STATIFIER_PATH` escape hatch. It swaps the
Hex dep for `path:` with `override: true`. A path dep compiles the whole
checkout, including `lib/mix`. The collision condition returns for anyone who
works with that variable set.

Today it cannot occur, but only because no statifier consumer keeps a local
copy of these tasks to collide with. This follows from the instruction at the
top of this section. It is not an independent guarantee. predicator-ex keeps a
local `gate.verify.ex`, but it does not depend on statifier, so it has nothing
to collide with either. Follow the instruction and the edge case stays closed.

## What is not reference and never was

These files are per-repo configuration. Do not copy their text:
`.claude/wurk.json`, `mise.toml`, `.quality.exs`, `.credo.exs`, and the CI
workflow. A repo that standardizes on this one must end with the same *keys*
that it needs and its own *values*. The markings above apply to prose and to
`gate.verify.ex`. They say nothing about config files, except for the
`gate.attest` key named in the exception.

### Two CI rules that are not reference either, but are worth stating

The CI workflow stays per-repo configuration. Two rules came from the fleet
campaigns of 2026-08. Neither is obvious from a workflow file alone.

**Run the gate in the env that the gate tooling is defined for.** A workflow
that sets a global `MIX_ENV` can silently remove the gate task from the build
that it must protect. The gate workflow of predicator-ex set `MIX_ENV=test`
globally, and ex_quality is `only: :dev`. The gate task did not exist in that
CI environment. The first live run found the gap. Reading the workflow did
not. The workflow of statifier-ui avoids this trap because it sets no
`MIX_ENV`. This is the safer default when the gate tooling is a dev-only
dependency.

**Verify the CI trigger for stacked requests on a live request.** Stacked
requests are requests based on non-default branches. Verify the behavior per
repo. Do not assert it from a reading of the workflow file. A campaign report
claimed that stacked requests get no CI run in one repo. The next stacked
request in that repo ran CI. The workflow file describes what the repo asked
the forge to do. It does not describe what the forge triggers. Only a live
request shows which one is true.
