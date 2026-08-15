### Changed

- `Statifier.Event`'s `data` default moves from `nil` to `:undefined`, and an
  environment-supplied `:datamodel` value of `nil` now means predicator's
  null rather than "declared, no value yet" - pass `:undefined` for that.
