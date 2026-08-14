### Changed

- `<log expr>` is now evaluated against the datamodel; a failed evaluation
  raises `error.execution` instead of logging `nil`.
