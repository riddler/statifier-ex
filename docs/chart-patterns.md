# How to route a chart on an external resource's verdict

**Read this to:** decide what your chart does when an external resource says it
is unavailable.

**Short version:** the host decides the verdict and sends it as an event. The
chart routes on it with explicit arrows. Park and retry for a temporary
refusal. Fail fast for a permanent one.

This guide is for a chart author whose document reaches an external resource.
The document does this through an `<invoke>` handler (`docs/extending.md`) or an
external `<send>`. A host's connection or credential can be paused or revoked.
A downstream service can be rate-limited or gone. The chart must route on that
news, explicitly.

This page shows both reactions in one runnable chart: a card capture against a
payment provider. Substitute your own verdict events and the shapes stay the
same.

## The verdict is the host's; the chart just routes

The chart cannot tell "temporarily unavailable" from "permanently unavailable".
The engine never makes that call on behalf of the chart. Only the host knows if a refusal means "paused by an
administrator, try later" or "revoked, never again". That knowledge is in the
host's response codes, its configuration, and its own records.

The host renders the verdict and delivers it as events. The whole job of the
chart is to route on them. Two shapes work equally well:

- **Distinct event names.** The host's handler (or the code it enqueued)
  reports back with `capture.deferred` or `card.revoked`. It uses
  `Statifier.Session.send_event/2` or its instruction plan. The chart routes on
  the event name alone. The example below uses this shape, because every arrow
  stays legible in the document.
- **One event, payload routed by `cond`.** The host sends a single
  `capture.unavailable` event. Its payload carries the verdict. The chart
  splits with `cond="_event.data.verdict == 'deferred'"` arrows. This is the
  same pattern with one more level of indirection. Use distinct
  names unless the verdict vocabulary is open-ended.

**Engine error events.** The engine's own errors follow the same rule:

- A planning failure in a handler (`start/2` returning `{:error, _}`, or an
  unregistered type) raises `error.execution`.
- A registered handler that tried to communicate and failed raises
  `error.communication`.

These are events like any other. Give them explicit arrows. Errors are events,
never silent defaults. This posture of ADR-0004 runs through the whole engine.
The engine discards an unhandled error event, so a chart without the arrow decides silently that
failure changes nothing. Add an arrow to a state whose name says what you
decided.

Decision: [ADR-0051](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0051-invoke-handlers-are-registered-per-session.md)
and `docs/extending.md` for the two error events.
[ADR-0004](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0004-predicator-as-the-datamodel.md)
for errors as events.

**Permanent invoke failure.** `error.communication` is also how an
asynchronous invocation reports that it is over for good. A handler-backed
`<invoke>` can have work that outlives the macrostep. It has no return value to
route on. Its host reports the result through one of two functions:

- `Statifier.Session.done_invocation/3` for work that finished.
- `Statifier.Session.failed_invocation/3` for work that its retry policy has
  given up on.

The second function delivers `error.communication.invoke.<invoke_id>`. The
descriptor prefix rule makes this event match a plain `error.communication`
arrow, so the arrow above already catches it. To park one invocation
specifically, name the full event
(`event="error.communication.invoke.inv_3"`).

Decision: [ADR-0068](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0068-permanent-invoke-failure-is-a-suffixed-error-communication.md).
`docs/extending.md` documents the function.

**One retry owner.** A host-owned retry policy that gives up calls
`failed_invocation/3` once, and the chart receives a single terminal event. In
Pattern 1 the chart owns the retry budget, and the host reports the verdict of
each attempt. Pick one arrangement. If you use both, two retry loops run inside
each other.

## Pattern 1: park and retry, with the budget visible as states

A temporarily unavailable resource deserves a retry. The retry needs a limit
and a backoff. Both belong in the document, where a reader can see them.

1. Each verdict arrow moves to a park state.
2. The `<onentry>` of the park state schedules the next attempt with
   `<send delay="...">`.
3. The retry budget is a chain of states, not a counter. Exhaustion is then a
   place in the chart, not an arithmetic overflow in handler code.

Keep the budget in states, not in handler code. People review, version, and
observe the chart. A retry loop in the host's handler is invisible to all
three. A parked session's configuration names the attempt that it is parked
after. This helps in every trace and every debugger view.

The backoff schedule is the `delay` values on the `<send>` elements of the park
states. The example uses milliseconds so that its test runs fast. A real chart
uses `delay="30s"` or `delay="2h"`. For delays so long that the session process
can end before they finish, the same `<send delay>` becomes a durable timer.
Consume the `SendDelayed` effect in your host. The chart does not change.

Decision: [ADR-0054](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md),
[ADR-0059](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0059-per-execution-ordinal-on-durable-timer-effects.md).
See `docs/durable-timers.md`.

## Pattern 2: fail fast, on an explicit arrow

A permanently unavailable resource (revoked, unauthorized, deleted) gets no
retry loop. A retry of a revoked credential is not persistence. It is noise, and it is
often actively harmful (lockouts, alarms).

1. Add one explicit arrow from every state that can receive the verdict to a
   `<final>` state.
2. Name that state for what happened.
3. The host observes the `:done` effect (or `done.state.*`, or the final
   configuration) and takes it from there.

## The example chart

One document shows both arms, in the card-processing domain. An authorized
transaction is captured against a payment provider. Two deferred attempts are
retried with growing delays. The third `capture.deferred` exhausts the budget.
`card.revoked` fails fast from any state.

Two error events also fail fast, each on its own explicit arrow:

- `error.execution` is the engine's verdict that it could not plan the
  invocation.
- `error.communication` means that a registered handler reached for the
  provider and failed. This includes an async invocation whose host called
  `failed_invocation/3`.

```xml
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="capturing">
    <state id="capturing">
        <transition event="capture.succeeded" target="settled"/>
        <transition event="capture.deferred" target="parked_once"/>
        <transition event="card.revoked" target="needs_attention"/>
        <transition event="error.execution" target="needs_attention"/>
        <transition event="error.communication" target="needs_attention"/>
    </state>
    <state id="parked_once">
        <onentry>
            <send event="retry" delay="10ms"/>
        </onentry>
        <transition event="retry" target="retrying_once"/>
        <transition event="card.revoked" target="needs_attention"/>
    </state>
    <state id="retrying_once">
        <transition event="capture.succeeded" target="settled"/>
        <transition event="capture.deferred" target="parked_twice"/>
        <transition event="card.revoked" target="needs_attention"/>
        <transition event="error.execution" target="needs_attention"/>
        <transition event="error.communication" target="needs_attention"/>
    </state>
    <state id="parked_twice">
        <onentry>
            <send event="retry" delay="20ms"/>
        </onentry>
        <transition event="retry" target="last_attempt"/>
        <transition event="card.revoked" target="needs_attention"/>
    </state>
    <state id="last_attempt">
        <transition event="capture.succeeded" target="settled"/>
        <transition event="capture.deferred" target="needs_attention"/>
        <transition event="card.revoked" target="needs_attention"/>
        <transition event="error.execution" target="needs_attention"/>
        <transition event="error.communication" target="needs_attention"/>
    </state>
    <final id="settled"/>
    <final id="needs_attention"/>
</scxml>
```

**What to read from the chart:**

- **Budget.** It is three attempts, and you can count them: `capturing`,
  `retrying_once`, `last_attempt`. To widen it, add a park/retry pair. This is
  a reviewable diff, not an edit to a constant in host code.
- **Backoff.** It is 10ms, then 20ms. The values are on the `<send delay>` of
  the park states, where a reviewer looks for them.
- **Exhaustion.** It is an arrow, not an error. The `capture.deferred` arrow of
  `last_attempt` goes directly to `needs_attention`. Nothing counts down. The
  third deferral has no state left to park in.
- **Fatal verdict while parked.** A revocation that arrives while the chart is
  parked must not wait for the retry delay and then fail on the next attempt.
  `parked_once` and `parked_twice` have their own `card.revoked` arrows.
- **Final states.** `settled` and `needs_attention` are both `<final>`, and the
  host observes the `:done` effect for either. The names tell an operator if
  anything is owed. After a `<final>` state is reached, the active
  configuration of the run is empty.
  `Statifier.active_leaf_states/1` returns an empty `MapSet` for a finished run.
- **Who makes the attempt.** The attempt states only route. The host makes the
  attempt. Typically each state like `capturing` has an `<onentry>` `<send>`
  that signals the host. Alternatively, the whole region sits under an
  `<invoke type="myapp:capture">`. The host answers with one of the verdict
  events. This page omits that half, so that the routing stays the whole
  document. The routing is the pattern.

## Testing both arms

The chart above runs as written. Use the same declarative runner that this
repository uses for its own tests (`docs/testing-charts.md`). The delayed sends
route the test through a real `Statifier.Session` automatically. The verdict
events are ordinary external events. That is the premise of the pattern: you
need no special machinery to simulate the verdict of the host, because it is
just events:

```elixir
defmodule MyApp.CaptureVerdictChartTest do
  use Statifier.Testing.Case, async: true

  @chart """
  ... the document above ...
  """

  test "park/retry: the budget exhausts into the needs_attention final state" do
    test_scxml(@chart, "three deferrals exhaust the budget", ["capturing"], [
      {%{"name" => "capture.deferred"}, ["retrying_once"]},
      {%{"name" => "capture.deferred"}, ["last_attempt"]},
      {%{"name" => "capture.deferred"}, ["needs_attention"]}
    ])
  end

  test "fail-fast: a revoked card routes straight to needs_attention" do
    test_scxml(@chart, "revoked fails fast", ["capturing"], [
      {%{"name" => "card.revoked"}, ["needs_attention"]}
    ])
  end

  test "fail-fast: a permanently failed capture invocation parks the same way" do
    test_scxml(@chart, "exhausted invocation parks", ["capturing"], [
      {%{"name" => "error.communication.invoke.capture"}, ["needs_attention"]}
    ])
  end
end
```

The expected configuration of each `capture.deferred` step is the next attempt
state, not the park state. The runner waits for the short retry timer of the
park state to fire before it compares. All three tests end in
`["needs_attention"]`. They reach the same final state through three different
arrows, and the tests pin that property. That property is the one worth
pinning.

The third test shows the ADR-0068 function `failed_invocation/3` arriving as an
ordinary event.
Nothing in the chart names that function. The chart routes on the event that
the function delivers. The event matches the plain `error.communication` arrow
by prefix.

This repository runs this exact document and these tests in
`test/statifier/chart_patterns_test.exs`, so the example cannot drift from the
engine without a red gate.

## Where the pattern's pieces are specified

- Handler seam, `error.execution` versus `error.communication`, and why the
  engine never rescues a handler failure into a default:
  `docs/extending.md` and
  [ADR-0051](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0051-invoke-handlers-are-registered-per-session.md).
- Reporting an async invocation's completion or permanent failure back to the
  chart (`done_invocation/3`, `failed_invocation/3`, and
  `error.communication.invoke.<invoke_id>`): `docs/extending.md` and
  [ADR-0068](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0068-permanent-invoke-failure-is-a-suffixed-error-communication.md).
- Durable `<send delay>` for park delays measured in hours or days:
  `docs/durable-timers.md`,
  [ADR-0054](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md),
  and
  [ADR-0059](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0059-per-execution-ordinal-on-durable-timer-effects.md).
- The no-eval rule, where computation lives in the host. This makes the verdict
  the host's in the first place:
  [ADR-0004](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0004-predicator-as-the-datamodel.md)
  and `docs/datamodel.md`.
- The declarative test runner: `docs/testing-charts.md` and
  [ADR-0053](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0053-chart-test-helpers-ship-in-lib-under-statifier-testing.md).
