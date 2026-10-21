# Observability

**Read this to:** keep the seams that let step tooling (a debugger, live
visualization, replay, time travel) attach to the core without rework.
**Short version:** six constraints bind code that is written anyway. Keep each
microstep a resumable value, make trace events effects, keep locations on the
Machine, count and stamp steps, keep the pure queries callable, and observe and
record at the session boundary. The tooling itself is out of scope.

Read this page with `docs/architecture.md`. It depends on three decisions, and
it describes how to keep the seams that they create.

Decisions:
[ADR-0012](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0012-debuggability-designed-into-the-core.md)
makes the constraints binding.
[ADR-0002](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0002-literal-w3c-appendix-d-port.md),
[ADR-0003](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0003-pure-core-with-effects.md),
and
[ADR-0005](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0005-full-configuration-and-interned-state-indexes.md)
are the foundation.

## Vocabulary

- **Microstep**: one round of the Appendix D inner loop. It selects a
  transition set for the current event (or eventless), exits states, executes
  content, and enters states.
- **Macrostep**: microsteps that run to quiescence. It is one iteration of the
  outer loop. It consumes one external event. It drains eventless transitions
  and the internal queue until the configuration is stable.

Step tooling must pause at both boundaries. Visualization needs the trace of
what happened inside each.

## Constraint 1: the microstep boundary is a resumable value

Appendix D's `main_event_loop` runs microsteps to quiescence in a loop. The
state of the loop (current event, internal queue position) is local. A literal
port as one recursive function would keep the state "paused between
microsteps" on the call stack only. A stepper could not stop there.

Instead:

- **One struct holds the position.** The machine_state struct holds everything
  that the spec keeps in globals or loop variables: configuration, internal
  event queue, history values, datamodel, `running` flag, and the step counters
  from constraint 4. Any machine_state value is a complete, inspectable,
  resumable position.
- **`microstep/1` is the unit of progress.**
  `microstep(machine_state) -> {machine_state, [effect]} | :quiescent`.
  `Statifier.Interpreter.macrostep/1` is a fold over it.
- **The port stays literal.** The pseudocode's functions map one-to-one. Only
  the storage of loop state moves onto the struct. That deviation gets its
  mechanical-reason comment.

The result: a step debugger is `microstep/1` in a REPL. Pausing, inspecting, and
resuming need no support code in the core.

## Constraint 2: trace events are effects

ADR-0003 already returns log entries as effect data. Trace extends the same
vocabulary. Trace effects are structured effects that the core emits at the
phase boundaries that Appendix D names. A debugger or visualizer is then another
effect interpreter.

The minimum trace vocabulary is below. The shapes are settled at implementation.
The set is the commitment.

| Trace effect | Emitted when |
|---|---|
| event dequeued | an external or internal event is selected for processing |
| transitions selected | either selection function returns (includes the empty set) |
| exit set | `compute_exit_set` result, before exiting |
| content executed | a block of executable content ran (with its identity, constraint 3) |
| entry set | `compute_entry_set` result, before entering |
| macrostep stable | the configuration reached quiescence |
| done | top-level final entry / `exit_interpreter` |
| invoke pass | `run_invoke_pass` finished: the states walked and the invocations it started (`<invoke>`, spec 6.4) |
| finalize/autoforward pass | `apply_invoke_passes` finished for one external event: which invocation(s) it ran `<finalize>` for and which it autoforwarded the event to (spec 6.4/6.5) |
| conds evaluated | either selection function returned having evaluated at least one *written* `cond` through `Statifier.Evaluator`: which transitions were guarded, what each guard answered, and why a failing one failed (`conditionMatch`, spec 5.9.1) |

The last three rows arrived after the first seven. Each is a phase boundary that
Appendix D itself names inside `mainEventLoop`. They do not broaden what counts
as a phase boundary. They fill in rows that the first port did not yet need.

**Why `conds evaluated` exists.** `conditionMatch` is a function that Appendix D
names. Predicator is the datamodel that evaluates the guard, and it emits no
telemetry. Without this row, a guard that failed left no trace anywhere in the
family. The same was true of a guard that quietly disabled a transition that an
author expected to fire. The only exception was the `error.execution` that a
*failing* guard raises.

`Statifier.Effect.Trace.CondsEvaluated` is the engine-side answer. It differs
from "transitions selected" in two ways:

- **One effect per round, not per guard.** The effect carries the evaluations of
  the round as a list, with `size` as its measurement. `exit set`, `entry set`,
  and `transitions selected` use the same list-carrying shape.
- **No effect when the round evaluated nothing.** "Transitions selected"
  includes the empty set because a round always *selects*. A round with no
  written `cond` on any candidate performed no evaluation, so there is nothing
  to report. A `nil` `cond` short-circuits before the evaluator and is not an
  evaluation. The commitment is one entry per Predicator call, and no effect
  when the round made none. A chart that uses no guards pays nothing for this
  row.

Decision: ADR-0040 amendment.

**Rules:**

- **Emission gate.** An interpreter or machine option gates emission (working
  name `trace: true`). The untraced hot path allocates nothing for trace.
- **Stamps.** Trace effects carry the step counters (constraint 4) and
  identities (constraint 3). They never carry bare structs that force tooling to
  re-derive context.
- **One path.** Trace effects are ordinary members of the effect list. They have
  the same ordering guarantees and the same delivery path. There is no side
  channel.
- **Order across batches.** The ordering guarantee holds across batches, not only
  within one. Delivery order to a subscriber is non-decreasing in
  `(macrostep, round)` across the whole run. It matches the order that
  `Statifier.Replay` produces for the same recording.
  - A mid-batch re-entry (ADR-0039) keeps the enclosing macrostep and advances
    `round`. Its effects carry higher rounds than the unsent tail of the outer
    batch.
  - The core queues those effects and drains them after the batch that
    triggered them. It does not deliver them inline. This keeps arrival order
    monotone. Decision: ADR-0044 decision 1.
  - Every effect also carries the counter triple (ADR-0046). A consumer that
    holds a mixed stream whose arrival order was lost can sort it back into
    `(macrostep, round)` order offline. This holds under `trace: false` also.
- **Both selection functions.** "Either selection function" means both
  `select_eventless_transitions/1` and `select_transitions/2`, with no exception.
  This includes the terminal eventless probe that ends a macrostep. The round
  that reports quiescence therefore carries an effect list of its own. It is not
  a bare atom.
- **Exit set and entry set payloads.** These rows carry the *resulting*
  configuration (full configuration, ancestors included), not only the
  `indexes` delta. `configuration` is the configuration after every state named
  by `indexes` has left (exit set) or been added (entry set).
  - The step counters are still stamped from the state at the phase boundary
    that the row names. The table wording "before exiting" and "before
    entering" describes that boundary. Only `configuration` is read after the
    exit or entry.
  - A consumer can render the active configuration after every microstep. It
    does not fold deltas.
  - At `exit_interpreter`, the `configuration` of the exit set is the empty
    set. `Trace.Done` carries the configuration as it stood at exit.

## Constraint 3: the Machine retains locations and identities

The Document layer carries source locations. Compiled expressions keep their
source string next to predicator's compiled envelope. The envelope carries the
span table with the instructions (`{:compiled, %Predicator.Compiled{}, source}`).
The compiler pass is where locations are lost by default, because the runtime
does not need them. Keep them anyway:

- **Element locations.** States, transitions, and executable-content nodes on the
  Machine retain their source location. A visualizer that highlights the
  `<transition>` line that is now executing needs nothing else.
- **Attribute spans.** `Statifier.Machine.State`, `Statifier.Machine.Transition`
  and `Statifier.Machine.Invoke` each carry the `attribute_locations` map of
  their source node verbatim. The moduledoc of `Statifier.Document` holds the
  contract: value spans only, and a key exists only for an attribute that the
  author wrote.
  - A line-highlighting visualizer needs only the element-level location.
  - A consumer with attribute-level hover targets needs the map. Hover targets
    are the `event`, `target`, and `type` of a `<transition>`, or the `id` and
    `initial` of a state.
  - The consumer can instead re-parse the source and join Document nodes to
    Machine identities by location equality. This is sound only while the
    re-parsed bytes match the bytes that built the Machine. Nothing checks that
    (st-9i5r).
- **Indexes.** SCXML transitions and executable content have no IDs. The
  compiler assigns each a stable document-order index (per machine). Trace
  effects and error metadata reference these indexes. Tooling maps them back to
  locations.
- **`<data>` index.** A `<data>` element gets a third document-order index,
  `d_index`, dense from 0. The compiler assigns it with `t_index` and `c_index`
  (`Statifier.Compiler`). `Statifier.Machine.data/2` resolves it back to its
  `%Statifier.Machine.Data{}`, which carries its own `location` and
  `value_location` (st-1xwh).
- **No upkeep.** Locations and indexes are compile-time-immutable Machine data.
  They cost only memory. They need no invalidation.
- **Expression locations.** Expression-level locations are in scope, not only
  SCXML element locations. Compiled expressions retain predicator's span side
  table with the instructions. An expression failure then names the failing
  subexpression, not only the owning transition.

Decision:
[ADR-0014](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0014-expression-spans-in-cond-diagnostics.md)
settles the shape and sequencing (spans, `on_unbound: :error`, the table travels
with the instructions).

## Constraint 4: steps are counted, causes are stamped

- **Counters.** machine_state carries monotonic counters: the macrostep number,
  the microstep number within the macrostep, and the round number within the fold
  of the macrostep. Each advances in exactly one place. `begin_macrostep/1`
  resets both child counters (`microstep` and `round`) when it advances
  `macrostep`.
- **Ordering key.** Every trace effect is stamped with the counters.
  `(macrostep, round)` is the ordering key for any timeline UI or log merge. It
  advances on every round, including rounds that run no microstep. A fold that
  never reaches quiescence is therefore still ordered and countable.
- **`Trace.MacrostepStable`.** A macrostep can carry more than one: one per core
  drive that reached quiescence. A session can re-enter the core mid-macrostep
  (ADR-0039). There is exactly one per `(macrostep, round)`. The last one that
  arrives within a macrostep is the last quiescent point of that macrostep
  (ADR-0044 decisions 1 and 3).
- **`Trace.Done`.** The last quiescent point is not always where the macrostep
  ends. A macrostep that halts ends with `Trace.Done` instead. `Trace.Done`
  follows the final `MacrostepStable`. When the halting drive is the only drive,
  the macrostep has no `MacrostepStable` at all.
- **Cause metadata.** Internally raised events carry cause metadata: which
  transition or executable-content node (by constraint-3 identity) raised them,
  at which step and round. The first consumer is a better `error.execution`, for
  example "raised by the `<assign>` at line 42, transition 7, microstep 3, round
  1". The field pays for itself before any debugger exists.

Decision:
[ADR-0020](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0020-round-ordinal-joins-the-step-counters.md)
covers the counters and the round ordering key.

## Constraint 5: the pure queries stay callable

The function-per-pseudocode-block structure of ADR-0002 is the debug API.
`select_transitions(machine_state, event)` answers "what would happen if event X
arrived" without stepping. `compute_exit_set` and `compute_entry_set` preview the
effect of a transition on the configuration.

The constraints are:

- These functions take and return plain values (no hidden context).
- They are not inlined or fused in a way that makes exposing them later a
  refactor.

They can start private. The intended promotion path is `defdelegate` from a
debug module later.

## Constraint 6: observe and record at the boundary

`Statifier.Session` is *a* session boundary. It is the process that first hosted
one, and every property below is stated against it. But the property belongs to
the logical session, not to the process. A session boundary preserves two
properties: observation and replay.

**Observation.** The session forwards its effect and trace stream to every
subscriber pid as `{:statifier, session_id, {:effect, effect}}`. A `:telemetry`
bridge attaches at the same boundary.

- **Telemetry reference.** `Statifier.Telemetry` is the authoritative reference
  for every `[:statifier, :session, ...]` event. It is a caller-agnostic
  emitter. A driver calls it wherever the driver steps a chart.
  `Statifier.Session.Telemetry` is the `driver: :session` facade over it: the
  nine functions that 2.0.0 published, unchanged in arity. It is still the entry
  point for a `Statifier.Session` consumer.
- **Drivers without a session.** A driver can step the pure interpreter
  directly, with no `Statifier.Session` process. It emits the same contract by
  calling `Statifier.Telemetry` at its own step seam. See
  [docs/persistence.md](persistence.md) for this loop. Live tooling attaches at
  the boundary that its driver runs.
- **OpenTelemetry.** It uses this contract from outside the repo. The bridge is
  the separate `opentelemetry_statifier` package.
  [docs/opentelemetry.md](opentelemetry.md) holds the span topology and
  propagation design that it implements.
- **End of stream.** `{:halted, :done | :cancelled | :budget_exhausted}` is the
  last message that a session sends its subscribers for the run. A consumer can
  treat it as end-of-stream. The cross-batch ordering rule of constraint 2 makes
  this true: no later-round effect can still be queued behind the message.
- **Late subscribers.** A pid that subscribes after
  `Statifier.Session.start_link/2` has already missed the initialize burst. It
  can catch up in the same call that subscribes it.
  `Statifier.Session.subscribe(server, pid, catch_up: true)` returns
  `{:ok, recording}`. `Statifier.Replay.run/1` re-derives the missed prefix. This
  requires `record: true`. Without it, the session retains nothing to answer the
  request.
- **Prefix and suffix meet exactly.** Between GenServer callbacks,
  `Statifier.Replay.run/1` over the current recording of the session produces
  exactly the messages that the session has notified so far. This extends the
  end-of-run equality that `test/statifier/replay_round_trip_test.exs` asserts to
  every quiescent point. For a session started with `resume:`, the catch-up
  prefix begins at the resumed position, not at the initial configuration of the
  chart. See [docs/persistence.md](persistence.md#resuming-a-session).
- **Invoke trees.** Observation is per session, and an invoke tree is a tree of
  sessions. The `:inherit_observers` option of `Statifier.Session.start_link/2`
  starts each invoked child with the `:trace` and subscribers of the parent. One
  attach at the root then covers the whole tree. The messages of each session
  still carry its own `session_id` in the envelope.
  `Statifier.Session.invocations/1` names the live children for an observer that
  attaches to a tree that is already running. Such an observer necessarily
  misses the initialize burst of each child.

Decisions:
[ADR-0040](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0040-session-telemetry-event-contract.md)
(amended by
[ADR-0067](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0067-one-telemetry-contract-across-stepping-drivers.md)),
[ADR-0044](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0044-re-entry-effects-defer-to-the-outer-batch.md)
decision 2,
[ADR-0049](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0049-late-subscriber-catch-up-via-recording.md),
[ADR-0050](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0050-invoked-children-inherit-observation-by-opt-in.md),
[ADR-0062](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0062-opentelemetry-bridge-is-a-separate-package.md).

**Replay.** The core is pure and timers are effects. A run is reproducible when
the session boundary records the external inputs (delivered events, timer
firings, cancel markers) in the serialized input order of the session.

- **Four inputs.** The recording has four inputs: machine, initial data,
  external event log, and `interpret/2` batches. The fourth input is the effect
  list of each `Statifier.Session.interpret/2` call, at its position in the
  serialized input order. It is empty for a session that never received such a
  call. The three-input tuple therefore stays the common case.
- **One input path.** Keep the input path of the session single and capturable.
  Add no side doors that inject events without crossing the recordable boundary
  (`Statifier.Session.Inbox`).
- **The recorder.** The recorder is `Statifier.Session.Recording`.
  `Statifier.Session.start_link/2` builds it when it receives `record: true`.
  `Statifier.Session.recording/1` reads it back. The recorder cannot be a
  subscriber. The effect stream does not distinguish core-derived effects
  (replay re-derives them) from effects that `interpret/2` injected (replay
  re-injects them).
- **Replay drives the core.** `Statifier.Replay` drives the pure core directly,
  not a live session. The recording carries ordinal order with no clock reading.
- **Route snapshot.** Each recorded entry that triggers a core drive also carries
  the `Statifier.Send.Routes.t()` route snapshot that the drive was judged
  against. `Statifier.Replay` re-supplies it and does not rebuild it. This widens
  what an entry carries. The set of recorded input kinds does not grow.
- **Invoke types.** `:invoke_types` is recorded once as a normalized session
  option, next to `:routes`, not per entry. The registered `<invoke type>` set is
  fixed for the whole lifetime of the session. `@normalized_opts` in
  `Statifier.Session.Recording` carries it. `Statifier.Replay` rebuilds the same
  snapshot for every drive.

Decisions:
[ADR-0029](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0029-session-interpret-stays-public.md),
[ADR-0034](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0034-replay-re-drives-the-core-not-a-live-session.md),
[ADR-0048](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0048-send-reachability-judged-against-a-route-snapshot.md)
decision 3,
[ADR-0051](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0051-invoke-handlers-are-registered-per-session.md)
decision 2.

## Non-goals (for now)

- No stepper API, breakpoint model, debug protocol, or wire format.
- No visualization or UI of any kind.
- No trace persistence or rotation. The effect interpreter receives trace
  effects and owns them.
- No performance work on tracing beyond the emission gate.

## Where the seams live

| Seam | Where it lives |
|---|---|
| machine_state struct holds configuration, internal queue, history, datamodel, `running`, and step counters - no interpreter loop variable that is not reconstructible from the struct | `Statifier.MachineState` |
| `microstep` step function exists; macrostep folds over it | `Statifier.Interpreter` |
| trace effect types defined with the vocabulary above; emission gated | `Statifier.Effect`, `Statifier.Effect.Trace.*` |
| compiler retains locations on states, transitions, executable content, and - on states, transitions and `<invoke>` - the written-attribute spans of each (`attribute_locations`, carried verbatim) | `Statifier.Compiler`, `Statifier.Machine.State`/`Transition`/`Content`/`Invoke` |
| compiled expressions carry their span table with the instructions (ADR-0014) | `Statifier.Compiler.Expressions.compile/3` stores `%Predicator.Compiled{}` whole |
| compiler assigns document-order indexes to transitions, executable-content nodes, and `<data>` elements (`t_index`/`c_index`/`d_index`, dense from 0) | `Statifier.Compiler` |
| internally raised events carry cause metadata (identity + step) | `Statifier.Event.Cause`, `MachineState.raise_internal/4` |
| Appendix D query functions take/return plain values, unfused | `Statifier.Interpreter.Selection`, `Statifier.Interpreter.ExitEntry`, `Statifier.Interpreter.Content` |
| the session's live invocations are nameable from outside it, so an observer can walk the invoke tree | `Statifier.Session.invocations/1`, `Statifier.Session.Invocations.list/1` |
| validator warnings retained on the compiled Machine (ADR-0033) | `Statifier.Validator.Warning`, `Statifier.Machine.warnings` |

The last row is a seam of one link. A validator finding is produced before a
`Machine` exists, so none of the trace vocabulary above reaches it. A validator
finding has no trace effect, no `Logger` call, and no `:telemetry` event. The
channel, end to end, is the return value of `validate/3` and the field that
`compile/1` stamps it onto.
