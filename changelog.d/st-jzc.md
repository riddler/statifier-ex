### Added

- `Statifier.Machine.warnings` carries the validator's non-fatal findings on
  a successfully compiled machine.

### Changed

- `Statifier.Validator.validate/2` returns a third element, a list of
  non-fatal warnings, on both its `{:ok, ...}` and `{:error, ...}` arms.
