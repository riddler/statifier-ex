### Added

- `Statifier.Session.invocations/1` lists a session's live invocations as `%{invoke_id, session_id, pid}`, sorted by `invoke_id`.
- `Statifier.Session.start_link/2`'s `:inherit_observers` option (default `false`) starts every child a session starts for an `<invoke>` with that session's `:trace` setting and subscriber pids, plus `inherit_observers: true` of its own, so one opt-in at the root traces the whole invoke tree transitively.
