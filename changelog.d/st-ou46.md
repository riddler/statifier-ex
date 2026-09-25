### Added

- `Statifier.Publish.findings/2` reports row S14: a `<send>` whose literal `delay` is not a duration the engine can resolve (`:invalid_delay`), at the `delay` attribute's location with `data: %{delay: delay}`, before the runtime refuses the send.
