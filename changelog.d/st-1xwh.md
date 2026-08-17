### Added

- `Statifier.Effect.DatamodelInit` joins the core effect vocabulary as
  `{:datamodel_init, %Statifier.Effect.DatamodelInit{}}`, carrying the
  datamodel's starting map, and `[:statifier, :session, :effect,
  :datamodel_init]` joins the published `:telemetry` event names.
