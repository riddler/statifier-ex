### Added

- `Statifier.Invoke.Answer`, a public, pure module with `done/3` and
  `failed/3`: the two events that end a handler-backed invocation -
  `done.invoke.<invoke_id>` (ADR-0051 decision 5) and
  `error.communication.invoke.<invoke_id>` (ADR-0068) - built as plain
  `Statifier.Event.t()` values, for a host driving `Statifier.Interpreter`
  directly with no `Statifier.Session` process to hand
  `done_invocation/3` or `failed_invocation/3`. The two session doors call
  through this same module, so a live session's events and a process-less
  host's are byte-identical for the same arguments. The 6.4.3 discard of an
  answer for an already-cancelled invocation stays the process-less host's
  own check, against its own record of which invocations are live.
- `docs/persistence.md` gains "Answering an invocation with no session
  process" - the recipe, the liveness obligation, and where the payload
  rules live; `docs/extending.md`'s "Reporting permanent failure" points at
  it. Recorded as a dated decision note on ADR-0068, which had named this
  gap as its own reopening trigger for both events at once.
