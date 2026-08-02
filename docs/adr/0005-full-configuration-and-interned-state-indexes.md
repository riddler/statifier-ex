# ADR-0005: Store the full configuration; intern states to integer indexes

Status: accepted (2026-08-02)

## Context

v1 stored only leaf states and recomputed ancestors constantly - four separate
code paths existed just to fetch ancestors, plus a 376-line precomputed cache
module (descendant sets, ancestor paths, a pairwise LCCA matrix). The Appendix D
algorithm assumes the full configuration is available, so v1 also had to
reconstruct entry sets from leaves.

## Decision

The active configuration stores all active states, ancestors included, as the spec
assumes; "leaf states" is a derived view. The Machine compiler interns state IDs to
integers and lays states out in a flat array in document order with parent pointers
and descendant index ranges. Ancestor/descendant tests, LCCA, document-order
sorting, and exit-set computation are integer/range comparisons on that layout.

## Consequences

- The Appendix D port maps directly onto the storage model (ADR-0002).
- The hierarchy cache module and the four ancestor paths disappear.
- Configurations are `MapSet`s of integers; string IDs appear only at the API
  boundary (parsing in, event/introspection out).
- Slight cost: a translation step at the boundary, and debugging views must map
  indexes back to IDs (the Machine keeps both directions).
