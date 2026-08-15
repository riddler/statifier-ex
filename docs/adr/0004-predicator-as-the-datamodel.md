# ADR-0004: Predicator is the datamodel; no ECMAScript, no Elixir eval

Status: accepted (2026-08-02) - amended in part by ADR-0026 (2026-08-14)

**Amendment note.**
[ADR-0026](0026-script-as-predicator-statement-programs.md) discharges the
conditional final consequence below on its own stated condition: predicator
(5.0.0, pinned `~> 8.0` since st-59d) grew the safe statement layer -
`parse_program/2`, `store`/`pop`, `execute/1,2,3` - so `<script>` is now
supported, with predicator statement programs as bodies. Everything else in
this record stands unchanged: predicator is still the sole datamodel, no
ECMAScript engine is embedded, and no Elixir code is ever evaluated from a
document. The statement layer is the same non-evaluative instruction set the
expression language already runs on, extended with writes, so the security
posture this record stakes out is unaffected.

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
  layer. *(Condition met: see the amendment note above and ADR-0026.)*
