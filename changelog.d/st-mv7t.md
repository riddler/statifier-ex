### Fixed

- An `<invoke>` whose type is absent from a registered set the caller *did*
  declare is now refused by `Statifier.Interpreter` itself: it raises
  `error.execution` and emits no `Statifier.Effect.Invoke`, instead of
  emitting one that `active_invocations` never recorded. A host driving the
  pure core without `Statifier.Session` - a durable stepper, say - previously
  received that effect, had every answer it fed back discarded by the spec's
  6.4.3 liveness read, and parked the run with no error surfaced. The event
  raised is the one `Statifier.Session` already raised for this case, so a
  session-driven chart sees no change beyond the effect no longer appearing
  ahead of it. A caller that declared no `:invoke_types` at all is unaffected:
  its `<invoke>` still emits its effect exactly as before (ADR-0051, amended).
