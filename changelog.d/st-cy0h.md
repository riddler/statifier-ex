### Added

- `Statifier.Publish.findings/2` reports row S2: a `<send>` with a built-in or absent `type` whose literal `target` the engine cannot parse (`:invalid_target`), at the send's location with `data: %{target: target}`, before the runtime refuses the send.
