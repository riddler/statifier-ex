### Changed

- A `<send>` or `<invoke>` whose `namelist` attribute contains a
  syntactically ill-formed location expression now loads successfully
  through `Statifier.compile/1` instead of failing the whole document.
  The malformed entry is caught when the element runs: a `<send>` discards
  the message and an `<invoke>` aborts, each raising `error.execution`, per
  ADR-0036 and ADR-0031.
