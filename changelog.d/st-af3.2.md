### Added

- A transition's `cond` attribute is evaluated against the datamodel and
  gates whether the transition is selected: `true` enables it, `false` does
  not.
- A `cond` that fails to evaluate to `true` or `false` (an unbound variable,
  or any other non-boolean result) raises `error.execution` on the internal
  event queue instead of silently not enabling the transition, catchable in
  the same macrostep by a `<transition event="error.execution">` on the
  currently active state.
