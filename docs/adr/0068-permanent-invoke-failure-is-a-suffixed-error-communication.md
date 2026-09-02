# ADR-0068: Permanent invoke failure is a suffixed `error.communication`, delivered through the invocation door

Status: accepted (2026-08-27) - fires ADR-0051 decision 7's implicit gap
rather than one of its three named triggers, and says so below; extends
ADR-0051 decision 5's one-door rule to the failing half of the same
lifecycle

## Context

ADR-0051 decision 5 gave a handler-backed invocation a completion door:
`Statifier.Session.done_invocation/3`, which builds `done.invoke.<invoke_id>`
and delivers it as an invocation-tagged entry, subject to 6.4.3's drain-time
discard. `docs/extending.md`'s "Async and long-lived invocations" section is
written entirely around that door.

There is no failing counterpart. `docs/extending.md`'s "Where the library
will not help" states the gap positively:

> `perform/2`'s return value is not interpreted by the library at all: an
> `{:error, term()}` there is your own handler's concern to observe (log it,
> retry it, raise it), not something the session recovers from or turns into
> an event on your behalf.

That sentence is right about `perform/2` and stays. What it does not cover is
what happens *after* the host has finished observing: a host with a retry
policy eventually stops retrying, and at that moment the invocation is over
and will never produce a `done.invoke.<invoke_id>`. Today nothing reaches the
chart at all. The failure is visible only on the host's own discarded job
row, and a chart that models operator-recovery parking - a
`needs_attention`-style state entered on an invoke error - never hears about
it. The run sits in its invoking state forever.

The requirement source is a production CQRS/Oban host whose charts park
failed work for operator recovery, and the consuming implementation is
`statifier_oban`'s `StatifierOban.Invoke.Delivery` seam, which already
delivers `done.invoke` through `Statifier.Session.done_invocation/3` behind a
two-step liveness check. This repository owns the event vocabulary
(`CLAUDE.md`'s contract-ownership rule), so the name, the payload, and the
delivery contract are decided here; the satellite implements delivery.

Three facts bound the choice.

**3.12.2 defines exactly two error events, and ADR-0051 already classified
this failure onto one of them.** Quoted from the local cache:

> Two error events are defined in this specification: 'error.communication'
> and 'error.execution'. The former cover errors occurring while trying to
> communicate with external entities, such as those arising from `<send>` and
> `<invoke>`, while the latter category consists of errors internal to the
> execution of the document, such as those arising from expression
> evaluation. (3.12.2)

ADR-0051 decision 1's own table reads, verbatim: "A registered handler fails
to reach its service | `error.communication` | 3.12.2's 'trying to
communicate with external entities'". A host that attempted an external
service, retried it, and exhausted those retries is that row. Nothing about
exhaustion moves it to the other row - the communication was attempted, which
is 3.12.2's whole distinguishing question.

**A bare `error.communication` is not addressable per invocation.** A chart
with two concurrent invocations cannot tell which one failed from the event
name, and cannot write a transition that fires for one and not the other.
`done.invoke.<invoke_id>` has exactly that property and it is the reason
charts can park per-invocation work at all.

**The spec blesses the suffix that reconciles those two.** Quoted from the
local cache, 3.12.1:

> Platforms MAY extend the names of these automatically generated events by
> adding a suffix. For example, a platform could extend done.state. id with a
> timestamp suffix and generate done.state. id.timestamp instead. Because any
> prefix of done.state. id is also a prefix of done.state. id.timestamp , any
> transition that matches the former event will also match the latter.

and the descriptor rule it leans on:

> An event descriptor matches an event name if its string of tokens is an
> exact match or a prefix of the set of tokens in the event's name. In all
> cases, the token matching is case sensitive.

## Decision

**1. The event is `error.communication.invoke.<invoke_id>`.** Not
`error.invoke.<invoke_id>`, and not a bare `error.communication`. The name is
3.12.1's blessed suffix extension of the `error.communication` that ADR-0051
decision 1's table already assigns to this failure, so both properties hold
at once and neither is bought with the other:

- A chart already written against ADR-0051's classification -
  `<transition event="error.communication" target="failed"/>`, or the broader
  `event="error"` - catches invoke exhaustion with no edit, by the descriptor
  prefix rule quoted above.
- A chart that wants to park one invocation specifically writes
  `<transition event="error.communication.invoke.inv_3" target="needs_attention"/>`
  and matches that invocation alone.

`error.invoke.<invoke_id>`, the shape the bead named as a candidate, was
rejected on two grounds. It would invent a third top-level error family
alongside 3.12.2's two, which no clause of the spec creates and which no
existing chart or corpus document listens for. And it would silently falsify
ADR-0051 decision 1's table, which is a published statement about what a
registered handler's service failure raises - a chart author following that
table would write `error.communication` and catch nothing.

**2. The payload is a string-keyed map with `"reason"`, `"attempts"`, and
`"detail"`.** `_event.data.reason` and `_event.data.attempts` are readable
from a `cond` with no host cooperation beyond passing them. String keys
because that is what every other structured event payload in this engine uses
(`Statifier.Machine.Content.Send`'s `resolve_params/2` builds `namelist` and
`<param>` data the same way), so one convention covers reading a failure and
reading a send.

| Key | Value | Absent as |
|---|---|---|
| `"reason"` | a host-chosen string naming the failure class | `"unknown"` |
| `"attempts"` | how many attempts the host made before giving up | `:undefined` |
| `"detail"` | any further host term, uninterpreted | `:undefined` |

The library interprets none of the three. `"reason"` is deliberately a
free-form string and not a closed atom set: the classes a host can
distinguish are the classes *its* transport distinguishes, and an engine-side
enum would either be wrong for most hosts or so broad as to say nothing.
ADR-0037's `:undefined` spelling is what an unsupplied key reads as, nested
inside the map exactly as it does at the top level, so
`_event.data.attempts === undefined` is the honest test for "the host does
not count attempts" and is distinct from a host that counted zero.

**3. The door is `Statifier.Session.failed_invocation/3`, and it is the
host's to call, not the handler's.** Signature and semantics mirror
`done_invocation/3` deliberately:

```elixir
@spec failed_invocation(server :: server(), invoke_id :: String.t(), failure :: keyword()) :: :ok
def failed_invocation(server, invoke_id, failure \\ [])
```

`server` is the invocation's *owning* session, `failure` is a keyword list
read for `:reason`, `:attempts`, and `:detail`. A handler callback never
calls it: `start/2`, `cancel/2`, and `forward/3` are pure planning callbacks
that may not perform IO, and `perform/2` returning `{:error, term()}` is a
*transient* signal that belongs to whatever retry policy the host wraps it
in. Permanent exhaustion is a judgement only the host's retry layer can
make - it is the one component that knows the policy has run out - which is
the same reason completion is reported by the host rather than inferred by
the library. `docs/extending.md`'s "Where the library will not help"
paragraph therefore stands unamended in substance: `perform/2`'s return value
is still uninterpreted, and this decision adds nothing that interprets it.

**4. Delivery is the invocation-tagged entry, byte-for-byte the
`done_invocation/3` path, so the run-liveness rule is the same rule and not a
parallel one.** The cast enqueues through the same `enqueue_invoked/3` -
stamped, recorded as `Recording.put_invoked_event/4`, appended as
`{:invoked_event, invoke_id, event}` - and defers the entry pop with
`send(self(), {:pop_invocation, invoke_id})` for the reason
`done_invocation/3`'s own clause records: popping inline would make the drain
that decides whether to discard the event see the invocation as already gone.

Three consequences fall out of sharing the path rather than being decided
separately:

- 6.4.3's drain-time discard applies unchanged. A cancel queued ahead of the
  failure report wins, and the failure is dropped rather than delivered to a
  chart that has already moved on. This is the property a cast-time liveness
  check could not have: the cancel is in the inbox, not yet in
  `state.invocations`.
- The pop is terminal. An invocation that failed permanently is over in
  exactly the sense one that completed is over, so it leaves the table the
  same way, and a subsequent `done_invocation/3` or `failed_invocation/3` for
  the same id is the same harmless no-op a double completion already is.
- Replay and persistence are untouched. The event is an ordinary invoked-event
  input in the recording, which is a shape ADR-0034's four-input fold already
  handles, so no recording version moves and no position blob format changes.

**5. The event stays on the external queue, and 3.12.2's internal-queue
sentence is read as not reaching it.** That sentence -

> Once the SCXML processor has begun executing a well-formed SCXML document,
> it MUST signal any errors that occur by raising SCXML events whose names
> begin with 'error.'. the processor MUST place these events in the internal
> event queue

\- binds the processor when *it* signals an error occurring in its own
execution, which is every one of this engine's existing `error.*` raise sites
(`abort_invocation/4`, `communication_error/4`, `invoke_error/4`, the content
and selection raises). This event is not one of those. The processor detects
nothing here; a host reports, minutes or days later, on behalf of an external
service, through the same door and the same queue entry that carries that
service's success. The queue follows the arrival, not the name.

Reading it the other way was considered and costs the thing the bead asks
for. An internal raise happens at cast time, which forfeits the drain-time
discard of decision 4 - a cancel already sitting in the inbox would not be
seen, and a cancelled invocation's failure would be delivered anyway, against
6.4.3. It also needs the `{:invoke, state_index, invoke_index}` origin every
`deliver_internal/5` caller supplies, which the door does not have and cannot
get: it is handed an `invoke_id`, and the invocation's element indices are
not carried on the table entry.

The named reopen trigger for this decision: a corpus document or a conformance
test that pins an `error.*` event's queue by observing internal-before-external
ordering against an invocation report. Nothing in the corpus does today, and
the ordering is unobservable in practice here - the report arrives while the
session is idle, so both queues are empty when it lands.

## Consequences

- `Statifier.Session` gains one public function, one `handle_cast/2` clause,
  and one private construction site (`build_failure_event/3`) beside
  `build_done_event/3`. No existing function changes behavior.
- The change is additive for every chart that does not name the new event.
  The one behavior change worth a changelog line is the intended one: a chart
  already transitioning on `error.communication` or `error` now also catches
  permanent invoke failure, which is decision 1's whole point and is the
  spec's own suffix-extension semantics rather than this engine's invention.
- `docs/extending.md` gains a failure-reporting section beside the completion
  one, and `Statifier.Testing.HandlerCase`'s guidance names the door so an
  async handler's author reads the terminal-failure contract where they read
  the idempotency one. No new generated conformance check: what the door
  requires is of the *host's retry layer*, which a handler-scoped case has no
  view of, and a check that only asserted the door exists would pin the
  library rather than the implementor.
- `statifier_oban` (`sob-nnh`) can adopt this with no further upstream change:
  its `StatifierOban.Invoke.Delivery` seam gains a second callback that runs
  the same two-step liveness check and calls `failed_invocation/3` on discard.
- ADR-0051 decision 1's table stands and gains a row's worth of reach rather
  than an amendment: the failure this record names is the same
  `error.communication` that row already assigned, spelled more specifically.
- What would reopen this record: decision 5's named trigger, or a host that
  needs to report failure for an invocation it drives through the pure
  interpreter with no `Statifier.Session` process at all. The second is not
  hypothetical - `docs/persistence.md`'s process-less driver is a supported
  path - but it is equally open for `done.invoke` today, which has no
  process-less builder either. Deciding it for failure alone would create the
  asymmetry this record exists to remove, so it is left for the record that
  decides it for both.

### Decision note 2026-08-29: a permanently undecodable stored payload reports through this door (st-uumw)

Status: accepted (2026-08-29, unqualified direction-agent verdict under the operator campaign-015 grant, PR 238) - additive; the record's own Status above is
unchanged and this note decides nothing that record decided

A host may store an invocation's arguments in an opaque, host-encoded form
rather than as engine-readable terms - `statifier_oban`'s ADR-0004 makes that
codec pluggable, and ADR-0005 covers the job shape it rides on. Such a host can
find, on a later attempt, that a stored payload will never decode again: a
retired codec version, a rotated key, a corrupt row. st-uumw asked whether that
permanence is this record's failure family or needs its own treatment.

**It is this family.** When the host's retry layer judges the decode
permanently failed, it reports the invocation through this record's door,
`Statifier.Session.failed_invocation/3`, with `"reason"` spelled
`"undecodable"`. No new event name, no new function, no new error family, and
no engine change: this note pins a spelling and a call site, both of which
decision 2 and decision 3 already admit.

The argument is decision 1's own. 3.12.2's distinguishing question is whether
communication with an external entity was attempted, and here it was: the
invocation started, a registered handler was driven, and what has become
impossible is the *continuation* of that communication. Decision 1's rejection
of `error.invoke.<invoke_id>` applies verbatim to a hypothetical third name for
this case - it would invent a family no clause of the spec creates, and it
would give a chart author two names for one observable fact, that the
invocation is over and will never produce `done.invoke.<invoke_id>`. What made
completion impossible is a transport detail, and decision 2 is explicit that
the library interprets none of the three payload keys; `"undecodable"` is an
ordinary value of that free-form string, not an enum the library gains.

**First caller.** `statifier_oban`'s `StatifierOban.Invoke.Worker` is the
first caller: it calls the door with `reason: "undecodable"` before cancelling
the job whose args it could not decode. That change is landing in the satellite
alongside this note, not here. It is the same seam the Consequences bullet
naming `sob-nnh` describes, so that bullet stands unamended.

**The worked example lives in `docs/extending.md`**, in its "Reporting
permanent failure" section beside the keyword-list table a host implementor
reads at the moment of calling the door: `reason: "undecodable"`, `attempts` as
the host counted them, `detail` the codec's typed error, uninterpreted.

**Not decided here: the timer half.** Whether an undecodable *delayed-send*
payload has an analogous report is a separate question - ADR-0054's durable
timer path has no invocation, no `invoke_id`, and no door of this shape - and
is filed as st-i7y8. Nothing in this note should be read as deciding it.

### Decision note 2026-09-02: both answer events get a process-less builder (st-q6k2)

Accepted (2026-09-02) - additive; the record's own Status above is
unchanged, and this note decides nothing that record decided. It closes the
gap the Consequences bullet below names ("a host that needs to report failure
for an invocation it drives through the pure interpreter with no
`Statifier.Session` process at all"), on that bullet's own terms: for both
events at once, never one alone.

**What it decides: nothing about the events, only about who may build them.**
The name, the payload, the queue, and the delivery contract are decisions 1-5
above and are untouched. What changes is that
`done.invoke.<invoke_id>` and `error.communication.invoke.<invoke_id>` are now
built by a public, pure module, `Statifier.Invoke.Answer`
(`done/3` and `failed/3`), rather than by two private functions on
`Statifier.Session`. The Consequences bullet below describing "one private
construction site (`build_failure_event/3`) beside `build_done_event/3`" is
accurate as of this record's own date and is superseded by this paragraph:
the two construction sites are the same two, moved and made public, and
`Statifier.Session.done_invocation/3` and `failed_invocation/3` now call
through them. Session behaviour does not change, which
`test/statifier/invoke/answer_test.exs` pins by asserting the event a live
session actually dequeues is equal to the builder's own output for both
halves.

**Why the reopening trigger fires now, and why for both.** A host driving
`Statifier.Interpreter` directly against a persisted `%MachineState{}` is a
supported path (`docs/persistence.md`), and its next drive takes an event, not
a cast - so it needs the event as a value. Deciding this for failure alone
would recreate the asymmetry this record exists to remove, and deciding it for
completion alone would create the mirror image of it: a process-less host that
can say "finished" but not "gave up" parks nothing and waits forever, which is
the Context section's own failure mode reappearing one layer out. The bullet
below anticipated exactly this and left the decision to "the record that
decides it for both". This is that decision.

**What the library still does not do for a process-less host.** Two things a
live session does around these events are the host's own, because they need
state the library is not holding: 6.4.3's drain-time discard of an answer for
an already-cancelled invocation, and the invocation table entry's pop. A
process-less host has neither a drain nor a table, so it checks liveness
against its own record before feeding the event to its next drive and drops
the record afterwards either way - the same shape `docs/durable-timers.md`'s
Route B already gives a timer that fires after its cancel.
`docs/persistence.md`'s "Answering an invocation with no session process"
states this as the recipe's own step rather than a caveat.

**Not decided here: whether a driver-built answer event inherits the invoking
event's `caller_context`.** ADR-0063's opaque slot is left `nil` by both
builders. Whether a process-less host should be able to thread its correlation
term onto an answer, and from where, is filed as st-mvor; nothing in this note
should be read as deciding it.

## Related

- ADR-0051 (decision 1's classification table, decision 4's handler
  behaviour, decision 5's one-door rule and `done_invocation/3` itself)
- ADR-0031 (the *other* invoke failure: an argument evaluation that fails
  before any communication is attempted raises `error.execution` and produces
  no invocation at all - disjoint from this record, which is only ever about
  an invocation that started)
- ADR-0037 (`:undefined` as the unbound spelling, nested inside the payload
  map)
- ADR-0034 (replay's four-input fold, which the invoked-event entry already
  satisfies), ADR-0039 (`deliver_internal/5`, the door decision 5 declines to
  use), ADR-0065 (the conformance case whose guidance this record extends)
