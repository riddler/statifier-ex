### Added

- `Statifier.Publish.findings/2` reports row S3 of `docs/publish-time-checks.md`: a `<send>` with a built-in type whose literal `#_<invokeid>` target names no `<invoke id>` in the chart, as kind `:unreachable_target` with `data: %{target: target}`, before the send is refused at run time.
