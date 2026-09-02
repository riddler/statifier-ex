### Fixed

- An invoked child that reaches a top-level final now gets both of the
  events it returns delivered to its parent, in order: whatever its exiting
  states' `<onexit>` handlers sent to `#_parent`, and then its own
  `done.invoke.<invokeid>`. Previously, when the first of those drove the
  parent out of the invoking state, the parent cancelled the invocation and
  dropped the `done.invoke` the child had already returned - so a chart
  waiting on the child's completion stalled. Spec 6.4.3 conditions that
  cancel on the parent exiting the invoking state *before* it receives the
  done event, which a parent moved by the child's own farewell has not
  done. W3C conformance test236 passes and joins the regression registry.
