### Added

- `Statifier.Session.HaltNotice`: a send processor that holds a delay in a process it starts from `perform/2` can hand that process to `HaltNotice.watch/2`, and the session sends it `{:statifier_halted, session, reason}` when the session halts (`:done`, `:cancelled` or `:budget_exhausted`), at once when it already has, without ever calling it. `HaltNotice.take/1` removes and returns the processes watched under a key, and the session forgets each one when it ends. Outside a session `watch/2` keeps nothing and answers `:not_a_session`. A session that registers nothing sees nothing new.

### Changed

- A `Statifier.Send.BasicHTTP` delayed send whose transport raises now reaches the sender as `error.communication`, through `Statifier.Session.failed_send/3` with the reason `{:raised, exception}`; before, the raise ended the timer and nothing reached the chart. An immediate send whose transport raises is unchanged.
- A `Statifier.Send.BasicHTTP` delayed send of a live session that is busy when the delay passes is now POSTed; before, the timer asked the session for its status and dropped the send when the call timed out.
- A cancel that a `Statifier.Send.BasicHTTP` delayed send's timer has received before its POST now always wins; before, a cancel that arrived while the timer was checking its session could be ignored and the send POSTed.

### Fixed

- A `Statifier.Send.BasicHTTP` delayed send's timer no longer stays in the session's process dictionary after it fires. A delayed send performed outside a `Statifier.Session` is still discarded, now with no call sent to the process that performed it. A session halted `:done`, `:cancelled` or `:budget_exhausted`, or stopped, still discards a delayed send it holds.
