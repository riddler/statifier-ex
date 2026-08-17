### Changed

- Every core effect struct now carries a `round` field alongside
  `macrostep`/`microstep`, matching the trace effects and `BudgetExhausted`.
  Consumers reading `round` off the subscriber stream or a telemetry event's
  `effect` metadata now get it uniformly; code that builds a core effect
  literal to hand to `Statifier.Session.interpret/2` must supply `round`.
