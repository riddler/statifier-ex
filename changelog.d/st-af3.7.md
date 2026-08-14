### Added

- `Statifier.EventData.coerce/1`: one normalization function that turns raw
  `<content>` text, a `<param>` list, or an already-evaluated expression
  value into `_event.data`, per spec B.2.8.1.

### Changed

- `<log expr>` is now evaluated against the datamodel; a failed evaluation
  raises `error.execution` instead of logging `nil`.
- `<donedata><content>` now evaluates: an `expr` attribute is evaluated
  against the datamodel and its value coerced through
  `Statifier.EventData.coerce/1`; a text body is likewise coerced (so
  `<content>21</content>` now yields the integer `21`, not the string
  `"21"`). A failed `expr` raises `error.execution` and the `done.state.*`
  / terminal `Effect.Done` event carries no data, matching spec 5.10.1's
  "leave the field blank" rather than 5.6's empty-string rule for
  `<content>` in other contexts.
