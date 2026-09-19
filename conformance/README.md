# conformance/

A language-neutral conformance corpus for SCXML state charts, emitted by
statifier-ex so that another implementation of the same engine can make a
claim against the same cases
([ADR-0070](../docs/adr/0070-statifier-emits-a-language-neutral-conformance-corpus.md)).

| Path | What it is | Written by |
|---|---|---|
| `schema/` | JSON Schemas (draft 2020-12) for every file below: `case.json` (one case), `corpus.json` (one corpus file), `manifest.json`, `registry.json`, `exclusions.json` | hand, reviewed like code |
| `corpus/` | one file per suite, holding that suite's cases | the emitter |
| `manifest.json` | the corpus hash, the statifier-ex version, the corpus files and the upstream suites | the emitter |
| `registry.json` | the cases statifier-ex passes, derived from `test/passing_tests.json` | the emitter |
| `exclusions.json` | the upstream documents left out of the corpus, each with its reason | the emitter |

The corpus, the manifest, the registry and the exclusions are generated and
never edited by hand: a change to one is a change to the emitter or to its
input, regenerated. `test/passing_tests.json` stays the ratchet file
([ADR-0006](../docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md)).

Only the schemas exist so far; the emitter and the generated files land
after them. This directory is not part of the Hex package: a sibling
implementation vendors it from a statifier-ex tag.
