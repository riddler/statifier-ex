# Family reference: what the sibling repos copy from here

This repo is the de-facto reference for the family's agent-facing conventions -
`CLAUDE.md`, `.claude/wurk/`, and the quality-gate documentation. That status
was implicit until now, and the copies drift: as of 2026-08-21 the
`deps/ex_quality/usage-rules.md` pointer existed here and in statifier-ui and
nowhere else, this repo had 7 `.claude/wurk/` overrides against predicator-ex's
12, statifier-ui's 3 and none in the three scaffolds, and CI ran the gate here
and in no other repo.

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
| `mix gate.verify` and the `gate.attest` manifest key | `lib/mix/tasks/gate.verify.ex`, `.claude/wurk.json` | reference, copy-verbatim (with per-repo wiring) |
| The gate guard (`mix gate.check`) and its `guard_ledger` | `lib/mix/`, `.claude/wurk.json`, `docs/quality-gate-changes.md` | **not reference** |
| The ADR guard and the ADR judge | `lib/mix/` | **not reference** |
| The regression ratchet | `lib/mix/`, `test/passing_tests.json` | **not reference** |
| Which skipped stages are gaps and which will never apply | `CLAUDE.md` | **not reference** |

### Agent authority in this repo - adapt-per-repo

This is the worked example of why the distinction matters, and the one section
where copying verbatim does real damage.

**This repo holds a standing team-maintainer grant.** statifier_persistence,
statifier_oban and opentelemetry_statifier hold a **consent-scoped** grant:
authority to commit, push and open requests exists only inside an orchestrated
campaign carrying the user's explicit consent for that campaign, and nowhere
else. Copying this repo's section into one of those three would silently widen
it to standing. Copying one of theirs back into here would silently narrow it.
Neither change is one an agent may make; widening is the user's call to make
and record, as the section itself says.

What **is** common across all six repos, and is the actual reference, is the
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
up to match. Seven here, twelve in predicator-ex, three in statifier-ui and
none in the scaffolds is a legitimate spread: an override earns its place when
the repo has a judgment call the generic skill genuinely cannot make, and a
repo with no such call is correct to have no file. Copying an override across
imports a judgment about another codebase.

An adopter must change: everything inside the files. This repo's `mr.md` runs
`mix quality --profile merge` for an ADR judge no other repo has, and its
`commit.md` carries the v2/v1 changelog narrowing, which is a fact about this
package's release state.

## The custom gate stages are not the reference

The gate guard, the ADR guard, the ADR judge, the regression ratchet, and
`mix gate.check` with its `guard_ledger` are **out of scope for copying**. They
exist to protect a conformance corpus and an accepted ADR set that the other
repos do not have. The three scaffold repos' `.quality.exs` files each carry a
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

### `mix gate.verify` is the one exception

The user ruled on 2026-08-22 that the five other repos adopt it - beads px-591,
sui-4py, sp-7cu, sob-ehl and ots-4l6.

The line between it and `mix gate.check` is the whole reasoning. `gate.check`
is the config-change guard: it knows this repo's guarded paths, its ledger, and
its corpus registry, and it is repo-specific machinery by construction.
`gate.verify` is a generic reader of ex_quality's *own* report - roughly 150
lines that check the report for status ok, no profile, scope all, and no stage
skipped for a run-narrowing reason. It contains no statifier-ex specifics: no
corpus, no ADRs, no ledger.

It **adds no stage to `.quality.exs`**, so the "deliberately smaller than
statifier-ex's gate" statement in the scaffolds stays true after adoption. That
is what makes it an exception rather than a hole in the paragraph above.

It matters because the wurk pipeline sets `attested: false` when a project
declares no attestation command, and `/wurk:commit` then refuses to proceed. A
repo without it has a broken unattended commit path, which is a mechanical
problem rather than a stylistic one.

An adopter must change: nothing in the task body, but the wiring is per-repo -
set `gate.attest` in `.claude/wurk.json` to `["mix", "gate.verify"]`, and check
the task's expectations against the ex_quality version that repo depends on.

Expect the copies to be temporary. `gate.verify` is being extracted upstream
into ex_quality as a task that package ships (bead `st-wgr0`; design at
`~/Dev/github/ex_quality/PLAN-quality-verify.md`), after which each adopter
points `gate.attest` at the upstream task and deletes its copy. Do not block
the five adoptions on that extraction - the copies are small and the collapse
is mechanical.

## What is not reference and never was

`.claude/wurk.json` itself, `mise.toml`, `.quality.exs`, `.credo.exs`, and the
CI workflow are per-repo configuration, not text to copy. A repo standardizing
on this one should end up with the same *keys* it needs and its own *values*.
The section-by-section markings above are about prose and about
`gate.verify.ex`; they say nothing about config files beyond the
`gate.attest` key named in the exception.
