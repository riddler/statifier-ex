### Added

- `Statifier.Chart.to_binary/1` and `from_binary/1` give a compiled chart a
  versioned binary contract that carries its SCXML source and recompiles on
  load, never a compiled term.
- `Statifier.Machine.source/1` and `compile_opts/1` expose the source and
  persisted compile options a `Machine` was built from.
