### Added

- `Statifier.Effect.Invoke` and `Statifier.Effect.CancelInvoke` gain
  `caller_context :: term()` (default `nil`), stamped by the core from the
  current macrostep's triggering external event - ADR-0063's carrier list
  widened to the invoke seam. An asynchronous invoke handler stores the
  term with its own invocation record and puts it back on the result event,
  which is what lets a result arriving minutes later be linked to the trace
  that started the invocation. The library never reads the value.
- `[:statifier, :session, :effect, :invoke]` and
  `[:statifier, :session, :effect, :cancel_invoke]` gain a `caller_context`
  metadata key, matching the `:send_delayed` and `:cancel` events.

### Changed

- `Statifier.Session.Recording.format_version/0` bumps `3 -> 4`, because a
  recording's stored invoke-lifecycle effects change shape.
  `from_binary/1` still reads version 1, 2, and 3 blobs, defaulting
  `caller_context: nil` onto the stored structs that predate the field.
