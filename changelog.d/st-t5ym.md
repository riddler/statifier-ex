### Changed

- Requires `{:predicator, "~> 9.5"}`, where it required `~> 9.4`: the compile-time check that a chart calls only known functions reads each expression's calls through `Predicator.Analysis.calls/1`, which predicator 9.5.0 adds. A host that holds predicator at 9.4 moves to 9.5 with it (`mix deps.update predicator`); every answer `Statifier.compile/2` gives is unchanged.
