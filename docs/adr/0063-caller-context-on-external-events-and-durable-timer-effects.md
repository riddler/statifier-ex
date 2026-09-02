# ADR-0063: An opaque caller context rides external events and the durable-timer effects

Status: accepted (2026-08-20) - amended 2026-09-01 (st-u9l6: the invoke
seam joins the carriers - `%Effect.Invoke{}` and `%Effect.CancelInvoke{}`
gain `caller_context`, the `:invoke`/`:cancel_invoke` telemetry events
gain the metadata key, and the recording format bumps `3 -> 4`; see
"Amendment 2026-09-01" below) - decides the field ADR-0062 decision 4
names ("caller trace context on external events and on `%SendDelayed{}`")
and discharges the "future work" caveat in `docs/opentelemetry.md`'s
session-process paragraph; amends 0040 in part (four events' metadata
gain `caller_context`), the same additive reopening 0046 and 0059 made;
ADR-0054's dedup and cancellation keys are untouched

## Context

`docs/opentelemetry.md`'s session-process caveat states the gap this
record closes: `:telemetry.execute/3` is synchronous, so the
`opentelemetry_statifier` bridge's handlers run in the session's own
GenServer process, where the *sender's* OTel context is never ambient -
by the time a macrostep span opens, the caller's context stayed in the
caller's process. Two wants are impossible until the events carry the
context as data:

- **Caller-attached macrostep spans.** A host sending an event from
  inside a traced request wants the resulting macrostep span linked to
  (or parented under) its own span. The bridge reads the public
  telemetry events and nothing else (ADR-0062 decision 4), so the
  context must arrive in event metadata.
- **Span links from a durable timer's firing back to the trace that
  scheduled it.** `statifier_oban` stores `%SendDelayed{}` rows and
  fires them hours later, in a worker process with no memory of the
  scheduling trace. The firing site can only link back if the effect
  row itself carried the context. `%Cancel{}` is processed against the
  same store and wants the same attribution for the cancellation act.

ADR-0062 decision 4 already chose the mechanism class: when the bridge
needs data the events lack, "the field is added here under ADR-0040's
amendment discipline", never by the bridge reaching into internals. This
record is that addition. Constraints already on the books bound its
shape:

- **The library never interprets the value.** `statifier` takes no OTel
  dependency, ever (ADR-0062 decision 1). Whatever the host puts in the
  slot - an OTel span context, a request id, a correlation map - is
  opaque here: copied, carried, and handed back, never read.
- **The stamp must be the core's, not the session's.** A session-side
  stamp at plan or delivery time fails replay, for the reason ADR-0046
  recorded when it rejected that shape for `round` and ADR-0059 cited
  again for `ordinal`: `Statifier.Replay` re-drives the pure fold and
  `Session.Effects.plan/2` with no session behind them (ADR-0034), so
  anything a live session added outside the fold would be absent from
  the replayed stream and the byte-identical claim would break.
- **The recording already stores events verbatim.**
  `Statifier.Session.Recording`'s `put_event/3`, `put_invoked_event/4`,
  and `put_timer/4` append the `%Statifier.Event{}` as given
  (ADR-0029's recorded inputs, ADR-0057's envelope). A field on the
  event struct therefore reaches the recording by default; stripping
  it would be new code whose only effect is losing the input replay
  needs.
- **Additive is the open direction.** ADR-0040's st-ii9v amendment
  records that adding a metadata key to a published event is
  non-breaking while removing one after the bridge ships is breaking;
  ADR-0046 and ADR-0059 both reopened 0040 through exactly that door.

## Decision

**1. The field is `caller_context :: term()`, defaulting to `nil`, and
the library never reads it.** Named for what it holds - the caller's
context at send time - not for one consumer: nothing in the name or type
commits the slot to OpenTelemetry, and a host may carry any correlation
value. `nil` means "no context attached"; the `:undefined` convention on
`Statifier.Event.data` does not apply, because this slot never holds
datamodel content and a datamodel null can never be a caller context, so
`nil` is unambiguous here for the same reason it is on `sendid` and
`origin` (the event moduledoc's own argument). The field joins no
`@enforce_keys` list. The library's whole contract with the value is:
copy it where this record says, expose it where this record says, and
never pattern-match, transform, or branch on it anywhere.

**2. Three carriers: `%Statifier.Event{}`, `%SendDelayed{}`, and
`%Cancel{}`. No other struct gains the field.**

- `%Statifier.Event{}` gains `caller_context`, settable only through
  `Event.external/2`'s opts. `internal/3` and `platform/3` never read
  it from opts: an event the chart raised has no external caller, and
  its macrostep's attribution belongs to whatever external input opened
  that macrostep. No new `Statifier.Session` function is needed - a
  host attaches context by building the event
  (`Event.external(name, caller_context: ctx)`) and passing it to the
  existing `send_event/2` / `send_invoked_event/3`; the binary
  convenience `send_event(server, "name")` naturally attaches none.
- `%SendDelayed{}` and `%Cancel{}` each gain `caller_context`, stamped
  at their existing construction sites (decision 3). Both, not just the
  send: the two effects are one durable-timer vocabulary (ADR-0054
  decision 1), the same store processes both, and the firing-side host
  wants the cancellation act attributed exactly as it wants the firing
  attributed - the same both-or-neither argument that gave `%Cancel{}`
  its `ordinal` (ADR-0059 fact 4, by analogy rather than by dedup
  mechanics).
- No other effect carries it, by the rule ADR-0059 decision 5 already
  wrote for `ordinal`: the two durable-timer effects outlive the
  macrostep that emitted them, and no other effect does. An immediate
  `%Send{}` is delivered inside the macrostep whose telemetry already
  carries the context (decision 4); stamping it there would duplicate a
  value every consumer can already read off the enclosing span.
- The slot never reaches the datamodel.
  `Statifier.Evaluator.SystemVariables.event/1` does not surface it, so
  `_event` is unchanged: spec 5.10.1 fixes `_event`'s fields, the value
  is host plumbing rather than chart-visible data, and a chart that
  could branch on its caller's trace context would make conformance
  runs depend on observability wiring.

**3. The stamp is the core's: `%MachineState{}` gains a transient
`caller_context :: term()` field (default `nil`) naming the current
macrostep's caller, and the two effect constructors copy it.** Every
macrostep-opening core entry point overwrites the field, so it never
holds a stale value: `Interpreter.handle_event/2` writes the triggering
event's `caller_context` at the macrostep's head (beside the existing
`begin_macrostep/1` / `put_event/2` sequence), and `initialize/2` and
`cancel/1` write `nil` - their macrosteps have no sending caller.
Internal-event rounds never touch it: an internal event was raised by
the chart inside the same macrostep, so the macrostep's attribution
stands. `<send delay>` and `<cancel>` executed anywhere in that
macrostep - directly, in an internal round, inside a `<foreach>` - read
the field into the effect at the same sites that read the counters
today. Because the field is pure fold state, ADR-0034's replay re-mints
it byte-identically from the recorded events, which is the whole reason
the session must not be the stamping site.

The chain continues at firing time without a new mechanism:
`Statifier.Session.Effects`' `delivered_event/2` and `internal_event/1`
- the functions that build the event a `{:schedule, ...}` instruction
will later deliver - copy `send.caller_context` onto the event they
construct. An in-process timer firing therefore re-enters
`handle_event/2` carrying the scheduler's context, and the firing
macrostep's telemetry attributes to it with no session-side code; a
durable host does the same copy at its own firing site (the
`statifier_oban` half). Both functions run inside `plan/2`, which replay
re-drives, so the copy is replay-sound. Autoforwarding needs nothing:
the forwarded event is the same `%Event{}` value, so its slot travels to
the invoked child untouched.

**4. Four telemetry events gain a `caller_context` metadata key - the
ADR-0040 amendment.** Per 0040's split, the value is identity, not a
number, so it is metadata everywhere and a measurement nowhere:

- `[:statifier, :session, :macrostep, :start]` and `[..., :stop]` gain
  `caller_context` - the triggering external event's slot, `nil` for
  the `:initialize`/`:cancel`/`:internal` triggers and for an event
  sent without one. Both halves carry it for the same reason both carry
  `trigger` and `event_name`: a consumer attaching to only one half
  still attributes. This is the read point for caller-attached
  macrostep spans.
- `[:statifier, :session, :effect, :send_delayed]` and `[..., :cancel]`
  gain `caller_context` beside their existing identity keys. The value
  also rides in `metadata.effect` verbatim by 0040's transitivity rule;
  the explicit key keeps the bridge's read uniform with the macrostep
  events rather than making these two the only events it destructures a
  struct for.

No event is added or renamed; the contract stays 27 events, and the
addition is the direction 0040's st-ii9v amendment calls non-breaking.
On the bridge side the value is never flattened into span attributes -
it is an opaque in-VM term the bridge *uses* (to parent or link) rather
than *exports*, the same line `docs/opentelemetry.md` already draws for
`metadata.effect`.

**5. The recording carries the field; nothing strips it.** Three
arguments, in order of force:

- **Replay soundness requires it.** The live core copies
  `event.caller_context` into `%SendDelayed{}`/`%Cancel{}` (decision
  3), so the live effect stream contains the value. Replay reproduces
  that stream only if the recorded events still carry the input the
  copy reads. A stripped recording would replay to a *different* effect
  stream - precisely the failure ADR-0034's byte-identical claim
  exists to rule out. Carrying is not a convenience; it is what keeps
  the recording a sound input set under ADR-0029.
- **Stripping would be new code.** The appenders store the `%Event{}`
  as given today; the carry direction is the zero-code direction at
  record time.
- **The serializability question is already answered.** ADR-0057's
  Consequences place host-supplied terms inside recorded payloads -
  atoms and worse in event `data` - under the host's own `:safe` and
  pid-free obligation, with the codec neither scanning nor translating.
  `caller_context` joins `data` under exactly that existing rule: an
  OTel span context is plain data and round-trips fine; a host that
  stows a pid or a fun in the slot loses persistability of that
  recording the same way it would through `data`, and the library owes
  it nothing new.

One format consequence follows. `%Statifier.Event{}` gaining a defstruct
key changes the shape of the structs inside a recording blob's
`entries`: a blob written before the field decodes to event maps missing
`:caller_context`, and reading such a map as the new struct is exactly
the silent misread ADR-0057 decision 4's obligation names.
`Statifier.Session.Recording`'s `@format_version` therefore bumps
`2 -> 3` on the implementing branch, and this record blesses the same
default ADR-0059 blessed for version-1 positions: the decoder should
read version-2 blobs and default `caller_context: nil` onto each stored
event on import, which is safe exactly because a version-2 blob predates
the field - no context was ever attached to the events it holds.
`Statifier.Position` and `Statifier.Chart` are untouched:
`%MachineState{}`'s `caller_context` is transient per-macrostep state,
a position is written at quiescence where no macrostep is open and the
value attributes nothing, so it stays out of `Position`'s export and no
position bump happens. The chart did not change shape.

**6. ADR-0054's keys are untouched.** `caller_context` joins neither the
eight-component dedup key nor the `{session scope, send_id}`
cancellation key: an opaque host term has no business in a key (it is
not comparable across hosts, not bounded, and not replay-relevant to
identity), and ADR-0059's `ordinal` already made the dedup key
per-instance. A durable store carries the value as row data beside the
key components, reading it back at firing or cancellation time.

**7. Deliberately deferred, with the trigger named.** `Session.cancel/1`
and `Session.interpret/2` accept no context: their macrosteps (trigger
`:cancel`) and the `:interpret` event carry `caller_context: nil` until
a bridge consumer asks for attached cancellation or injection spans. The
addition would be additive on the same terms as this record - an opts
keyword on the public function, a metadata key already present - so
deferring costs nothing and commits nothing.

## Consequences

- The implementation is sized separately on this bead's follow-on, per
  ADR-0046/0059's precedent (this record changes no code): the field,
  `@type` line, and moduledoc paragraph on `Statifier.Event`,
  `Statifier.Effect.SendDelayed`, and `Statifier.Effect.Cancel`;
  `Event.external/2`'s opt; `%MachineState{}`'s transient field with
  its three writers and the two effect-constructor reads;
  `Session.Effects.delivered_event/2` / `internal_event/1`'s copy; the
  four telemetry metadata clauses and
  `Statifier.Session.Telemetry`'s contract table; the recording
  format-version bump `2 -> 3` with the version-2 import default and
  its round-trip tests; and the test/support literal builds.
- Documentation edits are directed to the implementing branch, the
  ADR-0049 decision 6 pattern: `docs/opentelemetry.md`'s
  session-process caveat paragraph is rewritten from "until that field
  exists" to the field's name and read points;
  `docs/durable-timers.md`'s field table gains the `caller_context` row
  (row data, never a key component); `docs/persistence.md`'s recording
  section notes the version bump and the host-term obligation the slot
  inherits from `data`. None of these may land before `lib/` carries
  the field, so none land with this record.
- A changelog fragment is owed on the implementing branch, not this
  one (ADRs alone get none, per `changelog.d/README.md`): the public
  additions and the recording format bump are exactly the ADR-0061
  decision 3 surface, and the version-2-read default keeps the bump
  from breaking blobs written against an earlier pin.
- The firing-side half - restoring the context and emitting span links
  when a stored timer fires or a stored cancel is processed - belongs
  to `statifier_oban`'s tracker. As of this record that mirror bead
  does not exist: this bead's `mirrors:` line names an id
  (`sob-v28`) that does not resolve in that tracker, and filing the
  statifier_oban half is a human ask no agent may make (this repo's
  cross-repo rules). Until it is filed, the in-process firing chain
  (decision 3's `plan/2` copy) is the only implemented consumer of the
  slot at firing time.
- Once `opentelemetry_statifier` ships against the amended shapes, the
  four metadata keys join the ADR-0040 freeze: removing or renaming one
  is a breaking change to a real consumer.
- What would reopen this record: a third effect becoming durably stored
  (it claims the same stamp, as it claims `ordinal`); a consumer
  needing the context on internal-round granularity rather than
  macrostep granularity (decision 3's overwrite rule is where that
  argument lands); the deferred `cancel/1`/`interpret/2` trigger in
  decision 7 firing; or the library ever needing to *read* the value,
  which would contradict decision 1 and ADR-0062's opacity constraint
  rather than extend them.

### Amendment 2026-09-01: the invoke seam joins the carriers (st-u9l6)

Status: accepted (2026-09-01) - amends decision 2's carrier list,
decision 3's stamp sites, decision 4's telemetry keys, and decision 5's
format version. Decision 1's opacity rule, decision 6's keys, and
decision 7's deferral are unchanged.

Decision 2 fixed three carriers and said so plainly:

> Three carriers: `%Statifier.Event{}`, `%SendDelayed{}`, and
> `%Cancel{}`. No other struct gains the field.

Its ground was that "the two durable-timer effects outlive the macrostep
that emitted them, and no other effect does". That last clause was
wrong about `<invoke>`, and the record's own Consequences named the
trigger that would show it: "a third effect becoming durably stored (it
claims the same stamp, as it claims `ordinal`)". A `statifier_oban`
worker finding during campaign 025 is that trigger firing. An
asynchronous invoke handler (ADR-0051's dispatch) starts work that
finishes minutes or hours later, in another process, and reports back
through `Statifier.Session.send_invoked_event/3`. With the invoke seam
carrying nothing, the handler had no scheduling-side term to store, so
the result event could not be link-stitched the way a durable timer's
firing already is - the exact asymmetry decision 3's firing-time copy
removed for `%SendDelayed{}`.

**1. Two more carriers: `%Effect.Invoke{}` and
`%Effect.CancelInvoke{}`.** Both, not just the start, by decision 2's
own both-or-neither argument: one handler and one durable store process
the pair, and the cancellation act wants the attribution the start has.
Both are stamped at their existing construction sites from
`%MachineState{}`'s transient slot - `Statifier.Interpreter`'s
`invoke_one/6` and `Statifier.Interpreter.ExitEntry`'s
`cancel_one_invocation/4` - so decision 3's "the stamp is the core's"
and its replay soundness carry over unchanged.

**2. `%Effect.Autoforward{}` deliberately gains nothing.** It carries
the triggering `%Statifier.Event{}` whole, and decision 3 already
settled that case: "the forwarded event is the same `%Event{}` value, so
its slot travels to the invoked child untouched." A field on the effect
would be a second copy of a term the effect already contains.

**3. Decision 4's list grows to six events.**
`[:statifier, :session, :effect, :invoke]` and
`[..., :effect, :cancel_invoke]` gain a `caller_context` metadata key on
the terms decision 4 set: identity rather than a number, so metadata
everywhere and a measurement nowhere; the value also rides in
`metadata.effect` verbatim, and the explicit key keeps a bridge's read
uniform. No event is added or renamed, and this is ADR-0040's additive
direction, so the amendment to 0040 is the same non-breaking one 0063
already made.

**4. `Statifier.Invoke.Handler`'s callbacks are untouched.** `start/2`
already receives the `%Effect.Invoke{}`, so the handler that needs the
term to store it has it with no signature change. `cancel/2` receives an
`invoke_id` rather than the effect, and widening it to the struct would
break every handler in the wild for a term only a bridge reads - the
`:cancel_invoke` telemetry event is that bridge's read point. Left
alone deliberately; the trigger to revisit is a handler needing the
cancelling macrostep's context inside a *pure planning* callback, which
no consumer has asked for.

**5. `Statifier.Session.Recording`'s `@format_version` bumps `3 -> 4`,**
for exactly the reason decision 5 gave for `2 -> 3`: a version-3 blob's
stored `:interpret` entries hold invoke-effect structs written before
the field, and reading such a map as the new struct is the silent
misread ADR-0057 decision 4's obligation names. The same blessed default
applies - `caller_context: nil` on import - and is safe for the same
reason: a version-3 blob predates the field on these structs, so no
context was ever attached to what it holds. Version 3 joins versions 1
and 2 as readable. `Statifier.Position` and `Statifier.Chart` stay
untouched, unchanged from decision 5's argument.

**6. Decision 6 is untouched.** `caller_context` still joins no key. A
durable invoke store carries it as row data beside its own invocation
key, exactly as a durable timer store carries it beside the dedup key.

### Amendment 2026-09-01's own consequences

- The firing-side half remains statifier_oban's: storing the term with
  the invocation row and putting it back on the result event is that
  repo's work, and this record does not schedule it.
- What would reopen the amendment: a *fourth* effect becoming durably
  stored; a consumer needing the context inside `cancel/2`'s planning
  callback (point 4's named trigger); or `%Effect.Autoforward{}` ever
  ceasing to carry the whole event, which is what makes point 2 true.

### Decision note 2026-09-02: a driver-built answer event inherits the invoking event's caller context (st-mvor)

Accepted (2026-09-02) - additive; the record's own Status above is
unchanged, decision 2's carrier list is unchanged, and no struct gains a
field. It answers the one question ADR-0068's own 2026-09-02 decision note
declined to answer ("Not decided here: whether a driver-built answer event
inherits the invoking event's `caller_context`"), and it is recorded *here*
rather than there because the question is about this record's slot and not
about those events: ADR-0068 fixes the two answers' names, payloads, queue
and delivery, all of which stand untouched, while what travels in the
opaque slot and where it is copied is decision 3's subject. This note
extends decision 3's copy chain by one link, on the trigger the 2026-09-01
amendment named and left unscheduled: "putting it back on the result event
is that repo's work, and this record does not schedule it" turned out to
need a library-side answer first, because the *engine* builds the result
event on both paths.

**1. Both answer events inherit, from the invoking event.** The two events
`Statifier.Invoke.Answer` builds - `done.invoke.<invoke_id>` and
`error.communication.invoke.<invoke_id>` - carry the `caller_context` of the
event that opened the macrostep whose `<invoke>` started the invocation.
Not the context of whatever call reports the answer: an answer arrives
minutes or hours later, from a retry layer or an Oban worker whose own
ambient context is a different trace, and stamping *that* would attribute
the chart's continuation to the reporter rather than to the arming trace -
the exact link the se-opg capstone found missing. Both, not one, by the
both-or-neither rule ADR-0068 is built on and decision 2 used for
`%Cancel{}`: a host that can correlate a completion but not a permanent
failure has the asymmetry back in a different place.

**2. The term is read from the invocation, never minted.** The chain is
already three-quarters built. `%Effect.Invoke{}` carries the slot (the
2026-09-01 amendment, point 1), stamped by the core from
`%MachineState{}`'s transient field, so replay re-mints it byte-identically.
`Statifier.Session` copies it off that effect onto the invocation's own
table entry (`Statifier.Session.Invocations`, an `optional(:caller_context)`
key beside `optional(:type)`) at the two sites that record an entry, and
reads it back when it builds an answer. A process-less host has no such
table, so it passes the term it stored beside its own invocation row. Both
builders therefore take it as an argument rather than reading anything
ambient - `Statifier.Invoke.Answer.done/4` and `failed/4` gain a trailing
`opts` keyword read for `:caller_context` alone, which is the additive shape
decision 7 already named for this class of addition ("an opts keyword on the
public function"). `Statifier.Session.done_invocation/3` and
`failed_invocation/3` keep their arities: a caller cannot pass a context and
cannot override the invocation's, because the invocation's is the only
correct one.

**3. Per variant.** Two events by two paths, and the difference between the
paths is only *where the term is kept*, never what it is or whether it
travels:

| Answer event | Session path | Process-less path |
|---|---|---|
| `done.invoke.<invoke_id>` | `done_invocation/3` reads the entry `Invocations` holds for `invoke_id` and passes it to `Answer.done/4`. A child `scxml` session's own completion arrives through this same door (`return_done_event/2` calls `done_invocation/3` on its parent), so it inherits identically with no separate rule | the host calls `Answer.done/4` with the term it stored beside its invocation row, then feeds the returned event to its next `Interpreter.handle_event/2` drive |
| `error.communication.invoke.<invoke_id>` | `failed_invocation/3` reads the same entry and passes it to `Answer.failed/4`, in the same three lines the done cast uses | the host calls `Answer.failed/4` the same way, with the same stored term |

The two paths still build byte-identical events for the same arguments,
which is what `test/statifier/invoke/answer_test.exs` pins; this note adds
the slot to what "the same arguments" covers.

**4. `nil` is a value, not a failure.** Three distinct situations read
`nil`, and none of them is an error: an invocation started by a macrostep
whose triggering event carried no context (decision 1's "no context
attached"); an entry written before this key existed or by hand in a test,
which reads exactly as an attached `nil` on ADR-0051's nil-permissive terms,
unchanged here; and an answer delivered on a **resumed** session, whose
`Invocations` table is rebuilt empty (ADR-0060) so the invoking event's term
is no longer in reach. The third is a real gap and is named rather than
papered over: a host that wants correlation across a resume stores the term
itself and drives the process-less way, which is what
`docs/persistence.md`'s "Answering an invocation with no session process"
now documents. Widening `%MachineState{}` or a position to carry it would
make transient per-macrostep state durable, which decision 5 refused for
this slot and decision 3's "transient" is the reason.

**5. Nothing serialized changes.** No struct gains a field, so
`Statifier.Session.Recording`'s `@format_version` does not move (it stays at
the amendment's 4), and `Statifier.Position` and `Statifier.Chart` are
untouched for decision 5's own reason. The invocation table is session
state, never persisted; the answer events already travel as
`%Statifier.Event{}` values whose `caller_context` key has existed since
this record's implementation. The telemetry contract is unchanged too: the
answer re-enters through `handle_event/2`, so the macrostep it opens
attributes through decision 4's existing `caller_context` metadata key with
no new event and no new key.

**What would reopen this note.** A consumer wanting the *reporter's* context
alongside the invoking one (two terms on one event, which decision 1's
single opaque slot cannot hold); `Statifier.Session` gaining a way to
restore its invocation table across a resume, which would close point 4's
third case; or `Statifier.Invoke.Answer` gaining a third answer event, which
would need its own row in point 3's table.

## Related

- ADR-0062 (decision 4 names this field; the bridge consumes only
  public events)
- ADR-0040 (the event contract this record amends in part; st-ii9v's
  additive-is-non-breaking direction)
- ADR-0059 (the durable-timer-effects precedent: fold-state stamping,
  both-effects symmetry, the off-every-other-effect rule, the
  old-version import default)
- ADR-0046 ("the stamp is the core's, not the session's")
- ADR-0034 / ADR-0029 (replay re-drives the fold from recorded inputs;
  why the recording must carry the field)
- ADR-0057 (recording envelope and format-version obligation; the
  host-term serializability rule the slot inherits)
- ADR-0054 (the durable-timer vocabulary; keys untouched here)
