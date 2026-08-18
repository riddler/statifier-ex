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
| invoke pass | `run_invoke_pass` finished: the states walked and the invocations it started (`<invoke>`, spec 6.4) |
| finalize/autoforward pass | `apply_invoke_passes` finished for one external event: which invocation(s) it ran `<finalize>` for and which it autoforwarded the event to (spec 6.4/6.5) |

The last two rows postdate the table above them - they arrived with
`<invoke>` support and are two more phase boundaries Appendix D itself
names inside `mainEventLoop`, not a broadening of what counts as a phase
boundary. The "Minimum trace vocabulary... the set is the commitment" line
above is about the shapes being settled at implementation, not about the
table being closed to boundaries Appendix D had not yet been ported far
enough to need.

Rules:

- Emission is gated by an interpreter/machine option (working name
  `trace: true`); the untraced hot path allocates nothing for trace.
- Trace effects carry the step counters (constraint 4) and identities
  (constraint 3), never bare structs that force tooling to re-derive context.
- Trace effects are ordinary members of the effect list - same ordering
  guarantees, same delivery path. No side channel.
- The ordering guarantee holds across batches too, not only within one:
  delivery order to a subscriber is non-decreasing in `(macrostep, round)`
  across the whole run, matching the order `Statifier.Replay` produces for
  the same recording. A mid-batch ADR-0039 re-entry keeps the enclosing
  macrostep and advances `round`, so its effects carry higher rounds than
  the outer batch's unsent tail; those effects are queued and drained after
  the batch that triggered them rather than delivered inline, which is what
  keeps arrival order monotone (ADR-0044 decision 1). That live-arrival
  guarantee is stronger than re-derivability, not a substitute for it: every
  effect carries the counter triple (ADR-0046), so a consumer holding a mixed
  stream whose arrival order was lost can still sort it back into
  `(macrostep, round)` order offline, including under `trace: false`.
- "Either selection function" is `select_eventless_transitions/1` and
  `select_transitions/2` both, with no exception - including the terminal
  eventless probe that ends a macrostep, which is why the round reporting
  quiescence carries an effect list of its own rather than being a bare
  atom.
- The "exit set" and "entry set" rows carry the *resulting* configuration
  (ADR-0005, full configuration, ancestors included), not only the
  `indexes` delta: `configuration` is the configuration as it stands after
  every state named by `indexes` has left (exit set) or been added (entry
  set). The table's "before exiting"/"before entering" wording still
  describes the phase boundary the payload is stamped against - the step
  counters keep coming from that boundary - but `configuration` is what
  the boundary produced, read after the mutation it names. This is what
  lets a consumer render the active configuration after every microstep
  without folding deltas or re-deriving `exit_interpreter`'s
  whole-configuration sweep; at `exit_interpreter`, the exit set's
  `configuration` is the empty set.

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
- Attribute-level spans are retained too, one step finer than the bullet
  above: `Statifier.Machine.State`, `Statifier.Machine.Transition` and
  `Statifier.Machine.Invoke` each carry their source node's
  `attribute_locations` map verbatim (`Statifier.Document`'s moduledoc holds
  the contract - value spans only, and a key exists only for an attribute
  the author wrote). The element-level sentence above is what a
  line-highlighting visualizer needs; a consumer with attribute-level hover
  targets on a `<transition>`'s `event`/`target`/`type` or a state's
  `id`/`initial` needs the map, and re-deriving it by re-parsing the source
  and joining Document nodes to Machine identities by location equality is
  sound only while the re-parsed bytes match what built the Machine, which
  nothing checks (st-9i5r).
- SCXML transitions and executable content have no IDs, so the compiler assigns
  each a stable document-order index (per machine). Trace effects and error
  metadata reference these indexes; tooling maps them back to locations.
- A `<data>` element gets the same treatment, as a third document-order index:
  `d_index`, dense from 0, assigned by the compiler alongside `t_index` and
  `c_index` (`Statifier.Compiler`) and resolved back to its
  `%Statifier.Machine.Data{}` - carrying its own `location` and
  `value_location` - through `Statifier.Machine.data/2`. This completes an
  enumeration the compiler had already outgrown: `d_index` existed on
  `Machine.Data` and cited this ADR before this list named it (st-1xwh).
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
- Every trace effect is stamped with the counters - `(macrostep, round)` is
  the ordering key for any timeline UI or log merge, and it advances on
  every round including those that run no microstep, so a fold that never
  reaches quiescence is still ordered and countable (ADR-0020).
- A macrostep may carry more than one `Trace.MacrostepStable`: one per core
  drive that reached quiescence, since a session may re-enter the core
  mid-macrostep (ADR-0039). There is exactly one `MacrostepStable` per
  `(macrostep, round)`, and under ADR-0044 decision 1 the last one arriving
  within a macrostep is that macrostep's last quiescent point (ADR-0044
  decision 3) - which is not always where the macrostep ends, since a
  macrostep that halts ends with `Trace.Done` instead, either after its
  final `MacrostepStable` or, when the halting drive is the only one, with
  no `MacrostepStable` of its own at all.
- Internally raised events carry cause metadata: which transition or
  executable-content node (by constraint-3 identity) raised them, at which
  step and round. The first consumer is a better `error.execution` - "raised
  by the `<assign>` at line 42, transition 7, microstep 3, round 1" - which
  pays for the field before any debugger exists.

## Constraint 5: the pure queries stay callable

The function-per-pseudocode-block structure of ADR-0002 is itself the debug
API: `select_transitions(machine_state, event)` answers "what would happen if
event X arrived" without stepping, and `compute_exit_set` / `compute_entry_set`
preview a transition's effect on the configuration. The constraint is only:
these functions take and return plain values (no hidden context), and they are
not inlined or fused in a way that makes exposing them later a refactor. They
may start private; `defdelegate` from a debug module later is the intended
promotion path.

## Constraint 6: observe and record at the boundary

`Statifier.Session` is the session boundary. Two properties it preserves:

- **Observation**: the session forwards its effect/trace stream to every
  subscriber pid as `{:statifier, session_id, {:effect, effect}}`, and a
  `:telemetry` bridge attaches at that same boundary - `Statifier.Session.Telemetry`,
  the authoritative reference for every `[:statifier, :session, ...]` event
  (ADR-0040). Live tooling attaches there; the core is untouched.
  `{:halted, :done | :cancelled | :budget_exhausted}` is the last message a
  session sends its subscribers for the run, so a consumer may treat it as
  end-of-stream (ADR-0044 decision 2) - constraint 2's cross-batch ordering
  sentence is what makes that true, since it guarantees no later-round
  effect can still be queued behind it. A pid that subscribes after
  `Statifier.Session.start_link/2` has already missed the initialize burst,
  and catches up by asking for the recording in the same call that
  subscribes it: `Statifier.Session.subscribe(server, pid, catch_up: true)`
  returns `{:ok, recording}`, and `Statifier.Replay.run/1` re-derives the
  missed prefix (ADR-0049). It requires `record: true`; nothing is retained
  on the session to answer it otherwise. What makes prefix and suffix meet
  exactly: between GenServer callbacks, `Statifier.Replay.run/1` over the
  session's current recording produces exactly the messages the session has
  notified so far - which generalizes the end-of-run equality
  `test/statifier/replay_round_trip_test.exs` asserts to every quiescent
  point.
  Observation is per session, and an invoke tree is a tree of sessions: `Statifier.Session.start_link/2`'s
  `:inherit_observers` (ADR-0050) starts each invoked child with the
  parent's `:trace` and subscribers so one attach at the root covers the
  whole tree, with each session's messages still carrying its own
  `session_id` in the envelope. `Statifier.Session.invocations/1` names the
  live children for an observer attaching to a tree already running, which
  necessarily misses each child's initialize burst.
- **Replay**: because the core is pure and timers are effects, recording the
  external inputs (delivered events, timer firings, cancel markers) in the
  session's serialized input order at the session boundary makes a run
  reproducible. The recording has four inputs: (machine, initial data,
  external event log, `interpret/2` batches) - the fourth is each
  `Statifier.Session.interpret/2` call's effect list at its position in the
  session's serialized input order, and it is empty for a session never
  handed such a call, which keeps the familiar three-input tuple as the
  common case (ADR-0029). Keep the session's input path single and
  capturable - no side doors that inject events without crossing the
  recordable boundary (`Statifier.Session.Inbox`). The recorder is
  `Statifier.Session.Recording`, built when `Statifier.Session.start_link/2`
  is given `record: true` and read back with `Statifier.Session.recording/1`;
  note it cannot be a subscriber, because the effect stream does not
  distinguish core-derived effects (replay re-derives them) from
  `interpret/2`-injected ones (replay re-injects them). `Statifier.Replay`
  drives the pure core directly rather than a live session, and the recording
  carries ordinal order with no clock reading (ADR-0034). Each recorded entry
  that triggers a core drive also carries the `Statifier.Send.Routes.t()`
  route snapshot that drive was judged against (ADR-0048 decision 3), so
  `Statifier.Replay` re-supplies it rather than rebuilding one; this widens
  what an entry carries, and the set of recorded input kinds does not grow.

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
| compiler retains locations on states, transitions, executable content, and - on states, transitions and `<invoke>` - the written-attribute spans of each (`attribute_locations`, carried verbatim) | `Statifier.Compiler`, `Statifier.Machine.State`/`Transition`/`Content`/`Invoke` |
| compiled expressions carry their span table with the instructions (ADR-0014) | `Statifier.Compiler.Expressions.compile/3` stores `%Predicator.Compiled{}` whole |
| compiler assigns document-order indexes to transitions, executable-content nodes, and `<data>` elements (`t_index`/`c_index`/`d_index`, dense from 0) | `Statifier.Compiler` |
| internally raised events carry cause metadata (identity + step) | `Statifier.Event.Cause`, `MachineState.raise_internal/4` |
| Appendix D query functions take/return plain values, unfused | `Statifier.Interpreter.Selection`, `Statifier.Interpreter.ExitEntry`, `Statifier.Interpreter.Content` |
| the session's live invocations are nameable from outside it, so an observer can walk the invoke tree | `Statifier.Session.invocations/1`, `Statifier.Session.Invocations.list/1` |
| validator warnings retained on the compiled Machine (ADR-0033) | `Statifier.Validator.Warning`, `Statifier.Machine.warnings` |

The last row is a seam of one link, not an omission: a validator finding is
produced before a `Machine` exists, so none of the trace vocabulary above
reaches it. There is no trace effect, no `Logger` call, and no `:telemetry`
event for a validator finding - the return value `validate/2` hands back and
the field `compile/1` stamps it onto *are* the channel, end to end.
