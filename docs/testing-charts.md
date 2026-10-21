# How to test your own charts

**Read this to:** write a declarative test for an SCXML document that your
application drives.

**Short version:** `use Statifier.Testing.Case`, then call `test_scxml/4` with a
document, an initial configuration, and `{event, expected configuration}`
steps.

This guide is for a chart author outside this repository. You depend on
`statifier` and you want to test the SCXML documents that your application
drives. It shows you how to write a chart test in the same way this engine
tests itself. This page does not re-explain the architecture of the
interpreter. For that, see `docs/architecture.md`.

## What this gives you

- `Statifier.Testing.Case` is the test case template that drives every SCION
  and W3C conformance test in this repository. A test gives an expected initial
  configuration, then a list of `{event, expected configuration}` steps.
- `Statifier.Testing.FeatureDetector` stops a document from passing silently
  when it uses an SCXML feature that the engine does not support.

Both modules are public API, versioned with the engine. You get the same runner
without a copy of any file from this repository.

Decision: [ADR-0053](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0053-chart-test-helpers-ship-in-lib-under-statifier-testing.md).

## Add the dependency

```elixir
{:statifier, "~> 2.0"}
```

You do not need an `only: :test` companion dependency.
`Statifier.Testing.Case` and `Statifier.Testing.FeatureDetector` ship in
`lib/`, in the same way as `Plug.Test` and `Phoenix.ConnTest` in their own
ecosystems. ExUnit ships with Elixir itself. The two modules compile in every
environment, including `:prod`, where nothing uses them.

## Write a test

```elixir
defmodule MyApp.AuthorizationChartTest do
  use Statifier.Testing.Case, async: true

  test "an approved authorization advances to capture" do
    test_scxml(
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="authorizing">
          <state id="authorizing"><transition event="card.approved" target="capturing"/></state>
          <state id="capturing"/>
      </scxml>
      """,
      "authorizing advances on card.approved",
      ["authorizing"],
      [{%{"name" => "card.approved"}, ["capturing"]}]
    )
  end
end
```

`use Statifier.Testing.Case, async: true` gives the test module `test_scxml/4`.
Run the test with `mix test`, as for any other ExUnit case.

## What `test_scxml/4` asserts

The four arguments are:

1. The XML document.
2. A description string. The runner uses it only in failure messages.
3. The expected initial configuration.
4. The list of `{event_map, expected_configuration}` steps.

`test_scxml/4` asserts the active leaf-state configuration, by state id. It
asserts after `initialize` and again after each event it sends.

A chart that terminates has an empty configuration by construction. The test
asserts against the configuration that the chart held at exit. To do this, the
runner restores the terminal position from the interpreter's own `:done`
effect before it compares.

Decision: [ADR-0006](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md)
defines this fixture shape for the conformance corpus. A fixture in that shape
runs against your own chart without translation.

## Fail, never skip

A document can use an SCXML feature that the engine does not yet support. The
test then fails and names the feature. The test never skips. An unimplemented
feature cannot look like a passing test.

Every feature that the detector recognizes is now `:supported` or `:partial`,
so this path is a guarantee for the future. You are unlikely to hit it today. For the current list and status,
see `Statifier.Testing.FeatureDetector.feature_registry/0`.

## Charts with timers, delayed sends, or `<invoke>`

A document can depend on wall-clock timers, delivery to an external queue, or
child sessions. It then needs a running `Statifier.Session`. The synchronous
driving path is not enough. `test_scxml/4` detects this (`session_required?/1`)
and routes the test automatically. In the common case, you do not change the
call site.

Two options tune the timing of the session path. Use them for a chart with
delays longer than this repository's own conformance corpus needed:

- `:settle_window_ms` (default `100`): how long to wait for pending timers to
  drain before the runner sends the next event.
- `:configuration_deadline_ms` (default `4_000`): the maximum time to wait for
  a session to reach an expected configuration.

Pass them as a keyword list after the events:

```elixir
test_scxml(xml, "slow chart", ["idle"], steps,
  configuration_deadline_ms: 15_000,
  settle_window_ms: 400
)
```

Next: see a full chart and its tests in `docs/chart-patterns.md`.
