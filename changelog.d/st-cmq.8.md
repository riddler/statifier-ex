### Added

- Hosts can register their own `<invoke>` handlers for types beyond the
  built-in `scxml` (and its long-URI spelling): a new
  `Statifier.Invoke.Handler` behaviour and a per-session
  `invoke_handlers: %{type_string => module}` option on
  `Statifier.Session.start_link/2`. A handler implements three pure planning
  callbacks (`start/2`, `cancel/2`, `forward/3`) and one optional impure
  `perform/2`; the built-in `scxml` handling now runs behind this same
  interface. `perform/2` may be called more than once for the same
  `invoke_id` after a crash and retry, so handlers must be idempotent on it -
  the library performs no deduplication of its own. An `<invoke>` whose type
  names no registered handler still raises `error.execution`, unchanged.
- A new `Statifier.Session.done_invocation/3` reports a non-`scxml`
  invocation's completion back to its owning session, constructing
  `done.invoke.<invoke_id>` from the caller-supplied donedata - the door a
  process-less or externally-run service uses in place of a child session's
  own `done` transition.
