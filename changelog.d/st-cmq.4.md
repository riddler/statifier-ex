### Added

- `Statifier.Session` is a new GenServer that runs a state chart to
  completion: `start_link/2` starts one, `send_event/2` delivers events
  asynchronously, `interpret/2` hands it externally-produced effects,
  `cancel/1` stops it as `<cancel>` would, `snapshot/1` and `status/1` read
  its current position, and `subscribe/2`/`unsubscribe/2` manage the
  subscriber pids that receive its effect stream.
