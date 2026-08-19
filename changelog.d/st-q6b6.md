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
- `Statifier.Position`'s persisted format moves to version 2, which adds
  `ordinal`. A host reading a stored version-1 `Position` keeps working -
  version 1 is read, not refused - and new saves write version 2.
