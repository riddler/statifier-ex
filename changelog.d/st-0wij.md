### Added

- `Statifier.Publish.findings/2`: one pure publish-time function over a
  compiled chart and the host's declaration (registered send types, invoke
  types, accepted event names), returning a list of findings that each name
  their row of `docs/publish-time-checks.md`. It composes
  `Statifier.Send.Types.unsupported_sends/2` (row S1) and
  `Statifier.Chart.check_accepts/2` (row S15); the rows the table lists as
  NONE land inside it one check at a time.
