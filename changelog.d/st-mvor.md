### Added

- `Statifier.Invoke.Answer.done/4` and `failed/4` take a `caller_context:`
  option, so a host driving the interpreter with no session process can carry
  its correlation term onto an invocation's answer event.

### Changed

- `Statifier.Session.done_invocation/3` and `failed_invocation/3` now stamp
  the answer event with the `caller_context` of the event that armed the
  `<invoke>`, instead of leaving it `nil`.
