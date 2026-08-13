### Added

- `<datamodel>` / `<data>` are now supported, with both `binding="early"` and
  `binding="late"` respected: a `<data>`'s `expr` or child content is compiled
  and, under early binding, evaluated at document-initialization time; under
  late binding, evaluation is deferred until the owning state is entered.
