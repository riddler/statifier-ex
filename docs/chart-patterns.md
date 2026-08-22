# Chart patterns: external-resource verdicts

This is a guide for a chart author whose document reaches an external
resource - through an `<invoke>` handler (`docs/extending.md`) or an external
`<send>` - and who has to decide what the chart does when that resource
reports itself unavailable. A host's external connection or credential may be
paused or revoked, a downstream service may be rate-limited or gone; the
chart has to route somewhere on that news, explicitly.

Two canonical reactions cover the ground, and this document shows both in one
runnable chart: **park and retry** for a resource that is temporarily
unavailable, and **fail fast** for one that is permanently unavailable.

## The verdict is the host's; the chart just routes

The distinction between "temporarily unavailable" and "permanently
unavailable" is not one the chart can make, and this engine will never make
it on the chart's behalf. Only the host knows whether a refusal means "paused
by an administrator, try later" or "revoked, never again" - that knowledge
lives in the host's response codes, its configuration, its own records.

So the host renders the verdict and delivers it as events, and the chart's
whole job is to route on them. Two delivery shapes work equally well:

- **Distinct event names** - the host's handler (or the code it enqueued)
  reports back with `resource.paused` versus `resource.revoked`, via
  `Statifier.Session.send_event/2` or as part of its instruction plan. The
  chart routes on the event name alone. This is the shape the example below
  uses, because it keeps every arrow legible in the document.
- **One event, payload routed with `cond`** - the host sends a single
  `resource.unavailable` whose payload carries the verdict, and the chart
  splits with `cond="_event.data.verdict == 'paused'"` arrows. Same pattern,
  one more level of indirection; prefer distinct names unless the verdict
  vocabulary is open-ended.

The engine's own error events follow the same posture. A planning failure in
a handler (`start/2` returning `{:error, _}`, or an unregistered type) is
raised as `error.execution`; a registered handler that genuinely attempted
communication and failed is `error.communication` (`docs/extending.md`,
ADR-0051). Those are events like any other: give them explicit arrows too.
Errors are events here, never silent defaults (ADR-0004's posture, carried
through the whole engine): an unhandled error event is simply discarded, so a
chart that omits the arrow has decided - silently - that failure changes
nothing. Decide it out loud instead, with an arrow to a state whose name says
what you decided.

## Pattern 1: park and retry, with the budget visible as states

A temporarily unavailable resource deserves a retry - but a bounded one,
with backoff, and both bounds belong in the document where a reader can see
them. The pattern: each verdict arrow moves to a *park* state whose
`<onentry>` schedules the next attempt with `<send delay="...">`; the retry
budget is spelled as a chain of states rather than a counter, so exhaustion
is a place in the chart, not an arithmetic overflow in handler code.

Keeping the budget in states rather than in handler code is the point of the
pattern. The chart is the artifact that gets reviewed, versioned, and
observed; a retry loop hidden in the host's handler is invisible to all
three. When a session is parked, its configuration *names* which attempt it
is parked after - useful in every trace and every debugger view.

The backoff schedule is the `delay` values on the park states' `<send>`
elements. The example uses milliseconds so its test runs fast; a real chart
says `delay="30s"` or `delay="2h"`. For delays long enough that the session
process may not outlive them, the same `<send delay>` becomes a durable
timer by consuming the `SendDelayed` effect in your host - see
`docs/durable-timers.md`; the chart does not change.

## Pattern 2: fail fast, on an explicit arrow

A permanently unavailable resource - revoked, unauthorized, deleted - gets no
retry loop. Retrying a revoked credential is not persistence, it is noise,
and often actively harmful (lockouts, alarms). The pattern is a single
explicit arrow from every state that could hear the verdict to a `<final>`
state whose id says what happened. The host observes the `:done` effect (or
`done.state.*` / the final configuration) and takes it from there.

## The example chart

One document, both arms. Two failed attempts are retried with growing
delays; the third `resource.paused` exhausts the budget. `resource.revoked`
fails fast from anywhere. `error.execution` - the engine's own verdict that
the invocation could not even be planned - also fails fast, on its own
explicit arrow.

```xml
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="requesting">
    <state id="requesting">
        <transition event="resource.ready" target="succeeded"/>
        <transition event="resource.paused" target="parked_once"/>
        <transition event="resource.revoked" target="failed"/>
        <transition event="error.execution" target="failed"/>
    </state>
    <state id="parked_once">
        <onentry>
            <send event="retry" delay="10ms"/>
        </onentry>
        <transition event="retry" target="retrying_once"/>
        <transition event="resource.revoked" target="failed"/>
    </state>
    <state id="retrying_once">
        <transition event="resource.ready" target="succeeded"/>
        <transition event="resource.paused" target="parked_twice"/>
        <transition event="resource.revoked" target="failed"/>
        <transition event="error.execution" target="failed"/>
    </state>
    <state id="parked_twice">
        <onentry>
            <send event="retry" delay="20ms"/>
        </onentry>
        <transition event="retry" target="last_attempt"/>
        <transition event="resource.revoked" target="failed"/>
    </state>
    <state id="last_attempt">
        <transition event="resource.ready" target="succeeded"/>
        <transition event="resource.paused" target="failed"/>
        <transition event="resource.revoked" target="failed"/>
        <transition event="error.execution" target="failed"/>
    </state>
    <final id="succeeded"/>
    <final id="failed"/>
</scxml>
```

Things to read off it:

- **The budget is three attempts, and you can count them** - `requesting`,
  `retrying_once`, `last_attempt`. Widening the budget is adding a
  park/retry pair, a reviewable diff, not editing a constant in host code.
- **The backoff is visible** - 10ms then 20ms, on the park states'
  `<send delay>` values, exactly where a reviewer would look for them.
- **Exhaustion is an arrow, not an error** - `last_attempt`'s
  `resource.paused` goes to `failed` directly. Nothing counts down; the
  third pause simply has nowhere left to park.
- **The park states still hear the fatal verdict.** A revocation that
  arrives while parked must not wait out the retry delay only to fail on the
  next attempt - `parked_once` and `parked_twice` carry their own
  `resource.revoked` arrows.
- **In this example the attempt states only route.** How an attempt is
  *made* is the host's side of the seam: typically each `requesting`-shaped
  state carries an `<onentry>` `<send>` (or the whole region sits under an
  `<invoke>`) that pokes the host, and the host answers with one of the
  verdict events. That half is omitted here so the pattern - the routing -
  stays the whole document.

## Testing both arms

The chart above is runnable as written, with the same declarative runner
this repository tests itself with (`docs/testing-charts.md`). The delayed
sends route the test through a real `Statifier.Session` automatically; the
verdict events are ordinary external events, which is the pattern's premise -
the host's verdict needs no special machinery to simulate, because it is
just events:

```elixir
defmodule MyApp.ResourceVerdictChartTest do
  use Statifier.Testing.Case, async: true

  @chart """
  ... the document above ...
  """

  test "park/retry: the budget exhausts into the failed final state" do
    test_scxml(@chart, "three pauses exhaust the budget", ["requesting"], [
      {%{"name" => "resource.paused"}, ["retrying_once"]},
      {%{"name" => "resource.paused"}, ["last_attempt"]},
      {%{"name" => "resource.paused"}, ["failed"]}
    ])
  end

  test "fail-fast: a revoked-style verdict routes straight to failed" do
    test_scxml(@chart, "revoked fails fast", ["requesting"], [
      {%{"name" => "resource.revoked"}, ["failed"]}
    ])
  end
end
```

Each `resource.paused` step's expected configuration is the *next attempt*
state, not the park state: the runner waits for the park state's short retry
timer to fire before comparing. The exhaustion step and the fail-fast test
both land on `["failed"]` - the same final state, reached down two very
different arrows, which is exactly the property worth pinning.

This repository runs this exact document and both tests in
`test/statifier/chart_patterns_test.exs`, so the example cannot drift from
the engine's behavior without a red gate.

## Where the pattern's pieces are specified

- Handler seam, `error.execution` versus `error.communication`, and why the
  engine never rescues a handler failure into a default:
  `docs/extending.md` and ADR-0051.
- Durable `<send delay>` for park delays measured in hours or days:
  `docs/durable-timers.md` and ADR-0054/0059.
- The no-eval, computation-lives-in-the-host posture that makes the verdict
  the host's in the first place: ADR-0004 and `docs/datamodel.md`.
- The declarative test runner: `docs/testing-charts.md` and ADR-0053.
