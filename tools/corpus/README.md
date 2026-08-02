# Corpus tooling

Generator for the SCION and W3C conformance test suites (see `docs/testing.md`
and ADR-0006). Seeded verbatim from
[ex_statechart](https://github.com/camshaft/ex_statechart)'s Makefile and
scripts, which already do the bulk of the work:

- `Makefile` - fetches the corpora and drives generation:
  - W3C: downloads the IRP manifest + `.txml` sources from
    https://www.w3.org/Voice/2013/scxml-irp, transforms `.txml -> .scxml` with
    Saxon-HE and `scxml_w3/conf_elixir.xsl` (the datamodel-specific
    transformation), then emits test cases via `scxml_w3/cases.exs` filtered by
    `scxml_w3/manifest.exs` (mandatory vs optional, datamodel).
  - SCION: clones https://github.com/jbeard4/scxml-test-framework, drops the
    ecma-only trees, then emits test cases from the JSON case descriptions via
    `scion/cases.exs`.

## Adaptation needed (tracked in beads)

The scripts currently emit ex_statechart-style cases. To produce Statifier v2
test files they must be updated to:

1. Emit the v1-style test file shape: one module per file
   (`SCIONTest.Category.NameTest` / `SCXMLTest.Section.TestNNN`),
   `use Statifier.Case`, suite tags (`:scion` / `:scxml_w3`),
   `@tag required_features: [...]` (derived via the feature detector),
   inline XML heredoc (4-space base indent), single `test_scxml/4` call built
   from the JSON events/configuration sequence.
2. Rewrite the XSL for the predicator datamodel (v1's converted corpus used
   `datamodel="elixir"`; the alias is accepted) rather than ex_statechart's
   expression forms.
3. Record exclusions (irreducibly ECMAScript-dependent tests) in a committed
   manifest with reasons, per ADR-0004.

Generated output is committed under `test/scion_tests/` and
`test/scxml_tests/`; regeneration must produce a reviewable diff. v1's
generated corpus (`../statifier/test/scion_tests`, `.../scxml_tests`) is the
reference for the target shape and for seeding `test/passing_tests.json`.
