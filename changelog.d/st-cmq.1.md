### Added

- `Statifier.Session` emits `:telemetry` events for its effect and trace
  stream - lifecycle, macrostep spans, and per-effect events, all prefixed
  `[:statifier, :session, ...]`. `Statifier.Session.Telemetry.events/0`
  enumerates every event name a session can emit, and its moduledoc is the
  full measurement/metadata reference.
