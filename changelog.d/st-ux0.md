### Added

- `%Statifier.MachineState{}` carries a `round` counter, and the seven
  `Statifier.Effect.Trace.*` payloads, `%Statifier.Event.Cause{}`, and
  `%Statifier.Effect.BudgetExhausted{}` are stamped with it, so the rounds of
  a macrostep that never reaches quiescence can be ordered and counted in a
  trace.
