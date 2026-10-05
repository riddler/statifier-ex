---
# The docs manifest the documentation tools read. Generated from the family's manifest
# table: change a key there and regenerate. The two prose lines below may be sharpened.
product: statifier
family: statifier
audience: Elixir developers who run long-lived processes as statecharts
tone: "plain, second person, no marketing"
terminology:
  use:
    - execution
    - chart
    - document
    - revision
  avoid:
    - "run (noun)"
    - workflow instance
example_world: library-loan
docs_root: docs
quadrants:
  tutorials: docs/tutorials
  how_to: docs/guides
  reference: docs/reference
  explanation: docs/explanation
readme: README.md
reference_generator: ex_doc
publish: hexdocs
contributor_paths:
  - docs/adr
  - docs/plans
  - docs/spikes
  - docs/research
  - docs/design
  - docs/measurements
  - CLAUDE.md
executed_snippets:
  - test/statifier/readme_test.exs
  - test/statifier/chart_patterns_test.exs
  - test/statifier/hosting_without_session_test.exs
readme_max_lines: 250
---

A statechart (SCXML) interpreter for Elixir: parse a chart, step it with events, read its configuration.
Examples are written in the library loan: a copy of a book lent to a patron, due, renewed, returned or lost.
