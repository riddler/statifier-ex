# ADR-0067: One telemetry contract across stepping drivers

Status: accepted (2026-08-23) - amends ADR-0040 in part (the
`[:statifier, :session, ...]` prefix is redefined as naming the logical
session, not the `Statifier.Session` process; the emission helpers
generalize out of the session boundary; a `driver` key joins every event's
metadata) - deliberately fires the reopening trigger ADR-0040's own
Consequences names for a telemetry-shaped `@effect_interpreter_paths`
entry, and argues it below rather than riding it

## Context

ADR-0040 shipped the `[:statifier, :session, ...]` event contract with
`Statifier.Session` as its one emitter, and ADR-0062 shipped
`opentelemetry_statifier` as its one external consumer. Both records assume
the session process is where stepping happens. It no longer is the only
place: `docs/persistence.md` and the `Statifier.Interpreter` moduledoc's
"Rehydrating a position" section document a fully supported second driver -
a host that decodes a position (ADR-0052/0060), re-stamps the per-drive
snapshot fields, calls an advance entry (`handle_event/2`,
`deliver_internal/5`, `cancel/1`, `microstep/1`, `macrostep/1`), executes
the returned effects, and persists the result, with no `Statifier.Session`
process anywhere. `statifier_persistence`'s run lifecycle is exactly this
loop, and `statifier_oban` drives it from timer and invoke jobs.

The first production embedder (a production CQRS/Oban host) wired
`opentelemetry_statifier` and found the gap this record closes: the durable
path emits nothing. Every event ADR-0040 defines is emitted from
`Statifier.Session`'s own callbacks, so a run stepped through the pure
interpreter is invisible to the bridge - zero spans, zero span events -
while the same chart hosted in a session process is fully observed. The
flagship durable path is dark to the flagship observability bridge.

This repository owns the telemetry contract (ADR-0040, ADR-0062 decision
6), so the decision of what the durable path emits, under what names, and
from what code is made here. The emit sites in `statifier_persistence` and
the consumption in `opentelemetry_statifier` are follow-ups in those repos,
named in the Consequences.

Facts that bound the choice:

- **The bridge wants one family.** `opentelemetry_statifier` attaches to
  `Statifier.Session.Telemetry.events/0` and maps measurements and metadata
  to attributes uniformly (`docs/opentelemetry.md`). A second event family
  means a second handler table, a second attribute mapping, and two span
  vocabularies a backend user has to know are the same thing.
- **The logical session exists on both paths.** `session_id` is
  `datamodel["_sessionid"]`, carried in the position blob, preserved across
  persist and resume by ADR-0060's `_sessionid` rule precisely so external
  references keep working. The GenServer is one way to host a session; the
  session itself - identity, configuration, counters, datamodel - is the
  `MachineState`, and the durable path has all of it.
- **A hand-copied contract will drift.** The contract is 27 event names
  with per-event measurement/metadata shapes, a four-resolver location
  rule, and a configuration-translation rule. ADR-0040 and three amendment
  cycles (st-oef3, st-1xwh, ADR-0046, ADR-0059, ADR-0063) show the table
  moves; a second implementation in `statifier_persistence` written against
  prose would be behind within weeks.
- **The freeze is live.** statifier 2.0.0 is on Hex (ADR-0066) and the
  bridge ships against these shapes, so changes must be additive and
  `Statifier.Session.Telemetry`'s public surface cannot break.

## Decision

### 1. The prefix stays; `:session` names the logical session

The durable path emits the existing `[:statifier, :session, ...]` events,
not a new `[:statifier, :step, ...]` family. This record amends ADR-0040's
reading of the prefix: the second segment names the logical SCXML session -
the `_sessionid`, the thing a position blob persists and a resume
preserves - not the `Statifier.Session` process. The GenServer was the
first driver of a session, not the definition of one.

The alternative was weighed and loses on every axis that matters to the
consumer. A `[:statifier, :step, ...]` family would be honest about the
process's absence at the cost of telling the bridge, and every
`:telemetry_metrics` user, that a macrostep stepped durably is a different
kind of thing than the same macrostep stepped in a process. It is not: same
core call, same effect stream, same counters, same chart. The one thing
that differs is the driver, and one metadata key (decision 4) states it
without forking 27 names. Session-hosted and durable spans look like one
family because they are one family.

### 2. The emitter generalizes: `Statifier.Telemetry` ships here

The emission implementation moves out of the session boundary into a new
caller-agnostic module, `Statifier.Telemetry`
(`lib/statifier/telemetry.ex`), and every driver - `Statifier.Session`
included - emits through it. `statifier_persistence` does not hand-roll
emissions against a documented table; it calls the same functions
`session.ex` calls. One implementation is what makes "the same family" a
structural fact rather than a review obligation, exactly the argument
ADR-0062 made for the bridge consuming only public events.

The module's shape, stated here because implementation lands in a later
stage of this bead:

- `Statifier.Telemetry` receives the entire current body of
  `Statifier.Session.Telemetry`: the authoritative `@moduledoc` contract
  table, `events/0`, the lifecycle emitters (`init`, `halt`, `terminate`,
  `macrostep_start`, `macrostep_stop`, `interpret`, `unroutable`), the
  `effect/3` dispatcher, and the private shape builders, location resolver,
  and configuration translation - moved, not copied.
- Every public emitter function gains a leading `driver :: atom()`
  argument, and every event's metadata gains that value under the `driver`
  key (decision 4). `events/0` is unchanged in shape: same 27 names.
- `Statifier.Session.Telemetry` stays, as a thin facade: its existing
  public functions keep their arities and `defdelegate`/wrap into
  `Statifier.Telemetry` with `driver: :session` pinned, and its `events/0`
  delegates directly. Its `@moduledoc` shrinks to a pointer at the new
  module. Nothing published in 2.0.0 breaks; the facade is soft-deprecated
  in docs and its removal is a 3.0 question, not this record's.
- `Mix.Statifier.AdrGuard.@effect_interpreter_paths` gains
  `lib/statifier/telemetry.ex`. This is the reopening trigger ADR-0040
  named ("a second module outside `session.ex` and `session/telemetry.ex`
  needing an exemption for telemetry-shaped reasons"), fired on purpose:
  the exemption is not a second effect interpreter appearing, it is the
  ADR-0040 emission half moving to a path whose name no longer claims the
  session owns it. The exempt surface stays what it was - the emission
  code - plus one facade; the guard's list and this record land on the
  same branch, the same pairing rule ADR-0040 used.
- Clock reads (`System.system_time/0`, `System.monotonic_time/0`) stay
  inside the emitter and its callers, as today. ADR-0034's clock-freedom
  is untouched for the same reason ADR-0040 gave: telemetry is a
  live-channel concern, never recorded, never replayed. `Statifier.Replay`
  still fires nothing.

The core remains silent. No advance entry in `Statifier.Interpreter` ever
calls `:telemetry` (ADR-0003); the driver that called the core emits, which
is why a driver that wants observability must call the emitter at its own
seam. For `statifier_persistence` that seam is its stepper: open the
macrostep span before the advance call, emit the effect events while
executing the returned effects, close the span after, emit `:halt` on a
terminal outcome.

### 3. Per-event applicability across drivers

No event changes shape. The contract gains an applicability column instead
of new names:

| Event | `Statifier.Session` | Process-less driver |
|---|---|---|
| `:init` | at process boot, `resumed` per ADR-0060 | once per logical run, at `Interpreter.initialize/2` time, `resumed: false`; never per load |
| `:halt` | yes | yes - the step whose outcome is terminal |
| `:terminate` | yes (GenServer contract) | never |
| `:macrostep, :start` / `:stop` | yes | yes - brackets each core advance call |
| `:interpret` | yes (ADR-0029 seam) | only if the driver exposes an equivalent injection seam |
| `:unroutable` | yes | yes - the driver routes effects too |
| `:effect, _` (11) | yes | yes |
| `:trace, _` (9) | yes, under `trace: true` | yes, under `trace: true` - the flag rides the position (ADR-0060), and the gate stays in the core |

The judgments behind the non-obvious rows:

- **`:init` is initialization, not loading.** On the durable path a run is
  rehydrated on every step; an `:init` per load would fire thousands of
  times per logical run and would mean "process boot", which does not
  exist there. The durable `:init` marks the one
  `Interpreter.initialize/2` call at run creation. There is no
  `resumed: true` durable `:init`, because resumption is implicit in every
  load rather than an event; correspondingly the `:resume` trigger on the
  macrostep span stays Session-only, since a rehydration is not an
  advance.
- **`:terminate` has no durable analog and gets no replacement.** It names
  a GenServer callback. ADR-0040 already directs "session finished"
  metrics at `:halt`, and that guidance is driver-uniform. The bridge's
  per-session ETS cleanup keys on `:terminate` plus a liveness sweep
  today; for the durable driver both span halves arrive within one
  synchronous call (decision 5), so there is no open-span entry to leak,
  and the existing sweep covers the last-span-context link entry.
- **`:interpret` is conditional, not dropped.** It names Session's
  ADR-0029 injection seam. A durable driver with no such seam emits
  nothing there; one that grows an equivalent seam emits the same event
  rather than minting a new name.

### 4. Metadata: `driver` is the one addition

Every event's metadata gains `driver :: atom()`, identifying the stepping
driver that emitted it. `Statifier.Session` emits `driver: :session`; that
value is reserved for this library's own process driver. An external
driver names itself with one stable atom of its own - the
`statifier_persistence` follow-up is expected to use `:persistence`, but
the choice is that repo's, made once and frozen by its own contract.

Nothing else is added, and that is the point of the shared family:
`session_id`, the counter measurements, `span_ref`, `caller_context`
(ADR-0063), the location-resolution rule, and the configuration
translation are identical across drivers because one implementation
produces them (decision 2). The bridge's attribute mapping in
`docs/opentelemetry.md` is unchanged except for one new uniform attribute
(`statifier.driver`), and a consumer that ignores `driver` sees exactly
the pre-amendment contract - the addition is additive under ADR-0040's
freeze, the same precedent as `resumed` (ADR-0060) and `caller_context`
(ADR-0063).

A storage-level run identity key was considered and rejected here:
`session_id` is the durable correlation key on both paths (ADR-0060's
`_sessionid` rule exists precisely so it survives the crash or deploy),
and a host-side run or job id is `statifier_persistence`'s own vocabulary,
carried on its own events (decision 6) or in ADR-0063's opaque
`caller_context` slot, never flattened into this contract.

### 5. Span semantics when a step is one call

`span_ref` keeps its ADR-0040 semantics unchanged: a fresh `make_ref/0`
per span, carried on both halves, the only pairing key. On the durable
path both halves are emitted within one driver call, so pairing is trivial
- the key stays anyway, because uniform bridge code beats a per-driver
special case, and because a durable driver that delivers internal events
through `deliver_internal/5` mid-execution can nest spans exactly as
ADR-0039 re-entry does in a session.

What the one-call shape does constrain: **a macrostep span never crosses a
persist boundary.** A reference is node- and VM-local and cannot be
serialized; the contract therefore requires a driver to emit a span's
start and stop within the same driver invocation, bracketing the in-memory
core advance - never a span opened before persist and closed after a later
load. The durable timeline across steps is stitched the way
`docs/opentelemetry.md` already stitches session macrosteps: one trace per
macrostep, linked to its predecessor via the bridge's last-span-context
table, and to the scheduling trace via `caller_context` (ADR-0063) when
the step was driven by a durable timer or an external send.

### 6. Load and persist bracketing is not this contract

The durable loop has phases this vocabulary deliberately does not name:
load, decode/identity-check, effect execution against storage, persist,
lock handling. Those are storage-lifecycle semantics owned by
`statifier_persistence` (per the family's contract-ownership rule), and
they belong in that package's own event namespace - for example
`[:statifier_persistence, ...]` - designed in that repo, bridged by
`opentelemetry_statifier` as a sibling setup call exactly as ADR-0062
decision 3 already plans for the family. This record draws the line: the
`[:statifier, :session, ...]` family describes interpreter semantics
(initialization, macrosteps, effects, traces, halting), whatever the
driver; everything about how a position got into memory and back out is
the driver's own surface. A durable macrostep span is therefore expected
to appear *inside* whatever step/job span the persistence and Oban layers
open around it, attached by the ordinary OTel ambient context, since both
are in the same process during the call.

## Consequences

- Follow-ups, by owner. In this repo, a later stage of this same bead
  (st-737e) implements decision 2: `Statifier.Telemetry`, the
  `Statifier.Session.Telemetry` facade, the AdrGuard path addition, the
  ADR-0040 status-line amendment note, and the `docs/observability.md`
  constraint-6 / `docs/opentelemetry.md` updates (attribute
  `statifier.driver`; the durable stitching in decision 5). In
  `statifier_persistence`: emit through `Statifier.Telemetry` at the
  stepper seam per decision 3's table, and design its own storage-phase
  events per decision 6 (to be filed there, mirrored per the family's
  `mirrors:` discipline). In `opentelemetry_statifier`: read `driver`,
  map it to `statifier.driver`, and verify the no-`:terminate` cleanup
  path for the durable driver. In `statifier_oban`: nothing new - its jobs
  drive the persistence stepper and inherit its emissions.
- ADR-0040 is amended in part, not superseded: prefix meaning, emitter
  location, and the `driver` metadata key. Its event names, shapes,
  measurement/metadata split, location rules, and freeze all stand, and
  its status line gains this amendment on the implementing branch.
- The contract freeze now binds `Statifier.Telemetry`: the facade keeps
  2.0.0 consumers whole, and from the first bridge release reading
  `driver`, that key is frozen like every other.
- What would reopen this record: a driver needing an event the
  applicability table marks inapplicable (rather than absent by
  circumstance); a second external driver whose seam cannot call
  `Statifier.Telemetry` (which would force the documented-contract
  hand-roll this record rejects); or `statifier_persistence`'s storage
  events wanting to live under `[:statifier, ...]` after all, which
  decision 6 currently refuses.

## Open questions

Recorded, not blocking:

1. The durable driver's atom (`:persistence` suggested here) is decided
   and frozen by `statifier_persistence`'s follow-up, not by this record;
   the bridge should treat `driver` as an open enumeration either way.
2. Whether a durable driver that grows an injection seam reuses
   `:interpret` verbatim or needs a distinguishing trigger-style metadata
   key is deferred until such a seam exists (decision 3 commits only to
   "same event, not a new name").
3. Whether the `Statifier.Session.Telemetry` facade is formally
   `@deprecated` at the next minor or only documented as superseded is
   left to the implementing stage's judgment against the 2.x deprecation
   noise budget; removal is 3.0 either way.
