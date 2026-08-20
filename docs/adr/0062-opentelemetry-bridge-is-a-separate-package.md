# ADR-0062: The OpenTelemetry bridge is a separate package, `opentelemetry_statifier`

Status: accepted (2026-08-20) - decides st-cmq.2's packaging question; the
span topology, context propagation, and cardinality decisions the bridge
implements are recorded in `docs/opentelemetry.md`

## Context

ADR-0040 shipped the `[:statifier, :session, ...]` telemetry contract with
an OpenTelemetry bridge named as its first external consumer, and st-cmq.2
holds the design question that was deliberately left open: does that bridge
live in this repository as an optional `Statifier.Telemetry.OTel` module
behind a `Code.ensure_loaded?` guard, or in a separate package?

Constraints already fixed before this record: no OTel API call anywhere but
the bridge; the bridge consumes only the public telemetry events, and a
data gap is fixed by the event contract gaining a field (an ADR-0040
amendment), never by the bridge reaching into internals; trace-off behavior
degrades to macrostep-grained spans structurally (ADR-0040's core-side
gate).

Facts that bound the choice:

**1. The ecosystem surveyed one way.** Oban, Ecto, Phoenix, Broadway,
Finch, and Redix all keep OTel out of the core library and ship the bridge
as a separate `opentelemetry_<lib>` package, most under
`open-telemetry/opentelemetry-erlang-contrib`. The in-library optional
module is the minority pattern. (Survey table in `docs/opentelemetry.md`.)

**2. The in-library module has recurring costs here.** This repo's gate
holds 100% Doctor thresholds and warnings-as-errors; an optional dependency
means every full gate run happens twice (with and without
`opentelemetry_api` present) or silently checks only one side. OTel API
releases would force `statifier` releases. And the consume-only-public-
events constraint would be a review obligation inside the repo whose
internals are one alias away.

**3. The bridge's natural scope is the family, not this repo.**
`statifier_persistence` and `statifier_oban` will grow telemetry surfaces
of their own (each repo's tracker carries the mirrored design bead), and a
host wants one trace across load -> step -> effects -> timer hop -> resume.
A bridge module inside `statifier` can never own the spans and span links
that cross those package boundaries.

**4. `statifier` is not on Hex (ADR-0061).** A published Hex package
cannot carry a git dependency, so the bridge cannot publish before
`statifier` does - and ADR-0061 decision 5 names "a satellite package must
itself publish to Hex" as a trigger that reopens the no-publish rule.

## Decision

**1. The bridge is a separate package in its own repository:
`opentelemetry_statifier`.** This repository gains no OTel dependency, no
optional module, and no `Code.ensure_loaded?` guard. `Mix.Statifier.AdrGuard`
needs no new exemption: the emission half stays exactly the two files
ADR-0040 named.

**2. The name follows the OTel ecosystem convention, not the `statifier_*`
family convention.** `opentelemetry_statifier` sits alphabetically and
mentally next to `opentelemetry_oban` and `opentelemetry_ecto`, which is
where its audience looks. The family convention (`statifier_ui`,
`statifier_persistence`, `statifier_oban`) names packages that extend
statifier; this one extends OpenTelemetry coverage *to* statifier, and the
ecosystem's naming encodes that direction. Recorded so the inconsistency
reads as chosen, not accidental.

**3. Its scope is the statifier family.** The package bridges this repo's
27-event contract first, and the sibling packages' telemetry surfaces as
they appear - as separate setup calls per library, the same shape
`opentelemetry_ecto` and `opentelemetry_oban` compose in a host today.
Cross-package trace stitching (span links across the persistence and timer
hops) belongs to it and to no single statifier repo.

**4. It consumes only public contracts, structurally.** Its `statifier`
dependency is a git pin to a `main` SHA under the ADR-0061 contract, like
every other consumer. When the bridge needs data the events do not carry -
the already-identified case is caller trace context on external events and
on `%SendDelayed{}`, so a delayed send firing later can link its
scheduling trace - the field is added here under ADR-0040's amendment
discipline and tracked as its own bead, mirrored where the consuming host
lives.

**5. It stays unpublished until `statifier` is on Hex.** Consumers take it
by git pin, same contract. The moment it genuinely needs to publish,
that is ADR-0061 decision 5's trigger firing, and the pre-release question
is re-decided there, not here.

**6. What this repo owes the bridge is the freeze ADR-0040 already
states.** The 27 event names, their measurement/metadata shapes, and the
fields of the effect structs riding in `metadata.effect` are a public
commitment; from the bridge's first release against them, a change is a
breaking change to a real consumer, surfaced in `changelog.d/` per
ADR-0061 decision 3.

## Consequences

- `docs/opentelemetry.md` holds the bridge-facing design (span topology,
  context propagation, sampling/cardinality, failure tolerance); this
  record holds only the packaging decision. `docs/observability.md`
  constraint 6 points at both.
- The repository for `opentelemetry_statifier` is created by the
  maintainer; its own tracker owns bridge implementation beads, and
  st-cmq.2 closes when this record and the design note land - the
  charter-transfer pattern `statifier_persistence` (sp-4an) and
  `statifier_oban` (sob-q01) already used.
- The named follow-up bead in this repo: an opaque caller-context slot on
  external events and `%SendDelayed{}`/durable-timer payloads, additive
  under ADR-0040's amendment rules, mirrored into `statifier_oban`'s
  tracker for the firing-side link.
- What would reopen this record: the bridge needing per-microstep child
  spans (rejected in the design note as span events), a second bridge
  package appearing for one sibling library (decision 3 says one package),
  or `statifier` publishing to Hex, which unlocks decision 5's publish
  question but does not by itself reopen packaging.
