### Added

- `Statifier.compile/2` stamps a content-hash chart identity onto every
  `Statifier.Machine.t()` it produces (`Statifier.Machine.identity/1`).
- `Statifier.Position.to_binary/1` and `from_binary/2` give a `MachineState`
  a versioned binary contract that refuses to load against a chart whose
  identity does not match.
- `Statifier.Position.export/1` and `import/2` let a host migrate a position
  across chart revisions using string state ids.
