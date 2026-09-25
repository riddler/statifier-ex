### Added

- `Statifier.Publish.findings/2` reports row S16: a cycle of eventless transitions none of which carries a `cond` (`:eventless_cycle`), at the location of the transition taken from the cycle's first state with `data: %{states: [id]}`, before the macrostep spends its round budget at run time.
