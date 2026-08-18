# Project orientation: statifier-ex

Statifier-ex is a literal port of the W3C SCXML Appendix D algorithm over a
pure functional core (`../statifier` is the read-only reference it replaces).

## Layout

`lib/statifier/` in pipeline order: `parser/` (Saxy SAX to a generic DOM,
`Parser.Location` on every node), `lowering/` (DOM to typed `Document`
structs), `validator/` (one check per file under `validator/checks/`),
`compiler/` (`Document` to interned `Machine`), `interpreter/` (`selection.ex`,
`name_match.ex`, `exit_entry.ex`, `content.ex`, `datamodel.ex`, `datamodel/`),
`evaluator/`, `effect/` (one struct per effect) plus `effect/trace/` (trace
effects).

The pure core stops at `{machine_state, [effect]}`; `session.ex` is the
GenServer that performs those effects (ADR-0003, ADR-0027) - the one module
under `lib/statifier/` allowed to do I/O. `session/` holds its pure deciding
halves (`effects.ex`, `inbox.ex`, `invocations.ex`, `timers.ex`,
`recording.ex`), `invoke/` and `send/` hold the small resolvers those effects
need (`invoke/source.ex`, `send/target.ex`), and `replay.ex` re-drives a
`Session.Recording` through the same core with no process and no timer
(ADR-0034). `docs/architecture.md`'s "Sessions and invoke" section is the map
of how these fit together.

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

`send_` and `inv_` are good search keys now that `<send>`
(`lib/statifier/machine/content/send.ex`) and `<invoke>` (the invoke pass in
`lib/statifier/interpreter.ex`) are both implemented - but neither is a UXID.
ADR-0008 was amended (2026-08-15): a UXID reads the clock and a CSPRNG, which
the pure core's contract does not admit, so an id minted *inside* the core is
always a deterministic `%MachineState{}` counter instead. `sess_` (minted
outside the core, at session start) is the only prefix in this file that is
still a real UXID. `inv_<counter>` (or `stateid.inv_<counter>` per 6.4.1) comes
from `machine_state.invoke_counter`; `send_<counter>` comes from a sibling
`machine_state.send_counter` (ADR-0035) and is never prefixed by a state id.
Grepping `send_` still turns up unrelated `send_event`/`send_id` matches
alongside the id-generation sites, so read for `send_counter` and
`"send_" <>` specifically when hunting the generator itself.

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
