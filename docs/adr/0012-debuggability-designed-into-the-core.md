# ADR-0012: Debuggability is designed into the core

Status: accepted (2026-08-04)

## Context

We eventually want tooling that steps through a running state chart at macrostep
and microstep granularity - an interactive debugger, live visualization, time
travel. That tooling is explicitly not being built now. The risk is that the
interpreter, written without these consumers in mind, fuses away the seams they
need: microstep state living only on the call stack, source locations dropped at
compilation, trace points that would have to be retrofitted into a finished
Appendix D port. Each seam is cheap while the code is being written and
expensive to recover afterwards.

The architecture already does most of the work. A pure
`(machine_state, event) -> {machine_state, [effect]}` core (ADR-0003) is
inherently steppable and replayable, and the function-per-pseudocode-block port
(ADR-0002) naturally exposes `select_transitions`, `compute_exit_set`, and
friends as callable queries. What remains is a short list of constraints on how
that code is shaped.

## Decision

The interpreter is built to the constraints in `docs/observability.md`, which
this ADR makes binding. In summary:

1. **Microsteps are resumable values.** The machine_state struct fully reifies
   the between-microsteps position (configuration, internal queue, datamodel,
   running flag, history, step counters). A macrostep is a fold over a
   `microstep` step function; mid-macrostep state never lives only in loop
   variables or on the call stack.
2. **Trace is part of the effect vocabulary.** Structured trace effects are
   emitted at the phase boundaries Appendix D itself names (event dequeued,
   transitions selected, exit set, executable content, entry set, macrostep
   stable, done), gated by an option so the untraced hot path pays nothing.
   Debuggers and visualizers are effect interpreters, not core hooks.
3. **The Machine retains source locations and stable identities.** Compilation
   keeps locations on states, transitions, and executable content, and assigns
   document-order indexes to transitions and executable-content nodes so trace
   effects can name them and tooling can map them back to source.
4. **Steps are counted and causes are stamped.** machine_state carries monotonic
   macrostep/microstep counters; trace effects and internally raised events
   (e.g. `error.execution`) carry the step and the identity of what raised them.

No stepper API, debug protocol, or UI is built now. Items 1-4 are constraints
on code being written anyway.

## Consequences

- Future step tooling attaches to existing seams: the public microstep
  boundary, the trace effect stream, and the pure Appendix D queries. No core
  rework, no instrumentation pass.
- Deterministic replay stays a property of the session boundary: (machine,
  initial data, external event log) reproduces a run, and step counters give
  every trace an ordering key.
- The core carries modest permanent weight: locations and indexes on Machine,
  counters on machine_state, and a trace-gate check per phase boundary.
- Interpreter code review gains a checklist item: a change that moves microstep
  state off the struct, drops locations in the compiler, or raises an internal
  event without cause metadata violates this ADR.
