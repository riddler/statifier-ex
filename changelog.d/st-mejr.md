### Fixed

- A session halted `:budget_exhausted` that is handed a miss through `Statifier.Session.failed_send/3` now drops it without stepping, as a session halted `:done` or `:cancelled` does, so a miss no longer sends its subscribers another halted message and is the host's dead letter; it used to step the halted chart again and send another halted message for every miss, without end for a chart that re-sends on each one. A session halted `:done` or `:cancelled` is unchanged.
