### Added

- `Statifier.Effect.SendDelayed` and `Statifier.Effect.Cancel` gain an
  `ordinal` field: a per-execution sequence number minted from
  `Statifier.MachineState`'s new session-global `timer_counter`, which
  starts at `0` and never resets. It is what disambiguates two `<foreach>`
  iterations that execute the same `<send delay>` or `<cancel>` content
  node, in the same microstep, under the same author-written id - a
  durable host's at-least-once dedup key now reads
  `{session scope, send_id, macrostep, microstep, round, c_index, owner,
  ordinal}`, eight components instead of seven. `[:statifier, :session,
  :effect, :send_delayed]` and `[..., :cancel]` both carry `ordinal` in
  their telemetry measurements.

### Changed

- `ordinal` is enforced on both effect structs, so code that *builds* a
  `%Statifier.Effect.SendDelayed{}` or `%Statifier.Effect.Cancel{}` by
  hand - test fixtures and durable-scheduler harnesses, mostly - must now
  pass it. Pattern matching on either struct is unaffected. Where a
  hand-built effect only needs to be distinct from its neighbours, any
  positive integer will do; where it stands in for one the engine
  produced, use the `ordinal` the engine stamped.
