# ADR-0040: Session telemetry event contract

Status: accepted (2026-08-16) - amended 2026-08-16 (st-ii9v: singleton
location carve-out withdrawn; no trace event carries a location)

## Context

`docs/observability.md` constraint 6 has carried a forward-looking hedge - a
`:telemetry` bridge attaches at the effect/trace boundary "once it exists."
st-cmq.1 discharges that hedge: `Statifier.Session` forwards the effect and
trace stream it already fans out to subscriber pids (st-cmq.4) as `:telemetry`
events, on top of that stream rather than in place of it.

ADR-0003 draws the line this bead has to stay on: the pure core returns
effects, and everything that performs them or observes them lives on the
session side of the boundary. The trace effects already produced by
`Effect.trace/3` (`lib/statifier/effect.ex:163-173`) are themselves the
instrumentation stream `docs/observability.md` describes; a `:telemetry`
bridge is one more interpreter of that stream, not a new channel the core has
to grow. `Mix.Statifier.AdrGuard`'s `@effect_call_pattern`
(`lib/mix/statifier/adr_guard.ex:97-102`) makes that mechanical: it flags a
process-shaped or I/O-shaped call added under `lib/statifier/` outside the
named `@effect_interpreter_paths`, exempting exactly `session.ex` today.

Two seams already carry everything the bridge needs, with nothing new to
plumb into the core:

- **One fan-out point, total and ordered.** `Statifier.Session.Effects.plan/2`
  emits `{:notify, effect}` as the head of every effect's instruction list,
  and `perform_instruction/3` hands it to `notify/2`, which already carries
  `state.session_id`. The `{:unroutable, effect}` and `{:halted, reason}`
  envelopes ride the same function.
- **The trace gate is already in the core.** `Effect.trace/3` is a macro that
  expands to a zero-or-one-element list keyed on `machine_state.trace`. With
  `trace: false` the core produces no trace effect at all, so there is
  nothing for a bridge to filter.

Nine research questions were open going into this bead (see
`docs/research/260816-st-cmq.1-session-telemetry-effect-trace-streams.md`).
This record settles all nine and states the event contract they produce, so
that the code in the phases that follow encodes a decision already made
rather than makes it in the diff.

## Decision

### The session boundary is the one emitter, and it is two files

`Statifier.Session` is the ADR-0003 effect interpreter. Emitting `:telemetry`
events from it is squarely inside that role - it is another way of performing
an effect the core already produced, alongside notifying subscriber pids. The
event contract itself (25 names, their measurement and metadata shapes, and
the per-family helpers that build them) is defined in a new module,
`Statifier.Session.Telemetry`, and `session.ex` calls it rather than calling
`:telemetry.execute/3` directly.

This is a documentation-coverage split, not a second effect interpreter.
`.doctor.exs` holds 100% `@moduledoc`/`@doc`/`@spec` thresholds on every
axis; `session.ex` is already close to 1300 lines, and folding 25 event
shapes and a location resolver into it would fight
`Credo.Check.Refactor.Nesting` and bury the contract inside a module that is
not primarily about telemetry. `Statifier.Session.Telemetry` holds no state,
drives no core function, and is called from nowhere but `session.ex` - it has
no life of its own outside the one caller. Measured against ADR-0027's bar
for a new `@effect_interpreter_paths` entry ("a smell to be argued, not
defaulted"): the argument is that this is the emission half of the single
path ADR-0003 already names, split out only because the Doctor bar makes the
event contract belong in a `@moduledoc` a library consumer can read without
opening the source. `Mix.Statifier.AdrGuard.@effect_call_pattern` gains a
`:telemetry\.` alternation, and `@effect_interpreter_paths` gains
`lib/statifier/session/telemetry.ex` alongside `session.ex` - the two changes
land together, because the pattern would otherwise flag the emitters the same
branch just wrote. The alternative - an `ADR-0003` escape comment repeated
above roughly ten `:telemetry.execute/3` call sites - is the same exemption
spelled out ten times with no single record, which is the gap ADR-0027 calls
riding rather than arguing.

### Event names, prefix, and enumeration

Every event name starts with `[:statifier, :session, ...]`. Three families
follow the prefix:

- **Lifecycle and span events** (`init`, `halt`, `terminate`,
  `macrostep, :start`, `macrostep, :stop`, `interpret`, `unroutable`) - no
  further segment beyond the event's own name.
- **Core effect events** - `[:statifier, :session, :effect, kind]` for
  `kind` in `[:send, :send_delayed, :cancel, :invoke, :cancel_invoke,
  :autoforward, :budget_exhausted, :done, :log]`, one per core effect struct.
- **Trace effect events** - `[:statifier, :session, :trace, kind]` for
  `kind` in `[:event_dequeued, :transitions_selected, :exit_set,
  :content_executed, :entry_set, :macrostep_stable, :done, :invoke_pass,
  :finalize_autoforward]`, one per `Effect.Trace.*` struct.

`kind` is derived by a private, multi-clause function pattern-matching each
struct to a literal atom - never `Module.split/1` composed with
`String.to_atom/1`, which `Credo.Check.Warning.UnsafeToAtom` forbids and
which would make the event list impossible to enumerate ahead of a call.
`Statifier.Session.Telemetry.events/0` returns the full list of 25 names,
built from the same literal-atom lists the emitters use, so a consumer can
attach to everything the module can ever emit without hand-copying names out
of documentation. The `@moduledoc` is the single authoritative reference for
the full contract (name, measurements, metadata, per event); no second copy
of that table lives in `docs/observability.md` - it states that the bridge
exists and points at the module.

### Measurements are numbers, identity is metadata

Every measurement is a number. Every identity - a session id, an effect
struct, a target, a `send_id`, a resolved location, and every constraint-3
index (`state_index`, `t_index`, `c_index`, `owner`, `invoke_id`,
`invoke_index`) - is metadata, including the ones that happen to be
integers. The step counters (`macrostep`, `microstep`, `round`) are numbers
and belong in measurements: they are exactly the kind of value
`:telemetry_metrics` aggregates, and putting an opaque index like
`state_index` there would invite averaging a value that has no numeric
meaning.

The bead's own text phrases this two ways - "metadata carries ... the step
counters" in one place, "numbers in measurements, identity in metadata per
`:telemetry` convention" in another. This record resolves the conflict in
favor of the convention the bead itself names as governing: counters are
numbers, so they are measurements, not metadata. This is the reading the
Phase 2/3 tests assert.

Configurations carried in metadata are translated from the raw
`MapSet.t(non_neg_integer())` index set into a `MapSet.t(String.t())` of
state ids via `Machine.id/2`, mirroring what `session.ex`'s private
`build_status/1`
already does for the subscriber-facing status - so a subscriber never needs
a `Machine` handle to read a configuration out of an event.

### Locations are resolved at emission, for single-index effects only

An effect carrying exactly one resolvable index gets `metadata.location`,
resolved through `Machine.content/2`, `Machine.at/2`, or `Machine.transition/2`
as appropriate, and carried as the `%Statifier.Parser.Location{}` struct
verbatim - not flattened into ad hoc `line`/`column` keys, which would invent
a key set the library does not otherwise have and would silently drop
whatever `Location` gains later. An effect with no index, or an index field
present but `nil` (`Effect.Log.c_index` is `nil` for a global `<script>`),
carries no `location` key at all. `cond_location` is never resolved: no
effect in the vocabulary is emitted from guard evaluation, so a resolved
`cond_location` would always describe a condition that did not produce the
event carrying it. An effect carrying a *list* of indexes (the list-carrying
trace effects - `ExitSet`, `EntrySet`, `TransitionsSelected`,
`ContentExecuted`, `InvokePass`) carries the list in metadata and its length
as a `size` measurement, with no `location` key; resolving a location per
list entry would put an O(configuration) `Machine` walk on every microstep
of a high-volume traced run, for a value a consumer with the index list and
a `Machine` handle can already compute.

**Amendment (st-f6i9):** the rule above originally had every trace_shape/2
clause return a literal `location: nil`, including the clauses - all nine at
the time - where no location could structurally ever resolve. A key that can
never hold a value is contract noise a consumer has to learn to ignore, and
this contract is published once st-cmq.2 lands, so the key is now absent
from those clauses rather than present-and-`nil`; a consumer distinguishes
"no location resolved" from "this event never carries one" with
`Map.has_key?/2` on either side.

That same review also found the O(configuration) argument above does not
apply to a *singleton* list: `Trace.TransitionsSelected` with exactly one
`t_indexes` entry is O(1) to resolve, no different in cost from a bare
`t_index`, and is the overwhelmingly common traced case (a chart usually
selects one transition per microstep, not several). `TransitionsSelected`
now resolves that one entry through `Machine.transition/2` and carries it
verbatim, exactly as the single-index rule above resolves a bare `t_index`.
With zero or many entries, it carries no `location` key, same as the rest of
the list-carrying family. `TransitionsSelected` is therefore the one trace
event that legitimately carries a location; the key-removal amendment above
had to keep it there rather than dropping `location` from the trace family
by rote. The other four list-carrying trace effects (`ExitSet`, `EntrySet`,
`ContentExecuted`, `InvokePass`) keep the no-location-key rule even for a
singleton list - `TransitionsSelected` was the case this review actually
raised, and generalizing to the other four is future work, not a decision
this amendment makes for them.

**Amendment (st-ii9v):** the open note above is now settled, in the
withdraw direction: the singleton carve-out is removed from
`TransitionsSelected` rather than extended to the other four, and no
list-carrying trace effect carries a `location` key at any cardinality. The
trace-family rule is uniform and fits in one line - no
`[:statifier, :session, :trace, _]` event ever carries a `location` key.
Locations on this surface live exclusively on the single-index core effect
events and `:unroutable`, resolved by the rule at the top of this decision.
Four arguments, in the order they carried the decision:

- *A set-valued trace event names a phase, not a chart element.* The exit
  set, the entry set, the invoke-pass walk, and a selection round's result
  are each the subject of their event; a location resolved from a singleton
  describes one member of a set that happened to have one member - a
  coincidence of the chart and of the round, not a property of the event. A
  selected transition is the closest thing to singular in the family, which
  is why the carve-out started there, but even there the key's presence
  flaps with runtime data: a consumer that wants transition locations must
  handle the key-absent case anyway, so it already resolves from
  `t_indexes` and a `Machine` handle, and the singleton value saves it
  nothing it can build on.
- *The extended rule cannot even be stated uniformly.* `InvokePass` carries
  two lists (`state_indexes` and `invoke_ids`), so "a singleton list
  resolves to a location" is ill-formed across the family without a
  per-event footnote naming which list counts - which recreates exactly the
  consult-a-table asymmetry the carve-out was criticized for, inside the
  rule that was supposed to remove it.
- *Cost never decided this.* The O(configuration) worst case above was
  st-f6i9's opening for the carve-out, but the real per-microstep cost of
  resolving singletons across all five is a handful of O(1) map reads -
  negligible on a high-volume traced run. Extension was affordable; it
  loses on shape, not on cost.
- *Withdrawal is the reversible direction under the st-cmq.2 freeze.*
  Adding a metadata key to a published event is additive and non-breaking;
  removing one after the OpenTelemetry bridge ships against these shapes is
  breaking. Before the freeze, withdrawing costs nothing and re-adding
  stays open; extending is a commitment the semantic argument above does
  not earn. Under genuine doubt, the direction that keeps the door open
  wins.

Withdrawal keeps the key-removal amendment's own rule honest: with the
carve-out gone, no `trace_shape/2` clause can ever set `location`, so the
key is absent from every trace event rather than present on one of them
under a data-dependent condition. The open question this amendment records
rather than resolves: whether a future consumer demand for a resolved
"which line fired" attribute justifies re-adding a location to
`transitions_selected`. If that demand materializes after st-cmq.2, the
re-addition is additive and reopens only that event's table row, not this
rule - the residual risk of withdrawing is a wanted key arriving late, not
a breaking change.

### The trace-off policy is structural, not a bridge-side branch

Everything except the `[:statifier, :session, :trace, _]` family fires
whether `trace` is `true` or `false`. The trace family vanishes because the
core produces no trace effect under `trace: false` - `Effect.trace/3`
expands to an empty list at that call site, so the bridge has nothing to
forward. `Statifier.Session.Telemetry` contains no `if trace` of its own: the
gate lives entirely in the core's macro, one level below where the bridge
sits, and both directions are exercised by test.

### One new clock read, and why it does not amend ADR-0034

`Statifier.Session` reads `System.monotonic_time/0` at the head of each
core-driving path and again when that call returns, to compute the `duration`
measurement (`:native` units, per `:telemetry`'s own convention) carried on
the macrostep stop event. `%State{}` gains one field,
`macrostep_started_at :: integer() | nil`, holding the span's open start time;
`Interpreter.initialize/2` runs inside `init/1` before `%State{}` exists, so
that span's start time is a local binding rather than a state field.

This is the library's first clock read outside the process-shaped calls
`Mix.Statifier.AdrGuard` already allowlists in `session.ex`
(`Process.send_after/3`, `Process.cancel_timer/1`, and friends). It does not
amend ADR-0034. ADR-0034's clock-freedom is a property of
`Statifier.Session.Recording` and `Statifier.Replay`: a recording that
carried wall-clock timestamps would either replay them - making replay a
simulation of timing rather than a re-derivation of order, which ADR-0034
Decision 2 rules out by name - or discard them, making them dead weight.
Neither argument reaches telemetry. Telemetry is a live-session-only channel:
`macrostep_started_at` is state on a running `Statifier.Session`, never
written into a `Recording.put_*` call, and by ADR-0034's own construction
`Statifier.Replay` is a pure fold with no session and no process, so it has
nothing to read a clock from and nothing to emit a `:telemetry` event with.
This record cites ADR-0034 rather than reinterpreting or amending it: the
clock read is new, the boundary ADR-0034 already drew around what a
recording carries is unchanged.

### The ADR-0029 interaction: naming the call, not the effects

`init/1`, `drain_event/2`, `drain_cancel/1`, and `deliver_internal/6` (the
ADR-0039 re-entry path) each call the core and each advances the step
counters, so each opens and closes a macrostep span with a `trigger` in
`[:initialize, :event, :cancel, :internal]` distinguishing them.
`handle_cast({:interpret, effects}, _)` (ADR-0029's public embedder seam)
calls no core function - it reaches `perform/3` directly - so it is not a
macrostep by this record's own definition; it emits its own
`[:statifier, :session, :interpret]` event instead, carrying `effect_count`.

Naming that call is not the same as distinguishing what it injects. ADR-0029's
point is that a consumer of the effect stream cannot tell a core-derived
effect from one `interpret/2` injected, because `Effects.plan/2` plans both
to the same `{:notify, effect}` instruction with nothing to discriminate
them. That has no per-event discriminator here either:
`[:statifier, :session, :interpret]` fires once, naming the call itself, and
every effect it injects then flows through the ordinary
`[:statifier, :session, :effect, kind]` / `[:statifier, :session, :trace,
kind]` events with no metadata key on any one of them distinguishing an
injected effect from a core-derived one - carrying such a key would mean
plumbing a discriminator through `Effects.plan/2` that ADR-0029 deliberately
does not have, which is a change to the core's own contract this record does
not make.

This is narrower than ADR-0029's indistinguishability claim, not the same
claim restated: `Statifier.Session` is a `GenServer`, so it is serial, and
`:telemetry.execute/3` is synchronous, so a subscriber that also counts
`effect_count` on the `:interpret` event can reconstruct which effects were
injected by position - the `effect_count` effects immediately following that
event are exactly the injected ones, in order, with nothing else able to
interleave. A consumer willing to track that sequence can tell the two apart;
one reading a single event's metadata in isolation cannot. A recorder built
on these events still has to record the four ADR-0029 inputs directly - the
telemetry stream is not a substitute for that recording, and this record
does not claim it is.

### Replay fires nothing

`Statifier.Replay` fires no `:telemetry` event, by ADR-0034's construction
rather than by any new rule this record adds: it is a pure fold over a
recording with no `Statifier.Session` process behind it, and every event
this contract defines is emitted from session state (`session_id`,
`machine_state`, the macrostep span timer) that a replay fold does not
carry. A replayed run is therefore silent on this channel exactly as
ADR-0034 already implies, and observably different from a live run only in
the sense ADR-0034 already accepts: replay reproduces the effect stream and
terminal snapshot, not the live session's side channels.

### The event contract

Measurements are numbers; metadata is everything else, including bare
integer identities. `session_id` is metadata on every event.

**Lifecycle and span events (7), emitted regardless of `trace`:**

| Event | Measurements | Metadata |
|---|---|---|
| `[:statifier, :session, :init]` | `system_time` | `session_id`, `machine_name`, `trace`, `invoked_by` |
| `[:statifier, :session, :halt]` | `macrostep`, `microstep`, `round` | `session_id`, `reason` (`:done \| :cancelled \| :budget_exhausted`), `configuration` (state ids) |
| `[:statifier, :session, :terminate]` | `macrostep`, `microstep`, `round` | `session_id`, `reason` (the GenServer reason), `status` |
| `[:statifier, :session, :macrostep, :start]` | `system_time`, `monotonic_time` | `session_id`, `trigger`, `event_name`, `span_ref` |
| `[:statifier, :session, :macrostep, :stop]` | `duration` (native), `macrostep`, `microsteps`, `rounds`, `monotonic_time` | `session_id`, `trigger`, `outcome`, `event_name`, `configuration`, `span_ref` |
| `[:statifier, :session, :interpret]` | `effect_count`, `macrostep`, `microstep` | `session_id` |
| `[:statifier, :session, :unroutable]` | `macrostep`, `microstep` | `session_id`, `effect`, `target`, `send_id`, `location` |

`[:statifier, :session, :unroutable]` is a lifecycle event rather than a
member of the `[..., :effect, _]` family on purpose: it names a routing
failure the session itself detected from the `{:unroutable, effect}`
instruction, not an effect the core produced, and a consumer alerting on it
wants one name to attach to rather than a filter across nine effect names.

`[:statifier, :session, :terminate]` fires from `terminate/2` and is
therefore subject to the GenServer contract - it does not fire on a brutal
kill. `:halt` is the event to build a "session finished" metric on.

**Core effect events (9), emitted regardless of `trace`:**

`[:statifier, :session, :effect, kind]` for
`kind in [:send, :send_delayed, :cancel, :invoke, :cancel_invoke, :autoforward, :budget_exhausted, :done, :log]`.

- Measurements: `macrostep`, `microstep`; plus `round` and `budget` for
  `:budget_exhausted` only (the one core effect ADR-0020 stamps with a
  round); plus `delay_ms` for `:send_delayed`.
- Metadata: `session_id`, `effect` (the struct itself), `location` per the
  resolution rule above, and the family's identities - `send_id`, `target`,
  `c_index`, `owner` for the send family; `invoke_id`, `state_index`,
  `invoke_index` for the invoke family; `label` for `:log`; `configuration`
  for `:done`, resolved from the `Effect.Done` struct's own `configuration`
  field (the full configuration as it stood at exit) rather than from
  `MachineState.configuration`, which is already empty by the time this
  effect fires.

**Trace effect events (9), emitted only under `trace: true`:**

`[:statifier, :session, :trace, kind]` for
`kind in [:event_dequeued, :transitions_selected, :exit_set, :content_executed, :entry_set, :macrostep_stable, :done, :invoke_pass, :finalize_autoforward]`.

- Measurements: `macrostep`, `microstep`, `round`; plus `size` for the
  list-carrying families (`exit_set`, `entry_set`, `transitions_selected`,
  `content_executed`, `invoke_pass`).
- Metadata: `session_id`, `effect`, the index lists as carried, no
  `location` key on any trace event, at any cardinality (st-ii9v amendment
  above); plus `configuration` for `:done`, mirroring the core `:done`
  effect's own resolution (both are built from the same
  `configuration_at_exit` binding).

## Consequences

- `Statifier.Session.Telemetry.events/0` and its `@moduledoc` are the
  authoritative reference; `docs/observability.md` constraint 6 states that
  the bridge exists, names this record and the module, and carries no second
  copy of the table above.
- `Mix.Statifier.AdrGuard.@effect_call_pattern` gains a `:telemetry\.`
  alternation and `@effect_interpreter_paths` gains
  `lib/statifier/session/telemetry.ex`, landing together on the implementing
  branch. This amends no accepted ADR - it exercises the exemption mechanism
  ADR-0027 already established, the same way ADR-0027 itself added
  `supervisor.ex`.
- These 25 event names, their prefix, and their measurement/metadata split
  are a public commitment from the moment they ship: st-cmq.2 (an
  OpenTelemetry/`:telemetry_metrics` bridge, and out of this record's scope)
  consumes exactly this contract and no more. A name, measurement, or
  metadata key changing after st-cmq.2 lands is a breaking change to that
  consumer, not a free-standing implementation detail of `Statifier.Session`.
- This record contradicts no accepted ADR. ADR-0034's clock-freedom applies
  to `Statifier.Session.Recording` and `Statifier.Replay`, not to a live
  session's own state, and is cited rather than reopened. ADR-0029's
  indistinguishability of core-derived and `interpret/2`-injected effects on
  the effect stream is cited rather than reopened; naming the `interpret/2`
  call is additive to that record, not a revision of it. ADR-0003's boundary
  - the core never calls `:telemetry`, the session (now two files) is the
  interpreter - is the record this ADR implements, not one it amends.
- What would reopen this record: a second module outside `session.ex` and
  `session/telemetry.ex` needing an `@effect_interpreter_paths` exemption for
  telemetry-shaped reasons, an event name changing shape after st-cmq.2 has
  shipped against it, or a field being added to, removed from, or renamed on
  any `Statifier.Effect.*`/`Statifier.Effect.Trace.*` struct. The raw struct
  rides verbatim in every core/trace event's `effect` metadata key, so a
  struct's fields are part of this contract by transitivity even though no
  table above names them individually - the same st-cmq.2 breaking-change
  argument applies to a field a subscriber was reading off `effect` as to a
  metadata key this record does name directly. None of this is expected from
  this bead's own scope.
