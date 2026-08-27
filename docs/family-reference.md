# Family reference: what the sibling repos copy from here

This repo is the de-facto reference for the family's agent-facing conventions -
`CLAUDE.md`, `.claude/wurk/`, and the quality-gate documentation. That status
was implicit until it was written down here, and the copies drift, so what to
copy needs stating rather than inferring.

The family is **seven published packages across seven repos**: `statifier`
(this repo), `predicator`, `statifier_ui`, `statifier_persistence`,
`statifier_oban`, `opentelemetry_statifier`, and `statifier_blocks`. All seven
are on Hex as of 2026-08-27, which is the single fact that most changes how
this document reads - see "Attestation is the one exception" below, whose
entire premise used to be that they were not.

Beads in the other repos say some version of "copy statifier-ex's, adapted
down". That instruction is only safe if what to copy - and what **not** to
copy - is written down rather than inferred by whoever reads the file next.
This document is that record. Cite it from those beads instead of naming this
repo and hoping.

## The two markings

- **copy-verbatim** - the text is the artifact. An adopting repo takes it byte
  for byte and changes nothing. A later diff between this repo's copy and an
  adopter's is drift to reconcile, in whichever direction the reasoning points.
- **adapt-per-repo** - the *structure* is the reference and the *content* is
  not. An adopter keeps the shape and rewrites the specifics. Copying the words
  here silently changes something the adopting repo decided for itself, which
  is the failure this document exists to prevent.

A third marking is just as load-bearing: **not reference**. A section marked so
is repo-specific machinery, and an adopter that copies it has taken on
machinery it has nothing to protect with.

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

This is the worked example of why the distinction matters, and the one section
where copying verbatim does real damage.

**This repo holds a standing team-maintainer grant**, as do predicator-ex and
statifier-ui. statifier_persistence, statifier_oban, opentelemetry_statifier
and statifier_blocks hold a **consent-scoped** grant: authority to commit, push
and open requests exists only inside an orchestrated campaign carrying the
user's explicit consent for that campaign, and nowhere else. Copying this
repo's section into one of those four would silently widen it to standing.
Copying one of theirs back into here would silently narrow it. Neither change
is one an agent may make; widening is the user's call to make and record, as
the section itself says.

The split is three standing to four consent-scoped, and it does not track
package maturity - statifier_blocks was added consent-scoped at 0.1.0, and
being on Hex did not promote the other three. Read the grant kind from the
repo's own `CLAUDE.md`, never from its release state.

What **is** common across all seven repos, and is the actual reference, is the
structure:

- the per-action table, with a trigger and a "still unauthorized when" column
  for every row;
- the anti-inference paragraph - resemblance is not firing, and another
  agent's dispatch is not the user's own words;
- the two override paragraphs - a current "do not commit"/"do not push" wins
  outright, and authority belongs to the session that owns the work rather
  than to a subagent it delegates to;
- the reversibility principle, which says *why* the rows fall where they do:
  the human gate belongs where an action stops being reversible;
- the closing line that widening the section is the user's decision to record,
  which an agent may draft but not adopt.

An adopter must change: the opening sentence naming the grant's kind, every
trigger in the table, and the release/version-bump row where the repo has one.
The consent-scoped exemplar to copy the structure from is
`statifier_persistence`'s `CLAUDE.md` on its `main` branch, added by
`riddler/statifier_persistence` request #3 and refined by request #5. Read it
from the branch rather than from a commit SHA - two SHAs written down during
the 2026-08-21 campaign were orphaned by non-fast-forward merges.

### Beads that span repositories - adapt-per-repo

The reference is the `mirrors:` discipline: both halves carry the line first in
the description, the repository whose files change owns the decision, an
unrefreshed reconciliation note is not a defect but acting on one is, and a
`mirrors:` id that no longer resolves is broken immediately rather than stale.

An adopter must change: which trackers touch the repo, which artifacts it owns
the decision for, and the ADR citation. The `upstream`-bead and
`--external-ref` row is specific to work happening in a monorepo this repo
tracks, and does not travel.

### Non-interactive shell commands - copy-verbatim

Nothing in it is project-specific: `cp -f`, `mv -f`, `rm -f`, `ssh -o
BatchMode=yes`, and avoiding `bd edit` because it blocks on `$EDITOR`. Take it
as it stands.

### ExQuality (`mix quality`) and the usage-rules pointer - copy-verbatim

The marker-delimited block (`<!-- usage-rules-start -->` to
`<!-- usage-rules-end -->`) and the `deps/ex_quality/usage-rules.md` pointer at
its head are the same text in every repo that depends on ex_quality;
statifier-ui's copy is byte-identical to this one today, and that is the
correct state. The block is synced from the dependency, so an adopter takes it
whole rather than paraphrasing the four rules - a paraphrase is what makes a
later sync look like a conflict.

The pointer itself is the point: an agent that needs the JSON report shape or
an unexplained stage failure reads the dependency's own reference, which
travels with the version of ex_quality actually installed. Adopting the block
is therefore the cheapest of these items and the one every repo should have.

An adopter must change: nothing, beyond depending on ex_quality.

### The `.claude/wurk/` extension mechanism - adapt-per-repo

The reference is the contract, stated in `CLAUDE.md`: `.claude/wurk.json` is
the manifest the generic `wurk:*` skills read for every project-specific value,
and `.claude/wurk/<skill>.md` holds the judgment calls only this project needs,
**additive to and never overriding** the generic skill. That contract is
ADR-0016 and ADR-0017 and it holds everywhere.

Which override files a repo has is not the reference and should not be levelled
up to match. The spread as of 2026-08-27 is twelve in predicator-ex, seven
here, three in statifier-ui, two each in statifier_persistence,
statifier_oban and opentelemetry_statifier, and none in statifier_blocks - all
legitimate. An override earns its place when the repo has a judgment call the
generic skill genuinely cannot make, and a repo with no such call is correct to
have no file. Copying an override across imports a judgment about another
codebase.

Treat those numbers as a snapshot illustrating the spread, not a target. They
are the one thing in this document guaranteed to go stale, and a count drifting
by one is not by itself a finding.

An adopter must change: everything inside the files. This repo's `mr.md` runs
`mix quality --profile merge` for an ADR judge no other repo has, and its
`commit.md` carries the v2/v1 changelog narrowing, which is a fact about this
package's release state.

## The custom gate stages are not the reference

The gate guard, the ADR guard, the ADR judge, the regression ratchet, and
`mix gate.check` with its `guard_ledger` are **out of scope for copying**. They
exist to protect a conformance corpus and an accepted ADR set that the other
repos do not have. Four repos' `.quality.exs` files - statifier_persistence,
statifier_oban, opentelemetry_statifier and statifier_blocks - each carry a
comment saying their gate is deliberately smaller than this one for exactly
that reason, and **that decision stands**. This document does not reverse it,
and nothing here is licence to adopt one of those stages by default; adopting
one is a decision to record when there is something for it to protect.

`### Which skipped stages are gaps and which will never apply` is not reference
for the same reason. Its `gate.not_applicable_skips` patterns encode claims
about *this* project - that gettext will never apply to an SCXML engine
library, and that `^disabled in \.quality\.exs$` today matches only the ADR
judge. A repo that copied those patterns would be asserting things it has not
checked. What does travel is ADR-0017 point 6's rule behind it: adding a
pattern to either list means writing the reason down on the same branch.

### Attestation is the one exception - and it now lives upstream

**Do not copy `gate.verify.ex`. Point `gate.attest` at ex_quality's own
`mix quality.verify` instead.** That is the whole instruction; the rest of this
section is why, and what the older advice said before it was overtaken.

The user ruled on 2026-08-22 that the other repos adopt attestation - beads
px-591, sui-4py, sp-7cu, sob-ehl and ots-4l6. What they adopt has since
changed.

Attestation matters because the wurk pipeline sets `attested: false` when a
project declares no attestation command, and `/wurk:commit` then refuses to
proceed. A repo without it has a broken unattended commit path, which is a
mechanical problem rather than a stylistic one.

The line between attestation and `mix gate.check` is the reasoning that made it
an exception at all. `gate.check` is the config-change guard: it knows this
repo's guarded paths, its ledger, and its corpus registry, and it is
repo-specific machinery by construction. Attestation is a generic reader of
ex_quality's *own* report - it checks the report for status ok, no profile,
scope all, and no stage skipped for a run-narrowing reason. It contains no
statifier-ex specifics: no corpus, no ADRs, no ledger.

It also **adds no stage to `.quality.exs`**, so the "deliberately smaller than
statifier-ex's gate" statement in those repos stays true after adoption. That
is what makes it an exception rather than a hole in the paragraph above.

**The current instruction: wire `gate.attest` to `["mix", "quality.verify"]`.**
ex_quality 0.14 ships `Mix.Tasks.Quality.Verify`, so any repo on that version
already has the task and needs no local copy of anything.
statifier_persistence, statifier_oban and opentelemetry_statifier are wired
this way today. Bead `st-wgr0`, which planned the extraction, is **closed** -
the "expect this to be temporary" advice that used to sit here has been
overtaken by its own fix landing.

Two repos still point `gate.attest` at a local `mix gate.verify`: this one and
predicator-ex. That is legacy wiring, not a second sanctioned pattern - both
should move to `quality.verify`. Do not read this repo's `.claude/wurk.json` as
the example to copy on this key.

statifier-ui and statifier_blocks declare no `gate.attest` at all, which means
their unattended commit path is the broken one the paragraph above describes.
Naming it here is not a licence to fix it in passing: it is a change to those
repos, and belongs to their own beads.

**The historical caveat (st-hcgl, closed 2026-08-22) no longer applies, and
knowing why matters.** The problem it recorded was that a consumer taking
statifier as a **git dep** compiles this repo's entire `lib/` into its build,
so `Mix.Tasks.Gate.Verify` lands on the consumer's code path whether or not its
`.quality.exs` calls it. A verbatim local copy then redefines a module already
on that path: a "redefining module" warning, promoted to a red gate by
`warnings_as_errors`. That is the collision the four consumer adoptions hit on
2026-08-22/23.

Its premise is now gone twice over. ADR-0066 published 2.0.0 and ended the
SHA-pinning contract ADR-0061 had set up "pending Hex", and every sibling that
depends on statifier - statifier-ui, statifier_persistence, statifier_oban,
opentelemetry_statifier and statifier_blocks - now takes it from Hex as
`{:statifier, "~> 2.x"}` rather than as a git dep. The Hex
package's `files:` list excludes `lib/mix`, so a Hex consumer never sees these
tasks at all. Cite ADR-0066 for the current state; ADR-0061 is the superseded
record and its git-dep pin is not a live instruction.

One edge survives and is worth stating, because it is the same hazard wearing
different clothes. Each sibling's `mix.exs` keeps a `STATIFIER_PATH` escape
hatch that swaps the Hex dep for `path:` with `override: true`. A path dep
compiles the whole checkout, `lib/mix` included, so the collision condition
returns for anyone working with that variable set. It is unreachable today only
because no statifier consumer keeps a local copy of these tasks to collide with
- which is a consequence of following the instruction at the top of this
section, not an independent guarantee. (predicator-ex does keep a local
`gate.verify.ex`, but it does not depend on statifier at all, so it has nothing
to collide with either.) Take the instruction and the edge stays closed.

## What is not reference and never was

`.claude/wurk.json` itself, `mise.toml`, `.quality.exs`, `.credo.exs`, and the
CI workflow are per-repo configuration, not text to copy. A repo standardizing
on this one should end up with the same *keys* it needs and its own *values*.
The section-by-section markings above are about prose and about
`gate.verify.ex`; they say nothing about config files beyond the
`gate.attest` key named in the exception.

### Two CI rules that are not reference either, but are worth stating

The CI workflow staying per-repo configuration does not mean every adopting
repo has to relearn its failure modes from scratch. Two rules surfaced during
the 2026-08 fleet campaigns, both the hard way, and neither is obvious from
reading a workflow file in isolation.

**CI must run the gate in the same env the gate tooling is defined for.** A
workflow that sets a global `MIX_ENV` can silently drop the gate task off the
build it is meant to protect. predicator-ex's gate workflow set
`MIX_ENV=test` globally, and ex_quality is `only: :dev` - so the gate task did
not exist in that CI environment at all, a gap caught only on the first live
run rather than by reading the workflow. statifier-ui's workflow avoids the
same trap by setting no `MIX_ENV`, which is the safer default whenever the
gate tooling is a dev-only dependency.

**CI trigger behavior for requests based on non-default branches (stacked
requests) must be verified per repo on a live request, never asserted from
reading the workflow file.** A campaign report claimed stacked requests get no
CI run in one repo; the very next stacked request in that same repo ran CI
anyway. The workflow file describes what the repo asked the forge to do, not
what the forge actually triggers - the two can diverge, and only a live
request settles which.
