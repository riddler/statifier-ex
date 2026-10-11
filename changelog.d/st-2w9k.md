### Fixed

- `Statifier.Session.cancel/1` sent to a session halted `:budget_exhausted` with events queued (by `Statifier.Session.send_event/2`, or by a delayed send to the session itself fired after the halt) now reaches it and halts it `:cancelled`, discarding the queued events, so `{:halted, :cancelled}` follows the budget halt as the session's documentation promises; the cancel used to stay queued behind those events and the session stayed `:budget_exhausted`. A session halted `:done` or `:cancelled` is unchanged.
