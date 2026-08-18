### Fixed

- A `<send>` whose target names a session, parent, or invocation that is
  not reachable now raises `error.communication` at the `<send>`'s own
  position, carrying its `sendid`, and the rest of the enclosing block does
  not run (spec 4.9, C.1). A target that becomes unreachable after the block
  has run still raises the error afterwards, as before.
