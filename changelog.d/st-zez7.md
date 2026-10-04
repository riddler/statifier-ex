### Changed

- `Statifier.Validator.validate/2`, and so `Statifier.compile/2`, refuses an `initial` attribute or an `<initial>` element on a compound state with no `id` whose target is outside that state, as `{:initial_not_descendant, target, nil}`: such a chart validated, and `Statifier.compile/2` raised `KeyError`.
