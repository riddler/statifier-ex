# Statifier

[![CI](https://github.com/riddler/statifier-ex/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/riddler/statifier-ex/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/statifier.svg)](https://hex.pm/packages/statifier)
[![Hex Downloads](https://img.shields.io/hexpm/dt/statifier.svg)](https://hex.pm/packages/statifier)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/statifier/)
[![License](https://img.shields.io/hexpm/l/statifier.svg)](https://github.com/riddler/statifier-ex/blob/main/LICENSE)

A W3C SCXML-conformant statecharts engine for Elixir. Ground-up rewrite of
[statifier](https://github.com/riddler/statifier) v1.x, built against the SCION
and W3C conformance corpora from day one.

## Why a rewrite

v1 works, but its interpreter re-derived the SCXML semantics instead of porting
the spec's algorithm, and the divergences account for nearly all of its remaining
conformance failures. v2 is:

- a **literal port of W3C SCXML Appendix D** - same functions, same names
- a **pure functional core** returning effects - one semantics for every API,
  sessions and timers layered on top
- **predicator as the datamodel** - safe, non-evaluative expressions; no
  ECMAScript, no eval
- built **corpus-first** - 186+ SCION/W3C conformance tests and a
  forward-only regression ratchet inherited from v1, with the generator
  committed this time

## Installation

Add `statifier` to your dependencies:

```elixir
def deps do
  [
    {:statifier, "~> 2.0"}
  ]
end
```

Releases follow [SemVer](https://semver.org); [CHANGELOG.md](CHANGELOG.md)
is the upgrade briefing, and its `[2.0.0]` section is written as a migration
document for 1.x users. (The pre-release SHA-pinning contract ended with
2.0.0 - [ADR-0066](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0066-publishes-2-0-0-ending-the-sha-pinning-contract.md).)
Persisted position and recording blobs refuse with a typed error on a
format-version or chart-identity mismatch rather than misreading.

## Quick start

Compile an SCXML document, initialize it, and send it events. Effects come
back as data - the engine never performs them for you:

```elixir
source = """
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="authorizing">
  <state id="authorizing">
    <transition event="card.approved" target="authorized"/>
    <transition event="card.declined" target="declined"/>
  </state>
  <state id="authorized">
    <transition event="capture.succeeded" target="settled"/>
  </state>
  <state id="declined"/>
  <state id="settled"/>
</scxml>
"""

{:ok, machine} = Statifier.compile(source)
{machine_state, _effects} = Statifier.initialize(machine)

Statifier.active_leaf_states(machine_state)
#=> MapSet.new(["authorizing"])

{:ok, machine_state, _effects} = Statifier.send_event(machine_state, "card.approved")

Statifier.active_leaf_states(machine_state)
#=> MapSet.new(["authorized"])
```

That four-function surface (`compile/2`, `initialize/2`, `send_event/2`,
`active_leaf_states/1`) is the whole entry point; sessions, durable timers,
persistence, and telemetry layer on top of it.

## Documentation

Published guides on [hexdocs](https://hexdocs.pm/statifier/):

- [Architecture](docs/architecture.md) - the layered design and the
  decisions behind it
- [Datamodel](docs/datamodel.md) - predicator expressions, `<data>`,
  `<assign>`, and `<script>`
- [Extending](docs/extending.md) - registering your own `<invoke>` handlers
- [Persistence](docs/persistence.md) - chart identity, persisted positions,
  and resuming sessions
- [Durable timers](docs/durable-timers.md) - scheduling delayed sends
  outside the session process
- [Observability](docs/observability.md) - trace effects and what to do
  with them
- [OpenTelemetry](docs/opentelemetry.md) - span topology and the OTel bridge
- [Testing charts](docs/testing-charts.md) - testing your own state charts
- [Chart patterns](docs/chart-patterns.md) - patterns for
  external-resource verdicts (park/retry, fail-fast)
- [Family reference](docs/family-reference.md) - what the statifier sibling
  repos copy from here

Architecture Decision Records live in the repository at
[docs/adr/](https://github.com/riddler/statifier-ex/blob/main/docs/adr/README.md).

## Development

```bash
mix deps.get
mix quality --profile loop   # fast inner loop
mix quality                  # full gate (required green before commit)
```

Issue tracking is [beads](https://github.com/gastownhall/beads) (`bd ready` to
find work). Workflow, model roles, and worktree conventions:
[docs/workflow.md](https://github.com/riddler/statifier-ex/blob/main/docs/workflow.md).

## License

MIT - see [LICENSE](https://github.com/riddler/statifier-ex/blob/main/LICENSE).
