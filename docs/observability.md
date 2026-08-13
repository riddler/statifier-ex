# Observability

How the core is shaped so that future step-level tooling - an interactive
debugger, live visualization, deterministic replay, time travel - can attach to
it without rework. ADR-0012 makes these constraints binding; this document is
the detail. The tooling itself is out of scope for now; everything below is a
constraint on code being written anyway, not a feature.

Read alongside `docs/architecture.md`. ADR-0002 (literal Appendix D port),
ADR-0003 (pure core with effects), and ADR-0005 (full configuration, interned
indexes) are the load-bearing decisions; this page is about not fusing away the
seams they create.

## Vocabulary

- **Microstep**: one round of the Appendix D inner loop - select a transition
  set for the current event (or eventless), exit states, execute content, enter
  states.
- **Macrostep**: microsteps run to quiescence - the outer loop iteration that
  consumes one external event and drains eventless transitions and the internal
  queue until the configuration is stable.

Step tooling wants to pause at both boundaries; visualization wants the trace
of what happened inside each.

## Constraint 1: the microstep boundary is a resumable value

Appendix D's `main_event_loop` runs microsteps to quiescence in a loop whose
state (current event, internal queue position) is local. Ported literally as
one recursive function, "paused between microsteps" would exist only on the
call stack and a stepper could not stop there.

Instead:

- The machine_state struct reifies everything the spec holds in globals or loop
  variables: configuration, internal event queue, history values, datamodel,
  `running` flag, and the step counters from constraint 4. Any machine_state
  value is a complete, inspectable, resumable position.
- `Statifier.Interpreter.microstep/1` -
  `microstep(machine_state) -> {machine_state, [effect]} | :quiescent` - is the
  unit of progress, and `Statifier.Interpreter.macrostep/1` is a fold over it.
  The fold function started private (`macrostep/2`) and is trivially
  publishable through `macrostep/1` - no fused loop needed dismantling.
- This does not conflict with the literal port: the pseudocode's functions map
  one-to-one; only the *storage* of loop state moves onto the struct, and that
  deviation gets its mechanical-reason comment per ADR-0002.

The payoff: a step debugger is `microstep/1` in a REPL; pausing, inspecting,
and resuming need no support code in the core.

## Constraint 2: trace events are effects

ADR-0003 already returns log entries as effect data. Trace extends the same
vocabulary: structured effects emitted at the phase boundaries Appendix D
names, so a debugger or visualizer is just another effect interpreter.

Minimum trace vocabulary (shapes settled at implementation, the set is the
commitment):

| Trace effect | Emitted when |
|---|---|
| event dequeued | an external or internal event is selected for processing |
| transitions selected | either selection function returns (includes the empty set) |
| exit set | `compute_exit_set` result, before exiting |
| content executed | a block of executable content ran (with its identity, constraint 3) |
| entry set | `compute_entry_set` result, before entering |
| macrostep stable | the configuration reached quiescence |
| done | top-level final entry / `exit_interpreter` |

Rules:

- Emission is gated by an interpreter/machine option (working name
  `trace: true`); the untraced hot path allocates nothing for trace.
- Trace effects carry the step counters (constraint 4) and identities
  (constraint 3), never bare structs that force tooling to re-derive context.
- Trace effects are ordinary members of the effect list - same ordering
  guarantees, same delivery path. No side channel.
- "Either selection function" is `select_eventless_transitions/1` and
  `select_transitions/2` both, with no exception - including the terminal
  eventless probe that ends a macrostep, which is why the round reporting
  quiescence carries an effect list of its own rather than being a bare
  atom.

## Constraint 3: the Machine retains locations and identities

The Document layer carries source locations and compiled expressions keep their
source string alongside predicator's compiled envelope, which carries the span
table with the instructions (`{:compiled, %Predicator.Compiled{}, source}`, per
ADR-0014 item 2). The place this is lost by
default is the compiler pass, because the runtime does not need locations. Keep
them anyway:

- States, transitions, and executable-content nodes on the Machine retain their
  source location. A visualizer highlighting the `<transition>` line currently
  executing needs nothing else.
- SCXML transitions and executable content have no IDs, so the compiler assigns
  each a stable document-order index (per machine). Trace effects and error
  metadata reference these indexes; tooling maps them back to locations.
- Locations and indexes are compile-time-immutable Machine data - no runtime
  cost beyond memory, no invalidation story.
- Expression-level locations are in scope, not just SCXML element locations:
  compiled expressions retain predicator's span side table alongside the
  instructions, so an expression failure names the failing subexpression, not
  just the owning transition. Shape and sequencing are settled by ADR-0014
  (spans, `on_unbound: :error`, table travels with the instructions).

## Constraint 4: steps are counted, causes are stamped

- machine_state carries monotonic counters: macrostep number, microstep
  number within the macrostep, and round number within the macrostep's fold.
  They advance in exactly one place each, and `begin_macrostep/1` resets both
  child counters (`microstep` and `round`) when it advances `macrostep`
  (ADR-0020).
- Every trace effect is stamped with the counters - the ordering key for any
  timeline UI or log merge.
- Internally raised events carry cause metadata: which transition or
  executable-content node (by constraint-3 identity) raised them, at which
  step. The first consumer is a better `error.execution` - "raised by the
  `<assign>` at line 42, transition 7, microstep 3" - which pays for the field
  before any debugger exists.

## Constraint 5: the pure queries stay callable

The function-per-pseudocode-block structure of ADR-0002 is itself the debug
API: `select_transitions(machine_state, event)` answers "what would happen if
event X arrived" without stepping, and `compute_exit_set` / `compute_entry_set`
preview a transition's effect on the configuration. The constraint is only:
these functions take and return plain values (no hidden context), and they are
not inlined or fused in a way that makes exposing them later a refactor. They
may start private; `defdelegate` from a debug module later is the intended
promotion path.

## Constraint 6 (session layer, later): observe and record at the boundary

Nothing to build until `Statifier.Session` lands, but two properties to
preserve when it does:

- **Observation**: the session forwards its effect/trace stream to
  `:telemetry` or a subscriber pid. Live tooling attaches there; the core is
  untouched.
- **Replay**: because the core is pure and timers are effects, recording the
  external inputs (delivered events, timer firings, with session timestamps) at
  the session boundary makes a run reproducible: (machine, initial data,
  external event log). Keep the session's input path single and capturable -
  no side doors that inject events without crossing the recordable boundary.

## Non-goals (for now)

- No stepper API, breakpoint model, debug protocol, or wire format.
- No visualization or UI of any kind.
- No trace persistence/rotation story - trace effects are handed to the effect
  interpreter and are its problem.
- No performance work on tracing beyond the emission gate.

## Where the seams live

| Seam | Where it lives |
|---|---|
| machine_state struct holds configuration, internal queue, history, datamodel, `running`, and step counters - no interpreter loop variable that is not reconstructible from the struct | `Statifier.MachineState` |
| `microstep` step function exists; macrostep folds over it | `Statifier.Interpreter` |
| trace effect types defined with the vocabulary above; emission gated | `Statifier.Effect`, `Statifier.Effect.Trace.*` |
| compiler retains locations on states, transitions, executable content | `Statifier.Compiler`, `Statifier.Machine.State`/`Transition`/`Content` |
| compiled expressions carry their span table with the instructions (ADR-0014) | `Statifier.Compiler.Expressions.compile/3` stores `%Predicator.Compiled{}` whole |
| compiler assigns document-order indexes to transitions and executable-content nodes (`t_index`/`c_index`, dense from 0) | `Statifier.Compiler` |
| internally raised events carry cause metadata (identity + step) | `Statifier.Event.Cause`, `MachineState.raise_internal/4` |
| Appendix D query functions take/return plain values, unfused | `Statifier.Interpreter.Selection`, `Statifier.Interpreter.ExitEntry`, `Statifier.Interpreter.Content` |
