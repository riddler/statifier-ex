# ADR-0056: Recording identity and serialization

Status: accepted (2026-08-19) - answers ADR-0052 decision 8's named
follow-up (st-hz2a); consumes 0052's identity and chart-codec machinery
without amending any of its decisions; ADR-0034's whole-`%Machine{}`
embedding stands untouched

## Context

ADR-0052 gave the library two versioned binary contracts - a position
(`Statifier.Position`) and a chart (`Statifier.Chart`, its st-i7y7
amendment) - and its decision 8 explicitly left the third persistable
artifact, `Statifier.Session.Recording`, out of scope, filing it as
st-hz2a. Its Consequences name that requirement as what reopens the
ground. This record answers it.

A recording is already a plain term: every field is asserted and tested
free of pids, refs, ports, and funs, and a raw `term_to_binary` round
trip is pinned green
(`test/statifier/session/recording_test.exs:224-248`). So, exactly as
0052's Context said of positions, the mechanics of encoding were never
the open question. What a recording lacks is a *supported* contract: an
envelope with a format version checked before use, a chart identity a
host can verify a load against, no compiled term written (ADR-0014 item
2, 0052 decision 3), and a `:safe` decode story - which the module-atom
`:invoke_handlers` map (ADR-0051) makes genuinely non-trivial here in a
way it was not for positions or charts.

Three facts about the struct bound every answer:

- **It is `@opaque`** (`lib/statifier/session/recording.ex:105-109`),
  with exactly four readers - `machine/1`, `opts/1`, `entries/1`,
  `size/1` - and construction only through `new/2` and the six `put_*`
  appenders. `Statifier.Replay.run/1` honors that boundary: it re-drives
  `Recording.machine(recording)` from inside the recording through those
  accessors alone (`lib/statifier/replay.ex:186-215`).
- **It embeds the whole `%Machine{}` by design.** ADR-0034 chose the
  embedding so replay never reconciles one artifact against another; any
  identity work here must preserve that property, not reopen it. The
  st-i7y7 amendment added a consequence on top: an identified `%Machine{}`
  now retains its source binary and persisted compile opts for its whole
  lifetime, which enlarges every recording that embeds one.
- **Its `opts` carry `:invoke_handlers` as module atoms** (ADR-0051
  decision 4, recorded so replay's plan context matches the live run's).
  `:erlang.binary_to_term/2` with `:safe` refuses to create atoms a blob
  names (0052's Consequences), and a module's atom exists on a node only
  once that module is loaded - so whether and how those atoms survive a
  serialization boundary is a real question, not plumbing.

**Why this is a new record and not a third state of ADR-0052.** 0052 has
an amendment precedent, but st-i7y7 amended because it *superseded*
something 0052 said - decision 3's implicit no-chart-codec corollary.
Nothing here supersedes, narrows, or widens anything 0052 states: every
decision there stands and is consumed as accepted. Decision 8's own words
chose this shape in advance ("filed as its own follow-up (st-hz2a) rather
than folded into this record by proximity"), on grounds that still hold -
a different struct, a different consumer, a different embedding decision
already on record. The procedural precedent is ADR-0055 against ADR-0054:
a follow-up that decides a gap the parent recorded, without altering the
parent's decisions, takes the next free number, and the parent's status
line gains a pointer on the implementing branch.

## Decision

**1. The codec lives on `Statifier.Session.Recording` itself, because
`@opaque` decides placement.** `Statifier.Position` and `Statifier.Chart`
live on dedicated boundary modules (0052 decision 5); the recording's
codec cannot follow them off-module without breaking the exact boundary
st-hz2a asks to preserve. Only the owning module may decompose and
rebuild an `@opaque` struct - dialyzer's opaqueness checking makes a
foreign `%Recording{...}` match or construction a violation, which is why
`Statifier.Replay` reads through the accessors. A separate codec module
could technically stay legal - `entries/1`'s `entry()` tuples are a
public `@type`, so it could re-fold `new/2` plus the six `put_*` heads to
rebuild - and that path is rejected: it re-normalizes `opts` on every
decode (a future default change in `new/2` would silently rewrite
recorded history rather than restore it), couples the codec to every
appender head, and re-derives the struct where a decoder's job is to
restore it. Decision 5's two grounds do not apply here anyway: the
recording is already a session-boundary artifact, not the pure core, and
`recording.ex`'s moduledoc already owns this artifact's documentation
burden, so there is no second concern being mixed in. Neither function
performs I/O; ADR-0003 does not apply to the pair, same as for the two
shipped codecs.

**2. Identity gains no new accessor, and no existing one is repurposed:
`Recording.machine/1` composed with `Statifier.Machine.identity/1` is
already the reader.** The bead's either/or has a third answer - the
surface already exposes the fact. A dedicated `Recording.identity/1`
would be a second reader of one fact, the same redundancy
`lib/statifier/machine.ex`'s "No top-level `initial`" section rules out
for the Machine itself. The accessor surface is therefore unchanged; the
codec pair is the only new public surface, and the boundary's meaning
survives it: a recording is still constructed only by this module's own
functions, and `from_binary/1` restores only what `to_binary/1` wrote.

**3. The blob substitutes the chart's inputs for the compiled chart - a
nested `Statifier.Chart.to_binary/1` blob in the machine's place - and
`from_binary/1` recompiles it and re-embeds the resulting `%Machine{}`
before returning.** No compiled term is written, so ADR-0014 item 2 and
0052 decision 3 are consumed intact. ADR-0034's embedding is preserved
where it operates - the in-memory value: no caller, `Statifier.Replay`
included, ever sees a machine-less recording, and the `@opaque` `t()`
gains no `nil` arm; rehydration happens entirely at decode time. The
whole verification chain is inherited rather than re-implemented:
`Chart.from_binary/1` checks its own version, recompiles the stored
source under the stored opts through `Statifier.compile/2`, and compares
the recompiled identity against the stored one, in that order, for the
reasons 0052 already argued. `to_binary/1` refuses exactly when
`Chart.to_binary/1` refuses (`{:error, :unidentified_chart}`), which
extends 0052 decision 4's structural guarantee to recordings: no
recording blob can exist whose chart cannot be identity-checked on load.
A session recorded over an unidentified `%Machine{}` (built via
`Statifier.Compiler.compile/1` directly) records and replays in memory
exactly as today; only persistence is refused - the same rule positions
already live under.

Nesting the chart blob, rather than inlining `source`/`compile_opts`/
`identity` as recording-envelope fields, is deliberate: one codec per
artifact keeps the chart half's compatibility story owned by
`Statifier.Chart`, so a chart-format bump is not forced to be a
recording-format bump (nor the reverse), and the chart codec's error
vocabulary arrives at the recording's caller recognizably instead of
re-spelled.

**4. The recording envelope carries its own format version, checked
before the nested chart is touched, and nested chart errors surface
wrapped.** The envelope is
`{:statifier_recording, @format_version, chart_blob, opts, entries}`,
written by `term_to_binary` and decoded with `:safe` plus the
one-literal-shape match and per-function `@sobelow_skip` the three
shipped decoders share (0052's Consequences). Two shape choices are part
of the contract:

- `entries` is written in `entries/1`'s append order, not the struct
  field's internal order. The field stores entries reversed as a
  prepend-list optimization; a blob that copied the raw field would bake
  that storage choice into the format, and this keeps it an
  implementation detail no blob depends on. `from_binary/1` restores the
  internal representation itself - the owning-module placement of
  decision 1 is what makes that legal.
- Nested chart failures come back as `{:error, {:chart, reason}}` with
  `reason` being `Chart.from_binary/1`'s own tuple, unflattened. Two
  envelopes means two version namespaces, and an unwrapped
  `{:unsupported_format_version, v}` would not say which decoder refused;
  the wrap is what keeps `Recording.format_version/0` and
  `Chart.format_version/0` independently bumpable, which is the point of
  nesting.

The version buys an obligation as well as a check: any future widening of
`entry()` - ADR-0048's trailing-routes widening is the precedent that it
happens - is now a format-version decision, not just a typespec edit. A
build must either read the old shape under the old version or refuse it
loudly; silently misreading a narrower tuple is exactly what
`format_version/0` exists to prevent.

**5. `:invoke_handlers` cross the boundary as strings - never as atoms in
the blob, and never as code.** The load-bearing mechanics: `:safe`
refuses to create atoms a blob names, and a module's atom exists only
once the module is loaded. A blob carrying raw handler-module atoms would
therefore decode fine on the node that wrote it and collapse to
`{:error, :not_a_statifier_blob}` on a node that has not yet loaded the
host's handler code - the wrong error for a real, actionable condition.
So `to_binary/1` writes `Atom.to_string/1` of each handler value, and
`from_binary/1` resolves each back with `String.to_existing_atom/1`,
collecting every failure into
`{:error, {:unknown_handler_modules, names}}`, sorted, in one round trip
- an error that says "load your handler code, then decode" instead of
"this is not a statifier blob."

What the codec deliberately does not do: call `Code.ensure_loaded?/1`, or
verify that a resolved module's callbacks behave as they did at record
time. A handler is code, and code cannot travel in a data blob; the
decoding host provides the modules, exactly as it provides them to
`Statifier.Session.start_link/2`. Replay's determinism does depend on
them: `Statifier.Session.Effects.plan/2` dispatches to the handler's
*planning* callbacks during replay (ADR-0051 decision 4), so a decoded
recording replays to the recorded stream only where those planning
callbacks are equivalent to the recorded run's. `perform/2`, the impure
half, is never called by replay (`lib/statifier/replay.ex`'s
`{:handler, _, _}` clause is a no-op), so it needs no equivalence at all.
The planning-equivalence assumption is recorded as an accepted
environmental limit - the same class as ADR-0034's OTP `MapSet`-iteration
caveat - rather than solved, because no codec can verify it.

## Consequences

- New public surface, all on `Statifier.Session.Recording`:
  `to_binary/1` (`{:ok, binary()} | {:error, :unidentified_chart}`),
  `from_binary/1` (`{:ok, t()} | {:error, :not_a_statifier_blob}
  | {:error, {:unsupported_format_version, term()}}
  | {:error, {:chart, term()}}
  | {:error, {:unknown_handler_modules, [String.t()]}}`), and
  `format_version/0`. `Statifier.Replay.run/1` is untouched - its input
  is a `Recording.t()` however obtained, so decode-then-run composes with
  no replay change, and ADR-0049's `subscribe(catch_up: true)` hands a
  live value with no codec involved.
- The st-i7y7 size consequence lands where 0052 predicted and stays
  accepted as priced there: an in-memory recording over an identified
  chart carries the source bytes for its lifetime. That same retention is
  what makes `to_binary/1` possible at all - the source is guaranteed to
  be sitting beside the identity it was hashed from. The blob itself is
  small for the same reason a position blob is: the compiled term never
  travels, so a recording blob is roughly source plus opts plus entries.
- Every `from_binary/1` pays a compile on load - the 0052 amendment's
  accepted cost, inherited unchanged with its recorded compensation (no
  ISA-version check, no compiled-format compatibility story, ever).
- The blob still names atoms beyond the handler map: struct names, entry
  tags, opts keys, event fields. All of those are this library's own and
  exist on any node that has loaded statifier, so `:safe` never refuses
  them. Host-supplied atoms inside recorded *payloads* - an atom a host
  put into `:datamodel` values or event data - remain the host's own
  `:safe` obligation; the codec neither scans for them nor translates
  them.
- Tests the implementing plan owes, each with its sabotage line per
  `docs/testing.md`: a full round trip (record a live run, encode,
  decode, replay, compare stream and terminal position against the live
  run's); the `:unidentified_chart` refusal; the wrapped
  `{:chart, {:identity_mismatch, _, _}}` path via a doctored nested blob;
  the `{:unknown_handler_modules, _}` path; and append-order stability of
  `entries` across a round trip.
- Documentation edits directed to the implementing branch, the ADR-0049
  decision 6 pattern: `docs/persistence.md` gains a recording section
  (what a recording blob carries, the handler-provisioning requirement,
  the planning-equivalence limit); ADR-0052's status line gains a pointer
  to this record, discharging its reopen bullet the way ADR-0054's status
  line points at ADR-0055.
- Open questions recorded rather than decided: whether a host needs to
  read a blob's identity *without* paying the recompile (deferred until a
  consumer asks - a host indexing many recordings stores
  `Identity.to_binary/1` beside each blob at write time, the same pattern
  `docs/persistence.md` already gives positions); and whether handler
  planning-callback equivalence across builds ever needs a checkable
  fingerprint (nothing today could consume the answer, and decision 5
  records the limit instead).
- What would reopen this record: a measured need to decode a recording
  without recompiling its chart (the same trigger the 0052 amendment
  names for itself, arriving through this artifact); a requirement to
  replay a recording against a *different* chart revision than it was
  recorded over - the migration counterpart 0052 decision 6 gives
  positions, deliberately not extended here because replay's determinism
  claim is per-revision by construction; or a change to ADR-0034's
  embedding, which that record owns.

## Related

- ADR-0052 (chart identity, the two shipped codecs, decision 8 filing
  this work, the st-i7y7 chart blob this record nests)
- ADR-0034 (the whole-`%Machine{}` embedding preserved by decision 3; the
  accepted-environmental-limit precedent decision 5 follows)
- ADR-0029 (the four recorded inputs, unchanged in kind here)
- ADR-0051 (`:invoke_handlers` as per-session module atoms; replay's
  handler-dispatch plan context)
- ADR-0049 (the recording as a public catch-up artifact - the consumer
  that makes a supported codec worth having)
- ADR-0048 (the trailing-routes `entry()` widening, decision 4's
  precedent for format-version obligations)
- ADR-0014 (item 2: no compiled predicator term in any blob), ADR-0005
  (interned indexes - the hazard recordings dodge by embedding, and
  positions could not), ADR-0003 (why the codec is not an effect)
