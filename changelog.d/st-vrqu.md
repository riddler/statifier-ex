### Added

- `Statifier.Invoke.SyncHandler`: a two-callback shape (`invoke_types/0`,
  `handle/3`) for `<invoke>` handlers that answer a call and report the result.
- `Statifier.Invoke.SyncHandler.Adapter`: `use` it over a list of sync handlers
  to get the `Statifier.Invoke.Handler` implementation plus the
  `:known_invoke_types` list and the `:invoke_handlers` map a host registers.
- `Statifier.Invoke.Types.from_handlers/1`: builds the registered-type snapshot
  from an `:invoke_handlers` map's own keys.
