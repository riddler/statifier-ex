# Persistence

How to persist and reload a running chart safely, and the hazard that makes
"safely" a real qualifier rather than a formality. Read alongside
[ADR-0052](adr/0052-chart-identity-and-position-serialization.md), which is
the decision record this page explains for a host author who has not read
[ADR-0005](adr/0005-full-configuration-and-interned-state-indexes.md).

## The hazard

A `Statifier.MachineState.t()`'s active configuration, `entered_states`,
`states_to_invoke`, and history values are `MapSet`s of interned integer
state indexes, not state ids
([ADR-0005](adr/0005-full-configuration-and-interned-state-indexes.md)).
Those indexes are assigned by the compiler when it lays states out in a flat
array in document order - they are stable *within* one `Statifier.Machine.t()`
build and mean nothing across two. ADR-0005's own Consequences section says
so directly:

> Slight cost: a translation step at the boundary, and debugging views must
> map indexes back to IDs (the Machine keeps both directions).

Adding a state, removing one, or reordering the document renumbers every
index after the change point. Nothing about a bare `MapSet.t(non_neg_integer())`
carries any information about which chart build produced it. Load a position
that was saved against yesterday's chart onto today's recompiled chart and
the integers still decode into a valid-looking `MachineState` - they just
name different states than they did yesterday. The machine does not crash;
it silently resumes the wrong configuration. That is the failure mode this
whole document, and ADR-0052, exist to turn into a loud error instead.

## What identity buys

Two separate facts, two separate fields, both stamped onto a position blob
by `Statifier.Position.to_binary/1`:

- **The content hash** (`Statifier.Machine.Identity`) detects a chart
  revision change. It is a SHA-256 hash of the SCXML source bytes handed to
  `Statifier.compile/2` - not a hash of the compiled `Machine` term, so it
  agrees for two byte-identical documents regardless of what the compiler
  did with them, and disagrees the moment a state is added, removed, or
  reordered in the source.
- **The format version** (`Statifier.Position.format_version/0`) detects a
  library upgrade that changed the blob's own shape - independent of
  whether the chart itself changed at all.

`Statifier.Position.from_binary/2` checks the format version first and the
identity second: a future format whose identity representation changed
shape reports the version mismatch rather than a confusing identity failure
produced by misreading the new shape as the old one. A mismatch on either
axis is a returned error tuple, never a silent misread -
`{:error, {:unsupported_format_version, version}}` or
`{:error, {:identity_mismatch, expected, actual}}`.

## Migration story A: drain on the old version

Keep the old chart source compiled and reachable - the source bytes, not
just the `Machine` built from them, since `Statifier.compile/2` needs the
bytes again to reproduce the same identity. Run every position that was
saved against the old revision to completion against that same compiled
chart. Start every new position on the new revision. No translation
happens, no data is lost, and the whole migration is bounded by how long a
position lives: once the last position saved against the old revision
finishes (or is abandoned), the old chart never needs to be loaded again.

This is the default recommendation. It costs nothing but keeping one extra
compiled chart reachable for a while, and it never asks a position to
change meaning mid-flight.

## Migration story B: position migration via string ids

`Statifier.Position.export/1` translates a `MachineState` into a map keyed
by state ids (strings) instead of interned indexes; `Statifier.Position.import/2`
reverses the translation onto a *different* `Machine` than the one that
produced the export. Between the two, a host - or an operator by hand - can
rename an id, drop a field for a state the new revision deleted, or leave
the export untouched, before handing it to `import/2`. Unlike `to_binary/1`
/ `from_binary/2`, `import/2` performs no identity check at all: crossing a
revision on purpose is exactly what this pair is for.

What it cannot do:

- **It cannot invent a state the new revision deleted.** If the export
  references a state id that no longer resolves against the target
  `Machine`, `import/2` returns
  `{:error, {:unknown_state_ids, ids}}` naming every such id, sorted, in one
  round trip. A host must resolve every one - by mapping it to a
  replacement id in the exported map, or by accepting that the position
  cannot be migrated - before `import/2` will succeed.
- **It cannot fix an `active_invocations` key whose state's `<invoke>`
  children were edited.** `active_invocations`' key pairs a state id with an
  integer `invoke_index` - a within-state, document-order ordinal over that
  state's own `<invoke>` children. The ordinal survives states being added
  or reordered elsewhere in the chart, but not an edit to that one state's
  own `<invoke>` children; renumbering those requires the host to adjust the
  ordinal itself, the same way it would adjust a renamed state id.
- **It refuses a non-quiescent position.** `export/1` returns
  `{:error, :internal_queue_not_empty}` for a `MachineState` with a
  non-empty internal event queue: those queued events were selected against
  the source chart's own transitions, so a position mid-macrostep is not a
  thing to move across chart revisions. A host drains to quiescence - lets
  the macrostep finish - before exporting.

`export/1` also refuses outright, rather than silently dropping, any
referenced state with no author-written id
(`{:error, {:unnameable_states, indexes}}`); a state a host wants to migrate
through this path needs an id in the SCXML source.

## What a host must persist

Three things, and only three:

1. **The SCXML source**, so `Statifier.compile/2` can recompile the exact
   `Machine` deterministically. This is what makes the content hash a
   verifiable fact rather than an opaque token: recompiling the retained
   source and comparing the resulting identity against a loaded blob's is
   how a host proves to itself that "this position matches this chart" is
   still true.
2. **The identity blob** (`Statifier.Machine.Identity.to_binary/1`), so a
   host can record which revision a position belongs to without recompiling
   the source just to ask.
3. **The position blob** (`Statifier.Position.to_binary/1`), which carries
   the identity itself alongside the position's own state.

Explicitly **not** the `%Statifier.Machine{}` struct. `Position.to_binary/1`
refuses to encode one at all (`{:error, :unidentified_chart}` for an
unidentified chart, and the compiled chart is never written to the blob for
an identified one either) - see
[ADR-0052 decision 3](adr/0052-chart-identity-and-position-serialization.md).
The reasoning is the same one predicator gives its own callers for
`%Predicator.Compiled{}` (`compiled.ex:10-38`): persist the source and
recompile, rather than persisting a compiled form whose internal shape can
drift across a library upgrade with no compatibility story of its own. A
compiled chart is also the overwhelming majority of a naively serialized
position's bytes - measured on this branch, 5848 bytes with the machine
embedded against 725 without it for one small position - so stripping it is
also what keeps a position blob small.
