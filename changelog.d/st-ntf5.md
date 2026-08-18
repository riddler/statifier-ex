### Added

- `Statifier.Effect.Trace.EntrySet` and `Statifier.Effect.Trace.ExitSet`
  gain a `configuration` field: the full configuration (ancestors included)
  as it stands after the entry set or exit set the payload names has been
  applied, so a subscriber can render the active configuration after every
  microstep without folding `indexes` deltas itself. At
  `Statifier.Interpreter.exit_interpreter/1`'s termination sweep,
  `ExitSet.configuration` is the empty set; `Trace.Done.configuration`
  still carries the configuration as it stood at exit.
