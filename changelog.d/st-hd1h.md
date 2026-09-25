### Added

- `Statifier.Publish.findings/2` reports row S6 of `docs/publish-time-checks.md`: an `<invoke>` whose literal `type` the declared `invoke_types:` does not register (with no declaration, any type outside the built-in `scxml` set), as kind `:unregistered_invoke_type` at the `<invoke>`'s location with `data: %{type: type}`, before the invocation is refused at run time.
