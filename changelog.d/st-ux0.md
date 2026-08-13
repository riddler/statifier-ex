### Added

- A trace of a macrostep that never reaches quiescence can now be ordered and
  counted: `%Statifier.MachineState{}` carries a `round` counter, and the
  `Statifier.Effect.Trace.*` payloads, `%Statifier.Event.Cause{}`, and
  `%Statifier.Effect.BudgetExhausted{}` are stamped with it.
