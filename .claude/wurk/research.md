# Statifier-ex extension: /wurk:research

This project's own vocabulary for its pipeline, its tree map, and where to
point a sub-agent outside this repo. Adds only - see
`~/.claude/skills/wurk:research/SKILL.md` for everything this does not repeat.

## The pipeline vocabulary

This is a plain Elixir library (no Phoenix, no Ecto): an SCXML statecharts
engine that is a literal port of the W3C SCXML Appendix D algorithm over a
pure functional core.

```
XML string -> Parser (Saxy SAX -> generic DOM) -> Lowering (typed builders)
  -> Document -> Validator + Compiler -> Machine (interned, valid by
  construction) -> Interpreter (pure Appendix D core) -> {state, [effect]}
```

- **Interpreter functions keep the Appendix D names** in snake_case:
  `select_transitions`, `compute_exit_set`, `compute_entry_set`, `microstep`,
  `enter_states`, `exit_states`.
- **Errors are events**: evaluations return `{:ok, v} | {:error, e}`; the
  interpreter maps errors to `error.execution` internal events.
- **Datamodel is predicator**: expressions compile to
  `{:static, term} | {:compiled, instructions, source}` at Machine-build time.

## The tree map

- `lib/statifier/` - library code: parser, DOM lowering, document structs,
  validator, compiler/machine, interpreter, datamodel/evaluator, effects.
  `lib/statifier/lowering/*.ex` holds the per-element lowering builders.
- `test/statifier/` - internal unit tests, run by default.
- `test/scion_tests/` - SCION conformance suite, tag `:scion`, excluded by
  default.
- `test/scxml_tests/` - W3C conformance suite, tag `:scxml_w3`, excluded by
  default.
- `test/support/` - harness code, including `Statifier.Case` and its
  `test_scxml/4` helper.
- `test/passing_tests.json` - the regression ratchet registry.
- `tools/corpus/` - the conformance corpus generator.

## The `../statifier` v1 reference checkout

Read-only. Point a sub-agent at it **explicitly**, and only when the question
genuinely involves v1 behavior - it is a comparison point, not part of this
repo's own research surface.

## Good search keys in this codebase

SCXML element names (`history`, `parallel`, `invoke`, `send`), Appendix D
function names (see the pipeline vocabulary above), and the terms
"datamodel", "predicator", "corpus", "ratchet".

## Areas that reliably want their own sub-agent

The interpreter core, the lowering builders, the conformance corpus and
ratchet, and any v1 comparison (pointed explicitly at `../statifier`).

## External authority

The W3C SCXML spec at https://www.w3.org/TR/scxml/ is the relevant external
authority; `site:w3.org/TR/scxml` is the right web-search shape when a
question needs it.
