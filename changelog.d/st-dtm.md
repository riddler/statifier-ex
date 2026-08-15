### Added

- `Statifier.Session.start_link/2` accepts `record: true` to capture every
  delivered event, timer firing, cancel marker, and `interpret/2` batch a
  session handles, in input order.
- `Statifier.Session.recording/1` returns the captured
  `Statifier.Session.Recording.t()`, or `{:error, :not_recording}` if the
  session was not started with `record: true`.
- `Statifier.Replay.run/1` replays a `Statifier.Session.Recording.t()` through
  the pure core with no process and no timer, reproducing the original run's
  effect stream and terminal `%Statifier.MachineState{}`.
