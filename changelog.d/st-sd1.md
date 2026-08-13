### Added

- `Statifier.MachineState.new/2` accepts `:max_macrostep_rounds` (a positive
  integer, default `10_000`, or `:infinity`), bounding one macrostep's fold.

### Fixed

- A macrostep that cannot reach quiescence now returns a
  `{:budget_exhausted, %Statifier.Effect.BudgetExhausted{}}` effect with a
  resumable position instead of hanging the calling process.
