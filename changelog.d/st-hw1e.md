### Changed

- `Statifier.Validator.validate/2` no longer raises `FunctionClauseError` on a `<history>` whose compound parent has no `id`: the default target is checked against the parent by the tree's structure, so a target inside the parent is accepted and one outside it is reported as `{:initial_not_descendant, target, nil}`. The `parent_id` in an `:initial_not_descendant` reason may now be `nil`; a host that matches it as a binary should also handle `nil`.
