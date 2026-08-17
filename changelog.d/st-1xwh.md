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
- The starting datamodel is now fully reconstructable from the effect stream
  alone, with no `Session.snapshot/1` call and no `%Machine{}` handle: a
  subscriber folds the one `:datamodel_init` baseline and every
  `:datamodel_change` after it and reproduces every datamodel key exactly,
  except `"_event"` (spec 5.10's current-event-under-evaluation, not
  authored or assigned content). This holds under both `binding="early"` and
  `binding="late"`, for an environment-supplied `:datamodel` option
  (including one that shadows a top-level `<data>`), and with `trace: false`
  - both effects are core.
