# ADR-0061: Consumers pin main SHAs under a documented contract until 2.0.0

Status: accepted (2026-08-19) - decides st-jdvr's either/or: no pre-release
is published; the `2.0.0-dev` / no alpha-beta-rc rule stands on updated
grounds; a SHA-pinning contract is documented for consumers; `package/0`
metadata lands now; publishing before 2.0.0 is deferred with a named
trigger

## Context

`mix.exs` holds `2.0.0-dev` for the whole rewrite, and the documented rule
(`docs/workflow.md` "Versioning and the changelog", `CLAUDE.md`
Conventions) is that nothing is published until 2.0.0 is complete - no
alpha, beta, or release-candidate versions along the way. The recorded
justification was "there is no audience for a pre-release of an engine
that cannot yet run a statechart."

That justification has expired, and st-jdvr names why: satellite packages
(`statifier_ui`, `statifier_persistence`, `statifier_oban`) and production
embedders now take the dependency. Today their only option is a git
dependency pinned to a moving `2.0.0-dev` SHA, with no statement of what
may change between two pins or how they would find out. The bead offers
two ways to close that gap:

- publish a 2.0.0 pre-release to Hex, rolling up the `changelog.d/`
  fragments, or
- keep the no-publish rule and document an explicit SHA-pinning contract.

Four facts bound the choice:

**1. Every consumer that exists today is git-capable.** The named
satellites are unpublished sibling projects and the embedders build from
source; a `{:statifier, github: ..., ref: <sha>}` dependency works for all
of them. The one thing a git dependency cannot do is sit inside a package
*published to Hex* - Hex refuses git dependencies in published packages -
and no consumer is publishing yet. This repo already lives on the same
mechanism itself: the `credo` dependency is a git pin with `mix.lock`
holding the SHA for reproducibility (`mix.exs`).

**2. A Hex pre-release is a permanent public artifact plus a recurring
ceremony.** Each cut is a human publish action (Hex credentials for the
existing `statifier` package, which carries v1's `0.1.0`-`1.9.0` history),
is effectively irrevocable after Hex's retraction window, and starts a
treadmill: a pre-release that is not re-cut regularly is staler than a SHA
pin, and one that is re-cut regularly is a release process this pre-alpha
project would be running for an audience of three sibling repos. It would
also break the `changelog.d/` design: fragments assemble into a single
2.0.0 migration document for 1.x users
(`changelog.d/README.md` "While v2 is unreleased"); draining them into
`2.0.0-rc.N` sections would fracture that document for no reader.

**3. The gate is the real stability guarantee, and st-jdvr's other half
puts it on every `main` commit.** Full `mix quality` (format, compile
with warnings-as-errors, credo, dialyzer, deps audit, full suite with
coverage), `mix gate.verify`, `mix adr.check`, and the conformance
ratchet (`mix test.regression` against `test/passing_tests.json`) already
gate every merge locally; CI on the default branch makes that property of
a SHA verifiable by a consumer who was not in the room.

**4. Breaks between pins are already loud where they are most dangerous,
and discoverable where they are not.** Persisted position and recording
blobs are format-versioned and identity-checked - a mismatch refuses with
a typed error instead of misreading (ADR-0052, ADR-0057). Public API
shape changes surface at the consumer's compile. The remaining category -
behavior changes for the same input - is exactly what `changelog.d/`
fragments record, and fragments live in git, so the difference between
two pins is a `git diff` away.

## Decision

**1. No pre-release is published. The `2.0.0-dev` rule stands, on new
grounds.** `mix.exs` stays `2.0.0-dev` until 2.0.0 is complete; no alpha,
beta, or release-candidate versions. This reaffirms the documented
convention rather than changing it, but the *reason* recorded in
`docs/workflow.md` changes: not "no audience," which is false now, but
that every existing consumer is git-capable, a Hex pre-release is a
permanent artifact plus a recurring human ceremony this project does not
want yet, and pre-release sections would fracture the 2.0.0 migration
document the changelog design exists to produce. `docs/workflow.md`'s
"Versioning and the changelog" section is updated to cite this record.

**2. The pinning contract, stated as what a consumer may rely on:**

- **Pin only commits reachable from `main`.** Every such commit has
  passed the full gate - the same one CI runs on the default branch and
  `mix gate.verify` proves locally. A branch tip is covered by nothing
  and the contract does not extend to it.
- **Between two pins, any public API and any observable behavior may
  change without deprecation, notice period, or compatibility shim.**
  `2.0.0-dev` is one moving version; SemVer promises nothing within it
  and neither does this project. There are no git tags before 2.0.0 - a
  tag is a pseudo-release, and the pin *is* the SHA.
- **What will never break silently:** persisted position and recording
  blobs refuse with typed errors on a format-version or chart-identity
  mismatch rather than misreading (ADR-0052, ADR-0057); API shape
  changes fail the consumer's compile.
- **How a consumer learns what changed between pins:**
  `git diff <old-sha>..<new-sha> -- changelog.d/ CHANGELOG.md` lists
  every user-visible difference. Decision 3 is what makes that diff
  complete.

**3. The fragment rule widens by one clause: a change that breaks code or
persisted data written against an earlier `main` SHA gets a fragment
touch, by editing in place.** Today `changelog.d/README.md` warrants a
fragment where v2 differs from v1. That leaves a hole the contract cannot
tolerate: a v2-only API added at one SHA and reshaped at a later one may
read, against v1, as the same single difference - no new fragment, no
signal in the diff. The clause closes it: when a v2-only public API or
behavior changes between pins, the issue's fragment is edited (or created)
so that it describes the *current* v2-vs-v1 difference. Editing in place
keeps both properties at once - the `git diff` between pins carries the
between-pins signal, while the fragment's final text stays a clean
v1-to-v2 migration statement for release assembly, never a transcript of
intermediate churn. `changelog.d/README.md` gains this clause, citing
this record.

**4. `package/0` metadata lands now; publishing stays a human decision.**
`mix.exs` gains the Hex package block - name (`statifier`, continuing the
v1 package), description, `licenses: ["MIT"]` (the LICENSE file is
already in the tree), `links` to the source URL, and the file list -
without any publish. This makes publishing 2.0.0 a decision rather than a
project, exactly as st-jdvr asks, and adding metadata neither publishes
anything nor contradicts decision 1. ExDoc/hexdocs configuration beyond
what publishing minimally requires is left to the implementation plan.

**5. The no-publish rule is deferred against a named trigger, not
forever.** The first time either fires, the pre-release question is
re-decided in a new record rather than argued from this one:

- a satellite package must itself publish to Hex (Hex refuses git
  dependencies in published packages, so statifier must be on Hex first),
  or
- a production embedder's dependency policy forbids git dependencies.

Completion of 2.0.0 ends the contract naturally: from the first real
release onward, SemVer and `CHANGELOG.md` replace it.

**6. The contract is documented where a consumer looks.** `README.md`
gains a short installation-and-pinning section stating decision 2's
bullets: pin a `main` SHA via a git dependency, what a pin guarantees,
what may break between pins, and the `changelog.d/` diff as the upgrade
briefing. `docs/workflow.md` carries the maintainer-facing half
(decisions 1, 3, and 5).

## Consequences

- Satellite packages and embedders get an explicit upgrade contract
  today, with no release ceremony added: pin a green `main` SHA, upgrade
  by moving the pin, read the `changelog.d/` diff as the briefing, trust
  the format-versioned blob codecs to refuse rather than corrupt.
- The implementation plan for st-jdvr's remaining scope now has its
  direction: CI on the default branch running the full local gate (the
  mechanics are plan-stage work, per the bead); `package/0` in `mix.exs`;
  the README consumer section; the `docs/workflow.md` prose update; the
  `changelog.d/README.md` clause. The `mix.exs` edit touches a
  gate-relevant file, so the branch carrying it needs its
  `docs/quality-gate-changes.md` ledger entry approved by a human
  (ADR-0011) - `package/0` itself is not gate-relevant, but the guard
  keys on the file.
- What this contract does NOT give a consumer, stated plainly: no
  deprecation cycles, no notice before a break, no support for pins off
  `main`, no tags to diff release notes between, and no Hex package until
  2.0.0 or a decision-5 trigger. A consumer who needs any of those needs
  the trigger to fire, not a workaround.
- The fragment-editing clause (decision 3) makes fragment edits part of
  the definition of done for a change that reshapes v2-only public
  surface - reviewers should expect to see them, and their absence on
  such a change is a review finding.
- `.claude/wurk.json`'s `release` key stays `null`: there is still no
  release recipe to run, and `wurk:release` correctly refuses. Writing
  that recipe is 2.0.0-release work, not this bead's.

## Open questions

- **Hex ownership of the `statifier` package.** Decision 4 assumes the
  existing `statifier` Hex package (v1, through 1.9.0) is publishable-to
  by this project's maintainer. Verifying ownership and credentials is a
  human step; nothing in this record or its implementation depends on it
  until a decision-5 trigger fires, but the assumption should be checked
  before that day.
- **Whether the satellites adopt a shared pin.** Whether
  `statifier_ui`, `statifier_persistence`, and `statifier_oban`
  coordinate on one statifier SHA or move independently is those repos'
  decision; this contract works either way and deliberately does not
  choose.
