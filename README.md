# Statifier

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

## Development

```bash
mix deps.get
mix quality --profile loop   # fast inner loop
mix quality                  # full gate (required green before commit)
```

Issue tracking is [beads](https://github.com/gastownhall/beads) (`bd ready` to
find work). Workflow, model roles, and worktree conventions:
[docs/workflow.md](docs/workflow.md). Registering your own `<invoke>`
handlers: [docs/extending.md](docs/extending.md).
