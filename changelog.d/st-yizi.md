### Fixed

- A `<send>` whose `type` is unsupported, or whose `target` names none of
  the special targets C.1 defines, is now rejected while the element is
  evaluated rather than after its block has run. The rest of the enclosing
  `<onentry>`/`<onexit>`/transition block no longer executes, per spec 4.9,
  and the raised `error.execution` carries the failing send's `sendid`.
