# Statifier

[![CI](https://github.com/riddler/statifier-ex/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/riddler/statifier-ex/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/statifier.svg)](https://hex.pm/packages/statifier)
[![Hex Downloads](https://img.shields.io/hexpm/dt/statifier.svg)](https://hex.pm/packages/statifier)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/statifier/)
[![License](https://img.shields.io/hexpm/l/statifier.svg)](https://github.com/riddler/statifier-ex/blob/main/LICENSE)

A statechart (SCXML) interpreter for Elixir: compile a chart, step it with
events, and read its configuration. It follows the W3C SCXML algorithm and
hands back what the chart wants done as data, so your application decides
how and when to do it.

## Why a statechart engine

A long-lived process - a loan that is renewed, comes due, and is returned or
lost - usually ends up as a status column and conditionals spread across the
code that touches it, and the question "what may happen next?" has no single
answer. Statifier makes the chart that answer: states, guarded transitions
and data live in one SCXML document; its expressions are
[predicator](https://github.com/riddler/predicator-ex) expressions, with no
ECMAScript and no `eval`; the core is pure and returns effects
instead of performing them; and the interpreter is checked against 287
generated SCION/W3C conformance tests (119 SCION + 168 W3C).

## Installation

Add `statifier` to your dependencies:

```elixir
def deps do
  [
    {:statifier, "~> 2.12"}
  ]
end
```

## Basic usage

A loan may be renewed twice; a third renewal makes it due instead:

```elixir
source = """
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
       datamodel="predicator" initial="on_loan">
  <datamodel>
    <data id="renewals" expr="0"/>
  </datamodel>

  <state id="on_loan">
    <transition event="loan.renew" cond="renewals &lt; 2" target="on_loan">
      <assign location="renewals" expr="renewals + 1"/>
    </transition>
    <transition event="loan.renew" target="due"/>
    <transition event="loan.returned" target="returned"/>
  </state>

  <state id="due">
    <transition event="loan.returned" target="returned"/>
    <transition event="loan.lost" target="lost"/>
  </state>

  <final id="returned"/>
  <final id="lost"/>
</scxml>
"""

{:ok, chart} = Statifier.compile(source)
{execution, _effects} = Statifier.initialize(chart)

{:ok, execution, _effects} = Statifier.send_event(execution, "loan.renew")
{:ok, execution, _effects} = Statifier.send_event(execution, "loan.renew")
Statifier.active_leaf_states(execution)
#=> MapSet.new(["on_loan"])

{:ok, execution, _effects} = Statifier.send_event(execution, "loan.renew")
Statifier.active_leaf_states(execution)
#=> MapSet.new(["due"])
```

Those four functions are the whole entry point. Sessions, durable timers,
persistence and telemetry are layered on top of them, and the guides below
show each one.

## Documentation

- Learn
  - [Basic usage](https://hexdocs.pm/statifier/readme.html#basic-usage) - a
    first chart compiled, started and stepped with events
- Do
  - [How to extend Statifier](docs/extending.md) - register your own
    `<invoke>` handlers and `<send>` types, and report their outcome back
  - [How to persist and resume an execution](docs/persistence.md) - save
    where an execution stands and pick it up again after a restart
  - [How to host the pure core without a session](docs/hosting-without-session.md) -
    drive the core yourself and perform its effects
  - [How to make a delayed send outlive the process](docs/durable-timers.md) -
    keep a timer across a restart
  - [How to test your own charts](docs/testing-charts.md) - assert the
    configurations a chart walks through
  - [How to route a chart on an external resource's verdict](docs/chart-patterns.md) -
    park and retry, or fail fast
  - [Upgrading](https://github.com/riddler/statifier-ex/blob/main/docs/upgrading.md) -
    what a host changes, release by release
- Look up
  - [API reference](https://hexdocs.pm/statifier/api-reference.html) - every
    public module and function
  - [Datamodel](docs/datamodel.md) - predicator expressions, `<data>`,
    `<assign>` and `<script>`
  - [The Basic HTTP Event I/O Processor](docs/basichttp.md) - the mapping
    between events and HTTP requests, and what is not supported
  - [CHANGELOG](CHANGELOG.md) - what changed in each release
- Understand
  - [Architecture](docs/architecture.md) - the layers and the design
    principles behind them
  - [Observability](docs/observability.md) - the trace effects and what a
    host can do with them
  - [OpenTelemetry](docs/opentelemetry.md) - how spans map onto an execution
  - [The decision records](https://github.com/riddler/statifier-ex/blob/main/docs/adr/README.md) -
    why the engine is built the way it is

## Compatibility

- Elixir `~> 1.18`.
- Runtime dependencies: `predicator ~> 9.4`, `saxy ~> 1.6`,
  `telemetry ~> 1.3`.
- Releases follow [SemVer](https://semver.org). Persisted position and
  recording blobs refuse with a typed error on a format-version or
  chart-identity mismatch rather than misreading.

## Contributing

The gate is `mix quality`; the workflow and its conventions are in
[docs/workflow.md](https://github.com/riddler/statifier-ex/blob/main/docs/workflow.md),
and what the sibling repos copy from here is in the
[family reference](https://github.com/riddler/statifier-ex/blob/main/docs/family-reference.md).

## License

MIT - see [LICENSE](https://github.com/riddler/statifier-ex/blob/main/LICENSE).
