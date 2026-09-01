### Added

- `Statifier.Session.start_link/2`'s `:inherit_invoke_handlers` option: when
  `true`, every child session started for an `<invoke>` boots with this
  session's `:invoke_handlers` map and the flag itself, so a nested chart can
  resolve the handlers the root registered. Defaults to `false`, which starts
  children with an empty registry as before.
