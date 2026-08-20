# OpenTelemetry

How the `[:statifier, :session, ...]` telemetry contract (ADR-0040,
`Statifier.Session.Telemetry`) maps onto OpenTelemetry, and where the code
that does the mapping lives. This is the st-cmq.2 design note; the packaging
half is decided by ADR-0062 (a separate package, `opentelemetry_statifier`),
and this page holds the span topology, context propagation, and
sampling/cardinality decisions the bridge implements.

Read alongside `docs/observability.md` (the constraints that shaped the
telemetry surface) and ADR-0040 (the event contract itself). OpenTracing is
not a target: the project merged into OpenTelemetry and is archived, so OTel
is the only tracing API this note considers.

## Constraints fixed before this note

Restated from st-cmq.2 so the decisions below are read against them:

- No OTel API call anywhere but the bridge. `statifier` takes no
  `opentelemetry_api` dependency, ever; `Mix.Statifier.AdrGuard` already
  flags process-shaped calls outside the session boundary, and the bridge
  lives outside this repo entirely (ADR-0062).
- The bridge consumes only the public telemetry events. If it needs data the
  events lack, the fix is the event contract gaining a field under ADR-0040's
  amendment discipline - never the bridge reaching into internals.
- Trace-off behavior degrades gracefully (last section).

## Packaging: a separate package, `opentelemetry_statifier`

Decided by ADR-0062; the survey the bead asked for is recorded here.

The BEAM ecosystem settled this question some time ago: a library emits
`:telemetry` events and stays free of OTel dependencies, and an
OpenTelemetry bridge ships as a separate `opentelemetry_<lib>` package,
most of them collected in `open-telemetry/opentelemetry-erlang-contrib`.

| Library | Bridge | In-library OTel? |
|---|---|---|
| Oban | `opentelemetry_oban` | no |
| Ecto | `opentelemetry_ecto` | no |
| Phoenix | `opentelemetry_phoenix` | no |
| Broadway | `opentelemetry_broadway` | no |
| Finch | `opentelemetry_finch` | no |
| Redix | `opentelemetry_redix` | no |

The alternative the bead names - an optional `Statifier.Telemetry.OTel`
module behind a `Code.ensure_loaded?` guard - is the minority pattern, and
it costs a with-and-without-OTel test matrix in this repo's gate, OTel
concepts in this repo's docs, and a release of `statifier` every time the
OTel API moves. The separate package also makes the consume-only-public-
events constraint structural rather than reviewed: a bridge in its own repo
has nothing but the public contract to build against.

The package is named `opentelemetry_statifier` (ecosystem convention wins
over the `statifier_*` family convention - it should be findable next to
`opentelemetry_oban`), and its scope is the family, not just this repo: as
`statifier_persistence` and `statifier_oban` grow telemetry surfaces of
their own, their bridges land in the same package as optional per-library
setup calls, which is the one thing an in-library module could never do.
See ADR-0062 for the full argument, including why the package stays
unpublished (pinning `main` SHAs per ADR-0061) until `statifier` itself is
on Hex.

## Span topology

**A macrostep is a span.** The `[:statifier, :session, :macrostep, :start]`
/ `[..., :stop]` pair is already shaped for this: both halves carry
`span_ref` (the `telemetry_span_context` convention) and `monotonic_time`,
so the bridge opens a span on `:start` and closes it on the `:stop` whose
`span_ref` matches - never by pairing on `(session_id, macrostep)`, which
the module doc explains is unusable (ADR-0039 re-entry nests spans, and
`macrostep` is only authoritative on the stop half). Span name:
`statifier.macrostep`, with `trigger` (`initialize | event | cancel |
internal`) and `event_name` as attributes rather than in the name -
event names are chart vocabulary and would explode the span-name
cardinality backends key on.

**Effect and trace events are span events, not child spans.** Everything
that fires between a `:start` and its `:stop` - the eleven
`[:statifier, :session, :effect, _]` events, the nine
`[:statifier, :session, :trace, _]` events, `:interpret`, `:unroutable`,
`:halt` - is recorded as a span event on the currently open macrostep span.
Microsteps as full child spans were considered and rejected as too chatty:
a traced run emits several trace events per microstep and a macrostep can
run many microsteps, and none of them has a meaningful duration of its own
(they are points, not intervals - the interval is the macrostep). The
`macrostep`/`microstep`/`round` measurements ride along as span-event
attributes, so the intra-macrostep timeline is fully reconstructible from
one span.

**There is no session-lifetime span.** A `Statifier.Session` can live for
days behind a persistence host; a span that long outlives every backend's
buffering and export assumptions and would hold every macrostep hostage to
one sampling decision. Session identity is an attribute
(`statifier.session_id` on every span), not a span.

**One trace per macrostep, stitched with links.** Each macrostep span is
the root of its own trace, carrying span links for its causal and temporal
neighbors:

- a link to the same session's previous macrostep span (the bridge holds
  the last-emitted span context per `session_id` in an ETS table it owns),
  so a backend can walk a session's history even though each macrostep
  samples independently;
- for a child session's `:initialize` macrostep, a link to the parent
  session's macrostep span that was open when the child started. The
  `:init` event's `invoked_by` metadata names the parent session, and the
  parent's open span context is in the same ETS table - invoke children run
  on the same node as their parent, so no wire-format propagation is needed
  for this link.

Links rather than parent-child relationships, in both cases: a
parent-child edge claims the child's duration is contained in the
parent's, which is false for both (the next macrostep starts after the
previous one closed; a child session outlives the invoking macrostep). The
alternative - one trace per session - was rejected with the
session-lifetime span and for the same reason: unbounded traces.

**The session-process caveat, and why caller attachment is future work.**
`:telemetry.execute/3` is synchronous, so the bridge's handlers run in the
session's own GenServer process. OTel context is process-local, which means
the *sender's* current span context is never ambient where the bridge
runs: by the time a macrostep span opens, the caller's context stayed in
the caller's process. The bead's "probably yes - the sender's trace wants
to see the statechart react" is therefore not implementable from the
public events as they stand, and under the constraints above the fix is an
upstream field, not a bridge workaround. The named follow-up (tracked as
its own bead, cross-repo mirrored): external events and the delayed-send
effect vocabulary gain an opaque caller-context slot the host sets at send
time and the bridge reads at emission - which is the same field a durable
timer host (`statifier_oban`) needs so that a delayed send firing hours
later can link back to the trace that scheduled it. Until that field
exists, macrostep traces are detached and the previous-macrostep /
invoke-parent links above are the whole correlation story.

## Attribute mapping

All attributes live under the `statifier.` namespace. The general mapping,
applied uniformly rather than per-event:

- Measurements (`macrostep`, `microstep`, `round`, `size`, `delay_ms`,
  `budget`, `effect_count`, `ordinal`) become integer attributes of the
  same name.
- Identity metadata (`session_id`, `event_name`, `trigger`, `outcome`,
  `reason`, `send_id`, `target`, `invoke_id`, `label`, the constraint-3
  indexes) becomes string/int attributes of the same name.
- A resolved `location` (a `%Statifier.Parser.Location{}`) flattens to
  `statifier.source.line` / `statifier.source.column` - the one place the
  bridge flattens a struct, because OTel attributes are scalar.
- `configuration` (already translated to state-id strings by the contract)
  becomes a string-array attribute; it is bounded by the chart's state
  count, not by runtime data.
- The raw `effect` struct in every event's metadata is *not* serialized
  into attributes. It is there for in-VM consumers; a wire format is
  exactly where "the struct rides verbatim" stops being cheap.

## Sampling and cardinality

- Span-name cardinality is one (`statifier.macrostep`); event names,
  state ids, and indexes are attributes, which backends tolerate at chart
  cardinality.
- Nothing unbounded is exported by default. The two events whose payloads
  carry datamodel values - `:datamodel_change` (`new_value`,
  `prior_value`) and `:datamodel_init` (`datamodel`) - are recorded as
  span events *without* those value attributes unless the host opts in at
  bridge setup (`record_datamodel_values: true`). The write's identity
  (`location_path`, `location_source`, indexes, location) is always
  recorded; the values are the opt-in.
- Trace-family span events multiply volume by roughly the microstep count;
  they exist only under `trace: true` (below), which is itself the
  sampling knob for that granularity. The bridge adds no second filter.
- Head sampling composes per macrostep trace: because every macrostep is
  its own root, a sampler drops whole macrosteps, never half of one, and
  links to unsampled neighbors are the standard OTel dangling-link case.

## Failure tolerance

Two caveats the event contract publishes, and what the bridge does about
them:

- A crash mid-span leaves a `:start` with no `:stop`. The bridge must not
  leak: the per-session ETS entry (open span + last span context) is
  cleaned on `:terminate`, and because `:terminate` does not fire on a
  brutal kill, the bridge sweeps entries whose sessions no longer exist
  rather than trusting the event alone. An unmatched open span is ended
  with an error status at sweep time, not silently dropped.
- The `:initialize` span's `:start` fires after `Interpreter.initialize/2`
  already ran, so its wall-clock start is late even though `duration` on
  the stop is honest. The bridge sets the span start from the event's
  `monotonic_time` and accepts the skew on that one span rather than
  inventing a second clock.

## Trace-off degradation

With `trace: false` the core produces no trace effect at all -
`Statifier.Effect.trace/3` expands to nothing, so the trace family never
reaches `:telemetry` and the bridge has nothing to filter (ADR-0040's
structural gate). The bridge therefore degrades to exactly what the
lifecycle and core-effect families carry: macrostep-grained spans with
effect-level span events, locations included. No bridge configuration
changes, no conditional in the bridge; turning `trace` on enriches the
same spans with microstep-grained span events and nothing else changes
shape.

## What lands where

| Piece | Where |
|---|---|
| Packaging decision, naming, publish policy | ADR-0062 (this repo) |
| The bridge itself: handlers, ETS span table, setup API | `opentelemetry_statifier` (own repo) |
| Caller/delayed-send context field | future statifier-ex bead (ADR-0040 amendment), mirrored into `statifier_oban`'s tracker |
| Sibling-package telemetry surfaces and their bridge halves | each sibling repo's own ADR, bridged in `opentelemetry_statifier` |

Nothing in this note adds code to this repository. The one obligation it
leaves here is the contract freeze ADR-0040 already states: once
`opentelemetry_statifier` ships against the 27 event names and their
shapes, changing one is a breaking change to a real consumer.
