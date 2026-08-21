### Fixed

- `Statifier.Position.to_binary/1` no longer writes `routes` or
  `invoke_types` into the blob, and `Statifier.Position.from_binary/2` now
  blanks both fields to `nil` on decode regardless of what the blob carries.
  A resumed position previously came back with the stale per-drive snapshot
  from whenever it was saved; a host must re-stamp both before the first
  drive, as `Statifier.Interpreter`'s moduledoc already instructed.
