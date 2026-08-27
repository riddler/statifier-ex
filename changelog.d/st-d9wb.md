### Added

- `Statifier.Session.failed_invocation/3`, the failing counterpart to
  `done_invocation/3`: the door a host uses to report that an async
  `<invoke>` handler's work has failed permanently, once its own retry
  policy is exhausted. It delivers `error.communication.invoke.<invokeid>`
  on the same invocation-tagged entry as `done.invoke.<invokeid>`, under the
  same spec 6.4.3 drain-time discard, carrying `reason`, `attempts`, and
  `detail` in the event data. Without it, a chart that models
  operator-recovery parking never heard about permanent failure and the run
  waited in its invoking state forever. See ADR-0068 and
  `docs/extending.md`'s "Reporting permanent failure".

### Changed

- A chart with a `<transition event="error.communication">` (or the broader
  `event="error"`) now also catches an async invocation's permanent failure,
  because the new event name is a spec 3.12.1 suffix extension of
  `error.communication` and the event-descriptor prefix rule matches it.
  This is the intended reach of ADR-0051's existing classification - "a
  registered handler fails to reach its service" was already
  `error.communication` - but a chart relying on that transition firing only
  for `<send>` failures will now see it fire for invoke exhaustion too.
