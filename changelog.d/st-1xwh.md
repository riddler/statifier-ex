### Added

- `Statifier.Effect.DatamodelInit` joins the core effect vocabulary as
  `{:datamodel_init, %Statifier.Effect.DatamodelInit{}}`, carrying the
  datamodel's starting map, and `[:statifier, :session, :effect,
  :datamodel_init]` joins the published `:telemetry` event names.
- Every `<data>` binding - early or late - now emits a
  `{:datamodel_change, %Statifier.Effect.DatamodelChange{}}` naming a new
  `d_index` field, the `<data>` element's own compiler-assigned identity
  (mutually exclusive with the existing `c_index`). A failed or
  environment-overridden binding emits nothing, matching the existing
  write-side rule. `metadata.location` for a binding resolves through
  `Statifier.Machine.data/2`.
