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
- `<param>` under `<donedata>` now compiles and evaluates: each `<param>`'s
  `expr` or `location` attribute compiles through the same value-expression
  path, and at done time the params fold in document order into a
  string-keyed map via `Statifier.EventData.coerce({:params, _})` - a
  duplicate name takes the last value, and a `<donedata>` with no surviving
  params carries `nil` data, not `%{}`. A param whose expression fails to
  evaluate raises its own `error.execution` and is dropped from the result
  rather than aborting the remaining params (spec 5.7's "MUST ignore the
  name and value"). The `done.state.*` event and the terminal `Effect.Done`
  both carry the same folded map.
