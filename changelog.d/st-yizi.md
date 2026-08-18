### Fixed

- A `<send>` with an unsupported `type` or an unroutable, non-`#_`-prefixed
  `target` now aborts the rest of its executable-content block, per spec
  5.7: the remaining `<send>`, `<assign>`, and other elements in the same
  `<onentry>`/`<onexit>`/transition block no longer run before the
  `error.execution` event arrives. The raised `error.execution` carries the
  failing send's `sendid`.
