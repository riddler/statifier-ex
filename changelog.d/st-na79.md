### Added

- `Statifier.MachineState` gains `last_selection`: `Statifier.Interpreter.handle_event/2` sets it to `:selected` when the event selected at least one transition and `:none` when it selected none, with or without tracing; it is `nil` before any external event, and a position restored with `Statifier.Position.from_binary/2` reads `nil` because the blob does not carry it.
