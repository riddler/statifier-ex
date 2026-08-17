# Corpus tooling

Generator for the SCION and W3C conformance test suites (see `docs/testing.md`
and ADR-0006). Seeded from
[ex_statechart](https://github.com/camshaft/ex_statechart)'s Makefile and
scripts, retargeted to the v2 layout and driven by mise tasks.

## Regenerating

One command, from anywhere in the repo:

```bash
mise run corpus
```

That runs three stages, each also available on its own (`mise tasks` lists them):

| Task | What it does |
| --- | --- |
| `mise run corpus:fetch` | Downloads the W3C IRP manifest and its `.txml` sources, Saxon-HE, and clones the SCION `scxml-test-framework` into `scratch/` |
| `mise run corpus:transform` | Runs Saxon over each `.txml` with `scxml_w3/conf_predicator.xsl` to produce `.scxml` for the predicator datamodel |
| `mise run corpus:emit` | Writes the generated test modules into `test/scion_tests/` and `test/scxml_tests/` |
| `mise run corpus:check` | Asserts every transformed mandatory W3C expression compiles under predicator, skipping `exclusions.exs` entries and allowing the values the W3C tests deliberately require to be invalid |
| `mise run corpus:clean` | Discards every upstream download; the next run refetches |

Every stage is incremental and resumable: fetch skips files already on disk,
transform reruns Saxon only where the `.txml` or the XSL is newer than the
`.scxml`. `mise install` provisions the toolchain (Erlang, Elixir, and a JRE for
Saxon); `curl`, `git`, and `unzip` come from the OS.

### Seeding from a local mirror

`www.w3.org` rate-limits a few hundred sequential requests with a 429, which
turns a cold W3C fetch into a long throttled crawl. If you have another checkout
holding the same `<conformance>/<spec>/<id>.{txml,description}` tree, point the
fetcher at it:

```bash
CORPUS_W3_MIRROR=~/repos/github/ex_statechart/test/scxml_w3/cases mise run corpus:fetch
```

Only `.txml`, `.description`, and `manifest.xml` are copied, and only where the
file is missing locally - a mirror's own `.scxml` output never displaces ours.
`CORPUS_W3_MIRROR` is intentionally not set in `mise.toml`, since a value there
would override the one you export.

## Layout

```
tools/corpus/
  scion/cases.exs           SCION emitter
  scion/exclusions.exs      SCION cases with no predicator equivalent, or that duplicate the W3C corpus, with reasons
  scxml_w3/manifest.exs     W3C manifest parser + TXML fetcher
  scxml_w3/conf_predicator.xsl  TXML -> SCXML for the predicator datamodel
  scxml_w3/exclusions.exs   tests with no predicator equivalent, with reasons
  scxml_w3/sub_documents.exs  manifest <dep> ids: <invoke>-loaded fixtures, not standalone tests
  scxml_w3/cases.exs        W3C emitter
  scratch/                  gitignored; everything fetched from upstream
    saxon/
    scion/cases/<spec>/<name>.{json,scxml}
    scxml_w3/cases/<conformance>/<spec>/<name>.{txml,scxml,description}
```

The tasks themselves live in `mise.toml` at the repo root, along with the
`CORPUS_*` paths and upstream URLs they use.

Nothing under `scratch/` is committed. The only generator output that enters git
is the emitted test modules:

- `test/scion_tests/<spec>/<name>_test.exs`
- `test/scxml_tests/<conformance>/<spec>/<name>_test.exs`

They are committed deliberately, so a regeneration lands as a reviewable diff.

## Status

The pipeline runs end to end: fetch, transform, and both emitters take an
empty `scratch/` tree to a populated `test/scion_tests/` and
`test/scxml_tests/`, and the emitted output is committed.

Fetch and transform pull 198 W3C documents and 316 SCION cases (127 native + the
189-case `w3c-ecma` duplicate of the W3C IRP suite, kept by
`corpus:fetch:scion` and filtered at emit time - see
`tools/corpus/scion/exclusions.exs`). The **W3C emitter** produces
`SCXMLTest.<Section>.<Name>`, `use Statifier.Case`, `@moduletag :scxml_w3`,
`@tag required_features: [...]` derived via `Statifier.FeatureDetector`,
inline XML heredoc (4-space base indent, pretty-printed from the transformed
`.scxml`, comments stripped), and a single `test_scxml/4` call. Of the 198
downloaded W3C documents, 5 are dependency documents an `<invoke>` loads at
runtime rather than conformance cases, leaving 193 cases; 162 of those emit
(159 mandatory + 3 optional), and the rest are filtered out (see below).
`test/scxml_tests/` is populated.

The **SCION emitter** produces `SCIONTest.<Spec>.<Name>Test`,
`use Statifier.Case`, `@moduletag :scion`, `@tag required_features: [...]`
derived via `Statifier.FeatureDetector`, inline XML heredoc (4-space base
indent, raw source unmodified - no xmerl re-serialization), and a single
`test_scxml/4` call. 119 of the 127 native SCION cases emit; the rest are
excluded per `tools/corpus/scion/exclusions.exs` (below). `test/scion_tests/`
is populated.

Emit also normalizes every generated path segment and module name
(`tools/corpus/normalize.exs`, shared by both emitters): upstream
camelCase/acronym/symbol-separated names become snake_case paths and the
matching PascalCase module segments (`st-yo4`).

Regeneration was verified reproducible on 2026-08-05: a cold run from an
empty `scratch/` tree, followed by a second `corpus:emit`, produced a
byte-identical, zero-diff match against the committed corpus. Because the
checkout has `core.ignorecase=true`, a case-only path drift between the
committed tree and the emitter's output (upstream camelCase segment vs.
emitted snake_case segment) is invisible to `git status` on a
case-insensitive filesystem; `test/corpus/emitted_paths_test.exs` asserts the
path-shape invariant directly so that class of drift fails a gate instead of
waiting for a case-sensitive filesystem to surface it.

`mix test.regression` and `mix test.baseline` report per-corpus coverage
against these emitted counts (119 SCION, 162 W3C), not the upstream suite
sizes above - see `docs/testing.md`'s regression ratchet section - so an edit
to either exclusions file that changes what emits also changes what those
tasks report as the denominator. `test/corpus/readme_counts_test.exs` pins
every count in this file against a fresh count of the emitted tree, so that
drift fails a gate instead of sitting here unnoticed.

Remaining work, tracked in beads:

1. **st-00p.10** - wire the regression ratchet into `mix quality`.

Three filters apply before a W3C case is emitted, all in `scxml_w3/cases.exs`:

- **datamodel**: only inputs `conf_predicator.xsl` transformed to
  `datamodel="predicator"` are emitted. The datamodel-specific optional suites
  (`ecma-profile`, ...) test literal ECMAScript/XPath behavior the XSL leaves
  untouched, so they keep their original datamodel and are out of scope for
  the predicator commitment (docs/datamodel.md).
- **exclusions.exs**: tests with no predicator equivalent (script, list
  concatenation, string prefix, and the BasicHTTP Event I/O Processor tree),
  recorded with a reason atom per ADR-0004.
- **sub_documents.exs**: manifest `<dep>` documents an `<invoke>` loads at
  runtime rather than a `<start>` document run as its own conformance test.
  This is a different category from `exclusions.exs`: an exclusion is a test
  with no predicator equivalent, still a would-be standalone test if datamodel
  support existed; a sub-document is never a standalone test at all, so it is
  filtered by manifest role rather than recorded as an exclusion (st-rbp).

One filter applies before a SCION case is emitted, in `scion/cases.exs`:

- **exclusions.exs**: cases with no predicator equivalent (`<script src>`),
  and the `w3c-ecma` tree - SCION's own untransformed duplicate of the W3C
  IRP suite - recorded with a reason atom per ADR-0004. `more-parallel/test10`
  and `test10b` are excluded too, for a different reason: they assume a
  `<parallel>` can be the LCCA, which the REC forbids (ADR-0022).

  The file holds 6 keys today. A key names either a whole spec directory
  (every case under it is excluded) or one `spec/case` pair. `w3c-ecma` is a
  directory key, but it excludes the separate 189-case duplicate tree, not
  any of the 127 native cases - it plays no part in the 127-vs-119
  reconciliation below. The other 5 keys account for all 8 native cases
  the emitted count is short of 127: `script-src` is a directory key
  matching 4 cases (`test0`-`test3`); `error` is a directory key matching 1
  case; `assign-current-small-step/test0`, `more-parallel/test10`, and
  `more-parallel/test10b` are single-case keys, 1 each. `4 + 1 + 1 + 1 + 1 =
  8`, and `119 + 8 = 127`. (An earlier version of this file also excluded a
  `script` directory - 3 more native cases - but st-af3.17 un-excluded it
  once `conf:script` could compile under predicator's statement grammar; the
  key is gone, not merely unmatched.)

v1's generated corpus (`../statifier/test/scion_tests`, `.../scxml_tests`) is the
reference for the target shape and for seeding `test/passing_tests.json`.
