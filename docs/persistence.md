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

A rename is not a one-field edit. A state id appears in *every* exported
field that references that state, and `import/2` resolves all of them: an id
left stale in any one of them fails the whole import. Renaming `"b"` to
`"bee"` means editing it in `configuration`, `entered_states` and
`states_to_invoke` (each a set of ids), in `history_values` (both its keys
and the id sets it values), and in the state-id half of every
`active_invocations` key. The error names the stale id but not the field it
came from, so an import that still reports `{:error, {:unknown_state_ids,
["b"]}}` after an apparently complete rename is a field the edit missed, not
a state the target revision lacks.

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

## Persisting the chart itself

A host that manages its own SCXML source has no reason to persist it a
second time through this library - the three items above are enough. A host
that *cannot* retain its own source (an embedder whose deployment story does
not include shipping `.scxml` files alongside its data) can persist a
single blob instead:
`Statifier.Chart.to_binary/1`. It carries the SCXML source, the persisted
subset of the compile options, and the chart's identity, all in one
envelope, and `Statifier.Chart.from_binary/1` recompiles a `Machine.t()`
from it on load - two lines compose the identity check a position blob also
needs:

```elixir
{:ok, machine} = Statifier.Chart.from_binary(chart_blob)
{:ok, machine_state} = Statifier.Position.from_binary(position_blob, machine)
```

This is the mechanized form of the same "persist the source, recompile"
advice the three-item list above already follows by hand; see the
[ADR-0052 amendment (st-i7y7)](adr/0052-chart-identity-and-position-serialization.md)
for why it ships as its own module rather than as functions on `Machine`.

Anything that is not this library's own chart envelope - a foreign
`term_to_binary` blob, corrupt bytes, or an envelope whose source or options
are the wrong shape - comes back as `{:error, :not_a_statifier_blob}`, decided
before any version, compile, or identity check runs. The other three arms are
`{:error, {:unsupported_format_version, version}}`,
`{:error, {:compile_failed, errors}}`, and
`{:error, {:identity_mismatch, expected, actual}}`, in the order
`from_binary/1` checks them; `Statifier.Chart.to_binary/1`'s one refusal is
`{:error, :unidentified_chart}`.

## Persisting a recording

A recording (`Statifier.Session.Recording.t()`) is the third persistable
artifact, alongside a position and a chart. What its blob carries: the
nested chart blob (`Statifier.Chart.to_binary/1`'s own envelope - the SCXML
source, the persisted compile opts, and the chart's identity, not a second
copy of anything), the recording's normalized session opts, and its
`entries/1` in append order. What it never carries: the compiled
`%Machine{}` term (`from_binary/1` recompiles one from the nested chart blob
on load, exactly as the chart section above does), any pid, ref, port, or
fun, and no clock reading -
[ADR-0034](adr/0034-replay-re-drives-the-core-not-a-live-session.md)
decision 2 is why a recording never reads wall-clock time in the first
place, so there is nothing of the kind for a blob to carry.

Loading one composes the same two-line shape the chart section above models:

```elixir
{:ok, recording} = Statifier.Session.Recording.from_binary(blob)
{:ok, result} = Statifier.Replay.run(recording)
```

**The decoding host must have its `:invoke_handlers` modules loaded before it
decodes.** `String.to_existing_atom/1` cannot conjure an atom for a module
nobody has loaded yet, so `to_binary/1` writes each handler module as a
string rather than an atom
([ADR-0056 decision 5](adr/0056-recording-identity-and-serialization.md)),
and `from_binary/1` resolves every one back, collecting every unresolvable
name into a single `{:error, {:unknown_handler_modules, names}}` instead of
failing on the first. The error is the actionable instruction: load the
handler code, then decode.

**Replay after decode is only as faithful as the handlers' planning
callbacks are.** `Statifier.Session.Effects.plan/2` dispatches to a
handler's planning callback while replaying; `perform/2`, the impure half,
is never called during replay. A decoded recording therefore reproduces the
recorded stream only where the handlers' planning callbacks are equivalent
to the ones the original run used - an accepted environmental limit, the
same class as
[ADR-0034](adr/0034-replay-re-drives-the-core-not-a-live-session.md)'s OTP
`MapSet`-iteration caveat, not a defect to chase down.

**Host-supplied atoms inside recorded payloads remain the host's own
`:safe` obligation.** The codec resolves only the handler-module atoms it
itself wrote; an atom a host put into `:datamodel` values or event data is
neither scanned for nor translated by `to_binary/1` or `from_binary/1`.

The error vocabulary, in the order `from_binary/1` checks it:
`:not_a_statifier_blob` (anything that is not this module's own tagged
envelope), `{:unsupported_format_version, version}`,
`{:chart, reason}` (carrying `Statifier.Chart.from_binary/1`'s own error
tuple, unflattened), and `{:unknown_handler_modules, names}`.
`to_binary/1` has exactly one refusal: `{:error, :unidentified_chart}`, for
a recording made over a `Machine` that was never identified to begin with -
the same rule positions and charts already live under.

As with a position blob, reading a recording's identity without paying the
recompile is not answered yet - deferred the same way
[ADR-0052](adr/0052-chart-identity-and-position-serialization.md) defers it
for positions. A host that needs to index many recordings by chart revision
without recompiling each one on lookup stores
`Statifier.Machine.Identity.to_binary/1` beside each recording blob at write
time, the same pattern item 2 of "What a host must persist" above already
gives positions.

## Explicitly not the *compiled* chart

What is still never persisted, in either shape above, is the *compiled*
`%Statifier.Machine{}` struct. `Position.to_binary/1` refuses to encode one
at all (`{:error, :unidentified_chart}` for an unidentified chart, and the
compiled chart is never written to the blob for an identified one either),
and `Statifier.Chart.to_binary/1` refuses the same way for the same reason -
see
[ADR-0052 decision 3](adr/0052-chart-identity-and-position-serialization.md)
and its
[st-i7y7 amendment](adr/0052-chart-identity-and-position-serialization.md).
The chart blob's source-carrying shape is exactly why that stays true even
though the blob now travels as one file: `Statifier.Chart.from_binary/1`
rebuilds the `Machine` by recompiling the stored source through
`Statifier.compile/2`, the same pipeline any other caller runs, never by
deserializing compiler output directly. The reasoning is the same one
predicator gives its own callers for `%Predicator.Compiled{}`
(`compiled.ex:10-38`): persist the source and recompile, rather than
persisting a compiled form whose internal shape can drift across a library
upgrade with no compatibility story of its own. A compiled chart is also
the overwhelming majority of a naively serialized position's bytes -
measured on this branch, 5848 bytes with the machine embedded against 725
without it for one small position - so stripping it is also what keeps a
position blob small; a chart blob is, by the same reasoning, roughly the
size of the SCXML source it carries, not the size of the compiled `Machine`
that source produces.

## What it costs

Choosing the chart-blob shape over retaining source directly is not free:

- **Recompilation on every load.** `Statifier.Chart.from_binary/1` runs the
  full `Statifier.compile/2` pipeline before it can return a `Machine.t()`,
  every time - there is no cached compiled form to skip straight to.
- **The source must still compile under the loading build.** A blob written
  by one build and loaded by a later one is only as portable as its source
  is: `{:error, {:compile_failed, errors}}` is the arm that says it is not,
  for instance because a validator check tightened across a library
  upgrade. That is a real, distinct failure from a format or identity
  mismatch, and is returned unflattened.
- **The compile-opts set is closed.** `Statifier.Chart.to_binary/1` carries
  only the same closed allowlist `Statifier.compile/2` already stamps onto
  `Machine.compile_opts/1` (`:invoke_content_markup`, `:chart_name`,
  `:chart_version`). An embedder that calls `Statifier.compile/2` with an
  option outside that set cannot expect the blob to carry it: recompiling
  that option back in on load is the embedder's own responsibility, not
  something `from_binary/1` does on its behalf.
- **A recording's own load pays the same recompile, once.** A recording
  nests exactly one chart blob, so `Statifier.Session.Recording.from_binary/1`
  pays the cost above once per decode, through the same
  `Statifier.Chart.from_binary/1` call the chart section describes - not a
  second, independent recompile cost of its own.
