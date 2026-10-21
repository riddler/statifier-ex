# OpenTelemetry

**Read this to:** build or review the OpenTelemetry bridge for the
`[:statifier, :session, ...]` telemetry contract.
**Short version:** the bridge is a separate package, `opentelemetry_statifier`.
It turns each macrostep into one span. Effect and trace events become span
events. This repo adds no OTel code.

`Statifier.Telemetry` emits the contract. ADR-0067 extends it to every stepping
driver, not only `Statifier.Session.Telemetry`. This page holds the decisions
the bridge implements: span topology, context propagation, sampling, and
cardinality. It is the st-cmq.2 design note.

Read it with `docs/observability.md` (the constraints behind the telemetry
surface). OpenTracing is not a target. It merged into OpenTelemetry and is
archived. OTel is the only tracing API that this page considers.

Decisions:
[ADR-0040](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0040-session-telemetry-event-contract.md),
[ADR-0062](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0062-opentelemetry-bridge-is-a-separate-package.md),
[ADR-0067](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0067-one-telemetry-contract-across-stepping-drivers.md).

## Constraints fixed before this note

These constraints come from st-cmq.2. Read the decisions below against them:

- **No OTel in this repo.** No OTel API call exists outside the bridge.
  `statifier` takes no `opentelemetry_api` dependency, ever.
  `Mix.Statifier.AdrGuard` already flags process-shaped calls outside the
  session boundary. The bridge lives in its own repo.
- **Public events only.** The bridge consumes only the public telemetry events.
  If it needs data the events lack, the event contract gains a field under the
  amendment rules of ADR-0040. The bridge never reads internals.
- **Graceful trace-off.** See "Trace-off degradation" below.

## Packaging: a separate package, `opentelemetry_statifier`

Decision: [ADR-0062](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0062-opentelemetry-bridge-is-a-separate-package.md)

The BEAM ecosystem settled this question some time ago. A library emits
`:telemetry` events and has no OTel dependencies. A separate
`opentelemetry_<lib>` package holds the bridge. Most of these packages are in
`open-telemetry/opentelemetry-erlang-contrib`. The table below is the survey
that the bead asked for.

| Library | Bridge | In-library OTel? |
|---|---|---|
| Oban | `opentelemetry_oban` | no |
| Ecto | `opentelemetry_ecto` | no |
| Phoenix | `opentelemetry_phoenix` | no |
| Broadway | `opentelemetry_broadway` | no |
| Finch | `opentelemetry_finch` | no |
| Redix | `opentelemetry_redix` | no |

The bead names an alternative: an optional `Statifier.Telemetry.OTel` module
behind a `Code.ensure_loaded?` guard. This is the minority pattern. It has
three costs:

- A with-OTel and without-OTel test matrix in this repo's gate.
- OTel concepts in this repo's docs.
- A release of `statifier` each time the OTel API changes.

A separate package also makes the public-events-only constraint structural. A
bridge in its own repo can build against nothing but the public contract.

**Name.** The package is `opentelemetry_statifier`. The ecosystem convention
wins over the `statifier_*` family convention, so users find it next to
`opentelemetry_oban`.

**Scope.** The package covers the whole family. `statifier_persistence` and
`statifier_oban` can add telemetry surfaces of their own. Their bridges then
land in the same package as optional per-library setup calls. An in-library
module cannot do this.

**Publishing.** The original clause of ADR-0062 on why the bridge stayed
unpublished pinned `main` SHAs (ADR-0061) until `statifier` itself was on Hex.
That clause is resolved. statifier 2.0.0 is published, and the bridge package
publishes on its own schedule.
Decisions:
[ADR-0061](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0061-sha-pinning-contract-until-2-0-0.md),
[ADR-0066](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0066-publishes-2-0-0-ending-the-sha-pinning-contract.md).

## Span topology

**A macrostep is a span.** The `[:statifier, :session, :macrostep, :start]`
and `[..., :stop]` events fit this. Both carry `span_ref` (the
`telemetry_span_context` convention) and `monotonic_time`.

1. On `:start`, the bridge opens a span.
2. On the `:stop` with the matching `span_ref`, the bridge closes it.
3. The bridge never pairs events on `(session_id, macrostep)`. The module doc
   explains that this pairing is unusable: re-entry nests spans (ADR-0039), and
   `macrostep` is authoritative only on the stop half.

Decision:
[ADR-0039](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0039-session-detected-send-failures-re-enter-the-core.md)

**Span name.** The name is `statifier.macrostep`. The `trigger`
(`initialize | event | cancel | internal | resume`) and `event_name` are
attributes. Event names are chart vocabulary. In the span name they would raise
the span-name cardinality that backends key on.

**Effect and trace events are span events, not child spans.** This covers
everything that fires between a `:start` and its `:stop`:

- the eleven `[:statifier, :session, :effect, _]` events
- the nine `[:statifier, :session, :trace, _]` events
- `:interpret`, `:unroutable`, and `:halt`

The bridge records each as a span event on the open macrostep span. Child spans
for microsteps are too chatty. A traced run emits several trace events per
microstep, and a macrostep can run many microsteps. A microstep has no duration
of its own. It is a point, and the macrostep is the interval. The `macrostep`,
`microstep`, and `round` measurements are span-event attributes. One span
therefore holds the full intra-macrostep timeline.

**No session-lifetime span.** A `Statifier.Session` can live for days behind a
persistence host. A span that long outlives the buffering and export limits of
every backend. It also ties every macrostep to one sampling decision. Session
identity is an attribute (`statifier.session_id` on every span), not a span.

**One trace per macrostep, stitched with links.** Each macrostep span is the
root of its own trace. It carries span links to its neighbors:

- **Previous macrostep.** A link to the same session's previous macrostep span.
  The bridge holds the last-emitted span context per `session_id` in an ETS
  table it owns. A backend can then walk a session's history, although each
  macrostep samples independently.
- **Parent session.** For a child session's `:initialize` macrostep, a link to
  the parent macrostep span that was open when the child started. The `:init`
  event's `invoked_by` metadata names the parent session. The parent's open span
  context is in the same ETS table. Invoke children run on the same node as
  their parent, so this link needs no wire-format propagation.

Both cases use links, not parent-child relationships. A parent-child edge
claims that the parent's duration contains the child's. This is false in both
cases. The next macrostep starts after the previous one closed. A child session
outlives the invoking macrostep. One trace per session is also rejected, for the
same reason as the session-lifetime span: unbounded traces.

**A durable timeline stitches the same way.**
Decision: [ADR-0067](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0067-one-telemetry-contract-across-stepping-drivers.md) (decision 5)

- A driver must emit both halves of a macrostep span within one driver
  invocation. It must never open a span before a persist and close it after a
  later load. `span_ref` is a `make_ref/0` reference. It is local to the node
  and the VM, so it cannot cross a persist boundary. This rule keeps the spans of
  a durable driver under the rule above, so they need no rule of their own.
- A macrostep stepped without a `Statifier.Session` process stitches exactly as
  a session's macrostep does. Per-macrostep traces link through the bridge's
  last-span-context table.
- When a durable timer or an external send drove the step, the span links to the
  scheduling trace through `caller_context`.
- A durable macrostep span nests inside the step or job span that the
  persistence and Oban layers opened around it. This happens through ordinary
  OTel ambient context, because both run in the same process during the call.
  The bridge's own parent-child or link machinery does not do this.

**The session-process caveat, and how `caller_context` closes it.**
`:telemetry.execute/3` is synchronous. The bridge's handlers therefore run in
the session's own GenServer process. OTel context is process-local, so the
sender's current span context is never ambient where the bridge runs. When a
macrostep span opens, the caller's context is still in the caller's process.

The fix is an upstream field, not a bridge workaround. `caller_context ::
term()` is an opaque slot. The host sets it at send time
(`Statifier.Event.external(name, caller_context: ctx)`). The library carries it
and never reads it.
Decision: [ADR-0063](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0063-caller-context-on-external-events-and-durable-timer-effects.md)

The bridge reads these metadata keys (ADR-0063 decision 4):

- `caller_context` on `[:statifier, :session, :macrostep, :start]` and
  `[..., :stop]`. It is the slot of the triggering external event. It is `nil`
  for the `:initialize`, `:cancel`, `:internal`, and `:resume` triggers, and for
  an event sent without a slot. It attaches a macrostep span to the sender's
  trace.
- `caller_context` on `[..., :effect, :send_delayed]` and
  `[..., :effect, :cancel]`. A durable timer host (`statifier_oban`) stores it
  as row data. A delayed send that fires hours later can then link back to the
  trace that scheduled it.
- `caller_context` on `[..., :effect, :invoke]` and
  `[..., :effect, :cancel_invoke]` (ADR-0063 amendment of 2026-09-01). An
  asynchronous invoke handler stores the term with its invocation row. It
  restores the term on the result event. The result of an invocation then links
  back to the trace that started it, as a timer's firing does.
- `[..., :effect, :autoforward]` needs no key. Its effect carries the
  triggering event whole, slot included.

The bridge uses the value to parent or link. It never flattens the value into
span attributes. The attribute mapping below draws the same line for
`metadata.effect`. A macrostep whose trigger attached no context stays
detached. The previous-macrostep link and the invoke-parent link above remain
its correlation story.

## Attribute mapping

All attributes live under the `statifier.` namespace. The mapping applies to
all events in the same way, not per event:

- **Measurements.** `macrostep`, `microstep`, `round`, `size`, `delay_ms`,
  `budget`, `effect_count`, and `ordinal` become integer attributes of the same
  name.
- **Identity metadata.** `session_id`, `event_name`, `trigger`, `outcome`,
  `reason`, `send_id`, `target`, `invoke_id`, `label`, and the constraint-3
  indexes become string or integer attributes of the same name.
- **Location.** A resolved `location` (a `%Statifier.Parser.Location{}`)
  flattens to `statifier.source.line` and `statifier.source.column`. This is the
  only struct that the bridge flattens, because OTel attributes are scalar.
- **Configuration.** `configuration` (already translated to state-id strings by
  the contract) becomes a string-array attribute. The chart's state count bounds
  it. Runtime data does not.
- **Effect struct.** The bridge does not serialize the raw `effect` struct in
  the metadata of each event into attributes. The struct is for in-VM
  consumers. On a wire format, passing the struct verbatim is no longer cheap.
- **Driver.** `driver` becomes the `statifier.driver` attribute on every span
  and span event. It is `:session` for a `Statifier.Session` process, and the
  driver's own frozen atom for an external driver. A consumer that ignores it
  sees the contract as it was before the amendment. Decision: ADR-0067
  decision 4.

## Sampling and cardinality

- **Span names.** Cardinality is one (`statifier.macrostep`). Event names, state
  ids, and indexes are attributes. Backends tolerate attributes at chart
  cardinality.
- **Datamodel values.** By default, the bridge exports nothing unbounded. Two
  events carry datamodel values in their payloads: `:datamodel_change`
  (`new_value`, `prior_value`) and `:datamodel_init` (`datamodel`). The bridge
  records them as span events without those value attributes. The host can opt
  in at bridge setup with `record_datamodel_values: true`. The bridge always
  records the identity of the write (`location_path`, `location_source`,
  indexes, location). Only the values are opt-in.
- **Trace-family events.** They multiply the volume by roughly the microstep
  count. They exist only under `trace: true` (see "Trace-off degradation"),
  which is the sampling control for that granularity. The bridge adds no second
  filter.
- **Head sampling.** It works per macrostep trace. Every macrostep is its own
  root, so a sampler drops whole macrosteps and never half of one. Links to
  unsampled neighbors are the standard OTel dangling-link case.

## Failure tolerance

The event contract publishes two caveats. The bridge handles each as follows.

**A crash mid-span** leaves a `:start` with no `:stop`. The bridge must not
leak.

- It cleans the per-session ETS entry (open span and last span context) on
  `:terminate`.
- `:terminate` does not fire on a brutal kill. The bridge therefore also sweeps
  entries whose sessions no longer exist.
- At sweep time, the bridge ends an unmatched open span with an error status. It
  does not drop the span silently.
- `:terminate` exists for sessions only. It names a GenServer callback and has
  no durable analog. This is not a gap in the cleanup. A process-less driver
  delivers both span halves inside one synchronous driver call, so a mid-span
  crash leaves no open-span entry. The liveness sweep still covers the
  last-span-context entry in both cases.
  Decision: ADR-0067 decisions 3 and 5.

**A late `:initialize` start.** The `:start` of the `:initialize` span fires
after `Interpreter.initialize/2` has already run. The wall-clock start of that
span is therefore late, but `duration` on the stop is correct. The bridge sets
the span start from the `monotonic_time` of the event. It accepts the skew on
that one span and does not add a second clock.

## Trace-off degradation

With `trace: false`, the core produces no trace effect at all.
`Statifier.Effect.trace/3` expands to nothing, so the trace family never
reaches `:telemetry`. The bridge has nothing to filter. This is the structural
gate of ADR-0040.

The bridge then carries only what the lifecycle and core-effect families carry:
macrostep spans with effect-level span events, locations included. It needs no
configuration change and no conditional. When `trace` is on, the same spans
gain microstep-level span events. Nothing else changes shape.

## What lands where

| Piece | Where |
|---|---|
| Packaging decision, naming, publish policy | ADR-0062 (this repo) |
| The bridge itself: handlers, ETS span table, setup API | `opentelemetry_statifier` (own repo) |
| Caller/delayed-send context field | shipped in this repo as `caller_context` (ADR-0063, amending ADR-0040); see the session-process caveat under "Span topology" above, mirrored into `statifier_oban`'s tracker |
| Sibling-package telemetry surfaces and their bridge halves | each sibling repo's own ADR, bridged in `opentelemetry_statifier` |
| Durable-driver emit sites: calling `Statifier.Telemetry` at the stepper seam, with its own `driver` atom | `statifier_persistence` (own repo, own ADR, per ADR-0067 decision 3) |

This note adds no code to this repository. It leaves one obligation here: the
contract freeze that ADR-0040 already states. After `opentelemetry_statifier`
ships against the 28 event names and their shapes, a change to one of them is a
breaking change for a real consumer.

The count was 27 until `[:statifier, :session, :trace, :conds_evaluated]`
joined the trace family. It is one of the 28. It is the
guard seam, an amendment to ADR-0040. It fires only under `trace: true` and has
the shape of the existing trace family. The bridge needs no change for it
except the name.
