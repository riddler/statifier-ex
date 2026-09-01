### Added

- Adds `Statifier.Effect.Trace.CondsEvaluated` and the
  `[:statifier, :session, :trace, :conds_evaluated]` telemetry event, emitted
  once per selection round that evaluated a written `cond`, reporting each
  guard's `t_index`, outcome (`:enabled`/`:disabled`/`:error`) and failure
  reason.

### Changed

- `Statifier.Interpreter.Selection.select_transitions/2` and
  `select_eventless_transitions/1` return `{machine_state, transitions,
  effects}` instead of `{machine_state, transitions}`; the third element is
  the round's guard trace. Call them for their transitions and match the
  three-element tuple.
