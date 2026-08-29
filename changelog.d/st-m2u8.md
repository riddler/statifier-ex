### Fixed

- A session that reaches a top-level `<final>` now terminates with an empty
  internal event queue, so `Statifier.Position.export/1` accepts a finished
  position instead of refusing it with `{:error, :internal_queue_not_empty}`
  whenever a sibling `done.state.*` event was still queued.

### Changed

- A `<donedata>` expression that fails to evaluate at a top-level `<final>`
  no longer leaves its `error.execution` on the terminated machine state's
  internal queue; `Statifier.Effect.Done`'s `donedata: :undefined` is the
  signal that the expression failed.
