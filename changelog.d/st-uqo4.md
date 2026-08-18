### Added

- `Statifier.Session.subscribe/3` with `catch_up: true` returns the session's
  recording alongside the subscription, so a pid that attached after
  `start_link/2` can rebuild the effects it missed with
  `Statifier.Replay.run/1`. Requires `record: true`; otherwise returns
  `{:error, :not_recorded}` and does not subscribe.
