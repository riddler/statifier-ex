# conformance/

A language-neutral conformance corpus for SCXML state charts, emitted by
statifier-ex so that another implementation of the same engine can make a
claim against the same cases
([ADR-0070](../docs/adr/0070-statifier-emits-a-language-neutral-conformance-corpus.md)).

| Path | What it is | Written by |
|---|---|---|
| `README.md` | this file | hand, reviewed like code |
| `RATCHET.md` | the contract a registry is written against: the claims, the pin, the rules a check enforces, and the vendoring recipe for a sibling implementation | hand, reviewed like code |
| `schema/` | JSON Schemas (draft 2020-12) for every file below: `case.json` (one case), `corpus.json` (one corpus file), `manifest.json`, `registry.json`, `exclusions.json` | hand, reviewed like code |
| `cases/` | the `statifier` suite's cases, which this repository authors: per case, an SCXML document and a JSON file holding its description, its expected configurations and its `host` object | hand, reviewed like code |
| `corpus/` | one file per suite that has cases, holding that suite's cases: `scion.json` and `w3c.json` for the upstream suites, and `statifier.json` for the cases this repository authors itself (ADR-0070 decision 5) once it authors one | the emitter |
| `manifest.json` | the corpus hash, the corpus files and the upstream suites (a claim pins a corpus by its hash and the statifier-ex tag it was vendored from, not by a version in the file) | the emitter |
| `registry.json` | the cases statifier-ex passes, derived from `test/passing_tests.json` | the emitter |
| `exclusions.json` | the upstream documents left out of the corpus, each with its reason | the emitter |
| `LICENSES/` | the licence texts the upstream cases are redistributed under: the W3C 3-clause BSD License with the W3C test suite's copyright notice, and the Apache License 2.0 SCION ships | copied from the upstream licences, reviewed like code |

The corpus, the manifest, the registry and the exclusions are generated and
never edited by hand: a change to one is a change to the emitter or to its
input, regenerated. The same rule holds for the generated test modules under
`test/scion_tests/` and `test/scxml_tests/`, which `mise run corpus:emit`
writes from `corpus/`. Only the files the table marks as written by hand are
edited directly. `test/passing_tests.json` stays the ratchet file
([ADR-0006](../docs/adr/0006-reuse-conformance-corpus-and-regression-ratchet.md)).

`mix statifier.corpus` is the emitter: it reads the upstream suites that
`mise run corpus:fetch` and `mise run corpus:transform` put in the gitignored
`tools/corpus/scratch/` and the authored cases under `cases/`, runs every
case through statifier, and writes the generated files.
`mix statifier.corpus --check` writes nothing and needs no
upstream tree: it re-runs every committed case and fails when a generated
file differs from what the emitter would write from the committed inputs, or
when there is nothing to check. Its module documentation
(`Mix.Statifier.Corpus.Emitter`) states the rules; three are worth knowing
before reading the files:

- `corpus_hash` in `manifest.json` is `sha256:` and the hex SHA-256 of the
  corpus files' bytes concatenated in suite order (`scion`, `w3c`,
  `statifier`), skipping a suite with no file.
- A suite with no cases has no corpus file and no manifest entry.
- An exclusion keyed by a SCION directory stays one entry naming the
  directory; it is not expanded into the upstream cases under it.

This directory is not part of the Hex package: a sibling implementation
vendors it from a statifier-ex tag, byte for byte, with `LICENSES/` and every
case's `upstream` field, and writes its own registry against it. The recipe
and the registry contract are [`RATCHET.md`](RATCHET.md).
