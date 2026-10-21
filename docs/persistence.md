# How to persist and resume an execution

**Read this to:** save an execution and load it again without resuming the
wrong state.
**Short version:** a position stores interned integer state indexes, which
mean nothing across two chart builds. Statifier stamps each blob with the
chart identity and refuses a mismatch. Persist the SCXML source, the
identity, and the position. Write only at quiescence.

This page explains the decisions for a host author who has not read the
ADRs.

Decisions:
[ADR-0052](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0052-chart-identity-and-position-serialization.md),
[ADR-0005](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0005-full-configuration-and-interned-state-indexes.md).

## The four nouns

This page uses four nouns. Each has one job:

| Noun | Identity | Owner | Changes when |
|---|---|---|---|
| **Document** | The host's stable id for the thing an author edits | The host's authoring store | Never |
| **Revision** | The document id plus an ordinal or hash | The host's revision store (a `statifier_blocks` document carries the ordinal in its `revision` field) | Every saved edit |
| **Chart** | The SHA-256 hash of the SCXML source bytes handed to `Statifier.compile/2`, plus the optional `:chart_name` and `:chart_version` (`Statifier.Machine.Identity`, ADR-0052) | This engine | Every publish that changes a byte of the SCXML, or its name or version |
| **Execution** | A minted id, pinned to one chart hash | The persistence package (`statifier_persistence`) or the host | Re-pinned only by an explicit migration |

A position (below) is the saved state of one execution. It belongs to the
chart that the execution is pinned to.

- Byte-identical SCXML compiled under the same name and version is one chart.
- Publishing a new chart does not re-pin any execution.
- An execution moves to another chart only when a host migrates it on
  purpose, by story B below.

## The hazard

The active configuration, `entered_states`, `states_to_invoke`, and history
values of a `Statifier.MachineState.t()` are `MapSet`s of interned integer
state indexes. They are not state ids. The compiler assigns the indexes when
it lays states out in a flat array in document order. The indexes are stable
*within* one `Statifier.Machine.t()` build. They have no meaning across two
builds. The Consequences section of ADR-0005 says this:

> Slight cost: a translation step at the boundary, and debugging views must
> map indexes back to IDs (the Machine keeps both directions).

If you add a state, remove one, or reorder the SCXML source, every index
after the change point gets a new number. A bare
`MapSet.t(non_neg_integer())` carries no information about which chart build
produced it.

Suppose you load a position that was saved against yesterday's chart onto
today's recompiled chart. The integers still decode into a valid-looking
`MachineState`, but they name different states than they did yesterday. The
machine does not crash. It silently resumes the wrong configuration. This
page turns that failure into a loud error.

Decision: [ADR-0005](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0005-full-configuration-and-interned-state-indexes.md).

## What identity buys

`Statifier.Position.to_binary/1` stamps two separate facts onto a position
blob, in two separate fields:

- **The content hash** (`Statifier.Machine.Identity`) detects a chart
  change. It is a SHA-256 hash of the SCXML source bytes given to
  `Statifier.compile/2`. It is not a hash of the compiled `Machine` term.
  Two byte-identical sources have the same hash, whatever the compiler did
  with them. The hash changes when a state is added, removed, or reordered
  in the source.
- **The format version** (`Statifier.Position.format_version/0`) detects a
  library upgrade that changed the shape of the blob. It does not depend on
  whether the chart changed.

`Statifier.Position.from_binary/2` checks the format version first and the
identity second. A future format can change the shape of the identity
representation. Then `from_binary/2` reports the version mismatch and not a
confusing identity failure from a misread of the new shape.

A mismatch on either axis is a returned error tuple and never a silent
misread:

- `{:error, {:unsupported_format_version, version}}`
- `{:error, {:identity_mismatch, expected, actual}}`

One exception on the version axis: `from_binary/2` also reads a version-1
blob (written before `timer_counter` existed). It sets `timer_counter` to
`0`, because no ordinal was ever minted against a version-1 position
(ADR-0059).

## Migration story A: drain on the old version

This is the default recommendation. It costs only the effort to keep one
extra compiled chart reachable for a while. It never changes the meaning of
the position of an execution while the execution runs.

1. Keep the old chart source compiled and reachable. Keep the source bytes
   and not only the `Machine` built from them, because `Statifier.compile/2`
   needs the bytes again to reproduce the same identity.
2. Run every execution pinned to the old chart to completion against the
   same compiled `Machine`.
3. Start every new execution on the new chart.
4. After the last execution pinned to the old chart finishes (or is
   abandoned), stop loading the old chart.

No translation happens and no data is lost. The length of the migration
depends on how long an execution lives.

## Migration story B: position migration via string ids

Re-pin an execution to another chart only with an explicit plan that uses
this pair of functions:

- `Statifier.Position.export/1` translates a `MachineState` into a map keyed
  by state ids (strings) instead of interned indexes.
- `Statifier.Position.import/2` reverses the translation onto a *different*
  `Machine` than the one that produced the export.

Between the two calls, a host or an operator can rename an id, drop a field
for a state that the new chart deleted, or leave the export unchanged. Unlike
`to_binary/1` and `from_binary/2`, `import/2` does not check identity. This
pair exists so that you can cross to another chart on purpose.

**Rename.** A rename is not a one-field edit. A state id appears in every
exported field that references that state, and `import/2` resolves all of
them. An id left stale in any one field fails the whole import. To rename
`"b"` to `"bee"`, edit it in these places:

- `configuration`, `entered_states` and `states_to_invoke` (each a set of
  ids)
- `history_values` (both its keys and the id sets in its values)
- the state-id half of every `active_invocations` key

The error names the stale id but not the field it came from. Suppose an
import still reports `{:error, {:unknown_state_ids, ["b"]}}` after a rename
that seems complete. Then the edit missed a field. The target chart does not
lack a state.

`import/2` has these limits:

- **Deleted state.** It cannot invent a state that the new chart deleted.
  If the export references a state id that does not resolve against the
  target `Machine`, `import/2` returns `{:error, {:unknown_state_ids, ids}}`.
  It names every such id, sorted, in one round trip. A host must resolve
  every id before `import/2` succeeds: map it to a replacement id in the
  exported map, or accept that the execution cannot be migrated.
- **Edited `<invoke>` children.** It cannot fix an `active_invocations` key
  whose state's `<invoke>` children were edited. The key pairs a state id
  with an integer `invoke_index`. This is an ordinal, within the state, in
  document order over the `<invoke>` children of that state. The ordinal
  survives states that are added or reordered elsewhere in the chart. It
  does not survive an edit to the `<invoke>` children of that one state. The
  host must renumber the ordinal itself, in the same way as for a renamed
  state id.
- **Non-quiescent position.** `export/1` returns
  `{:error, :internal_queue_not_empty}` for a `MachineState` with a
  non-empty internal event queue. The chart selected those queued events
  against its own transitions, so you cannot move a position in the middle
  of a macrostep across charts. A host must drain to quiescence (let the
  macrostep finish) before it exports. A terminated position needs no
  draining. `exit_interpreter/1` empties the internal queue as its last
  step, so a `status: :done` machine state is quiescent by construction and
  always passes this check.

`export/1` also refuses, and does not silently drop, any referenced state
that has no author-written id (`{:error, {:unnameable_states, indexes}}`). A
state that a host wants to migrate through this path needs an id in the SCXML
source.

## What a host must persist

A host must persist three things:

1. **The SCXML source.** `Statifier.compile/2` recompiles the exact `Machine`
   from it deterministically, which makes the content hash verifiable.
   Recompile the retained source and compare the resulting identity with the
   identity of a loaded blob. This proves that "this position matches this
   chart" is still true.
2. **The identity blob** (`Statifier.Machine.Identity.to_binary/1`). A host
   can then record which chart a position belongs to without recompiling the
   source to find out.
3. **The position blob** (`Statifier.Position.to_binary/1`). It carries the
   identity and the state of the position.

## Persisting the chart itself

A host that manages its own SCXML source does not need to persist it a
second time through this library. The three items above are enough.

A host that cannot retain its own source can persist a single blob instead.
An example is an embedder whose deployment does not ship `.scxml` files with
its data. Use `Statifier.Chart.to_binary/1`. It carries the SCXML source,
the persisted subset of the compile options, and the identity of the chart,
all in one envelope. `Statifier.Chart.from_binary/1` recompiles a
`Machine.t()` from it on load. Two lines perform the identity check that a
position blob also needs:

```elixir
{:ok, machine} = Statifier.Chart.from_binary(chart_blob)
{:ok, machine_state} = Statifier.Position.from_binary(position_blob, machine)
```

This automates the same "persist the source, recompile" approach that the
three-item list above follows by hand.

Decision: [ADR-0052 amendment (st-i7y7)](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0052-chart-identity-and-position-serialization.md)
gives the reason it is its own module and not functions on `Machine`.

`from_binary/1` returns `{:error, :not_a_statifier_blob}` for anything that
is not the chart envelope of this library. This includes a foreign
`term_to_binary` blob, corrupt bytes, or an envelope whose source or options
have the wrong shape. It makes this decision before any version, compile, or
identity check runs. The other three errors, in the order that
`from_binary/1` checks them:

- `{:error, {:unsupported_format_version, version}}`
- `{:error, {:compile_failed, errors}}`
- `{:error, {:identity_mismatch, expected, actual}}`

`Statifier.Chart.to_binary/1` has one refusal: `{:error, :unidentified_chart}`.

## Resuming a session

This section explains how a host turns a persisted position back into a
running `Statifier.Session`, and what the host still owns afterwards.

Decision: [ADR-0060](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0060-resuming-a-session-from-a-persisted-position.md).

The recipe has two lines. Recompile the chart, then give the persisted
position to `start_link/2`, which decodes it against that chart:

```elixir
{:ok, machine} = Statifier.Chart.from_binary(chart_blob)
{:ok, pid} = Statifier.Session.start_link(machine, resume: position_blob)
```

`resume:` also accepts an already-decoded `%Statifier.MachineState{}`. This
is the output of `Statifier.Position.import/2` from migration story B. A host
that migrated the position of an execution to another chart by hand can give
the result directly to `start_link/2`, with no round trip through
`to_binary/1`. Both shapes use the same identity gate that this page
describes. `start_link/2` refuses both a blob that does not match `machine`
and a struct whose own `machine` does not match it. It does not resume them
against the wrong chart.

A host that drives `Statifier.Interpreter` directly, with no `Session`, uses
the pure-core equivalent of this recipe:

1. Decode the position.
2. Re-stamp `routes`, `invoke_types` and `send_types`.
   `Statifier.Position.from_binary/2` returns these three fields as `nil` on
   purpose, because they are per-driver snapshots and not durable position
   state.
3. Call any advance entry.

The full sequence is in the "Rehydrating a position" section of the
`Statifier.Interpreter` moduledoc.

A resumed session starts with the persisted configuration, datamodel,
history values, `entered_states`, `states_to_invoke`, `active_invocations`,
and all six counters exactly as they were saved. It makes no
`Statifier.Interpreter.initialize/2` call. It does not re-enter the initial
states of the chart. It does not run a top-level `<script>` or `<onentry>`
block a second time.

### What resume does not restore

A position cannot carry three things. Each has a structural reason:

- **In-flight delayed sends.** The position stores no scheduling deadline.
  `delay_ms` on a `SendDelayed` effect is relative, and no wall-clock instant
  is written where a position could carry it. A resumed session starts with
  an empty timer table and fires nothing that it scheduled before
  persisting. The host is responsible for durable scheduling. It uses the
  public `SendDelayed`/`Cancel` effect vocabulary. A host that wants timers
  to survive a resume must re-arm them itself from that vocabulary. A
  position blob carries nothing for this. Decisions: ADR-0034 decision 2
  (no clock), ADR-0054/0055/0059 (durable timers).
- **Live invoked children.** Pids, monitor refs, and child session ids are
  process-local. They were never part of `%MachineState{}`, so a position
  loses nothing here. The position carries `active_invocations` (the
  *record* of what was invoked) forward verbatim. See the divergence below.
  `invoke_id` itself is stable across a persist/reload cycle. It is a
  deterministic counter on `%MachineState{}` and not a newly generated value
  (`docs/extending.md`, "Async and long-lived invocations"). To
  re-establish a child, start or reattach a process behind an id that the
  resumed session already recognizes, through the invoke handler registry.
  Decision: ADR-0051.
- **The external inbox.** `Statifier.Session.Inbox` lives outside
  `%MachineState{}`. It was never persistable. Anything queued but not yet
  dequeued at persist time is lost with the process that held it, as with
  any other unpersisted mailbox. Decision: ADR-0002 (core/session split).

### The `active_invocations` divergence

A resumed session carries `active_invocations` forward, but its live process
table starts empty. The two can disagree for the life of the resumed
session, until the host re-establishes each child. The library accepts and
documents this.

- If `active_invocations` were cleared on resume, the meaning of the
  position would change. It would also disagree with `states_to_invoke` and
  `configuration`, which is worse.
- The divergence is safe because `{:stop_child, invoke_id}` treats an
  unknown id as a silent no-op. A `<cancel>` or an exit sweep over an
  invocation that is not yet re-established stops nothing and does not
  crash.
- The host must re-establish the processes behind the ids in
  `active_invocations` through the invoke handler registry (ADR-0051). This
  page does not track that work item.

### Refusals

`start_link/2` returns `{:error, {:resume, reason}}` and does not start a
session that is silently wrong:

| `reason` | Why | Fix |
|---|---|---|
| `{:conflicting_options, opts}` | `:resume` was passed alongside `:trace`, `:datamodel`, or `:max_macrostep_rounds` (`MachineState.new/2`'s own options, not read on this path) or `:invoked_by` (a child session is always library-started, never resumed) | Drop the conflicting option. A resumed position already carries its own trace, datamodel and rounds state |
| `:not_a_statifier_blob` | The blob is not this library's own position envelope | Pass a blob written by `Statifier.Position.to_binary/1` |
| `{:unsupported_format_version, v}` | The blob's format version is newer or older than this build understands | Load with a build that supports version `v`, or re-persist under the current version |
| `{:identity_mismatch, expected, actual}` | The position was saved against a different chart than `machine` | Recompile the chart the position was actually saved against, or migrate the position via `Statifier.Position.export/1` / `import/2` (migration story B above) |
| `:unidentified_chart` | Either side of the resume (the `machine` of the position or the supplied `machine`) was never identified. An example is a `Machine` resolved through `:invoke_source` or built directly with `Statifier.Compiler.compile/1` | Compile the chart through `Statifier.compile/2` so it carries an identity |
| `:position_not_quiescent` | The position's internal event queue is non-empty | Drain to quiescence (let the macrostep finish) before you persist. `Statifier.Position.export/1` gives the same instruction |
| `:position_not_running` | The position has `running: false` (`status: :done`) | Inspect a finished position directly with `Statifier.Position.from_binary/2` and `Statifier.active_leaf_states/1`. A session has nothing left to do with it |

### The `_sessionid` rule

By default, a resumed session uses `datamodel["_sessionid"]` of the
position as its `session_id`. You can pass `:session_id` with `:resume` to
override it. The override rewrites `datamodel["_sessionid"]` to match. The
invariant `session_id == datamodel["_sessionid"]` therefore always holds.
This library relies on that invariant elsewhere (ADR-0048 route stamping,
telemetry, and the `opts[:session_id]` contract of `Recording.new/2`).

Reuse the id and do not mint a new one. The same id keeps
`#_scxml_<sessionid>` addressing and any external reference to the session
working across the deploy or crash that made the resume necessary.

### `resume:` plus `record: true`

If you pass both, the new `Statifier.Session.Recording.t()` is anchored at
the resumed position and not at the initial configuration of the chart. The
`anchor` field of the recording carries the resumed position as a blob.
`Statifier.Replay.run/1` decodes it and starts from it, and does not call
`Statifier.Interpreter.initialize/2`.

`subscribe/3` with `catch_up: true` and `Statifier.Replay.run/1` behave as
they do for an unresumed session. They reproduce the prefix that the session
actually notified. The stream of an anchored recording has no initialization
effects, because a resumed session performs no initialization. The catch-up
invariant therefore holds exactly: no initialization burst is missing from
the prefix.

A recording (`Statifier.Session.Recording.t()`) is the third persistable
artifact, with a position and a chart. Its blob carries these items:

- the nested chart blob (the envelope of `Statifier.Chart.to_binary/1`: the
  SCXML source, the persisted compile opts, and the chart identity, with no
  second copy of anything)
- the normalized session opts of the recording
- its `entries/1` in append order

Its blob never carries these items:

- the compiled `%Machine{}` term (`from_binary/1` recompiles one from the
  nested chart blob on load, as the chart section above describes)
- any pid, ref, port, or fun
- any clock reading

A recording never reads wall-clock time, so a blob has no clock reading to
carry. Decision:
[ADR-0034](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md)
decision 2.

To load a recording, use the same two-line shape as the chart section above:

```elixir
{:ok, recording} = Statifier.Session.Recording.from_binary(blob)
{:ok, result} = Statifier.Replay.run(recording)
```

**Load handler modules first.** The decoding host must load its
`:invoke_handlers` modules before it decodes. `String.to_existing_atom/1`
cannot create an atom for a module that is not loaded. For this reason,
`to_binary/1` writes each handler module as a string and not as an atom.
`from_binary/1` resolves every string back to a module. It collects every
unresolvable name into a single `{:error, {:unknown_handler_modules, names}}`
and does not fail on the first. To fix the error, load the handler code,
then decode. Decision:
[ADR-0057 decision 5](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0057-recording-identity-and-serialization.md).

**Replay fidelity.** Replay after decode is only as faithful as the planning
callbacks of the handlers. `Statifier.Session.Effects.plan/2` dispatches to
the planning callback of a handler during replay. Replay never calls
`perform/2`, the impure half. A decoded recording reproduces the recorded
stream only if the planning callbacks of the handlers are equivalent to the
callbacks of the original execution. This is an accepted environmental
limit, in the same class as the OTP `MapSet`-iteration caveat. It is not a
defect to fix. Decision: [ADR-0034](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md).

**Host atoms.** The host remains responsible for `:safe` handling of
host-supplied atoms in recorded payloads. The codec resolves only the
handler-module atoms that it wrote. Neither `to_binary/1` nor
`from_binary/1` scans or translates an atom that a host put into
`:datamodel` values or event data.

**Format version 4 and `caller_context`.** The `caller_context` slot
inherits the host-term obligation above.

- ADR-0063 added `caller_context :: term()` to `%Statifier.Event{}` and to
  the two durable-timer effect structs. This changes the shape of the
  structs inside the `entries` of a blob, so `Recording.format_version/0`
  changed from 2 to 3.
- The 2026-09-01 amendment of that record added the same field to the two
  invoke-lifecycle effect structs (`%Effect.Invoke{}`,
  `%Effect.CancelInvoke{}`). This changed the version from 3 to 4.
- The library reads older blobs and does not refuse them. On import of a
  version-1, 2 or 3 blob, `from_binary/1` sets `caller_context: nil` on each
  stored event and on each stored durable-timer or invoke-lifecycle effect.
  This is safe because those blobs predate the field on the structs they
  hold, so no context was attached to their inputs.
- The slot follows the host-term rule above for event `data`. An OTel span
  context is plain data and round-trips correctly. If a host puts a pid or a
  fun in the slot, that recording can no longer be persisted, as it would be
  through `data`. The codec neither scans nor translates the slot.

`from_binary/1` checks errors in this order:

1. `:not_a_statifier_blob`: anything that is not the tagged envelope of this
   module.
2. `{:unsupported_format_version, version}`
3. `{:chart, reason}`: carries the error tuple of
   `Statifier.Chart.from_binary/1`, unflattened.
4. `{:unknown_handler_modules, names}`

`to_binary/1` has one refusal: `{:error, :unidentified_chart}`. It applies to
a recording made over a `Machine` that was never identified. Positions and
charts follow the same rule.

As with a position blob, the library does not yet let you read the identity
of a recording without recompiling. A host that must index many recordings by
chart, without recompiling each one on lookup, must store
`Statifier.Machine.Identity.to_binary/1` beside each recording blob at write
time. This is the same pattern that item 2 of "What a host must persist"
gives for positions.

Decision: [ADR-0052](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0052-chart-identity-and-position-serialization.md)
defers this for positions in the same way.

## Answering an invocation with no session process

This section covers one more need of a host that drives
`Statifier.Interpreter` directly, with no `Statifier.Session` process. There
is no session function for this need, because such a function needs a
process to call.

An `<invoke>` served by a `Statifier.Invoke.Handler` ends in one of two
ways. Each way is one event that the chart waits for:

| The invocation | The event | Built by |
|---|---|---|
| finished, with or without a result | `done.invoke.<invoke_id>` | `Statifier.Invoke.Answer.done/4` |
| failed permanently, retries exhausted | `error.communication.invoke.<invoke_id>` | `Statifier.Invoke.Answer.failed/4` |

A live session builds both events through
[`Statifier.Session.done_invocation/3`](https://github.com/riddler/statifier-ex/blob/main/lib/statifier/session.ex)
and `failed_invocation/3`. These functions cast to the session and deliver
the event on an invocation-tagged inbox entry. A process-less host calls the
two builders itself and feeds the returned event to its next drive. Route B
in `docs/durable-timers.md` feeds the event of a fired timer in the same
way. There is no running process to call, so the event is an input and not a
message.

```elixir
# The host's retry layer has just decided this invocation is over.
event = Statifier.Invoke.Answer.failed(execution_id, "inv_3", reason: "exhausted", attempts: 5)

{:ok, machine_state, effects} =
  Statifier.Interpreter.handle_event(machine_state, event)
```

`execution_id` is the `_sessionid` (spec 5.10) that the host assigned to the
execution. It is the same value that the host stamped onto the
`%MachineState{}` that it drives. It reaches the chart only as the `origin`
of the event, per C.1.

Both builders are pure: the same arguments give the same event, with no
clock and no id minting. A host that re-drives the same recovered step
rebuilds a byte-identical event. `Statifier.Invoke.Answer` is the one
construction site for both paths. The events of a live session are the same
bytes. `test/statifier/invoke/answer_test.exs` pins this directly.

**Check liveness.** A live session discards a done or failure event that
arrives for an invocation that the chart already cancelled (the drain-time
discard of spec 6.4.3). It also pops the table entry of that invocation. A
process-less host has no drain and no table, so it must:

1. Before it feeds the event in, check against its own record that the
   invocation is still live.
2. Afterwards, drop the record in either case.

This is the invoke half of the check that Route B describes for a timer that
fires after its cancel. The library does not report an error if you feed in
a stale answer. The chart may act on it.

**Carry the caller context.** Both builders take an optional
`caller_context:`, the opaque host slot of ADR-0063, and copy it onto the
answer event unread. Pass the value of the invoking event, not the value of
the reporting call. This is the term on the external event whose macrostep
executed the `<invoke>`. The host stamped it when it armed the work, and the
host wants the continuation of the chart linked back to it. A live session
takes it from its own invocation table entry, which it copied from the
`%Statifier.Effect.Invoke{}` that the core stamped. A process-less host has
no such table, so it must store the term beside its invocation row. This is
the invoke counterpart of storing the context of a `%SendDelayed{}` row in
Route B of `docs/durable-timers.md`:

```elixir
# Armed earlier, when the `%Statifier.Effect.Invoke{}` came out of the drive:
#   store_invocation(execution_id, invoke.invoke_id, invoke.caller_context)

{invoke_id, caller_context} = load_invocation(execution_id, "inv_3")

event =
  Statifier.Invoke.Answer.failed(execution_id, invoke_id, [reason: "exhausted", attempts: 5],
    caller_context: caller_context
  )

{:ok, machine_state, effects} =
  Statifier.Interpreter.handle_event(machine_state, event)
```

If you omit the option, or store nothing because the arming event carried
nothing, the value is `nil`: the "no context attached" of ADR-0063. It is
never an error. The library never reads the term. The macrostep that the
answer opens reports it on the `caller_context` telemetry metadata key, and
nothing else touches it.

A resumed session is the one case where the live path cannot help. Its
invocation table is rebuilt empty, so an answer delivered through
`done_invocation/3` after a resume gets `nil`. A host that needs the
correlation across a restart must keep the term itself and answer the
process-less way shown above. The 2026-09-02 decision note of ADR-0063
records all of this.

Both paths use the same payload rules:

- The `donedata` of `done` has the shape of spec 6.4.
- The three keys of `failed` are in ADR-0068 decision 2. "Reporting
  permanent failure" in `docs/extending.md` shows them at the point of the
  call.

## Explicitly not the *compiled* chart

In none of the three shapes above does the library persist the compiled
`%Statifier.Machine{}` struct.

- `Position.to_binary/1` refuses to encode one (`{:error, :unidentified_chart}`
  for an unidentified chart). For an identified chart, it does not write the
  compiled chart to the blob either.
- `Statifier.Chart.to_binary/1` and `Statifier.Session.Recording.to_binary/1`
  refuse in the same way for the same reason. The blob of a recording nests
  the blob of the chart, so it inherits the refusal.
- The chart blob carries the source, and this keeps the rule true even
  though the blob travels as one file.
- `Statifier.Chart.from_binary/1` rebuilds the `Machine` by recompiling the
  stored source through `Statifier.compile/2`. This is the same pipeline
  that any other caller runs. It never deserializes compiler output
  directly.

Predicator gives its own callers the same advice for `%Predicator.Compiled{}`
(`compiled.ex:10-38`): persist the source and recompile. Do not persist a
compiled form, because its internal shape can change across a library
upgrade and it has no compatibility story.

A compiled chart is also most of the bytes of a naively serialized position.
For one small position, measured on this branch, the size was 5848 bytes
with the machine embedded and 725 bytes without it. A chart blob is about
the size of the SCXML source that it carries, and not the size of the
compiled `Machine` that the source produces.

Decisions:
[ADR-0052 decision 3](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0052-chart-identity-and-position-serialization.md),
[st-i7y7 amendment](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0052-chart-identity-and-position-serialization.md).

## What it costs

The chart-blob shape has costs that retaining the source directly does not
have:

- **Recompilation on every load.** `Statifier.Chart.from_binary/1` runs the
  full `Statifier.compile/2` pipeline every time, before it can return a
  `Machine.t()`. There is no cached compiled form to use.
- **The source must still compile under the loading build.** A blob that one
  build wrote and a later build loads is only as portable as its source.
  `{:error, {:compile_failed, errors}}` reports that it is not portable. For
  example, a validator check can become stricter in a library upgrade. This
  failure differs from a format or identity mismatch. The library returns it
  unflattened.
- **The compile-opts set is closed.** `Statifier.Chart.to_binary/1` carries
  only the closed allowlist that `Statifier.compile/2` already stamps onto
  `Machine.compile_opts/1` (`:invoke_content_markup`, `:chart_name`,
  `:chart_version`). Suppose an embedder calls `Statifier.compile/2` with an
  option outside that set. The blob does not carry it. The embedder must
  supply that option again on load, because `from_binary/1` does not.
- **A recording's load pays the same recompile once.** A recording nests one
  chart blob. `Statifier.Session.Recording.from_binary/1` therefore pays the
  cost above once per decode, through the same
  `Statifier.Chart.from_binary/1` call that the chart section describes. It
  does not add a second recompile cost.
