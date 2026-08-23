# ADR-0066: Publishes 2.0.0 to Hex, ending the SHA-pinning contract

Status: accepted (2026-08-22) - re-decides ADR-0061's deferred publish
question after its named trigger fired; 2.0.0 ships with the remaining
open interpreter beads recorded as known issues; SemVer and
`CHANGELOG.md` replace the pinning contract from this release on

## Context

ADR-0061 decision 5 deferred the publish question against two named
triggers and required that, when one fired, the question be re-decided in
a new record rather than argued from the old one. The first trigger has
now fired, four times over: the satellite packages - `statifier_ui`
(sui-tx0), `statifier_persistence` (sp-989), `statifier_oban` (sob-qyl),
and `opentelemetry_statifier` (ots-k2v) - are themselves publishing to
Hex, and Hex refuses to publish a package that carries a git dependency,
so the engine must be on Hex first. The operator gave the release
go-ahead in session on 2026-08-22 (st-ueav).

ADR-0061's grounds for not publishing have all expired with the trigger:

- "Every consumer is git-capable" is no longer the whole population - the
  satellites' Hex consumers, transitively, are not.
- "A Hex release is a permanent artifact plus a recurring ceremony" is
  now simply true of the thing being asked for; the recurring-treadmill
  argument applied to *pre-releases*, and this is the release.
- "Pre-release sections would fracture the 2.0.0 migration document" is
  moot: the fragments assemble into exactly one `[2.0.0]` section, once,
  in this release.

What "2.0.0 is complete" means is the judgment this record has to make,
because the tracker is not empty. The documented rule
(`docs/workflow.md`) tied publishing to the engine being "complete"; the
conformance ratchet stands at 152 W3C and 119 SCION tests passing, the
full gate is green on every `main` commit, and the highest-priority open
interpreter defect (the spec-6.2 delayed-send discard at halt, st-dmfg)
is fixed ahead of this release. The remaining open interpreter beads are
edge-case races and diagnostics, none of which changes a published API or
a persisted format:

- st-vfmb, st-vy97: invoke-completion races between `done.invoke` and a
  sibling delayed timer or an `onexit` `<send>` to `#_parent`.
- st-2dht: a `_event` guard comparing against `'undefined'` evaluates
  false on the statifier side of the seam (test330).
- st-5577: `<assign>` lacks the markup-slicing treatment `<content>`
  received.
- st-ykn6: test530/test554 still fail to compile after ADR-0041.
- st-6lu: duplicate attributes on one element are not reported.
- st-lz1c: corpus exclusion policy for invoke `src`/`srcexpr` and
  unsupported send/invoke type files is undecided.

## Decision

**1. 2.0.0 is published to Hex, continuing the existing `statifier`
package.** The package name carries v1's `0.1.0`-`1.9.0` history;
`mix.exs` moves from `2.0.0-dev` to `2.0.0`, and `mix hex.publish` is a
human action performed by the operator, who holds the package
credentials. "Complete" is decided as: the ratchet's corpus green, the
full gate on every `main` commit, no open defect that changes a public
API or persisted format. The bead list above is the known-issues record;
fixes land in ordinary SemVer releases.

**2. The SHA-pinning contract (ADR-0061 decisions 1, 2, 5) ends with this
release, as ADR-0061 itself provided.** From 2.0.0 on, SemVer and
`CHANGELOG.md` are the upgrade contract. The first git tag of v2 is
`v2.0.0`, on the release commit, per `changelog.d/README.md`'s release
protocol. ADR-0061 decision 3's widened fragment rule (edit a fragment in
place when a v2-only surface reshapes between pins) retires with the
contract; the base fragment rule - one fragment per user-visible change,
assembled at each release - continues unchanged.

**3. The `[2.0.0]` changelog section is assembled as the migration
document the fragment design existed to produce.** All accumulated
`changelog.d/` fragments are assembled, grouped by Keep-a-Changelog
heading, in the release commit, and deleted in that same commit. Assembly
is editorial, not concatenation: the successive predicator floor bumps
collapse into the one floor 2.0.0 actually ships (`~> 9.0`), fragments
that amended earlier fragments merge into single current statements, and
the pin-documentation fragment (st-jdvr) is dropped as mooted by the
release itself.

**4. The consumer-facing pinning prose is replaced by ordinary Hex
instructions.** `README.md`'s installation-and-pinning section becomes a
standard `{:statifier, "~> 2.0"}` install section; `docs/workflow.md`'s
"Versioning and the changelog" section is rewritten for the released
world (SemVer, fragments assembling into each release's section, tags on
release commits). Both cite this record.

**5. Hexdocs ships with the package.** `mix.exs` gains the `docs/0`
configuration ADR-0061 decision 4 deferred: README as the landing page,
the user-facing guides under `docs/`, and the full ADR set (the guides
cite individual records by relative link, so the records travel with the
docs).

## Consequences

- The satellites unblock: each can swap its git pin for
  `{:statifier, "~> 2.0"}` and publish its own 0.1.0 (sui-tx0, sp-989,
  sob-qyl, ots-k2v).
- Behavior changes now cost a release. The between-pins freedom of
  ADR-0061 decision 2 - any API or behavior may change without notice -
  is gone; a breaking change after 2.0.0 is a major version.
- The known-issues list above is a public record in a published package's
  docs; fixes to those beads are ordinary patch or minor releases, and
  none of them may silently change persisted-format behavior without the
  format-version machinery ADR-0052/0057 already require.
- `docs/workflow.md`'s release protocol (assemble fragments, delete them
  in the release commit, tag) has now run once for real; the satellites
  copy it rather than invent their own.
