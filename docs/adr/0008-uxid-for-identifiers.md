# ADR-0008: UXID for generated identifiers

Status: accepted (2026-08-02)

## Context

The engine generates identifiers in several places: session IDs (`_sessionid`),
`<send>` IDs (including `idlocation`), invoke IDs, and effect correlation IDs.
v1 used ad hoc generation and regenerated `_sessionid` on every expression
evaluation (a live bug). UUIDs are opaque and unsorted; bare random strings say
nothing about what they name. UXID (`~> 2.9`, same maintainer) produces K-sortable,
prefixed identifiers.

## Decision

All generated identifiers are UXIDs with a stable prefix per kind: `sess_` for
sessions, `send_` for send IDs, `inv_` for invocations. IDs are generated once at
the owning entity's creation and are immutable for its lifetime - `_sessionid` is
set when a session starts and never regenerated. Document-authored IDs (state IDs,
explicit `id` attributes) are always respected; UXIDs fill the spec's
"platform-generated id" holes only.

## Consequences

- Log lines, effects, and error events are self-describing and time-sortable.
- Parent/child session trees are easy to follow in traces.
- Spec compliance note: SCXML only requires generated IDs be unique; prefixes are
  an implementation nicety and tests must not depend on their shape beyond the
  documented prefix.
