# Statifier

[![CI](https://github.com/riddler/statifier-ex/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/riddler/statifier-ex/actions/workflows/ci.yml)

A W3C SCXML-conformant statecharts engine for Elixir. Ground-up rewrite of
[statifier](https://github.com/riddler/statifier) v1.x.

**Status: pre-alpha.** The architecture is settled (see
[docs/architecture.md](docs/architecture.md) and [docs/adr/](docs/adr/README.md));
the engine is being built against the SCION and W3C conformance corpora from day
one.

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

Statifier v2 is not on Hex yet, and will not be before 2.0.0 - no alpha,
beta, or release-candidate versions along the way. Until then, depend on a
commit reachable from `main`:

```elixir
{:statifier, github: "riddler/statifier-ex", ref: "<sha>"}
```

What a pin gives you (the full contract is
[ADR-0061](docs/adr/0061-sha-pinning-contract-until-2-0-0.md)):

- **Pin only commits reachable from `main`.** Every one of them has passed
  the full quality gate - the same gate CI runs on the default branch. A
  branch tip is covered by nothing.
- **Between two pins, any public API and any observable behavior may
  change** without deprecation, notice period, or compatibility shim.
  `2.0.0-dev` is one moving version. There are no tags before 2.0.0; the pin
  is the SHA.
- **What will never break silently:** persisted position and recording blobs
  refuse with a typed error on a format-version or chart-identity mismatch
  rather than misreading; API shape changes fail your compile.
- **How to see what changed:**
  `git diff <old-sha>..<new-sha> -- changelog.d/ CHANGELOG.md` lists every
  user-visible difference between two pins.

## Development

```bash
mix deps.get
mix quality --profile loop   # fast inner loop
mix quality                  # full gate (required green before commit)
```

Issue tracking is [beads](https://github.com/gastownhall/beads) (`bd ready` to
find work). Workflow, model roles, and worktree conventions:
[docs/workflow.md](docs/workflow.md). Registering your own `<invoke>`
handlers: [docs/extending.md](docs/extending.md). Scheduling delayed sends
durably, outside the session process:
[docs/durable-timers.md](docs/durable-timers.md). Testing your own charts:
[docs/testing-charts.md](docs/testing-charts.md).

## License

MIT - see [LICENSE](LICENSE).
