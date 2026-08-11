### Added

- `Statifier.compile/1` compiles SCXML source straight to a `Statifier.Machine`,
  running the parse, lowering, validation, and compile stages in order and
  stopping at the first stage that fails. Failures from every stage are
  reported the same way: `{:error, [error]}`.
- `Statifier.initialize/2` runs a compiled `Statifier.Machine`'s
  initialization macrostep to quiescence, `Statifier.send_event/2` sends one
  event to a `Statifier.MachineState` and runs a macrostep to quiescence
  (accepting either a `Statifier.Event` or a plain name string), and
  `Statifier.active_leaf_states/1` reads the active leaf configuration back
  as a `MapSet` of string ids. Together with `compile/1` these are the
  library's whole four-function public surface (ADR-0006).
