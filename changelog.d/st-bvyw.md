### Added

- `Statifier.Publish.findings/2` reports row S9 of `docs/publish-time-checks.md`: an `<invoke>` of the built-in `scxml` type whose inline `<content>` does not compile as a child chart (`:child_does_not_compile`, `data: %{errors: errors}`) or reads as a value rather than markup, `null` included (`:content_not_markup`, `data: %{content: value}`), at the `<invoke>`'s location, before the child fails to start at run time.
