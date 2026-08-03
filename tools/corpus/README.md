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
  scxml_w3/manifest.exs     W3C manifest parser + TXML fetcher
  scxml_w3/conf_predicator.xsl  TXML -> SCXML for the predicator datamodel
  scxml_w3/exclusions.exs   tests with no predicator equivalent, with reasons
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

Fetch and transform are retargeted and working: 198 W3C cases and 127 SCION
cases. The **W3C emit stage is rewritten to the v2 shape** (`st2-00p.7`):
`SCXMLTest.<Section>.<Name>`, `use Statifier.Case`, `@moduletag :scxml_w3`,
`@tag required_features: [...]` derived via `Statifier.FeatureDetector`,
inline XML heredoc (4-space base indent, pretty-printed from the transformed
`.scxml`, comments stripped), and a single `test_scxml/4` call. 162 of the 198
W3C cases emit; the rest are filtered out (see below). `test/scxml_tests/` is
populated.

The **SCION emit stage is also rewritten to the v2 shape** (`st2-00p.6`):
`SCIONTest.<Spec>.<Name>Test`, `use Statifier.Case`, `@moduletag :scion`,
`@tag required_features: [...]` derived via `Statifier.FeatureDetector`,
inline XML heredoc (4-space base indent, raw source unmodified - no
xmerl re-serialization), and a single `test_scxml/4` call. All 127 SCION cases
emit; `test/scion_tests/` is populated. `mise run corpus` (fetch, transform,
emit for both W3C and SCION) now runs end to end without error.

Emit also normalizes every generated path segment and module name
(`tools/corpus/normalize.exs`, shared by both emitters): upstream
camelCase/acronym/symbol-separated names become snake_case paths and the
matching PascalCase module segments (`st2-yo4`).

Remaining work, tracked in beads:

1. **st2-00p.8** - committed exclusion manifest with reasons for the SCION
   suite.

Two filters apply before a W3C case is emitted, both in `scxml_w3/cases.exs`:

- **datamodel**: only inputs `conf_predicator.xsl` transformed to
  `datamodel="predicator"` are emitted. The datamodel-specific optional suites
  (`ecma-profile`, ...) test literal ECMAScript/XPath behavior the XSL leaves
  untouched, so they keep their original datamodel and are out of scope for
  the predicator commitment (docs/datamodel.md).
- **exclusions.exs**: tests with no predicator equivalent (script, list
  concatenation, string prefix, and the BasicHTTP Event I/O Processor tree),
  recorded with a reason atom per ADR-0004.

v1's generated corpus (`../statifier/test/scion_tests`, `.../scxml_tests`) is the
reference for the target shape and for seeding `test/passing_tests.json`.
