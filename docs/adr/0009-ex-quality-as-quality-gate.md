# ADR-0009: ex_quality is the quality gate

Status: accepted (2026-08-02)

## Context

v1 enforced quality through a hand-rolled 375-line `mix quality` task plus a
pre-push git hook running format, coverage, credo, and dialyzer sequentially, each
printing in its own format. ex_quality (`~> 0.13`, same maintainer) runs the same
tools in parallel with normalized one-line-per-stage output, skipped-stage
reporting, profiles, changed-scope tests, and JSON reports designed for agents.

## Decision

ex_quality replaces all hand-rolled quality tooling. Two named paths:
`mix quality --profile loop` (format, compile, credo, changed-scope tests, no
dialyzer/coverage) is the inner loop agents run between edits; plain `mix quality`
is the full gate required green before any commit or merge, and is what CI runs.
The regression ratchet (`mix test.regression`) is wired in as a custom stage once
the corpus lands, so a conformance regression is a named stage failure. Agents
route on `--format json --report -` rather than parsing terminal text. Gaps found
while dogfooding are upstreamed to ex_quality.

## Consequences

- One config (`.quality.exs`) instead of task code plus hook script; CI and local
  runs are the same command.
- The fast path has a name (`--profile loop`) that skills and docs point at.
- A scoped green run is distinguishable from a full green run in the report, so
  nothing ratchets on the narrow one.
