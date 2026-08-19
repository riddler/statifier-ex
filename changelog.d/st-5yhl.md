### Added

- `Statifier.Session.start_link/2` gains a `:resume` option that boots a
  session at a persisted `Statifier.Position` instead of running
  `Statifier.Interpreter.initialize/2`. In-flight delayed-send timers, live
  invoked children, and the external inbox are not restored; see
  `docs/persistence.md` for why and for the host's remaining obligations.

### Changed

- `Statifier.Session.Recording` blobs are format version 2, carrying an
  optional anchor position for recordings started by a resumed session;
  version 1 blobs still decode.
