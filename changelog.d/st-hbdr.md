### Added

- `Statifier.Testing.Case` and `Statifier.Testing.FeatureDetector` are now
  public API. A downstream application can write declarative chart tests -
  an expected initial configuration, then `{event, expected_configuration}`
  steps - with `use Statifier.Testing.Case`, without copying files out of this
  repository. Documents using an unsupported SCXML feature flunk naming the
  feature rather than skipping. `test_scxml/4` accepts optional
  `:settle_window_ms` and `:configuration_deadline_ms` for charts whose
  load-bearing delays exceed the defaults. See `docs/testing-charts.md`.
