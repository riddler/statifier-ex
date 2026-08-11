defmodule Statifier.Interpreter do
  @moduledoc """
  Appendix D's outer loop, ported function for function (ADR-0002), with its
  loop state reified onto `%Statifier.MachineState{}` per
  `docs/observability.md` constraint 1: any `%MachineState{}` value is a
  complete, resumable interpreter position, and this module keeps nothing
  of that position on the call stack.

  ## The map of the loop

  Appendix D's `interpret`/`mainEventLoop`/`microstep`/`exitInterpreter`
  collapse onto this module's functions. Only `microstep/2` and `microstep/1`
  are landed so far - the rest of this table names where the remaining
  pieces of st-wju.6 will land, so a reader sees the whole shape even though
  only the first row is real yet:

  | This module | Appendix D |
  |---|---|
  | `microstep/2` | `microstep(enabledTransitions)` verbatim |
  | `microstep/1` | `mainEventLoop`'s inner `while running and not macrostepDone` loop body, hoisted into a value so a paused position is data, not a stack frame |
  | `macrostep/1` (not yet landed) | that same inner loop, folded to quiescence |
  | `main_event_loop/1` (not yet landed) | one outer-loop iteration plus the trailing `exitInterpreter()` |
  | `exit_interpreter/1` (not yet landed) | `exitInterpreter` |
  | `initialize/2`, `handle_event/2` (not yet landed) | `interpret`'s two entry seams |

  ## Counters

  `Statifier.MachineState`'s counter contract is the source of truth;
  restated here only for where this module writes it. `microstep`'s writer
  (`Statifier.MachineState`'s docs name it) has exactly one call site in
  this module: the non-empty branch of `run_selected/3`, the private tail
  shared by every selection round (eventless, one dequeued internal event,
  and - once `handle_event/2` lands - the external event). A selection
  round that finds nothing to run never reaches that call, because no exit
  or entry happened - the same "no exit or entry happened" rule
  `MachineState`'s counter contract states for why an empty round does not
  advance `microstep`.

  This is also why the trace effects a selection round emits
  (`Trace.EventDequeued`, `Trace.TransitionsSelected`) are always stamped
  *one microstep behind* the `Trace.ExitSet` that follows them when the
  round is non-empty: both are built from the `machine_state` selection
  returned, which is still at the *previous* microstep's count - the
  counter only advances afterward, inside `run_selected/3`, right before
  `microstep/2` runs. The counter cannot be advanced before the selection
  result is known, because an empty result must not advance it.

  ## Deviations, with their reasons (ADR-0002)

  - **`microstep/1` is not a pseudocode function name.** It is
    `mainEventLoop`'s inner loop body, hoisted so a debugger can pause
    between rounds without support code (constraint 1). See `microstep/1`'s
    own `@doc`.
  - **The terminal eventless probe emits no `Trace.TransitionsSelected`.**
    When `Selection.select_eventless_transitions/1` finds nothing *and* the
    internal queue is also empty, `microstep/1` returns bare `:quiescent`
    before any trace is built - the round produces no effect list at all,
    so there is nothing to append a trace to. Every *other* selection,
    including an eventless probe that comes back empty while the queue
    still has an event, does emit `Trace.TransitionsSelected` with
    `t_indexes: []`. See `internal_round/1`.
  - **The machine_state `Selection` returns is threaded, never discarded.**
    Both `Selection.select_eventless_transitions/1` and
    `Selection.select_transitions/2` return `{machine_state, transitions}`,
    and this module continues with the returned `machine_state` rather than
    the one it passed in, so a later bead's `condition_match/2` change
    lands as a body change in `Selection`, not a signature change here.
  """

  alias Statifier.Event
  alias Statifier.Interpreter.Content
  alias Statifier.Interpreter.ExitEntry
  alias Statifier.Interpreter.Selection
  alias Statifier.Machine.Transition
  alias Statifier.MachineState

  require Statifier.Effect, as: Effect

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
  function name itself. One call makes exactly one round of progress:

  - Not `running` - returns `:quiescent`, nothing changes.
  - An eventless transition is enabled - the round runs it, exactly as
    `microstep/2` above.
  - No eventless transition is enabled - falls to `internal_round/1`,
    which dequeues one internal event (if any) and selects on it.

  Never runs two rounds and never inspects the call stack for a paused
  position: the returned `machine_state` (or the caller's own unchanged
  one, on `:quiescent`) *is* the position.
  """
  @spec microstep(machine_state :: MachineState.t()) ::
          {MachineState.t(), [Effect.t()]} | :quiescent
  def microstep(%MachineState{running: false}), do: :quiescent

  def microstep(%MachineState{} = machine_state) do
    {machine_state, eventless_transitions} = Selection.select_eventless_transitions(machine_state)

    case eventless_transitions do
      [] -> internal_round(machine_state)
      _enabled -> run_selected(machine_state, eventless_transitions, nil)
    end
  end

  # The eventless probe came back empty. `MachineState.dequeue_internal/1`
  # is the second half of Decision 2's :quiescent test (no eventless
  # transition enabled *and* the internal queue is empty) - both tests are
  # made before any mutation, so an `:empty` queue here yields bare
  # `:quiescent` with no trace built at all: the round produces no effect
  # list, so there is nothing to append one to.
  #
  # A dequeued event is a genuine round: it first records the eventless
  # probe that came up empty (`run_selected/3` with `[]`, giving
  # `Trace.TransitionsSelected` with `t_indexes: []` - Decision 2's
  # non-terminal case), then the `EventDequeued` trace, then selects on the
  # event and runs whatever it enables.
  @spec internal_round(machine_state :: MachineState.t()) ::
          {MachineState.t(), [Effect.t()]} | :quiescent
  defp internal_round(machine_state) do
    case MachineState.dequeue_internal(machine_state) do
      :empty ->
        :quiescent

      {:ok, event, machine_state} ->
        {machine_state, eventless_probe_effects} = run_selected(machine_state, [], nil)

        dequeued_trace =
          Effect.trace(machine_state, Effect.Trace.EventDequeued, event: event, from: :internal)

        # datamodel["_event"] = internalEvent (Appendix D) - st-af3's seam;
        # no datamodel write happens in this bead.

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
end
