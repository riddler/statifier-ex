### Added

- `Statifier.Event`, `Statifier.Effect.SendDelayed`, and
  `Statifier.Effect.Cancel` gain an opaque `caller_context :: term()` field
  (default `nil`, ADR-0063). A host attaches a correlation value - an OTel
  span context, a request id - via `Statifier.Event.external(name,
  caller_context: ctx)`; the library copies it onto the durable-timer
  effects and onto the events a scheduled timer later delivers, and never
  reads it.
- Four telemetry events gain a `caller_context` metadata key:
  `[:statifier, :session, :macrostep, :start]` and `[..., :stop]` (the
  triggering external event's slot, `nil` for the other triggers), and
  `[:statifier, :session, :effect, :send_delayed]` and `[..., :cancel]`
  (the effect's own slot).

### Changed

- `Statifier.Session.Recording` blobs are format version 3: the structs
  stored in `entries` now carry `caller_context`. Version-1 and version-2
  blobs still decode, defaulting `caller_context: nil` onto each stored
  event and durable-timer effect on import.
