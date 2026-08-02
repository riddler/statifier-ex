# ADR-0004: Predicator is the datamodel; no ECMAScript, no Elixir eval

Status: accepted (2026-08-02)

## Context

SCXML's default datamodel language is ECMAScript, which for an Elixir engine means
embedding a JS runtime and giving documents a general-purpose language. v1 used
predicator (also maintained by this project's owner) as a de facto datamodel but
hedged toward ECMAScript in docs and feature flags. Separately, evaluating raw
Elixir from documents is off the table: documents may be end-user-authored, and
safety is a core selling point.

## Decision

Predicator (`~> 3.5`) is *the* datamodel, permanently. `datamodel="predicator"`
(alias `elixir`). We do not embed ECMAScript and never evaluate Elixir code from a
document. W3C tests that irreducibly require ECMAScript are excluded by the corpus
tooling with the exclusion recorded in the manifest. Real computation reaches the
host through `<invoke>` handlers and external `<send>`. Gaps predicator has for
SCXML use (persistent bound contexts, auto-vivifying assignment, typed undefined,
statement sequences as a possible `<script>` answer) are upstreamed into predicator
rather than papered over in statifier - see `docs/datamodel.md`.

## Consequences

- A bounded, known conformance ceiling on ECMAScript-dependent W3C tests, accepted
  and documented.
- Security story stays simple and truthful: no eval anywhere.
- Predicator gains features that benefit all its embeddings; statifier's glue
  stays thin.
- `<script>` remains unsupported unless/until predicator grows a safe statement
  layer.
