# Testing your own charts

This is a guide for a chart author outside this repository - someone who
depends on `statifier` and wants to test the SCXML documents their own
application drives. It does not re-explain the interpreter's architecture;
see `docs/architecture.md` for that. It shows you how to write a declarative
chart test the same way this engine tests itself.

## What this gives you

`Statifier.Testing.Case` is the test case template that drives every SCION and
W3C conformance test in this repository: an expected initial configuration,
then a list of `{event, expected configuration}` steps. `Statifier.Testing.FeatureDetector` is
what keeps a document that uses an SCXML feature the engine does not support
from silently passing. Both are public API, versioned with the engine
(ADR-0053), so you get the same runner without copying any file out of this
repository.

## Add the dependency

```elixir
{:statifier, "~> 2.0"}
```

No `only: :test` companion dependency is needed. `Statifier.Testing.Case` and
`Statifier.Testing.FeatureDetector` ship in `lib/`, the same shape as
`Plug.Test` and `Phoenix.ConnTest` in their own ecosystems, and ExUnit ships
with Elixir itself. The two modules compile in every environment, including
`:prod` - they simply go unused there.

## Write a test

```elixir
defmodule MyApp.CheckoutChartTest do
  use Statifier.Testing.Case, async: true

  test "the cart advances to payment" do
    test_scxml(
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="cart">
          <state id="cart"><transition event="checkout" target="payment"/></state>
          <state id="payment"/>
      </scxml>
      """,
      "cart advances on checkout",
      ["cart"],
      [{%{"name" => "checkout"}, ["payment"]}]
    )
  end
end
```

`use Statifier.Testing.Case, async: true` gives the test module `test_scxml/4`.
Run it with `mix test` exactly like any other ExUnit case.

## What `test_scxml/4` asserts

The four arguments are the XML document, a description string (used only in
failure messages), the expected initial configuration, and the list of
`{event_map, expected_configuration}` steps.

`test_scxml/4` asserts the active leaf-state configuration - by state id -
after `initialize`, then again after each event is sent. A chart that
terminates asserts against the configuration it held at exit, not the empty
configuration a terminated chart has by construction: the runner restores the
terminal position from the interpreter's own `:done` effect before comparing.

## Fail, never skip

A document that uses an SCXML feature the engine does not yet support flunks
the test, naming the feature - it never skips. An unimplemented feature can
never look like a passing test this way. For the authoritative, up-to-date
list of what is detected and its support status, see
`Statifier.Testing.FeatureDetector.feature_registry/0`.

As of this writing, every feature the detector recognizes is `:supported` or
`:partial`, so this path is a guarantee for the future rather than something
you are likely to hit today.

## Charts with timers, delayed sends, or `<invoke>`

A document whose semantics depend on wall-clock timers, delivery to an
external queue, or child sessions needs a running `Statifier.Session` rather
than the synchronous driving path - `test_scxml/4` detects this
(`session_required?/1`) and routes automatically; no action is needed at the
call site for the common case.

Two options tune the session path's timing for a chart whose load-bearing
delays exceed what this repository's own conformance corpus needed:

- `:settle_window_ms` (default `100`) - how long to wait for pending timers to
  drain before sending the next event.
- `:configuration_deadline_ms` (default `4_000`) - the upper bound on waiting
  for a session to reach an expected configuration.

Pass them as a keyword list after the events:

```elixir
test_scxml(xml, "slow chart", ["idle"], steps,
  configuration_deadline_ms: 15_000,
  settle_window_ms: 400
)
```

## Where the fixture format comes from

The shape `test_scxml/4` takes - a document, an expected initial
configuration, and a list of `{event, expected configuration}` steps - is the
same shape ADR-0006 defines for this repository's own conformance corpus. A
fixture already written in that shape is executable against your own chart
with no translation.
