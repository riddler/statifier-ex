### Fixed

- A session reaching its top-level final (or being cancelled) now discards its
  own pending delayed sends at the halt, per spec 6.2, instead of leaving the
  timers armed on the idled process - previously a delayed `<send>` scheduled
  before termination still fired and delivered to a live cross-session target.
  `:budget_exhausted` keeps its timers armed until a later `cancel/1`, since
  the interpreter has not exited there.
