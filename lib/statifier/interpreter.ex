defmodule Statifier.Interpreter do
  @moduledoc """
  Appendix D's outer loop, ported function for function (ADR-0002), with its
  loop state reified onto `%Statifier.MachineState{}` per
  `docs/observability.md` constraint 1: any `%MachineState{}` value is a
  complete, resumable interpreter position, and this module keeps nothing
  of that position on the call stack.

  ## The map of the loop

  Appendix D's `interpret`/`mainEventLoop`/`microstep`/`exitInterpreter`
  collapse onto this module's functions:

  | This module | Appendix D |
  |---|---|
  | `microstep/2` | `microstep(enabledTransitions)` verbatim |
  | `microstep/1` | `mainEventLoop`'s inner `while running and not macrostepDone` loop body, hoisted into a value so a paused position is data, not a stack frame |
  | `macrostep/1` | that same inner loop, folded to quiescence |
  | `main_event_loop/1` | the outer-loop iteration(s) one call of `initialize/2` or `handle_event/2` performs - the invoke pass, its re-entry `continue`, and the trailing `exitInterpreter()` |
  | `exit_interpreter/1` | `exitInterpreter` |
  | `initialize/2`, `handle_event/2` | `interpret`'s two entry seams |

  ## Stepping it

  Constraint 1's payoff is that a step debugger is `microstep/1` in iex with
  no support code. Fold to quiescence, then hand it an event and drive the
  next macrostep one round at a time, inspecting the position between calls:

      # in iex, with `machine` already compiled
      {machine_state, _effects} = Interpreter.initialize(machine, trace: true)
      machine_state = MachineState.begin_macrostep(machine_state)

      # one round at a time; a `{:quiescent, _, _}` return ends the macrostep
      {machine_state, effects} = Interpreter.microstep(machine_state)
      machine_state.configuration
      Interpreter.microstep(machine_state)

  Every binding above is an ordinary value: keep an earlier `machine_state`
  to rewind to it, or round-trip one through `:erlang.term_to_binary/1` to
  resume in another process. `macrostep/1` is the same loop run to its fixed
  point, so stepping and folding are the same code path, not two.

  ## Counters

  `Statifier.MachineState`'s counter contract is the source of truth;
  restated here only for where this module writes it. `microstep`'s writer
  (`Statifier.MachineState`'s docs name it) has exactly one call site in
  this module: the non-empty branch of `run_selected/3`, the private tail
  shared by every selection round (eventless, one dequeued internal event,
  and the external event `handle_event/2` selects on). A selection round
  that finds nothing to run never reaches that call, because no exit or
  entry happened - the same "no exit or entry happened" rule
  `MachineState`'s counter contract states for why an empty round does not
  advance `microstep`.

  `macrostep`'s writer has exactly two call sites in this module:
  `initialize/2` (the initialization macrostep is macrostep 1) and
  `handle_event/2`, once per accepted external event (macrostep 2 onward).
  `initialize/2` additionally advances the microstep counter once, directly,
  before its own `enter_states/2` call - the pseudocode's
  `enterStates([doc.initial.transition])` is not inside `microstep`, so
  **the initial entry is microstep 1**, not 0, and nothing the
  initialization macrostep emits is stamped `microstep: 0`.

  An external event is the one case that is. `begin_macrostep/1` resets the
  microstep counter, and `handle_event/2` emits `Trace.EventDequeued` and
  (via `run_selected/3`) `Trace.TransitionsSelected` before the round's
  first entry has happened, so both carry `microstep: 0` - the round has
  begun but no exit or entry has occurred yet, which is exactly what
  `microstep: 0` means under `MachineState`'s counter contract. The first
  `Trace.ExitSet` of that macrostep is microstep 1.

  This is also why the trace effects a selection round emits
  (`Trace.EventDequeued`, `Trace.TransitionsSelected`) are always stamped
  *one microstep behind* the `Trace.ExitSet` that follows them when the
  round is non-empty: both are built from the `machine_state` selection
  returned, which is still at the *previous* microstep's count - the
  counter only advances afterward, inside `run_selected/3`, right before
  `microstep/2` runs. The counter cannot be advanced before the selection
  result is known, because an empty result must not advance it.

  `round`'s writer (`begin_round/1`) has exactly one call site in this
  module: the head of `microstep/1`, both clauses included - so the
  `running: false` clause counts a round too, and the first round of a
  macrostep's fold is round 1. `handle_event/2`'s own `Trace.EventDequeued`
  and `Trace.TransitionsSelected`, and everything `initialize/2` emits
  before `main_event_loop/1` begins the fold, are stamped `round: 0` for the
  same reason they are stamped `microstep: 0`: no round of this macrostep's
  fold has begun yet.

  ## Deviations, with their reasons (ADR-0002)

  - **`microstep/1` is not a pseudocode function name.** It is
    `mainEventLoop`'s inner loop body, hoisted so a debugger can pause
    between rounds without support code (constraint 1). See `microstep/1`'s
    own `@doc`.
  - **Quiescence is a tagged return, not a bare atom.** `microstep/1`
    returns `{:quiescent, machine_state, effects}` so the round that ends a
    macrostep can carry out both the machine_state its selection returned
    and that selection's own `Trace.TransitionsSelected`. Every selection
    this module makes emits that trace, with no exception for the terminal
    probe, so `docs/observability.md`'s "includes the empty set" is
    literally true. See `microstep/1`'s own `@doc` for why the
    machine_state half is load-bearing rather than tidiness.
  - **The machine_state `Selection` returns is threaded, never discarded.**
    Both `Selection.select_eventless_transitions/1` and
    `Selection.select_transitions/2` return `{machine_state, transitions}`,
    and this module continues with the returned `machine_state` rather than
    the one it passed in - `cond` evaluation lives inside `Selection`, where
    it reshapes that module's private walk without changing either entry
    point's signature or anything in this module.
  - **The outer `while running` loop is driven by the caller.** ADR-0003:
    the pure core takes one external event per call, and the session that
    drives it owns the waiting external events and their queue.
    `main_event_loop/1` is the loop's tail - fold to quiescence, then
    `exit_interpreter/1` when `running` went false - not the loop itself.
    See `main_event_loop/1`'s own `@doc` for the exact port-site comment.
  - **The invoke pass runs at the end of every fold, inside `main_event_loop/3`.**
    `run_invoke_pass/1` walks `states_to_invoke` sorted into entry order via
    `Machine.document_order/2` (the same sort `enter_states/2` already
    performs, and one the pseudocode itself specifies -
    `statesToInvoke.sort(entryOrder)` - so this is not a deviation), and
    within each state walks its compiled `invoke` list in document order.
    Each invocation's arguments are resolved against one threaded
    `Evaluator.context/1`; any evaluation failure raises `error.execution`
    and yields no `Effect.Invoke` for that invocation, siblings unaffected
    (ADR-0031), and otherwise the invocation is recorded in
    `machine_state.active_invocations` and emits one `{:invoke, _}` effect.
    `states_to_invoke` is cleared once the pass finishes, and one
    `Trace.InvokePass` is emitted last, carrying the states walked and the
    invoke ids started - a phase boundary Appendix D itself names
    (ADR-0012 item 2's parenthetical is illustrative, not closed) that
    predates this bead having any `<invoke>` to trace. When invoking left
    the internal queue non-empty, Appendix D's `continue` re-enters the
    outer loop - a self-call of the private `main_event_loop/3` - which is
    why the round budget has to span it (ADR-0032; see the deviation
    comment above `defp main_event_loop/3`).
  - **The finalize/autoforward pass runs once per external event, inside
    `handle_event/2`, before transition selection.** `apply_invoke_passes/2`
    walks the full `configuration` (ADR-0005), and for each state's
    compiled `invoke` list, in document order: when a live invocation's
    invokeid equals the external event's own `invokeid`, its `<finalize>`
    runs in the pure core (`Statifier.Machine.Invoke.finalize`'s
    absent/empty/populated split, spec 6.5); when it autoforwards, one
    `{:autoforward, %Effect.Autoforward{}}` carries the event on, verbatim,
    for the session to deliver - not `Effect.Send`, since 6.4 requires an
    exact copy of every 5.10.1 field and ADR-0003 keeps effect construction
    pure. Neither `if` is inside
    the other's `else`: a matching, autoforwarding invocation does both,
    exactly as Appendix D's own two separate `if`s read. The walk
    short-circuits to a no-op when `active_invocations == %{}` - but even
    that no-op still emits one `Trace.FinalizeAutoforward` with both lists
    empty, the same "includes the empty set" reasoning
    `Trace.TransitionsSelected` already carries into this vocabulary, so the
    pass's absence is never mistaken for a pass that found nothing to do.
  - **`returnDoneEvent` becomes a returned effect, appended last.**
    `exit_interpreter/1` builds `{:done, %Effect.Done{}}` instead of
    performing an I/O call (ADR-0003), and appends it after `Trace.Done`
    rather than mid-walk - a mechanical reordering, since effects are a
    returned list and nothing downstream observes the difference in the
    pseudocode's own terms. See `exit_interpreter/1`'s own `@doc`.
  - **The macrostep fold is bounded.** Appendix D's inner loop is
    unbounded; a pure core has no external entity to cancel a
    non-terminating macrostep, so the fold spends a round budget and stops
    with a `:budget_exhausted` effect on exhaustion (ADR-0019). See the
    private fold's own comment above `defp macrostep/3`.
  - **The round budget spans an invoke re-entry.** `continue` (Appendix D)
    is a self-call of `main_event_loop/3` in this port, and a self-call
    that started a fresh budget every time would reopen the same livelock
    ADR-0019 closed, one loop further out - two states whose `<invoke>`
    arguments deterministically error could hand each other control
    forever. The budget is therefore threaded across every re-entry of one
    `main_event_loop/1` call instead of restarted per fold (ADR-0032). See
    the deviation comment above `defp main_event_loop/3`.
  - **A round ordinal counts `microstep/1` invocations.** Appendix D's inner
    loop carries `macrostepDone` and no round variable of any kind
    (ADR-0020); `round` is a hoisting artifact of `microstep/1` itself, like
    the two counters before it. See the comment above `microstep/1`'s two
    clauses.
  """

  alias Statifier.Compiler
  alias Statifier.Evaluator
  alias Statifier.Event
  alias Statifier.Event.Cause
  alias Statifier.EventData
  alias Statifier.Interpreter.Content
  alias Statifier.Interpreter.Datamodel
  alias Statifier.Interpreter.ExitEntry
  alias Statifier.Interpreter.Selection
  alias Statifier.Machine
  alias Statifier.Machine.Block
  alias Statifier.Machine.Invoke, as: MInvoke
  alias Statifier.Machine.Param
  alias Statifier.Machine.Transition
  alias Statifier.MachineState

  require Statifier.Effect, as: Effect

  @doc """
  `interpret`'s entry seam (Appendix D) - binds `opts` into a fresh
  `%MachineState{}`, enters the top-level initial states, then runs the
  initialization macrostep to quiescence. Documents that reach a stable
  configuration or even terminate before any external event is ever sent
  are corpus-normal (`enter_states/2` can already set `running: false` on a
  top-level `<final>` entry, and `main_event_loop/1` runs
  `exit_interpreter/1` when it does).

  `opts` passes straight to `MachineState.new/2` - no option is interpreted
  here, so a new one is a `MachineState` change, not an entry-point change.

  Cannot fail: a `%Machine{}` is valid by construction
  (`docs/architecture.md`), so this returns the same untagged
  `{machine_state, [effect]}` pair every other loop function in this module
  returns, rather than an `{:ok, _, _}` wrapper with one possible value.
  """
  @spec initialize(machine :: Machine.t(), opts :: keyword()) ::
          {MachineState.t(), [Effect.t()]}
  def initialize(%Machine{} = machine, opts \\ []) do
    machine_state =
      machine
      |> MachineState.new(opts)
      |> MachineState.begin_macrostep()
      |> MachineState.begin_microstep()

    # `datamodel = new Datamodel(doc)` / `if doc.binding == "early":
    # initializeDatamodel(datamodel, doc)` (Appendix D `:101-102`), fused
    # into one unconditional call. The pseudocode's `if doc.binding ==
    # "early":` guard is **not** ported to this call site - it moves inside
    # `Datamodel.initialize/1` instead (Decision 7,
    # `docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md`),
    # for three reasons that must be read together, not the usual single
    # ADR-0002 mechanical-deviation note:
    #   1. `initializeDatamodel` has no procedure body anywhere in Appendix
    #      D, so there is no pseudocode definition of what the guard is
    #      guarding - what it means is decided by clause 5.3.2/5.3.3/B.2.2
    #      prose, not by porting a block that does not exist.
    #   2. Spec 5.3.3 makes *creation* of every <data> unconditional under
    #      both bindings ("...MUST create the data elements at document
    #      initialization time"), so seeding cannot sit behind an
    #      early-only guard without violating that MUST.
    #   3. Under binding="late", a top-level <data> is contained in no
    #      state, so it is never in `enterStates`' `statesToEnter` - this
    #      call is the only place in the whole interpreter it can ever be
    #      bound.
    # `Datamodel.initialize/1` seeds every declared id unconditionally and
    # binds every d_index under :early, only the root's own under :late -
    # see its own moduledoc.
    {machine_state, datamodel_effects} = Datamodel.initialize(machine_state)

    # `executeGlobalScriptElement(doc)` (Appendix D `interpret`, prose
    # quoted below - the procedure has no body of its own in Appendix D,
    # the same "no procedure body to port" situation
    # `Statifier.Interpreter.Datamodel`'s moduledoc documents for
    # `initializeDatamodel`): "Initialize the global data structures,
    # including the data model. If binding is set to 'early', initialize
    # the data model. Then execute the global <script> element, if any.
    # Finally call enterStates on the initial configuration...". This call
    # lands exactly at that position - after the data model, before
    # enterStates - with no ADR-0002 deviation: the pseudocode's own
    # ordering is what is ported here, unchanged. The one departure from a
    # literal reading is that Appendix D's prose says "the global <script>
    # element" (singular) while spec 5.8 says "any <script> element that
    # is a child of <scxml>" (plural, no count limit) - run_global_scripts/1
    # below folds over `machine.global_scripts` in document order, which is
    # the plural spec 5.8 actually specifies, not a reordering of anything
    # Appendix D's prose commits to.
    #
    # `global_effects` is threaded separately from `enter_effects`/
    # `loop_effects` below and prepended ahead of both in the function's
    # final return, rather than folded together with them here, because that
    # return-site concatenation is the one place this ordering needs to be
    # readable: `global_effects ++ enter_effects ++ loop_effects` reads as
    # the same before-enterStates ordering this call site already documents,
    # with no separate accumulator threading required. `datamodel_effects`
    # (above) precedes all three at that same return site - it is
    # `interpret`'s datamodel preamble, which Appendix D `:101-102` (quoted
    # above) places ahead of both the global script and enterStates.
    {machine_state, global_effects} = run_global_scripts(machine_state, machine.global_scripts)

    {machine_state, enter_effects} =
      ExitEntry.enter_states(machine_state, [initial_transition(machine)])

    {machine_state, loop_effects} = main_event_loop(machine_state)

    {machine_state, datamodel_effects ++ global_effects ++ enter_effects ++ loop_effects}
  end

  # `expandScxmlSource(doc)` (Appendix D's own normalization step) is what
  # gives a document an `<initial>` element where it wrote none; this is
  # that step, done lazily for the root only. ADR-0002 mechanical
  # deviation: a synthesized transition is not a document element, so it
  # has no `t_index`.
  @spec initial_transition(machine :: Machine.t()) :: Transition.t()
  defp initial_transition(%Machine{} = machine) do
    case Machine.at(machine, 0).initial_transition do
      nil ->
        %Transition{
          t_index: nil,
          source: 0,
          targets: Machine.initial(machine),
          events: [],
          type: :external,
          content: [],
          location: machine.location
        }

      t_index ->
        Machine.transition(machine, t_index)
    end
  end

  # `executeGlobalScriptElement(doc)` (Appendix D), the actual fold
  # `initialize/2`'s call site above names - one `Evaluator.execute/2` call
  # per top-level `<script>`, in document order, threading the mutated
  # `machine_state` from each into the next exactly the way a block runner
  # threads a `Context.t()` across its own nodes' writes (ADR-0026 decision
  # 3: no block runner and no `ExecutableContent.Context` on this path -
  # there is no block for a top-level script to belong to, so there is
  # nothing for a `Context.t()` to be built over). The effect list threads
  # the same way `machine_state` does - accumulated across scripts, in
  # document order, each script's own effects appended after the previous
  # script's - the same left-to-right accumulation `execute_block/3` uses
  # across the nodes *inside* one block, one level up.
  @spec run_global_scripts(machine_state :: MachineState.t(), scripts :: [Machine.program()]) ::
          {MachineState.t(), [Effect.t()]}
  defp run_global_scripts(machine_state, scripts) do
    scripts
    |> Enum.with_index()
    |> Enum.reduce({machine_state, []}, fn {script, index}, {ms, effects} ->
      {ms, script_effects} = run_global_script(ms, script, index)
      {ms, effects ++ script_effects}
    end)
  end

  # One top-level `<script>`'s load-time run. This is the one place outside
  # `Statifier.Interpreter.Content` that converts an evaluation error into
  # `error.execution` (ADR-0003) - it needs its own conversion, rather than
  # reusing the block runner's, because there *is* no block runner on this
  # path: a top-level script is never in `contents`, never owned by an
  # `<onentry>`/`<onexit>`/transition block, and never reaches
  # `Statifier.Interpreter.Content.run_nodes/2` at all (see `Machine`'s own
  # "why `global_scripts` is different" moduledoc section).
  # `Statifier.Interpreter.Datamodel.bind_value/4`'s `raise_binding_error/3`
  # is the existing precedent for exactly this shape: a load-time raise,
  # via `MachineState.raise_platform/4`, outside any runner, because
  # `<data>` binding has no runner either.
  #
  # It also emits a `Trace.ContentExecuted` effect, on both clauses' success
  # and error paths, reusing the same struct `execute_block/3` emits for an
  # `<onentry>`/`<onexit>`/transition block rather than minting a
  # load-time-only trace shape: nothing today (or foreseeably) needs to
  # distinguish "a block of content ran" from "a top-level script ran" at the
  # trace-consumer level, and `Effect.Trace.ContentExecuted.owner/0` is
  # already widened, above, to carry `{:global_script, index}` for exactly
  # this call. `c_indexes` is always `[]`, never a list of run indices: a
  # top-level `<script>` has no `c_index` at all (this module's own "why
  # `global_scripts` is different" moduledoc section), so there is no
  # per-node identity to report - the same "no indices to give" case
  # `execute_block/3`'s own empty-block clause already documents, reused
  # here for the same reason: a trace consumer should never have to infer a
  # missing entry from an absent effect.
  #
  # `{:invalid, error}` (Decision 1: a body that never compiled, deferred
  # from load to this reached-at-runtime position) is handled the same
  # way a successfully compiled program's own run-time failure is: no
  # partial context exists to keep (nothing ran), so `machine_state` passes
  # through unchanged and `error` is the raised event's `data:` directly -
  # the same two-element short-circuit
  # `Statifier.Machine.Content.Script`'s own `execute/2` clause takes for
  # the identical shape. The trace effect is still emitted after the raise,
  # stamped from the post-raise `machine_state` - `raise_platform/4` does not
  # touch `macrostep`/`microstep`/`round`, but stamping after it (rather than
  # before) matches `execute_block/3`'s own error clause, which stamps its
  # trace from the `machine_state` `raise_execution_error/4` returns, not the
  # one it received. Keeping both call sites' stamping order identical means
  # a future counter added to the raise path stays correctly reflected here
  # too, with no separate reasoning needed at this call site.
  @spec run_global_script(
          machine_state :: MachineState.t(),
          script :: Machine.program() | {:invalid, Compiler.Error.t()},
          index :: non_neg_integer()
        ) :: {MachineState.t(), [Effect.t()]}
  defp run_global_script(machine_state, {:invalid, error}, index) do
    machine_state =
      MachineState.raise_platform(machine_state, "error.execution", {:global_script, index},
        data: error
      )

    {machine_state,
     Effect.trace(machine_state, Effect.Trace.ContentExecuted,
       owner: {:global_script, index},
       c_indexes: []
     )}
  end

  defp run_global_script(
         machine_state,
         {:program, %Predicator.Compiled{}, _source} = program,
         index
       ) do
    machine_state =
      case Evaluator.execute(machine_state, program) do
        {:ok, new_machine_state} ->
          new_machine_state

        {:error, new_machine_state, error} ->
          MachineState.raise_platform(
            new_machine_state,
            "error.execution",
            {:global_script, index},
            data: error
          )
      end

    {machine_state,
     Effect.trace(machine_state, Effect.Trace.ContentExecuted,
       owner: {:global_script, index},
       c_indexes: []
     )}
  end

  @doc """
  `mainEventLoop`'s external-event tail (Appendix D) - the external-event
  counterpart to `internal_round/1`'s dequeue-and-select, driven by the
  caller instead of a blocking queue read (ADR-0003, `main_event_loop/1`'s
  own `@doc`). Rejects when the machine is not running - Appendix D's own
  `running` flag, so the guard reads as the pseudocode's loop condition -
  otherwise begins a new macrostep, runs the finalize/autoforward pass,
  selects on `event`, runs whatever it enables, and folds to quiescence.
  """
  @spec handle_event(machine_state :: MachineState.t(), event :: Event.t()) ::
          {:ok, MachineState.t(), [Effect.t()]} | {:error, :not_running}
  def handle_event(%MachineState{running: false}, %Event{}), do: {:error, :not_running}

  def handle_event(%MachineState{} = machine_state, %Event{} = event) do
    machine_state = MachineState.begin_macrostep(machine_state)

    dequeued =
      Effect.trace(machine_state, Effect.Trace.EventDequeued, event: event, from: :external)

    # `datamodel["_event"] = externalEvent` (Appendix D)
    machine_state = MachineState.put_event(machine_state, event)

    # `for state in configuration: for inv in state.invoke: if inv.invokeid
    # == externalEvent.invokeid: applyFinalize(inv, externalEvent); if
    # inv.autoforward: send(inv.id, externalEvent)` (Appendix D) -
    # `apply_invoke_passes/2` below, in the pseudocode's own position:
    # after `_event` is assigned, before `selectTransitions`.
    {machine_state, invoke_pass_effects} = apply_invoke_passes(machine_state, event)

    {machine_state, transitions} = Selection.select_transitions(machine_state, event)
    {machine_state, selected_effects} = run_selected(machine_state, transitions, event)
    {machine_state, loop_effects} = main_event_loop(machine_state)

    {:ok, machine_state, dequeued ++ invoke_pass_effects ++ selected_effects ++ loop_effects}
  end

  @doc """
  ADR-0039's re-entry seam: the sole path `Statifier.Session` uses to write
  a session-detected `<send>` failure (6.2.4's unsupported/invalid target,
  6.2.5's unsupported `type`) - or a `<send target="#_internal">` delivery -
  onto `%MachineState{}`'s own internal queue.

  Appendix D discovers a routing failure inside `mainEventLoop` and writes
  the internal queue in place. ADR-0003 puts routing in the effect
  interpreter, which is outside that loop by construction, so ADR-0039
  gives the session one way back in: enqueue on the internal queue exactly
  as an in-loop `raise` would, then run to quiescence. No selection or
  entry/exit procedure changes.

  That paragraph is ADR-0002's required citation for a deviation from the
  Appendix D pseudocode: the reason is mechanical (where effects run), not
  semantic, and the resulting queue state is what the in-loop write would
  have produced.

  Delegates to `MachineState.raise_internal/4` or `raise_platform/4` by
  `kind` - the same two functions the core's own executable content already
  uses, so no third internal-queue writer is introduced - then folds
  `main_event_loop/1` to quiescence, returning exactly `handle_event/2`'s own
  shape.
  """
  @spec deliver_internal(
          machine_state :: MachineState.t(),
          kind :: :internal | :platform,
          name :: String.t(),
          origin :: Cause.origin(),
          opts :: keyword()
        ) :: {:ok, MachineState.t(), [Effect.t()]} | {:error, :not_running}
  def deliver_internal(%MachineState{running: false}, _kind, _name, _origin, _opts),
    do: {:error, :not_running}

  def deliver_internal(%MachineState{} = machine_state, kind, name, origin, opts) do
    machine_state =
      case kind do
        :internal -> MachineState.raise_internal(machine_state, name, origin, opts)
        :platform -> MachineState.raise_platform(machine_state, name, origin, opts)
      end

    {machine_state, effects} = main_event_loop(machine_state)
    {:ok, machine_state, effects}
  end

  # `for state in configuration: for inv in state.invoke: if inv.invokeid
  # == externalEvent.invokeid: applyFinalize(inv, externalEvent); if
  # inv.autoforward: send(inv.id, externalEvent)` (Appendix D `:152-158`) -
  # the finalize/autoforward pass. Walks the **full** `configuration`
  # (every entered state, ancestors included - `MachineState.configuration`
  # already is that set, ADR-0005), not `states_to_invoke`: an ancestor
  # entered several macrosteps ago can still own a live invocation whose
  # finalize this event must reach. The `autoforward` test is deliberately
  # **not** in an `else` of the invokeid-match test - an invocation that
  # matches *and* autoforwards does both, exactly as the pseudocode's two
  # separate `if`s read.
  #
  # `active_invocations == %{}` short-circuits to a no-op: with no live
  # invocation, no `inv.invokeid` can ever equal `externalEvent.invokeid`
  # and no invocation can be autoforwarded to, so skipping the walk finds
  # exactly what walking it would have found - nothing. This is the same
  # observational-equivalence argument `Statifier.Machine.Content`'s
  # `execute_block/3` empty-block clause and this module's own untraced
  # `Effect.trace/3` gate already rely on, not a new semantic deviation
  # (ADR-0002).
  #
  # `configuration` sorts into document order via `Machine.document_order/2`
  # for a deterministic effect list - Appendix D's own loop names no sort
  # for this walk (unlike the invoke pass's `statesToInvoke.sort(entryOrder)`),
  # so this is a choice with no ordering constraint to conflict with, not a
  # deviation from one.
  @spec apply_invoke_passes(machine_state :: MachineState.t(), event :: Event.t()) ::
          {MachineState.t(), [Effect.t()]}
  defp apply_invoke_passes(
         %MachineState{active_invocations: invocations} = machine_state,
         %Event{} = event
       )
       when map_size(invocations) == 0 do
    trace =
      Effect.trace(machine_state, Effect.Trace.FinalizeAutoforward,
        event: event,
        finalized: [],
        forwarded: []
      )

    {machine_state, trace}
  end

  defp apply_invoke_passes(
         %MachineState{machine: machine, active_invocations: invocations} = machine_state,
         %Event{} = event
       ) do
    state_order = Machine.document_order(machine, machine_state.configuration)

    {machine_state, effects} =
      Enum.reduce(state_order, {machine_state, []}, fn state_index, {ms, effects} ->
        {ms, state_effects} = apply_invoke_passes_for_state(ms, state_index, event)
        {ms, effects ++ state_effects}
      end)

    # `finalized` reads the pass's own matching rule (`inv.invokeid ==
    # externalEvent.invokeid`) directly off `active_invocations` rather than
    # threading a second accumulator through `apply_invoke_passes_for_*` -
    # `active_invocations` is untouched by this pass (only the invoke pass
    # records into it, only `ExitEntry` removes from it), so it names the
    # same set `apply_invoke_passes_for_invocation/5` ran `apply_finalize/5`
    # against.
    finalized =
      invocations
      |> Map.values()
      |> Enum.filter(&(&1 == event.invokeid))
      |> Enum.uniq()

    forwarded = for {:autoforward, %Effect.Autoforward{invoke_id: id}} <- effects, do: id

    trace =
      Effect.trace(machine_state, Effect.Trace.FinalizeAutoforward,
        event: event,
        finalized: finalized,
        forwarded: forwarded
      )

    {machine_state, effects ++ trace}
  end

  # One state's own `for inv in state.invoke: ...` (Appendix D) -
  # `state.invoke` is already compiled in document order.
  @spec apply_invoke_passes_for_state(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          event :: Event.t()
        ) :: {MachineState.t(), [Effect.t()]}
  defp apply_invoke_passes_for_state(
         %MachineState{machine: machine} = machine_state,
         state_index,
         event
       ) do
    state = Machine.at(machine, state_index)

    state.invoke
    |> Enum.with_index()
    |> Enum.reduce({machine_state, []}, fn {invoke, invoke_index}, {ms, effects} ->
      {ms, new_effects} =
        apply_invoke_passes_for_invocation(ms, state_index, invoke, invoke_index, event)

      {ms, effects ++ new_effects}
    end)
  end

  # One `<invoke>`'s own body of the pass. `active_invocations`'s lookup
  # stands in for Appendix D's `inv.invokeid`/`inv.id` (`MachineState`'s own
  # moduledoc section on the hoist): an invocation with no entry there never
  # started (ADR-0031) or has already been cancelled, so it can neither
  # match an invokeid nor be forwarded to, and both `if`s are skipped for it
  # - the same no-op a never-started or already-gone `inv` would be in the
  # pseudocode, which has no `inv.invokeid`/`inv.id` to read at all in that
  # case.
  @spec apply_invoke_passes_for_invocation(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          invoke :: MInvoke.t(),
          invoke_index :: non_neg_integer(),
          event :: Event.t()
        ) :: {MachineState.t(), [Effect.t()]}
  defp apply_invoke_passes_for_invocation(machine_state, state_index, invoke, invoke_index, event) do
    case Map.fetch(machine_state.active_invocations, {state_index, invoke_index}) do
      :error ->
        {machine_state, []}

      {:ok, invoke_id} ->
        {machine_state, finalize_effects} =
          if invoke_id == event.invokeid do
            apply_finalize(machine_state, state_index, invoke, invoke_index, event)
          else
            {machine_state, []}
          end

        autoforward_effects =
          autoforward_effect(machine_state, state_index, invoke, invoke_id, event)

        {machine_state, finalize_effects ++ autoforward_effects}
    end
  end

  # `if inv.autoforward: send(inv.id, externalEvent)` (Appendix D) - one
  # `{:autoforward, %Effect.Autoforward{}}` carrying `event` verbatim - not
  # `Effect.Send`, since 6.4 requires an exact copy of every 5.10.1 field and
  # `Effect.Send` only ever *builds* an event from `<send>` attributes.
  @spec autoforward_effect(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          invoke :: MInvoke.t(),
          invoke_id :: String.t(),
          event :: Event.t()
        ) :: [Effect.t()]
  defp autoforward_effect(
         _machine_state,
         _state_index,
         %MInvoke{autoforward: false},
         _invoke_id,
         _event
       ),
       do: []

  defp autoforward_effect(
         machine_state,
         state_index,
         %MInvoke{autoforward: true},
         invoke_id,
         event
       ) do
    [
      {:autoforward,
       %Effect.Autoforward{
         invoke_id: invoke_id,
         state_index: state_index,
         event: event,
         macrostep: machine_state.macrostep,
         microstep: machine_state.microstep,
         round: machine_state.round
       }}
    ]
  end

  # `applyFinalize(inv, externalEvent)` (Appendix D) - the three-way split
  # spec 6.5 draws structurally on `Machine.Invoke.finalize` (that struct's
  # own moduledoc): `nil` is absent (no-op), `%Block{content: []}` is empty
  # (the namelist/`<param location>` auto-assign), anything else runs
  # through the ordinary block runner exactly like an `<onentry>`/`<onexit>`
  # block, owned by `{:finalize, state_index, invoke_index}`
  # (`Statifier.Machine.Content.owner/0`, ADR-0028's threaded context).
  @spec apply_finalize(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          invoke :: MInvoke.t(),
          invoke_index :: non_neg_integer(),
          event :: Event.t()
        ) :: {MachineState.t(), [Effect.t()]}
  defp apply_finalize(machine_state, _state_index, %MInvoke{finalize: nil}, _invoke_index, _event) do
    {machine_state, []}
  end

  defp apply_finalize(
         machine_state,
         state_index,
         %MInvoke{finalize: %Block{content: []}} = invoke,
         invoke_index,
         event
       ) do
    auto_assign_finalize(machine_state, state_index, invoke, invoke_index, event)
  end

  defp apply_finalize(
         machine_state,
         state_index,
         %MInvoke{finalize: %Block{content: c_indexes}},
         invoke_index,
         _event
       ) do
    Content.execute_block(machine_state, {:finalize, state_index, invoke_index}, c_indexes)
  end

  # 6.5's empty-`<finalize>` case: "for each item in the 'namelist'
  # attribute and each such `<param>` element, the Processor MUST update the
  # corresponding location as if by `<assign>` with any return value that
  # has a name that matches the 'namelist' item or the 'name' of the
  # `<param>` element" - read from the local spec cache, quoted verbatim.
  # Only a map `event.data` can carry named return values at all; anything
  # else has nothing to match against, so this is a no-op. The common case
  # is `:undefined` - "no data" under ADR-0037, and the struct's own default
  # - alongside `nil` for a null payload and a bare string from `{:text, _}`
  # coercion. The `is_map/1` guard rejects all three alike.
  @spec auto_assign_finalize(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          invoke :: MInvoke.t(),
          invoke_index :: non_neg_integer(),
          event :: Event.t()
        ) :: {MachineState.t(), [Effect.t()]}
  defp auto_assign_finalize(machine_state, state_index, invoke, invoke_index, %Event{data: data})
       when is_map(data) do
    context = Evaluator.context(machine_state)

    {machine_state, _context, effects} =
      (invoke.namelist ++ invoke.params)
      |> Enum.filter(&(&1.kind == :location))
      |> Enum.reduce({machine_state, context, []}, fn param, {ms, ctx, effects} ->
        case Map.fetch(data, param.name) do
          {:ok, value} ->
            {ms, ctx, new_effects} =
              write_finalize_target(ms, ctx, state_index, invoke_index, param, value)

            {ms, ctx, effects ++ new_effects}

          :error ->
            {ms, ctx, effects}
        end
      end)

    {machine_state, effects}
  end

  defp auto_assign_finalize(machine_state, _state_index, _invoke, _invoke_index, %Event{}),
    do: {machine_state, []}

  # The write itself, through the same `Datamodel.write_location/4` an
  # `<assign>` uses, factored out of `Statifier.Machine.Content.Assign` so
  # both call sites share it. `param.expr` for a `kind:
  # :location` entry is always `{:compiled, _compiled, source}` -
  # `Statifier.Compiler.Expressions.compile/3` is the only builder either a
  # namelist entry or a `<param location>` ever goes through
  # (`Statifier.Compiler`'s `build_param/6`), and it never returns
  # `{:static, _}`. A write failure raises `error.execution` with origin
  # `{:finalize, state_index, invoke_index}` - `Cause.origin/0`'s own arm for
  # exactly this block-less write, distinct from the `{:content, c_index,
  # owner}` arm a *populated* `<finalize>`'s own failures raise through
  # `Interpreter.Content.execute_block/3` - and the context is left
  # unrebound for that entry, matching that same module's "nodes that
  # already ran keep the effects they already produced" rule one level
  # down: a failed write for one target does not undo or block another.
  @spec write_finalize_target(
          machine_state :: MachineState.t(),
          context :: Predicator.Context.t(),
          state_index :: non_neg_integer(),
          invoke_index :: non_neg_integer(),
          param :: Param.t(),
          value :: term()
        ) :: {MachineState.t(), Predicator.Context.t(), [Effect.t()]}
  defp write_finalize_target(
         machine_state,
         context,
         state_index,
         invoke_index,
         %Param{expr: {:compiled, _compiled, source}},
         value
       ) do
    case Datamodel.write_location(machine_state, context, source, value) do
      {:ok, machine_state, context, write} ->
        effect =
          {:datamodel_change,
           %Effect.DatamodelChange{
             location_path: write.path,
             location_source: source,
             new_value: write.new_value,
             prior_value: write.prior_value,
             c_index: nil,
             owner: {:finalize, state_index, invoke_index},
             macrostep: machine_state.macrostep,
             microstep: machine_state.microstep
           }}

        {machine_state, context, [effect]}

      {:error, reason} ->
        machine_state =
          MachineState.raise_platform(
            machine_state,
            "error.execution",
            {:finalize, state_index, invoke_index},
            data: reason
          )

        {machine_state, context, []}
    end
  end

  @doc """
  `mainEventLoop`'s cancel path (Appendix D) - `running = false`, then
  `continue`, which ends the `while running` loop and reaches
  `exitInterpreter()`.

  ADR-0002 mechanical deviation: the outer loop is driven by the caller
  (`handle_event/2`), so there is no loop here to fall out of; the two steps
  the pseudocode reaches by falling out are performed directly, in the same
  order. Nothing about the exit itself changes - the states exited, the
  `<onexit>` blocks run, the `<donedata>` collected, and the `{:done, _}`
  effect produced are all `exit_interpreter/1`'s.

  Rejects an already-terminated machine_state with `{:error, :not_running}`,
  matching `handle_event/2`: Appendix D would not be inside the loop to check
  `isCancelEvent` at all.
  """
  @spec cancel(machine_state :: MachineState.t()) ::
          {:ok, MachineState.t(), [Effect.t()]} | {:error, :not_running}
  def cancel(%MachineState{running: false}), do: {:error, :not_running}

  def cancel(%MachineState{} = machine_state) do
    {machine_state, effects} =
      %{machine_state | running: false}
      |> exit_interpreter()

    {:ok, machine_state, effects}
  end

  @doc """
  `microstep(enabledTransitions)` (Appendix D) - exit the states
  `enabled_transitions` leave, run each transition's own content in
  document order, then enter the states they reach. The three calls run in
  exactly this order with nothing between them, matching the pseudocode
  line for line; the effect list is each block's effects concatenated in
  the same order.
  """
  @spec microstep(machine_state :: MachineState.t(), enabled_transitions :: [Transition.t()]) ::
          {MachineState.t(), [Effect.t()]}
  def microstep(%MachineState{} = machine_state, enabled_transitions) do
    {machine_state, exit_effects} = ExitEntry.exit_states(machine_state, enabled_transitions)

    {machine_state, content_effects} =
      execute_transition_content(machine_state, enabled_transitions)

    {machine_state, enter_effects} = ExitEntry.enter_states(machine_state, enabled_transitions)

    {machine_state, exit_effects ++ content_effects ++ enter_effects}
  end

  @doc """
  `mainEventLoop`'s inner `while running and not macrostepDone` loop body,
  hoisted into a named, resumable round (Decision 1) - not a pseudocode
  function name itself. One call makes exactly one round of progress, and
  begins it: both clauses call `MachineState.begin_round/1` first, so the
  returned position's `round` names which round this one was (ADR-0020).

  - Not `running` - returns `{:quiescent, machine_state, []}`, with `round`
    advanced and nothing else changed.
  - An eventless transition is enabled - the round runs it, exactly as
    `microstep/2` above.
  - No eventless transition is enabled - falls to `internal_round/1`,
    which dequeues one internal event (if any) and selects on it.

  Never runs two rounds and never inspects the call stack for a paused
  position: the returned `machine_state` *is* the position, on both the
  progressing and the quiescent return.

  **Quiescence carries a machine_state and an effect list of its own**
  (Decision 2, revised). The round that ends a macrostep still ran a
  selection - `Selection.select_eventless_transitions/1` - and that call
  returns a machine_state. A bare `:quiescent` atom has nowhere to put it,
  so the fold would fall back to the machine_state it passed *in* and drop
  whatever the final selection wrote, on the one round every macrostep ends
  with.

  Be precise about which writes that loses, because the obvious candidate
  is not one of them. The two `Selection` entry points enqueue
  `error.execution` on a failed `cond` - `condition_match/2`
  itself stays a pure query and never enqueues, so the write happens in
  `select_transitions/2` and `select_eventless_transitions/1` on the way
  out - and that enqueue is
  self-rescuing: it leaves the internal queue non-empty, so
  `internal_round/1` takes its dequeue branch instead of the terminal one
  and the write survives even under the old shape - traced end to end and
  pinned by `InterpreterAcceptanceTest`'s
  "a failed cond becomes a catchable error.execution" tests. What the old
  shape lost was any selection-side write that does *not* touch the
  internal queue - a datamodel write, a memo, a diagnostic - since only a
  queue write changes which branch runs. Carrying the machine_state out
  closes that gap without having to predict which kind of write a future
  selection-side change lands on.

  The effect slot is the other half: it is what the terminal eventless
  probe's own `Trace.TransitionsSelected` rides out on, which is why
  `docs/observability.md`'s "includes the empty set" holds with no
  exception.
  """
  @spec microstep(machine_state :: MachineState.t()) ::
          {MachineState.t(), [Effect.t()]} | {:quiescent, MachineState.t(), [Effect.t()]}
  # ADR-0002 mechanical deviation (ADR-0020). Appendix D's inner loop carries
  # `macrostepDone` and no round variable of any kind - the REC's Termination
  # note describes a non-terminating macrostep as "an infinitely long sequence
  # of microsteps", which is this port's rounds, not its microsteps. The
  # ordinal is therefore a hoisting artifact of `microstep/1` itself, like the
  # two counters before it: it labels the position a stepper resumes from
  # (constraint 1) so that a fold whose rounds advance neither counter is still
  # ordered and countable (ADR-0012 item 4). It decides nothing - the budget,
  # not the ordinal, ends the fold - and the loop's condition and body are
  # unchanged. It lives here rather than in the fold so a human hand-stepping
  # in iex advances it identically to `macrostep/1`; both clauses count,
  # because both are a round the fold spends.
  def microstep(%MachineState{running: false} = machine_state),
    do: {:quiescent, MachineState.begin_round(machine_state), []}

  def microstep(%MachineState{} = machine_state) do
    machine_state = MachineState.begin_round(machine_state)
    {machine_state, eventless_transitions} = Selection.select_eventless_transitions(machine_state)

    case eventless_transitions do
      [] -> internal_round(machine_state)
      _enabled -> run_selected(machine_state, eventless_transitions, nil)
    end
  end

  @doc """
  `mainEventLoop`'s inner `while running and not macrostepDone` loop,
  folded to quiescence over `microstep/1` (Decision 7) - not a pseudocode
  function name itself; `docs/observability.md`'s vocabulary for that same
  loop, hoisted so a paused position is a value on `%MachineState{}` rather
  than a stack frame (constraint 1). The fold ends one of three ways:

  - **Quiescence** - `microstep/1` returns
    `{:quiescent, machine_state, effects}`: no eventless transition is
    enabled and the internal queue is empty. That round's own effects (the
    terminal eventless probe's `Trace.TransitionsSelected`) are appended
    like any other round's, and its `machine_state` is the one this fold
    returns - never the one it passed in, which is what keeps a write made
    by the final selection from being dropped. The returned `machine_state`
    is still `running`, so this function then appends
    `Trace.MacrostepStable` with the configuration and counters as they
    stand.
  - **Termination** - a microstep entered a top-level `<final>`, setting
    `running: false` mid-fold. This is not quiescence -
    `Trace.MacrostepStable`'s own moduledoc reserves that trace for reaching
    a stable configuration - so no `Trace.MacrostepStable` is emitted;
    `Trace.Done` is the vocabulary row for this case, emitted by
    `exit_interpreter/1`.
  - **Budget exhaustion** (ADR-0019) - the private fold spent
    `machine_state.max_macrostep_rounds` without reaching quiescence. The
    position comes back exactly as the last round left it: `running` stays
    `true` and `status` stays `:running` (no `exit_interpreter/1` runs, no
    `Effect.Done` is built - faking termination would be a semantic lie).
    `Trace.MacrostepStable` is not emitted, and a
    `{:budget_exhausted, %Effect.BudgetExhausted{}}` core effect is
    appended last.

  The three outcomes are therefore mutually exclusive per macrostep.
  `macrostep/1` is public rather than starting private, because it is
  exactly `microstep/1` driven to a fixed point and a stepper and the fold
  should be the same code path (`docs/observability.md:41-42`).
  """
  @spec macrostep(machine_state :: MachineState.t()) :: {MachineState.t(), [Effect.t()]}
  # `macrostep` is not an Appendix D function name. It is
  # docs/observability.md's vocabulary for `mainEventLoop`'s inner
  # `while running and not macrostepDone` loop, hoisted into a fold over
  # `microstep/1` so that a paused position is a value on `%MachineState{}`
  # rather than a stack frame (constraint 1). Mechanical, not semantic: the
  # loop's condition and body are unchanged. ADR-0002.
  def macrostep(%MachineState{} = machine_state) do
    {outcome, machine_state, effects, _rounds_left} =
      macrostep(machine_state, [], machine_state.max_macrostep_rounds)

    {machine_state, effects ++ terminal_effects(machine_state, outcome)}
  end

  # The three mutually exclusive ways one macrostep ends (ADR-0019).
  # `:quiescent` while still `running` is the stable configuration and the one
  # case `Trace.MacrostepStable` names; `:quiescent` with `running: false` is
  # termination, whose vocabulary row is `Trace.Done` from
  # `exit_interpreter/1`; `:exhausted` is the spent round budget, a core
  # effect because it is the outcome of the call rather than diagnostics about
  # it, so it is built directly and not through the `Effect.trace/3` gate.
  @spec terminal_effects(machine_state :: MachineState.t(), outcome :: :quiescent | :exhausted) ::
          [Effect.t()]
  defp terminal_effects(machine_state, :quiescent) do
    if machine_state.running do
      Effect.trace(machine_state, Effect.Trace.MacrostepStable,
        configuration: machine_state.configuration
      )
    else
      []
    end
  end

  defp terminal_effects(machine_state, :exhausted) do
    [
      {:budget_exhausted,
       %Effect.BudgetExhausted{
         configuration: machine_state.configuration,
         budget: machine_state.max_macrostep_rounds,
         pending_internal_events: MachineState.internal_events(machine_state),
         macrostep: machine_state.macrostep,
         microstep: machine_state.microstep,
         round: machine_state.round
       }}
    ]
  end

  @spec macrostep(
          machine_state :: MachineState.t(),
          effects :: [Effect.t()],
          rounds_left :: MachineState.max_macrostep_rounds() | 0
        ) ::
          {:quiescent | :exhausted, MachineState.t(), [Effect.t()],
           MachineState.max_macrostep_rounds() | 0}
  # ADR-0002 mechanical deviation (ADR-0019). Appendix D's inner loop is
  # unbounded, and the REC allows that ("A macrostep may not [terminate].
  # ... This is currently allowed.") because it presumes an interpreter
  # an "external entity" can cancel mid-macrostep. A pure core (ADR-0003)
  # has no external entity inside a fold - a non-terminating macrostep
  # would hang the calling process with no recourse - so the fold spends
  # one round per `microstep/1` call and stops with a `:budget_exhausted`
  # effect when `max_macrostep_rounds` runs out. The loop's condition and
  # body are otherwise unchanged; `max_macrostep_rounds: :infinity`
  # restores the literal spec behavior for a caller that owns its own
  # interruption.
  #
  # The private accumulator behind `macrostep/1` - repeatedly calls
  # `microstep/1` until it returns `:quiescent`, threading the machine_state
  # and appending each round's effects in order. Not an Appendix D function
  # name; see `macrostep/1`'s own comment. ADR-0002.
  #
  # Exhausted base case: `rounds_left` reached `0` before the fold quiesced,
  # so the fourth element returned is `0` too - the exact budget
  # `main_event_loop/3` sees when it decides whether to `continue` (ADR-0032).
  defp macrostep(machine_state, effects, 0), do: {:exhausted, machine_state, effects, 0}

  # The ordinary round, charged against the budget by `spend/1`; the name
  # carries the same ADR-0002 caveat as the clause above. The quiescent
  # clause returns `rounds_left` unspent - reaching quiescence costs no
  # round beyond the ones already charged - so ADR-0032's re-entry resumes
  # with exactly the budget this fold had left, not a fresh one.
  defp macrostep(machine_state, effects, rounds_left) do
    case microstep(machine_state) do
      {:quiescent, machine_state, round_effects} ->
        {:quiescent, machine_state, effects ++ round_effects, rounds_left}

      {machine_state, round_effects} ->
        macrostep(machine_state, effects ++ round_effects, spend(rounds_left))
    end
  end

  @spec spend(rounds_left :: MachineState.max_macrostep_rounds()) ::
          MachineState.max_macrostep_rounds() | 0
  defp spend(:infinity), do: :infinity
  defp spend(rounds_left), do: rounds_left - 1

  # The eventless probe came back empty. `MachineState.dequeue_internal/1`
  # is the second half of Decision 2's quiescence test (no eventless
  # transition enabled *and* the internal queue is empty).
  #
  # Both branches record the empty eventless probe the same way
  # (`run_selected/3` with `[]`, giving `Trace.TransitionsSelected` with
  # `t_indexes: []`), and both carry out the machine_state selection
  # returned. The terminal branch differs only in tagging its return
  # `:quiescent` so the fold stops - it is a round that made no progress,
  # not a round that did not happen, and the `machine_state` it carries is
  # the one `Selection.select_eventless_transitions/1` handed back, never
  # the one `microstep/1` passed in (see `microstep/1`'s own `@doc`).
  #
  # A dequeued event continues: the `EventDequeued` trace, then selection on
  # the event, then whatever it enables.
  @spec internal_round(machine_state :: MachineState.t()) ::
          {MachineState.t(), [Effect.t()]} | {:quiescent, MachineState.t(), [Effect.t()]}
  defp internal_round(machine_state) do
    case MachineState.dequeue_internal(machine_state) do
      :empty ->
        {machine_state, probe_effects} = run_selected(machine_state, [], nil)
        {:quiescent, machine_state, probe_effects}

      {:ok, event, machine_state} ->
        # The eventless probe above dequeues nothing and runs before this
        # point, so it has no event to write - the pseudocode assigns
        # `_event` only when it has one, and `_event` keeps the previous
        # round's value until this dequeued event's own assignment below.
        {machine_state, eventless_probe_effects} = run_selected(machine_state, [], nil)

        dequeued_trace =
          Effect.trace(machine_state, Effect.Trace.EventDequeued, event: event, from: :internal)

        # datamodel["_event"] = internalEvent (Appendix D)
        machine_state = MachineState.put_event(machine_state, event)

        {machine_state, transitions} = Selection.select_transitions(machine_state, event)
        {machine_state, selected_effects} = run_selected(machine_state, transitions, event)

        {machine_state, eventless_probe_effects ++ dequeued_trace ++ selected_effects}
    end
  end

  # The `if not enabledTransitions.isEmpty(): microstep(enabledTransitions.toList())`
  # tail shared by every selection site (eventless, one dequeued internal
  # event, and - once handle_event/2 lands - the external event): emits
  # `Trace.TransitionsSelected` with `t_indexes: Enum.map(transitions, &
  # &1.t_index)` (the selected transitions themselves, per
  # `Selection.select_transitions/2`'s own note, already in the document
  # order of the states that selected them), then on a non-empty set begins
  # a microstep and runs it. Factored so the microstep counter's writer
  # (`Statifier.MachineState`'s counter contract) has exactly one call site.
  @spec run_selected(
          machine_state :: MachineState.t(),
          transitions :: [Transition.t()],
          event :: Event.t() | nil
        ) :: {MachineState.t(), [Effect.t()]}
  defp run_selected(machine_state, transitions, event) do
    selected_trace =
      Effect.trace(machine_state, Effect.Trace.TransitionsSelected,
        t_indexes: Enum.map(transitions, & &1.t_index),
        event: event
      )

    case transitions do
      [] ->
        {machine_state, selected_trace}

      _enabled ->
        machine_state = MachineState.begin_microstep(machine_state)
        {machine_state, microstep_effects} = microstep(machine_state, transitions)
        {machine_state, selected_trace ++ microstep_effects}
    end
  end

  # `executeTransitionContent(enabledTransitions)` (Appendix D) - each
  # enabled transition's own content block, through the same block runner
  # every other content site uses. The pseudocode iterates
  # `enabledTransitions` in the order it was given; selection already
  # produced them in the document order of the states that selected them,
  # so there is nothing to sort here.
  @spec execute_transition_content(
          machine_state :: MachineState.t(),
          enabled_transitions :: [Transition.t()]
        ) :: {MachineState.t(), [Effect.t()]}
  defp execute_transition_content(machine_state, enabled_transitions) do
    Enum.reduce(enabled_transitions, {machine_state, []}, fn transition, {ms, effects} ->
      {ms, new_effects} =
        Content.execute_block(ms, {:transition, transition.t_index}, transition.content)

      {ms, effects ++ new_effects}
    end)
  end

  @doc """
  `mainEventLoop`'s outer `while running` loop (Appendix D), one call's
  worth of iterations (ADR-0032). The loop itself is
  driven by the caller - one call of `initialize/2` or `handle_event/2`
  reaches here having already run its own selection round - so this
  function is what is left of the pseudocode's loop body after that: fold
  to quiescence with the private `macrostep/3`, run the invoke pass, clear
  `states_to_invoke`, and `continue` (a self-call of the private
  `main_event_loop/3`) when invoking left the internal queue non-empty;
  otherwise run `exit_interpreter/1` when the fold left `running` false, or
  stop and emit the one terminal effect this call produces.

  Delegates immediately to the private `main_event_loop/3`, which carries
  the round budget across every re-entry (ADR-0032) exactly as the private
  `macrostep/3` already carries it across rounds of one fold.
  """
  @spec main_event_loop(machine_state :: MachineState.t()) :: {MachineState.t(), [Effect.t()]}
  def main_event_loop(%MachineState{} = machine_state) do
    main_event_loop(machine_state, [], machine_state.max_macrostep_rounds)
  end

  @spec main_event_loop(
          machine_state :: MachineState.t(),
          effects :: [Effect.t()],
          budget :: MachineState.max_macrostep_rounds() | 0
        ) :: {MachineState.t(), [Effect.t()]}
  # ADR-0002 mechanical deviation (ADR-0032). Appendix D's `continue` after
  # the invoke pass re-enters `mainEventLoop`'s own outer body with no
  # notion of a budget at all. In this port that outer body is
  # `main_event_loop/3` itself, so `continue` is a self-call - and every
  # self-call re-enters the private `macrostep/3`, which would otherwise
  # start a fresh `max_macrostep_rounds` budget on every re-entry, reopening
  # the livelock ADR-0019 closed one loop further out (two states whose
  # <invoke> arguments deterministically error can hand each other control
  # forever). So the budget is threaded through this function exactly as it
  # is already threaded through `macrostep/3`: each re-entry starts with the
  # `rounds_left` the previous fold returned, not a fresh budget, and
  # `terminal_effects/2` is called exactly once here - when the loop stops,
  # not once per fold - so ADR-0019's three-outcome exclusivity survives a
  # re-entry. `main_event_loop/1` still hands this function a fresh budget
  # exactly once per external event, and public `macrostep/1` is unaffected:
  # it calls `macrostep/3` directly and keeps its own single-fold behavior.
  defp main_event_loop(machine_state, effects, budget) do
    {outcome, machine_state, macrostep_effects, budget} =
      macrostep(machine_state, [], budget)

    if machine_state.running do
      # for state in statesToInvoke.sort(entryOrder): for inv in
      # state.invoke.sort(documentOrder): invoke(inv) (Appendix D) -
      # `run_invoke_pass/1` below, in the pseudocode's own position: after
      # the fold reaches this point (running), before the internal-queue
      # re-check. `statesToInvoke.clear()` is the pass's own last step.
      {machine_state, invoke_effects} = run_invoke_pass(machine_state)
      effects = effects ++ macrostep_effects ++ invoke_effects

      # if not internalQueue.isEmpty(): continue (Appendix D). Invoking may
      # have raised internal error events (ADR-0031) and this is the check
      # that iterates to handle them, inside the same `main_event_loop/1`
      # call rather than waiting for the next external event.
      cond do
        MachineState.internal_queue_empty?(machine_state) ->
          {machine_state, effects ++ terminal_effects(machine_state, outcome)}

        budget == 0 ->
          {machine_state, effects ++ terminal_effects(machine_state, :exhausted)}

        true ->
          # `continue` (Appendix D) - the self-call ADR-0032 threads the
          # budget across.
          main_event_loop(machine_state, effects, budget)
      end
    else
      # ADR-0002 mechanical deviation, ADR-0003. Appendix D's
      # `mainEventLoop` owns both queues and blocks on
      # `externalQueue.dequeue()` at the end of every iteration, then checks
      # `isCancelEvent/1` on what it dequeues. This core takes one external
      # event per call, so the outer `while running` loop is driven by the
      # caller (`handle_event/2`), and the waiting external events live in
      # the session, not this struct. The semantics of processing one
      # external event are unchanged; only the storage of the waiting ones
      # moves outward. `isCancelEvent/1` is `Statifier.Session.Inbox.cancel_event?/1`;
      # its effect is `cancel/1` above. `if not running: break` (Appendix D)
      # precedes the invoke pass, so no invoke pass runs and no re-entry
      # check happens on this path - `exit_interpreter/1` is the loop's
      # only remaining tail.
      {machine_state, exit_effects} = exit_interpreter(machine_state)

      {machine_state,
       effects ++ macrostep_effects ++ terminal_effects(machine_state, outcome) ++ exit_effects}
    end
  end

  # `for state in statesToInvoke.sort(entryOrder): for inv in
  # state.invoke.sort(documentOrder): invoke(inv)` then `statesToInvoke.clear()`
  # (Appendix D) - the invoke pass. `states_to_invoke` sorts into entry order
  # through `Machine.document_order/2`, the same sort `enter_states/2` uses
  # for the same reason (the pseudocode itself calls for it, so this is not
  # an ADR-0002 deviation); each state's compiled `invoke` list is already in
  # document order, so no sort is needed within a state. One
  # `Evaluator.context/1` is built for the whole pass and threaded through -
  # `ExitEntry.evaluate_donedata_params/3`'s idiom - re-bound after each
  # `idlocation` write (`Datamodel.write_location/4` returns the updated
  # context) so a later invocation's arguments can see an earlier one's
  # written id, exactly as any other threaded-context fold in this codebase
  # can see an earlier write in the same fold.
  @spec run_invoke_pass(machine_state :: MachineState.t()) :: {MachineState.t(), [Effect.t()]}
  defp run_invoke_pass(%MachineState{machine: machine} = machine_state) do
    state_order = Machine.document_order(machine, machine_state.states_to_invoke)
    context = Evaluator.context(machine_state)

    {machine_state, _context, effects} =
      Enum.reduce(state_order, {machine_state, context, []}, fn state_index,
                                                                {ms, context, effects} ->
        {ms, context, state_effects} = invoke_state(ms, context, state_index)
        {ms, context, effects ++ state_effects}
      end)

    invoke_ids = for {:invoke, %Effect.Invoke{invoke_id: invoke_id}} <- effects, do: invoke_id

    trace =
      Effect.trace(machine_state, Effect.Trace.InvokePass,
        state_indexes: state_order,
        invoke_ids: invoke_ids
      )

    {%{machine_state | states_to_invoke: MapSet.new()}, effects ++ trace}
  end

  # One state's own `for inv in state.invoke.sort(documentOrder): invoke(inv)`
  # (Appendix D) - `state.invoke` is already compiled in document order
  # (`Statifier.Machine.Invoke.index`), so no sort happens here.
  @spec invoke_state(
          machine_state :: MachineState.t(),
          context :: Predicator.Context.t(),
          state_index :: non_neg_integer()
        ) :: {MachineState.t(), Predicator.Context.t(), [Effect.t()]}
  defp invoke_state(%MachineState{machine: machine} = machine_state, context, state_index) do
    state = Machine.at(machine, state_index)

    state.invoke
    |> Enum.with_index()
    |> Enum.reduce({machine_state, context, []}, fn {invoke, invoke_index},
                                                    {ms, context, effects} ->
      {ms, context, new_effects} =
        invoke_one(ms, context, state, state_index, invoke, invoke_index)

      {ms, context, effects ++ new_effects}
    end)
  end

  # `invoke(inv)` (Appendix D 6.4) - one invocation's own body. Every
  # argument (`type`/`typeexpr`, `src`/`srcexpr`, `namelist` and `<param>`
  # locations/exprs, `<content expr>`) is resolved against the threaded
  # context; the first failure among them raises `error.execution` and
  # aborts *this* invocation only (ADR-0031, "the element", not the state's
  # whole `invoke` list) - siblings already invoked or invoked afterward are
  # unaffected, since each invocation is independent work threaded through
  # the same accumulator rather than a fold that stops on first error.
  #
  # On success: `invoke_id` is the author's literal `id`, or `state.id <>
  # "." <> "inv_" <> counter`, or bare `inv_<counter>` when the state has
  # no `id` (ADR-0008 as amended 2026-08-15). `idlocation`, when set, is written through
  # `Datamodel.write_location/4` - a write failure is a step-4-shaped
  # failure, same abort, no effect. Otherwise the invocation is recorded in
  # `active_invocations` and one `{:invoke, %Effect.Invoke{}}` is emitted.
  @spec invoke_one(
          machine_state :: MachineState.t(),
          context :: Predicator.Context.t(),
          state :: Machine.State.t(),
          state_index :: non_neg_integer(),
          invoke :: MInvoke.t(),
          invoke_index :: non_neg_integer()
        ) :: {MachineState.t(), Predicator.Context.t(), [Effect.t()]}
  defp invoke_one(machine_state, context, state, state_index, invoke, invoke_index) do
    with {:ok, type} <- resolve_expr(context, invoke.type),
         {:ok, src} <- resolve_expr(context, invoke.src),
         {:ok, raw_params} <- resolve_params(context, invoke.namelist ++ invoke.params),
         {:ok, content} <- resolve_content(context, invoke.content) do
      {invoke_id, machine_state} = generate_invoke_id(machine_state, state, invoke)

      case maybe_write_idlocation(machine_state, context, invoke.idlocation, invoke_id) do
        {:ok, machine_state, context, write} ->
          machine_state =
            record_active_invocation(machine_state, state_index, invoke_index, invoke_id)

          effect =
            {:invoke,
             %Effect.Invoke{
               invoke_id: invoke_id,
               type: type,
               src: src,
               params: EventData.coerce({:params, raw_params}),
               content: content,
               autoforward: invoke.autoforward,
               state_index: state_index,
               invoke_index: invoke_index,
               macrostep: machine_state.macrostep,
               microstep: machine_state.microstep,
               round: machine_state.round
             }}

          # The datamodel write, when there is one, precedes the :invoke
          # effect it accompanies - same ordering rule <send idlocation>
          # follows.
          effects =
            datamodel_change_effects(
              write,
              invoke.idlocation,
              state_index,
              invoke_index,
              machine_state
            ) ++
              [effect]

          {machine_state, context, effects}

        {:error, reason} ->
          {abort_invocation(machine_state, state_index, invoke_index, reason), context, []}
      end
    else
      {:error, reason} ->
        {abort_invocation(machine_state, state_index, invoke_index, reason), context, []}
    end
  end

  # `type`/`typeexpr` and `src`/`srcexpr` - `nil` when the author wrote
  # neither, `Evaluator.evaluate/2` (which already handles both `{:static,
  # _}` and `{:compiled, _, _}`) otherwise.
  @spec resolve_expr(context :: Predicator.Context.t(), expr :: Machine.expr() | nil) ::
          {:ok, term()} | {:error, term()}
  defp resolve_expr(_context, nil), do: {:ok, nil}
  defp resolve_expr(context, expr), do: Evaluator.evaluate(context, expr)

  # `namelist` and `<param>` locations/exprs, already merged in document
  # order by the caller. Unlike `ExitEntry.evaluate_donedata_params/3`
  # (spec 5.7's "MUST ignore the name and value" - each `<param>` fails
  # independently), 6.4's MUST terminates the whole element on the first
  # failure, so this stops at the first error instead of dropping it and
  # continuing.
  @spec resolve_params(context :: Predicator.Context.t(), params :: [Param.t()]) ::
          {:ok, [{String.t(), term()}]} | {:error, term()}
  defp resolve_params(context, params) do
    Enum.reduce_while(params, {:ok, []}, fn %Param{name: name, expr: expr}, {:ok, pairs} ->
      case Evaluator.evaluate(context, expr) do
        {:ok, value} -> {:cont, {:ok, [{name, value} | pairs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, reason} -> {:error, reason}
    end
  end

  # `<content>` under `<invoke>` - `nil` when absent, `<content>`'s text
  # body coerced through `EventData.coerce({:text, _})` when static, or
  # `<content expr>` evaluated and coerced through `{:value, _}` when
  # compiled. Success only: a failed `<content expr>` is this function's
  # caller's `with` failure, not this function's own.
  @spec resolve_content(context :: Predicator.Context.t(), content :: Machine.expr() | nil) ::
          {:ok, term()} | {:error, term()}
  defp resolve_content(_context, nil), do: {:ok, nil}
  defp resolve_content(_context, {:static, text}), do: {:ok, EventData.coerce({:text, text})}

  defp resolve_content(context, {:compiled, _predicator_compiled, _source} = expr) do
    case Evaluator.evaluate(context, expr) do
      {:ok, value} -> {:ok, EventData.coerce({:value, value})}
      {:error, reason} -> {:error, reason}
    end
  end

  # ADR-0008 as amended (2026-08-15): the author's literal
  # `id`, used verbatim and never composed, or the generated
  # `state.id <> "." <> "inv_" <> counter` / bare `inv_<counter>` when the
  # state has no `id` - generated fresh for *this* invocation, not memoized
  # on the `<invoke>` element (3.14: "not at load time but each time the
  # element is executed", and a state entered twice invokes twice, each
  # with its own id).
  #
  # `counter` is `machine_state.invoke_counter`, one session-global
  # auto-increment - not per-state, not per-element (6.4.1 hangs its
  # uniqueness MUST on the platformid itself, so per-state counters would
  # be nonconformant). It is read from and written back to
  # `%MachineState{}` rather than generated at the call site: reading the
  # wall clock and a CSPRNG would make this function
  # `(state, event, clock, entropy) -> ...` instead of ADR-0003's
  # `(state, event) -> {state, [effect]}`, observably so because `<invoke
  # idlocation>` writes the generated id into the datamodel. A pure counter
  # replays identically. ADR-0003 wins over ADR-0008's original identifier
  # aesthetics where the two collide.
  #
  # An author-written id never advances the counter - only a generated id
  # consumes the session-global sequence, so `generate_invoke_id/3` returns
  # `machine_state` unchanged on that clause.
  @spec generate_invoke_id(
          machine_state :: MachineState.t(),
          state :: Machine.State.t(),
          invoke :: MInvoke.t()
        ) :: {String.t(), MachineState.t()}
  defp generate_invoke_id(machine_state, _state, %MInvoke{id: id}) when is_binary(id),
    do: {id, machine_state}

  defp generate_invoke_id(%MachineState{invoke_counter: counter} = machine_state, state, %MInvoke{
         id: nil
       }) do
    machine_state = %{machine_state | invoke_counter: counter + 1}
    platformid = "inv_" <> Integer.to_string(counter + 1)

    invoke_id =
      case state.id do
        nil -> platformid
        state_id -> state_id <> "." <> platformid
      end

    {invoke_id, machine_state}
  end

  # `idlocation`'s write (6.4.1) - a no-op tuple shaped like
  # `Datamodel.write_location/4`'s own success return when the attribute is
  # absent, so the caller's `case` needs only one shape regardless.
  @spec maybe_write_idlocation(
          machine_state :: MachineState.t(),
          context :: Predicator.Context.t(),
          idlocation :: String.t() | nil,
          invoke_id :: String.t()
        ) ::
          {:ok, MachineState.t(), Predicator.Context.t(), Datamodel.Write.t() | nil}
          | {:error, term()}
  defp maybe_write_idlocation(machine_state, context, nil, _invoke_id),
    do: {:ok, machine_state, context, nil}

  defp maybe_write_idlocation(machine_state, context, idlocation, invoke_id),
    do: Datamodel.write_location(machine_state, context, idlocation, invoke_id)

  # `nil` (no idlocation, or the write failed and never reached here) -> no
  # effect; a %Datamodel.Write{} -> one {:datamodel_change, _} effect.
  # `c_index: nil` and `owner: {:invoke, state_index, invoke_index}` - the
  # widened case DatamodelChange's own `owner/0` declares, since this write
  # belongs to no content block.
  @spec datamodel_change_effects(
          write :: Datamodel.Write.t() | nil,
          idlocation :: String.t() | nil,
          state_index :: non_neg_integer(),
          invoke_index :: non_neg_integer(),
          machine_state :: MachineState.t()
        ) :: [{:datamodel_change, Effect.DatamodelChange.t()}]
  defp datamodel_change_effects(nil, _idlocation, _state_index, _invoke_index, _machine_state),
    do: []

  defp datamodel_change_effects(
         %Datamodel.Write{} = write,
         idlocation,
         state_index,
         invoke_index,
         machine_state
       ) do
    [
      {:datamodel_change,
       %Effect.DatamodelChange{
         location_path: write.path,
         location_source: idlocation,
         new_value: write.new_value,
         prior_value: write.prior_value,
         c_index: nil,
         owner: {:invoke, state_index, invoke_index},
         macrostep: machine_state.macrostep,
         microstep: machine_state.microstep
       }}
    ]
  end

  # `active_invocations[{state_index, invoke_index}] = inv.invokeid`
  # (Appendix D stores this on `inv` itself; see `MachineState`'s own
  # moduledoc section on why it is hoisted here instead).
  @spec record_active_invocation(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          invoke_index :: non_neg_integer(),
          invoke_id :: String.t()
        ) :: MachineState.t()
  defp record_active_invocation(machine_state, state_index, invoke_index, invoke_id) do
    %{
      machine_state
      | active_invocations:
          Map.put(machine_state.active_invocations, {state_index, invoke_index}, invoke_id)
    }
  end

  # ADR-0031: any failed argument raises `error.execution` with origin
  # `{:invoke, state_index, invoke_index}` and produces no `Effect.Invoke`
  # for this invocation.
  @spec abort_invocation(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          invoke_index :: non_neg_integer(),
          reason :: term()
        ) :: MachineState.t()
  defp abort_invocation(machine_state, state_index, invoke_index, reason) do
    MachineState.raise_platform(
      machine_state,
      "error.execution",
      {:invoke, state_index, invoke_index},
      data: reason
    )
  end

  @doc """
  `exitInterpreter` (Appendix D) - every active state exited in exit order,
  the top-level final's `<donedata>` collected, then the terminal effects.

  Body, in the pseudocode's own order, with the deviations Decision 10
  records:

  1. The configuration is captured *before* the walk (`configuration_at_exit`)
     - both `Trace.Done.configuration` and `Effect.Done.configuration`
     document themselves as "the configuration as it stood at exit", which
     the walk would otherwise leave empty.
  2. `states_to_exit` = `Machine.exit_order/2` over the configuration, and
     `Trace.ExitSet` is emitted over it before any state leaves - the same
     phase-boundary row `exit_states/2` emits, at the one other place this
     engine exits states. ADR-0012 item 2 binds the row to the boundaries
     Appendix D itself names, and `exitInterpreter` names one: its
     `statesToExit` is the same variable `exitStates` computes. `Trace.Done`
     carries the same set as `configuration`, but it arrives after the walk
     and means "the run ended here", so it is not a substitute for a marker
     that means "these are about to be exited".
  3. Each state, in exit order, runs its `onexit` blocks
     (`ExitEntry.run_onexit_blocks/2` - the same per-state body
     `exit_states/2`'s `depart/2` runs), then each of its live invocations
     is cancelled (`ExitEntry.cancel_invocations_for_state/2` - the same
     shared walk `depart/2` runs, so the two exit paths cannot drift),
     before it leaves the configuration.
  4. **No history recording.** Appendix D's `exitInterpreter` has no
     history-recording loop at all - unlike `exitStates`, which has two
     consecutive `for s in statesToExit` loops for exactly that reason.
     "Port as written" therefore means recording nothing here; this walk
     never touches `machine_state.history_values`.
  5. `returnDoneEvent(s.donedata)` fires for the one state, if any, that is
     `Machine.final?/2` with `parent == 0` - `isFinalState(s) and
     isSCXMLElement(s.parent)`, the same test
     `ExitEntry.raise_completion_events/2` already makes. Since the root is
     compound, at most one child is active, so at most one top-level final
     is ever in the exit set. Its donedata (`ExitEntry.donedata/2`) becomes
     both `Trace.Done`'s and `Effect.Done`'s `donedata`. A failed
     `<content expr>` raises `error.execution` onto the *returned*
     `machine_state`'s internal queue - nothing ever dequeues it, since the
     event loop has already stopped by the time this function runs, but that
     is Appendix D's own consequence (5.6/5.7's error rule is unqualified,
     and `exitInterpreter` runs after the loop) rather than a deviation this
     port introduces. It
     is still observable: `MachineState.internal_events/1` on the returned
     terminal state shows it.
  6. The terminal effects are appended last, `{:done, %Effect.Done{}}` last
     of all - `returnDoneEvent` becomes a returned effect rather than an I/O
     call (ADR-0003), and moving its emission to the end of the list is a
     mechanical reordering: effects are a returned list, not an I/O call,
     so nothing the pseudocode's own terms observe changes order. Both
     `Trace.Done` and `Effect.Done` are populated from the same
     `configuration_at_exit` and `donedata` locals, so the trace row and the
     core effect always agree on the terminal position.

  `status: :done` is set only here, at the very end - the window
  `MachineState`'s moduledoc describes between `running: false` (from
  top-level final entry) and `status: :done` (once this walk finishes).
  """
  @spec exit_interpreter(machine_state :: MachineState.t()) :: {MachineState.t(), [Effect.t()]}
  def exit_interpreter(%MachineState{machine: machine} = machine_state) do
    configuration_at_exit = machine_state.configuration
    states_to_exit = Machine.exit_order(machine, configuration_at_exit)

    exit_set_trace = Effect.trace(machine_state, Effect.Trace.ExitSet, indexes: states_to_exit)

    {machine_state, donedata, exit_effects} =
      Enum.reduce(states_to_exit, {machine_state, nil, []}, fn state_index,
                                                               {ms, donedata, effects} ->
        {ms, onexit_effects} = ExitEntry.run_onexit_blocks(ms, state_index)

        # `for inv in s.invoke: cancelInvoke(inv)` (Appendix D) - the same
        # shared walk `ExitEntry.depart/2` runs on the ordinary exit path,
        # so the two never drift.
        {ms, cancel_effects} = ExitEntry.cancel_invocations_for_state(ms, state_index)

        ms = %{ms | configuration: MapSet.delete(ms.configuration, state_index)}

        {ms, donedata} =
          if Machine.final?(machine, state_index) and Machine.at(machine, state_index).parent == 0 do
            ExitEntry.donedata(ms, state_index)
          else
            {ms, donedata}
          end

        {ms, donedata, effects ++ onexit_effects ++ cancel_effects}
      end)

    done_trace =
      Effect.trace(machine_state, Effect.Trace.Done,
        configuration: configuration_at_exit,
        donedata: donedata
      )

    done_effect =
      {:done,
       %Effect.Done{
         donedata: donedata,
         configuration: configuration_at_exit,
         macrostep: machine_state.macrostep,
         microstep: machine_state.microstep,
         round: machine_state.round
       }}

    machine_state = %{machine_state | status: :done}

    {machine_state, exit_set_trace ++ exit_effects ++ done_trace ++ [done_effect]}
  end
end
