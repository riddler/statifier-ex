# Persistence

How to persist and reload a running chart safely, and the hazard that makes
"safely" a real qualifier rather than a formality. Read alongside
[ADR-0052](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0052-chart-identity-and-position-serialization.md), which is
the decision record this page explains for a host author who has not read
[ADR-0005](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0005-full-configuration-and-interned-state-indexes.md).

## The hazard

A `Statifier.MachineState.t()`'s active configuration, `entered_states`,
`states_to_invoke`, and history values are `MapSet`s of interned integer
state indexes, not state ids
([ADR-0005](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0005-full-configuration-and-interned-state-indexes.md)).
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
`{:error, {:identity_mismatch, expected, actual}}`. One exception on the
version axis: `from_binary/2` also reads a version-1 blob (written before
`timer_counter` existed), defaulting `timer_counter` to `0` on the way in,
since no ordinal was ever minted against a version-1 position (ADR-0059).

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
  the macrostep finish - before exporting. A *terminated* position never
  needs draining: `exit_interpreter/1` empties the internal queue as its
  last step, so a `status: :done` machine state is quiescent by
  construction and always passes this check.

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
[ADR-0052 amendment (st-i7y7)](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0052-chart-identity-and-position-serialization.md)
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

## Resuming a session

Everything above answers "how do I persist a position safely." This section
answers the other half: how a host turns a persisted position back into a
running `Statifier.Session`, and what it still owns after doing so. See
[ADR-0060](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0060-resuming-a-session-from-a-persisted-position.md) for the
full decision record; this section is the narrative for a host that has not
read it.

The recipe is two lines - recompile the chart, then hand the persisted
position to `start_link/2`, which decodes it against that chart for you:

```elixir
{:ok, machine} = Statifier.Chart.from_binary(chart_blob)
{:ok, pid} = Statifier.Session.start_link(machine, resume: position_blob)
```

`resume:` also accepts an already-decoded `%Statifier.MachineState{}` - the
`Statifier.Position.import/2` migration-story-B output - so a host that
migrated a position across a chart revision by hand can hand the result
straight to `start_link/2` without a round trip through `to_binary/1`. Either
shape inherits the same identity gate this whole document is about: a blob
that does not match `machine`, or a struct whose own `machine` does not match
it, is refused rather than silently resumed against the wrong chart.

A host driving `Statifier.Interpreter` directly, with no `Session` in the
picture, has the pure-core equivalent of the same recipe - decode, re-stamp
`routes` and `invoke_types` (the two fields `Statifier.Position.from_binary/2`
deliberately returns `nil`, per-driver snapshots rather than durable position
state), then call any advance entry. See the "Rehydrating a position" section
of `Statifier.Interpreter`'s moduledoc for the full composition.

A resumed session comes up with the persisted configuration, datamodel,
history values, `entered_states`, `states_to_invoke`, `active_invocations`,
and all six counters exactly as they were saved - no
`Statifier.Interpreter.initialize/2` call, no re-entry of the chart's initial
states, no top-level `<script>` or `<onentry>` block run a second time.

### What resume does not restore

Three things a position cannot carry, each for a structural reason rather
than an oversight:

- **In-flight delayed sends.** No scheduling deadline is ever stored: `delay_ms`
  on a `SendDelayed` effect is relative, and no wall-clock instant is written
  anywhere a position could carry it (ADR-0034 decision 2's no-clock choice,
  carried forward by ADR-0054/0055/0059's durable-timer design). A resumed
  session starts with an empty timer table and fires nothing it had scheduled
  before persisting. Durable scheduling is the host's own responsibility,
  driven off the same public `SendDelayed`/`Cancel` effect vocabulary
  ADR-0054 already publishes - a host that wants timers to survive a resume
  re-arms them itself from that vocabulary, not from anything a position
  blob carries.
- **Live invoked children.** Pids, monitor refs, and child session ids are
  process-local; they were never part of `%MachineState{}` to begin with, so
  there is nothing for a position to lose here - they simply were never in
  one. `active_invocations` (the *record* of what was invoked) is carried
  forward verbatim; see the divergence below for what that does and does not
  mean. `invoke_id` itself *is* stable across a persist/reload cycle -
  it is a deterministic counter on `%MachineState{}`, not a freshly generated
  value (`docs/extending.md`, "Async and long-lived invocations") - so
  re-establishing a child is a matter
  of starting or reattaching a process behind an id the resumed session
  already recognizes, through the invoke handler registry (ADR-0051).
- **The external inbox.** `Statifier.Session.Inbox` lives outside
  `%MachineState{}` by ADR-0002's core/session split - it was never
  persistable in the first place. Anything queued but not yet dequeued at
  persist time is lost with the process that held it, the same as any other
  unpersisted mailbox.

### The `active_invocations` divergence

Carrying `active_invocations` forward while the live process table starts
empty means the two can disagree for the lifetime of a resumed session, until
the host re-establishes each child. This is accepted and documented rather
than papered over: clearing `active_invocations` on resume would change what
the position means and would leave it disagreeing with `states_to_invoke` and
`configuration` as well, which is worse. The divergence is safe because
`{:stop_child, invoke_id}` already treats an unknown id as a silent no-op - a
`<cancel>` or an exit sweep over a not-yet-re-established invocation stops
nothing and crashes nothing. The host's obligation is to re-establish the
processes behind `active_invocations`' ids through the invoke handler
registry (ADR-0051); this document does not track that work item, but the
divergence exists precisely because it is not yet done.

### Refusals

`start_link/2` returns `{:error, {:resume, reason}}` rather than booting a
silently-wrong session:

| `reason` | Why | Fix |
|---|---|---|
| `{:conflicting_options, opts}` | `:resume` was passed alongside `:trace`, `:datamodel`, or `:max_macrostep_rounds` (`MachineState.new/2`'s own options, not read on this path) or `:invoked_by` (a child session is always library-started, never resumed) | Drop the conflicting option; a resumed position already carries its own trace/datamodel/rounds state |
| `:not_a_statifier_blob` | The blob is not this library's own position envelope | Pass a blob written by `Statifier.Position.to_binary/1` |
| `{:unsupported_format_version, v}` | The blob's format version is newer or older than this build understands | Load with a build that supports version `v`, or re-persist under the current version |
| `{:identity_mismatch, expected, actual}` | The position was saved against a different chart revision than `machine` | Recompile the chart the position was actually saved against, or migrate the position via `Statifier.Position.export/1` / `import/2` (migration story B above) |
| `:unidentified_chart` | Either side of the resume - the position's `machine` or the supplied `machine` - was never identified (for instance, a `Machine` resolved via `:invoke_source` or built with `Statifier.Compiler.compile/1` directly) | Compile the chart through `Statifier.compile/2` so it carries an identity |
| `:position_not_quiescent` | The position's internal event queue is non-empty | Drain to quiescence - let the macrostep finish - before persisting, the same instruction `Statifier.Position.export/1` already gives |
| `:position_not_running` | The position has `running: false` (`status: :done`) | Inspect a finished position with `Statifier.Position.from_binary/2` and `Statifier.active_leaf_states/1` directly; there is nothing left for a session to do with it |

### The `_sessionid` rule

A resumed session reuses the position's own `datamodel["_sessionid"]` as its
`session_id` by default. `:session_id` may be passed alongside `:resume` to
override it, and doing so rewrites `datamodel["_sessionid"]` to agree, so the
`session_id == datamodel["_sessionid"]` invariant this library already relies
on elsewhere (ADR-0048 route stamping, telemetry, `Recording.new/2`'s
`opts[:session_id]` contract) always holds. Reusing the id rather than minting
a fresh one matters because it is what keeps `#_scxml_<sessionid>` addressing,
and any external reference to the session, working across the deploy or crash
that made the resume necessary in the first place - restarting with a fresh id
would sever exactly the continuity a resume exists to preserve.

### `resume:` plus `record: true`

Passing both starts the new `Statifier.Session.Recording.t()` anchored at the
resumed position instead of at the chart's initial configuration - the
recording's `anchor` field carries the resumed position as a blob, and
`Statifier.Replay.run/1` decodes and starts from it rather than calling
`Statifier.Interpreter.initialize/2`. Nothing about this changes what a
caller does: `subscribe/3` with `catch_up: true` and `Statifier.Replay.run/1`
behave exactly as they do for an unresumed session, reproducing whatever
prefix the session has actually notified. An anchored recording's stream
carries no initialization effects, because a resumed session performs no
initialization in the first place - the catch-up invariant holds literally
rather than approximately for a resumed session, since there is no
initialization burst to be missing from the prefix.

A recording (`Statifier.Session.Recording.t()`) is the third persistable
artifact, alongside a position and a chart. What its blob carries: the
nested chart blob (`Statifier.Chart.to_binary/1`'s own envelope - the SCXML
source, the persisted compile opts, and the chart's identity, not a second
copy of anything), the recording's normalized session opts, and its
`entries/1` in append order. What it never carries: the compiled
`%Machine{}` term (`from_binary/1` recompiles one from the nested chart blob
on load, exactly as the chart section above does), any pid, ref, port, or
fun, and no clock reading -
[ADR-0034](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md)
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
([ADR-0057 decision 5](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0057-recording-identity-and-serialization.md)),
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
[ADR-0034](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md)'s OTP
`MapSet`-iteration caveat, not a defect to chase down.

**Host-supplied atoms inside recorded payloads remain the host's own
`:safe` obligation.** The codec resolves only the handler-module atoms it
itself wrote; an atom a host put into `:datamodel` values or event data is
neither scanned for nor translated by `to_binary/1` or `from_binary/1`.

**Format version 4, and the `caller_context` slot's inherited obligation.**
ADR-0063 added `caller_context :: term()` to `%Statifier.Event{}` and the
two durable-timer effect structs, which changes the shape of the structs
inside a blob's `entries`, so `Recording.format_version/0` bumped `2 -> 3`;
that record's 2026-09-01 amendment added the same field to the two
invoke-lifecycle effect structs (`%Effect.Invoke{}`,
`%Effect.CancelInvoke{}`), bumping `3 -> 4` for the same reason.
Older blobs are read, not refused: `from_binary/1` defaults
`caller_context: nil` onto each stored event and each stored durable-timer
or invoke-lifecycle effect on version-1/2/3 import - safe exactly because
those blobs predate the field on the structs they hold, so no context was
ever attached to their inputs. The slot
itself joins event `data` under the host-term rule above: an OTel span
context is plain data and round-trips fine, while a host that stows a pid
or a fun in it loses persistability of that recording the same way it
would through `data`, and the codec neither scans nor translates it.

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
[ADR-0052](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0052-chart-identity-and-position-serialization.md) defers it
for positions. A host that needs to index many recordings by chart revision
without recompiling each one on lookup stores
`Statifier.Machine.Identity.to_binary/1` beside each recording blob at write
time, the same pattern item 2 of "What a host must persist" above already
gives positions.

## Answering an invocation with no session process

Everything above is about a position: writing it, reading it back, resuming
it. This section is about the other thing a host driving
`Statifier.Interpreter` directly - with no `Statifier.Session` process at
all - eventually needs, and which has no door of its own because a door
needs a process to knock on.

An `<invoke>` served by a `Statifier.Invoke.Handler` ends exactly two ways,
and each way is one event the chart is waiting for:

| The invocation | The event | Built by |
|---|---|---|
| finished, with or without a result | `done.invoke.<invoke_id>` | `Statifier.Invoke.Answer.done/4` |
| failed permanently, retries exhausted | `error.communication.invoke.<invoke_id>` | `Statifier.Invoke.Answer.failed/4` |

A live session builds both through
[`Statifier.Session.done_invocation/3`](https://github.com/riddler/statifier-ex/blob/main/lib/statifier/session.ex)
and `failed_invocation/3`, which cast to the session and deliver the event
on an invocation-tagged inbox entry. A process-less host calls the two
builders itself and feeds the returned event to its **next drive**, the same
way `docs/durable-timers.md`'s Route B feeds a fired timer's event: there is
no running process to call into, so the event is an input, not a message.

```elixir
# The host's retry layer has just decided this invocation is over.
event = Statifier.Invoke.Answer.failed(run_id, "inv_3", reason: "exhausted", attempts: 5)

{:ok, machine_state, effects} =
  Statifier.Interpreter.handle_event(machine_state, event)
```

`run_id` is the host's own `_sessionid` (spec 5.10) for the run - the same
value it stamped onto the `%MachineState{}` it is driving. It reaches the
chart only as the event's `origin`, per C.1. Both builders are pure: same
arguments, same event, no clock, no id minting, so a host that re-drives the
same recovered step rebuilds a byte-identical event, and
`Statifier.Invoke.Answer` is the *one* construction site both paths share -
a live session's own events are the same bytes, which
`test/statifier/invoke/answer_test.exs` pins directly.

**Liveness is the host's own check.** A live session discards a done or
failure event that arrives for an invocation the chart already cancelled
(spec 6.4.3's drain-time discard) and pops that invocation's table entry.
A process-less host has neither a drain nor a table, so it owes itself the
same two things: check the invocation is still live against its own record
before feeding the event in, and drop the record afterwards either way. This
is the invoke half of the check Route B already describes for a timer that
fires after its cancel. Feeding a stale answer in is not an error the
library reports - it is an event the chart may act on.

**Carrying the caller context across.** Both builders take an optional
`caller_context:` - ADR-0063's opaque host slot - and copy it onto the
answer event unread. The value to pass is the *invoking* event's, not the
reporting call's: the term that rode the external event whose macrostep
executed the `<invoke>`, which is what a host stamped when it armed the
work and what it wants the chart's continuation linked back to. A live
session takes it off its own invocation table entry, which it copied from
the `%Statifier.Effect.Invoke{}` the core stamped. A process-less host has
no such table, so storing the term beside its invocation row is its half
of the same job - the invoke analogue of storing a `%SendDelayed{}` row's
context in `docs/durable-timers.md`'s Route B:

```elixir
# Armed earlier, when the `%Statifier.Effect.Invoke{}` came out of the drive:
#   store_invocation(run_id, invoke.invoke_id, invoke.caller_context)

{invoke_id, caller_context} = load_invocation(run_id, "inv_3")

event =
  Statifier.Invoke.Answer.failed(run_id, invoke_id, [reason: "exhausted", attempts: 5],
    caller_context: caller_context
  )

{:ok, machine_state, effects} =
  Statifier.Interpreter.handle_event(machine_state, event)
```

Omitting the option, or storing nothing because the arming event carried
nothing, gives `nil` - ADR-0063's "no context attached", never an error.
The library reads the term at no point; the macrostep the answer opens
reports it on the `caller_context` telemetry metadata key and nothing else
touches it. A **resumed** session is the one case where the live path
cannot help: its invocation table is rebuilt empty, so an answer delivered
through `done_invocation/3` after a resume inherits `nil`, and a host that
needs the correlation across a restart keeps the term itself and answers
the process-less way shown above. ADR-0063's 2026-09-02 decision note
records all of this.

The payload rules are the same on both paths, and are not restated here:
`done`'s `donedata` is spec 6.4's own shape, `failed`'s three keys are
`ADR-0068` decision 2's, and `docs/extending.md`'s "Reporting permanent
failure" is where a host implementor reads them at the moment of the call.

## Explicitly not the *compiled* chart

What is still never persisted, in any of the three shapes above, is the
*compiled* `%Statifier.Machine{}` struct. `Position.to_binary/1` refuses to
encode one at all (`{:error, :unidentified_chart}` for an unidentified
chart, and the compiled chart is never written to the blob for an identified
one either), and `Statifier.Chart.to_binary/1` and
`Statifier.Session.Recording.to_binary/1` refuse the same way for the same
reason - a recording's blob nests the chart's, so it inherits the refusal
rather than restating it - see
[ADR-0052 decision 3](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0052-chart-identity-and-position-serialization.md)
and its
[st-i7y7 amendment](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0052-chart-identity-and-position-serialization.md).
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
