# ADR-0052: Chart identity and position serialization

Status: accepted (2026-08-19) - reaffirms ADR-0014 item 2's premise rather
than amending it (decision 3 below) - amended 2026-08-19 (st-i7y7: decision
3's corollary superseded; a chart blob carries source and compile opts,
still no compiled term) - decision 8's named follow-up answered by ADR-0057
(2026-08-19: a recording blob nests the chart blob, the codec lives on the
`@opaque` owner, `:invoke_handlers` cross as strings)

## Context

A persisted `%Statifier.MachineState{}` is keyed by interned integer state
indexes (ADR-0005). Those indexes are stable within one `Machine` build and
mean nothing across two: adding or reordering a state renumbers them, and a
position loaded against the renumbered chart silently resumes the wrong
states rather than failing. Nothing before this bead (st-m5c3) correlated a
persisted position to the chart revision that produced it, so any
persistence story built on top of `%MachineState{}` - a resume API, the
`statifier_persistence` charter - was unsafe by construction: recompiling a
chart could invalidate every saved configuration with no error at all.

`Statifier.Interpreter`'s moduledoc already promises a `term_to_binary` round
trip, and every field of both `%Machine{}` and `%MachineState{}` is a plain
term with no pid, ref, port, or fun - asserted and tested
(`lib/statifier/session.ex:630`,
`test/statifier/session/recording_test.exs:224-248`). So the mechanics of
encoding either struct were never the open question; correlating the encoded
bytes to the chart that produced them was.

Measured on this branch: a `%MachineState{}` encoded with its embedded
`%Machine{}` runs 5848 bytes; the same state with the machine stripped runs
725 bytes - roughly 88% of a small position's bytes are the compiled chart,
not the position itself.

`Statifier.compile/2` (`lib/statifier.ex:76-86`) is the only place in the
library holding both the SCXML source binary and the finished `%Machine{}`;
`Compiler.compile/1` never receives the source, and nothing past
`Validator.validate/3` retains the document text. Upstream, predicator
already recommends against persisting its own compiled form:
`compiled.ex:10-38` advises storing the source (or the instruction list) and
recompiling, not storing the `%Predicator.Compiled{}` struct itself.
`Predicator.isa_version/0` is the prior art this record follows for an
integer format version checked before use, rather than an inferred or
absent one.

## Decision

**1. Chart identity is a SHA-256 hash of the SCXML source bytes handed to
`Statifier.compile/2`, plus an optional embedder-supplied name and version -
not a hash over the compiled `%Machine{}` term.** A term-level hash would
vary with compiler internals that carry no meaning to a host comparing chart
revisions - state-numbering order, expression-compilation output - while two
byte-identical SCXML documents must always agree regardless of what the
compiler does with them on a given build. `Statifier.Machine.Identity.of_source/2`
hashes the source with `:sha256` and carries `opts[:chart_name]` /
`opts[:chart_version]` alongside the hash unfiltered from `compile/2`'s own
option list. `Statifier.compile/2` stamps the resulting
`Statifier.Machine.Identity.t()` onto every `Machine` it produces
(`Machine.identity/1`); a `Machine` built any other way (directly from
`Compiler.compile/1`, bypassing `compile/2`) carries `identity: nil` and is
therefore unidentified.

Two identities are the same chart only through `Identity.matches?/2`, never
`==/2` on the struct directly: `nil` on either side answers `false`, never
`true`, and a future field addition to the struct should not silently change
what "the same chart" means at every existing comparison site the way a bare
`==/2` would.

**2. A position blob carries the identity and an integer format version,
checked before use.** `Statifier.Position.to_binary/1` writes a tagged,
versioned envelope; `from_binary/2` decodes it, checks the envelope's tag,
checks the format version against what this build understands, and only
then checks the blob's identity against the caller-supplied `Machine`'s.
Version is checked before identity deliberately: a future format whose
identity representation itself changed shape should report the version
mismatch, not a confusing identity failure produced by misreading the new
shape as the old one. The version lives as a bare integer
(`Position.format_version/0`, `Identity.format_version/0`), so a future
format change is a version bump at that one call site rather than an
inference drawn from the blob's shape - the same choice `Predicator.isa_version/0`
made for the same reason.

**3. A `%Machine{}` is never serialized.** ADR-0014 item 2 already established
that this library stores no predicator instruction lists; this record
*reaffirms* that premise rather than amending it, because the substitute for
persisting a compiled `Machine` is the same one predicator gives its own
callers for `%Predicator.Compiled{}`: persist the source, recompile, and let
the content hash make that recompilation safe to verify. `Position.to_binary/1`
therefore refuses to encode a `MachineState` whose `Machine` carries no
identity (`{:error, :unidentified_chart}`) - a `Machine` built without a
recorded source would have nothing for `from_binary/2` to check a future
load against, so no blob is produced for it at all. On success, the payload
is `machine_state` as a plain map with `:machine` deleted, never
`%{machine_state | machine: nil}` - `MachineState.t()` declares
`machine: Machine.t()`, not `Machine.t() | nil`, so assigning `nil` there
would be a dialyzer contract violation, and dropping the key from the map
entirely keeps the whole struct well-typed while still writing no compiled
chart to the blob. This is also what makes a position blob far smaller than
a naive `term_to_binary(machine_state)`: the compiled chart is the
overwhelming majority of a small position's bytes, per the measurement in
Context.

**4. `to_binary/1` refuses an unidentified chart, so no unverifiable blob can
exist.** This is the same fact as decision 3's refusal, stated as the
structural guarantee it buys: every position blob that exists was written
from a `Machine` that carried an identity, so `from_binary/2` always has
something to check a load against. There is no code path that writes a blob
first and discovers it cannot be verified later.

**5. Serialization lives on `Statifier.Position`, a boundary module, not on
`%MachineState{}` itself.** `docs/architecture.md` principle 2 (ADR-0003)
keeps the pure core free of concerns that belong to persisting a value across
a process or machine boundary; encode/decode-with-identity-check is exactly
such a concern, not a concern of computing a position. `lib/statifier/machine_state.ex`
already carries the full Doctor moduledoc burden for the core position
struct, so adding a second one there for the serialization contract would
mix the two. Neither `to_binary/1` nor `from_binary/2` performs I/O - encoding
and decoding a binary in memory is not an effect a caller has to route
around, so ADR-0003 does not apply to `Position` itself; it applies to where
the module sits relative to the core.

**6. `export/1` / `import/2` speak string ids (ADR-0005's boundary rule),
and perform no identity check, because crossing a revision is their whole
purpose.** `to_binary/1` /
`from_binary/2` are the same-revision contract: they refuse to cross a chart
revision at all. `export/1` and `import/2` are the deliberate counterpart - a
position translated into string state ids so a host holding a position saved
against revision A can load it onto revision B on purpose. `import/2`
performs no identity check: it does not compare `export/1`'s `:identity` key
to the target `Machine`'s own identity, and the malformed-export check does
not require `:identity` to be present or well-formed at all. A host
hand-editing an export may update, delete, or leave that key stale, and all
three import identically - the key is provenance for a host that wants to
log "migrated from revision X to revision Y," not a check this module
performs on the host's behalf.

The bead this record closes cited "the ADR-0006 public-surface rule" for the
string-id vocabulary. That is a mis-citation, corrected here rather than
carried forward: ADR-0006 is the conformance corpus and regression ratchet,
and its surface-shaped content is a closed list of the functions
`Statifier.Case` may *drive the library through* - a constraint on what the
corpus couples to, which that record is explicit is "not library surface".
The rule the bead describes is ADR-0005's Consequences: "Configurations are
`MapSet`s of integers; string IDs appear only at the API." So ADR-0006 is
not reopened by adding `to_binary/1`, `from_binary/2`, `export/1` or
`import/2` - none of them is a driving function, and the corpus references
none of them. That last clause is checked rather than asserted: a grep for
qualified calls to all four, plus `Machine.Identity` and `Machine.identity/1`,
over `test/support/`, `test/scion_tests/` and `test/scxml_tests/` returns
nothing. A future change that does couple the corpus to one of them reopens
ADR-0006 by its own terms, and is a different decision from this one.

The exported map deliberately omits four fields, none of them silently
dropped: `internal_queue`, because `export/1` refuses a non-empty one
outright (`{:error, :internal_queue_not_empty}` - the queued internal events
were selected against the source chart's own transitions, so a position
mid-macrostep is not something to move across chart revisions; a host drains
to quiescence first); `routes` and `invoke_types`, because both are
per-drive/per-session snapshots a driver re-stamps before the next drive
(ADR-0048, ADR-0051) rather than durable position state; and `machine`,
because the entire point of the string-id vocabulary is to let a host load
the exported map onto a *different* `Machine` than the one that produced it.
`import/2` always sets `internal_queue` to a fresh empty queue and
`routes`/`invoke_types` to `nil`, leaving both for the driver to re-stamp on
the next drive.

`export/1` also refuses any referenced state with no author-written id
(`{:error, {:unnameable_states, indexes}}`, every offending index across
every field collected at once) rather than silently dropping it - the one
documented exception is the root, index `0`, which has no written id by
construction and is re-added by `import/2` to `configuration` and
`entered_states` on the way back in.

**7. The blob records no library version; the format version is the only
compatibility fact it carries.** `Identity.to_binary/1` and
`Position.to_binary/1` both write `@format_version`, an integer local to
each module, not `Application.spec(:statifier, :vsn)` or any other
library-version string. A library version answers "which release wrote
this," which is not the question a loader needs answered; the format version
answers "can this build's decoder read this envelope's shape," which is the
only question `from_binary/2` actually checks. Coupling the blob to a
library version would force a format bump on every release regardless of
whether the envelope's shape changed, and would give a host nothing it could
act on that the format version does not already give it.

**8. `Session.Recording` is out of scope.** ADR-0034 already settled what a
recording is for - re-driving the pure core deterministically from four
recorded inputs, not resuming from an arbitrary position - and a
recording's `@opaque` boundary embeds the whole `Machine` it re-drives
against by design, for exactly that replay purpose. Extending chart identity
and a format version to `Session.Recording` is real, useful work - the
embedded `Machine` and the `:invoke_handlers` module-atom portability
question both need their own argument - but it is a different struct with a
different consumer and a different embedding decision already on record, so
it is filed as its own follow-up (st-hz2a) rather than folded into this
record by proximity.

**Amendment (st-i7y7):** no compiled term of any kind is serialized by
anything this amendment adds. Decision 3's literal rule and ADR-0014 item
2's premise are both untouched, and neither needs its own amendment for
that reason.

What decision 3 also carried, unstated as its own clause, was an implicit
corollary: that the library therefore ships no chart-level binary contract
at all, and leaves "persist the source and recompile" as advice for every
host to implement for itself. That corollary is what this amendment
supersedes. `Statifier.Chart.to_binary/1` and `from_binary/1`
(`lib/statifier/chart.ex`) mechanize that advice: a host calls one function
to get a blob and one function to get a `Machine.t()` back, rather than
inventing its own envelope around `Machine.source/1` and
`Machine.compile_opts/1`.

Encoding the compiled `Machine` itself was considered and rejected, for a
reason worth recording here so the next reader does not re-derive it.
Upstream, predicator's `compiled.ex:32-38` hazard is a *re-pairing* hazard:
instructions and a span table stored separately, and re-paired against each
other incorrectly on load. A whole-struct round trip of a `Machine.t()`
cannot trigger that specific hazard, because there is nothing to re-pair -
everything travels together in one term. But recompiling from source
sidesteps a different hazard entirely: predicator ISA skew across a library
upgrade. A build that recompiles the stored source always evaluates
instructions it compiled itself, so there is no compiled-instruction format
whose compatibility across a predicator version bump this library would
ever need to reason about.

`Statifier.Chart.to_binary/1` writes `machine.source` and
`machine.compile_opts` verbatim, and `compile_opts` is filtered through the
same closed allowlist `Statifier.compile/2` already stamps onto every
`Machine` it produces: `:invoke_content_markup`, `:chart_name`,
`:chart_version`. The allowlist is closed rather than open for a
decode-safety reason, not a completeness one - `Identity.from_binary/1` and
`Position.from_binary/2` already decode with `:erlang.binary_to_term/2` and
the `:safe` option (Consequences, below), which refuses to create atoms a
blob names; an open `compile_opts` set would let an embedder's own
unrecognized option key end up in a blob this library wrote, making that
blob undecodable by a build that never saw the embedder's atom. Adding a
fourth recognized `compile/2` option therefore carries an obligation this
amendment makes explicit: decide whether the new option belongs in
`@persisted_compile_opts` or is provably inert for compilation, the same
choice `lib/statifier.ex`'s own comment above that allowlist already
states for the three keys it holds today.

`Statifier.Chart` lives as its own module, not as functions on `Machine`,
for the same reason `Statifier.Position` does not live on `MachineState`:
decision 5's boundary-module rule extends to the chart codec unchanged.
Here the layering argument is sharper than it is for `Position`, because it
is not just a style preference - `from_binary/1` calls `Statifier.compile/2`
to rebuild its result, and `Statifier.compile/2` itself produces a
`Machine.t()`. Putting the codec on `Machine` would have the thing produced
call back into its own producer, which ADR-0003's layering already rules
out; `Position.from_binary/2` has no comparable call into `Statifier`, so
for `Position` decision 5's placement is a boundary-cleanliness argument
only. The bead that requested this work said `Machine.to_binary/1`; the
shipped pair is `Statifier.Chart.to_binary/1` and `from_binary/1` instead -
the same module substitution decision 5 already made when it put
`Position`'s codec on a dedicated module rather than on `MachineState`
itself.

Consequences of shipping this pair: every `from_binary/1` call pays a
compile on load, in exchange for never needing an ISA-version check or a
compiled-format compatibility story at all. And every `Machine` that
carries `source` and `compile_opts` now retains its source binary for its
whole lifetime, not only at the moment `compile/2` returns it - which also
enlarges every `Session.Recording` that embeds such a `Machine`, since a
recording's `@opaque` boundary embeds the whole `Machine` it re-drives
against (decision 8). That is still out of scope here, for the same reason
decision 8 gave: it is filed under st-hz2a, not folded into this amendment
by proximity.

What would reopen this amendment: recompilation cost on load becoming a
measured operational problem for some host, rather than an accepted one.
That is exactly the case for storing a compiled form instead - and
therefore for the ISA-version check and the compiled-format compatibility
story this shape exists to avoid needing at all.

## Consequences

- Every position blob is whitespace-sensitive on the SCXML source: two
  documents that differ only in formatting hash to different identities and
  therefore refuse to interoperate, even when they would compile to
  identical `Machine` structs. This is the accepted cost of hashing bytes a
  host actually retains rather than a canonicalized or term-level
  representation a host would have to reconstruct identically to compare.
- A host choosing to support a chart revision bump must pick one of two
  migration stories itself: drain existing positions to completion on the
  old chart before switching new positions to the new revision, or migrate
  positions across the revision via `export/1` / `import/2` with a
  hand-or-programmatic id mapping. `docs/persistence.md` names both and the
  concrete tradeoff between them; this record does not pick one for every
  host.
- `Identity.from_binary/1` and `Position.from_binary/2` both call
  `:erlang.binary_to_term/2` with the `:safe` option, which refuses to
  create atoms a blob names, so a hostile or corrupt blob cannot grow the
  atom table. `:safe` does not prevent decoding a fun term, so both decoders
  additionally match the decoded value against one literal tagged-tuple
  shape and treat anything else as `{:error, :not_a_statifier_blob}` -
  nothing decoded is ever called. Sobelow's `Misc.BinToTerm` check fires on
  the call site regardless of `:safe`, so both are `@sobelow_skip`-annotated
  per function, not exempted by file, so the rest of each module stays
  scanned.
- `docs/persistence.md` is the concern-scoped doc this decision's hazard and
  migration stories live in; `docs/architecture.md` and `docs/extending.md`
  each carry one cross-reference to it.
- What would reopen this record: a requirement to extend identity and format
  versioning to `Session.Recording` (decision 8's own follow-up, st-hz2a),
  or a requirement to canonicalize SCXML source before hashing it (decision
  1's whitespace-sensitivity cost becoming a real operational problem for
  some host, rather than an accepted one).

## Related

- ADR-0005 (interned state indexes - the hazard this record exists to
  detect, and the boundary rule `export`/`import`'s string ids follow),
  ADR-0006 (the corpus driving surface, deliberately *not* reopened here -
  see decision 6), ADR-0014 (item 2's no-instruction-list premise,
  reaffirmed by decision 3), ADR-0034 (replay's pure fold and why `Session.Recording` is
  out of scope), ADR-0048 and ADR-0051 (the per-drive/per-session snapshot
  fields `export/1` omits).
