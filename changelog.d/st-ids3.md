### Fixed

- `Statifier.Validator.validate/3` refuses a `<state>` with no `id` whose `initial` names a missing state (`{:unresolved_initial, missing_id}`) and one with no child states that carries an `initial` (`{:initial_on_atomic_state, nil}`); both documents used to validate and `Statifier.compile/2` raised `KeyError`.
