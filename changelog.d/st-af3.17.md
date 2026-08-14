### Added

- `<script>` is now supported: a body is a predicator statement program,
  compiled at load and run against the session datamodel wherever executable
  content or a top-level child of `<scxml>` may appear. `<script src>` is
  rejected at load; a body outside predicator's statement grammar (`var`,
  compound assignment, object literals, `typeof`, function definitions) is
  deferred to runtime and raises `error.execution` when reached.
