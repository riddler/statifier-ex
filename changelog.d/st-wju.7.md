### Added

- `Statifier.compile/1` compiles SCXML source straight to a `Statifier.Machine`,
  running the parse, lowering, validation, and compile stages in order and
  stopping at the first stage that fails. Failures from every stage are
  reported the same way: `{:error, [error]}`.
