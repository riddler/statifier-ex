# Project orientation: statifier-ex

Statifier-ex is a literal port of the W3C SCXML Appendix D algorithm over a
pure functional core (`../statifier` is the read-only reference it replaces).

## Layout

`lib/statifier/` in pipeline order: `parser/` (Saxy SAX to a generic DOM,
`Parser.Location` on every node), `lowering/` (DOM to typed `Document`
structs), `validator/` (one check per file under `validator/checks/`),
`compiler/` (`Document` to interned `Machine`), `interpreter/` (`selection.ex`,
`name_match.ex`, `exit_entry.ex`, `content.ex`), `evaluator/`, `effect/`
(one struct per effect) plus `effect/trace/` (trace effects).

`lib/mix/tasks/` and `lib/mix/statifier/` hold the repo's own gate machinery:
`gate.check`, `gate.verify`, `adr.check`, `adr.judge`, `test.regression`,
`test.baseline`. `tools/corpus/` holds the corpus pipeline (`mise run corpus`;
`tools/corpus/README.md` explains the stages). `docs/adr/` holds the settled
decisions.

## Suites

`test/statifier/` mirrors `lib/statifier/` one-to-one and runs by default.
`test/scion_tests/` (`:scion`) and `test/scxml_tests/` (`:scxml_w3`, split
`mandatory/` and `optional/`) are generated conformance corpora, excluded by
default (`test/test_helper.exs`). `test/passing_tests.json` is the regression
ratchet. `test/support/` is harness: `Statifier.Case.test_scxml/4`
(`test/support/case.ex`) is the single coupling surface every generated-corpus
test goes through; `Statifier.TmpDir` backs `@tag :isolated_tmp_dir`. A fourth
suite, `:adr_judge_corpus`, makes real `claude` CLI calls and is excluded from
every ordinary run too.

## Module families worth mining

- `Document.*` (`lib/statifier/document/`, uncompiled) versus `Machine.*`
  (`lib/statifier/machine/`, interned, valid by construction) are parallel
  families, the best pattern source for a new SCXML element.
- `validator/checks/*.ex` - one file per check, the template for a new one.
- `effect/*.ex`, `effect/trace/*.ex` - one struct per effect.

## Terms of art (the best search keys)

Appendix D function names - `select_transitions`,
`select_eventless_transitions`, `remove_conflicting_transitions`,
`get_transition_domain`, `compute_exit_set`, `compute_entry_set`,
`add_descendant_states_to_enter`, `microstep`, `macrostep`, `enter_states`,
`exit_states`, `main_event_loop`, `exit_interpreter`. SCXML element names as
they appear in tests and lowering builders. Project coinages: `t_index` /
`c_index`, LCCA, full configuration versus leaf-state view, `done.state.<id>`,
`error.execution`, UXID prefix `sess_`.

`send_` and `inv_` are also ADR-0008 UXID prefixes - for send ids and
invocations - but they are not search keys yet: `<send>` and `<invoke>` are
unimplemented, so nothing generates either prefix. Grepping `inv_` returns
nothing, and grepping `send_` is worse than nothing - it returns a pile of
unrelated `send_event` / `send_id` matches rather than the empty result that
would at least signal "not implemented". Both become good keys once `<send>`
and `<invoke>` land.

## Reading rules

- Appendix D function names are the highest-yield grep keys; reach for them
  before English descriptions of behavior.
- Describe a ported interpreter function **against the spec pseudocode**, not
  by inferring intent from the Elixir. A deviation is a finding worth
  reporting, and an inline comment citing a mechanical reason is what makes
  one legitimate (ADR-0002).
- The core is pure: `(machine_state, event) -> {machine_state, [effect]}`. A
  side effect in `lib/statifier/` is either an `Effect` struct being returned
  or a bug (ADR-0003).
- Evaluations return `{:ok, v} | {:error, e}`; only the interpreter, and only
  in `Interpreter.Content`, raises `error.execution`. A rescue-to-default at a
  leaf is a finding.
- State ids are strings only at the `Statifier` boundary; below it, everything
  is an interned integer index (ADR-0005). Expressions are predicator, never
  ECMAScript or `eval`; `<invoke>` is the escape hatch (ADR-0004). Accepted
  ADRs under `docs/adr/` are settled - cite the number rather than re-arguing.
