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
- `<param>` under `<donedata>` now lowers, instead of being rejected as an
  unsupported element: its `name`, `expr`, and `location` attributes land
  on a new `Statifier.Document.Param`, in document order, on
  `Donedata.params`. Two new validator rules cover it: a `<donedata>` must
  not specify both a `<content>` child and one or more `<param>` children
  (spec 5.5), and each `<param>` must specify exactly one of `expr` or
  `location` (spec 5.7). Nothing evaluates `<param>` yet - the values are
  inert until a later phase compiles and evaluates them into the done
  event's data.
