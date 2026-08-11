### Changed

- With tracing on, an empty executable-content block (an `<onentry/>` or
  `<onexit/>` with no children) now emits a `Trace.ContentExecuted` effect
  with `c_indexes: []`, so a trace consumer can tell it ran with no content
  apart from a block that never ran at all. Untraced runs are unaffected.
