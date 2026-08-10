defmodule Statifier.Interpreter.ExitEntry do
  @moduledoc """
  Appendix D's exit and entry blocks, ported function for function
  (ADR-0002) - the half of the algorithm that changes the configuration.
  `Statifier.Interpreter.Selection` answers "which transitions fire and
  what would they leave"; this module actually leaves and enters states.

  `machine_state` stands in for the pseudocode's globals exactly as
  `Statifier.Interpreter.Selection`'s moduledoc states for the same reason
  (`docs/observability.md` constraint 1, plan Decision 3 for this bead) -
  every function here that reads a global takes `machine_state` as its
  first argument.

  ## Return shapes (Decision 2)

  `exit_states/2` and `enter_states/2` are the two functions in this bead
  that both mutate the position and emit effects, so both return
  `{MachineState.t(), [Effect.t()]}` - the shape `docs/observability.md`
  fixes for `microstep/1`, their only future caller (st-wju.6). Effect
  order within the returned list is emission order: the trace effect
  first, then each block's effects in the order the blocks ran.

  ## Ordering (Decision 4)

  Exit order and entry order are never hand-sorted here: `exit_states/2`
  pipes `Statifier.Interpreter.Selection.compute_exit_set/2`'s `MapSet`
  through `Statifier.Machine.exit_order/2` (descending index).

  ## The content seam (Decision 6)

  Every call site that would run executable content - `<onexit>`,
  `<onentry>`, an `<initial>` transition's content, default history
  content - goes through the private `execute_block/3` seam, whose body is
  a no-op stub today. st-wju.5 owns the block runner and the
  `Trace.ContentExecuted` emission that wraps it; this bead owns only
  *where and in what order* blocks run. Replacing `execute_block/3`'s body
  changes no call site and no ordering.

  ## History recording (Decision 7)

  `exit_states/2` records history in a full first pass over the exit set,
  reading the configuration exactly as it stood before any state exited -
  *before* the first `onexit` runs and before any state is removed. The
  pseudocode writes two consecutive `for s in statesToExit` loops for
  exactly this reason: recording inside the delete loop would let a
  later-exiting state's deep history see a configuration its own siblings
  have already been removed from.
  """

  alias Statifier.Interpreter.Selection
  alias Statifier.Machine
  alias Statifier.Machine.Content
  alias Statifier.Machine.Transition
  alias Statifier.MachineState

  require Statifier.Effect, as: Effect

  @doc """
  `exitStates` (Appendix D) - the exit-ordered set of states
  `enabled_transitions` leave, with history recorded before any state
  exits and `onexit` content run per state in exit order.

  Body, in the pseudocode's own order:

  1. `states_to_exit` = `Selection.compute_exit_set/2` over
     `enabled_transitions`, piped through `Machine.exit_order/2` for exit
     order (Decision 4) - the boundary decision this bead's own note
     records: `compute_exit_set/2` returns an unordered `MapSet`, and
     ordering it is this function's job, not `Selection`'s.
  2. The pseudocode's `statesToInvoke.delete(s)` line is skipped:
     `states_to_invoke` is deliberately absent from `MachineState` until
     st-cmq (invoke) adds it with its own caller.
  3. `Effect.trace(machine_state, Effect.Trace.ExitSet, indexes:
     states_to_exit)` is emitted before any mutation (Decision 13), over
     the *original* `machine_state` - the macro's own hygienic
     `machine_state` rebinding inside its expansion does not touch this
     function's parameter (Decision 13's own note).
  4. `record_history_values/2` runs its whole first pass over
     `states_to_exit`, reading the untouched configuration (Decision 7).
  5. `states_to_exit` is reduced through `depart/2`, each state running its
     `onexit` blocks and then leaving the configuration.
  """
  @spec exit_states(machine_state :: MachineState.t(), enabled_transitions :: [Transition.t()]) ::
          {MachineState.t(), [Effect.t()]}
  def exit_states(%MachineState{machine: machine} = machine_state, enabled_transitions) do
    states_to_exit =
      machine_state
      |> Selection.compute_exit_set(enabled_transitions)
      |> then(&Machine.exit_order(machine, &1))

    trace_effects = Effect.trace(machine_state, Effect.Trace.ExitSet, indexes: states_to_exit)

    machine_state = record_history_values(machine_state, states_to_exit)

    {machine_state, depart_effects} =
      Enum.reduce(states_to_exit, {machine_state, []}, fn state_index, {ms, effects} ->
        {ms, new_effects} = depart(ms, state_index)
        {ms, effects ++ new_effects}
      end)

    {machine_state, trace_effects ++ depart_effects}
  end

  # `exitStates`'s history-recording loop - `for s in statesToExit: for h
  # in s.history: historyValue[h.id] = ...` - the whole first pass, run
  # before any `onexit` content and before any state leaves the
  # configuration (Decision 7). Reads `history_children` (populated by the
  # compiler), so this is a field read per exiting state, never a scan.
  @spec record_history_values(
          machine_state :: MachineState.t(),
          states_to_exit :: [non_neg_integer()]
        ) :: MachineState.t()
  defp record_history_values(%MachineState{machine: machine} = machine_state, states_to_exit) do
    Enum.reduce(states_to_exit, machine_state, fn state_index, ms ->
      machine
      |> Machine.at(state_index)
      |> Map.fetch!(:history_children)
      |> Enum.reduce(ms, &record_one_history_value(&2, state_index, &1))
    end)
  end

  # `historyValue[h.id] = ...` for one history child `history_index` of one
  # exiting state `state_index` - overwrites unconditionally, which is what
  # the pseudocode's assignment does (a revisit replaces the previous
  # record rather than merging).
  @spec record_one_history_value(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          history_index :: non_neg_integer()
        ) :: MachineState.t()
  defp record_one_history_value(machine_state, state_index, history_index) do
    value = recorded_value(machine_state, state_index, history_index)
    %{machine_state | history_values: Map.put(machine_state.history_values, history_index, value)}
  end

  # The two lambdas `exitStates` records history with, verbatim (Decision
  # 7): a `:shallow` history records `s`'s active *immediate* children; a
  # `:deep` history records `s`'s active *atomic descendants*.
  # `descendant?/3` is proper, which is correct here because `s` is not
  # atomic when it has a history child.
  @spec recorded_value(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          history_index :: non_neg_integer()
        ) :: MapSet.t(non_neg_integer())
  defp recorded_value(
         %MachineState{machine: machine, configuration: configuration},
         state_index,
         history_index
       ) do
    case Machine.at(machine, history_index).history_type do
      :shallow ->
        MapSet.filter(configuration, &(Machine.at(machine, &1).parent == state_index))

      :deep ->
        MapSet.filter(
          configuration,
          &(Machine.atomic?(machine, &1) and Machine.descendant?(machine, &1, state_index))
        )
    end
  end

  # `exitStates`'s per-state exit body: run its onexit blocks, skip
  # `cancelInvoke` (st-cmq owns invocations; nothing exists yet to
  # cancel), then remove it from the configuration.
  @spec depart(machine_state :: MachineState.t(), state_index :: non_neg_integer()) ::
          {MachineState.t(), [Effect.t()]}
  defp depart(machine_state, state_index) do
    {machine_state, effects} = run_onexit_blocks(machine_state, state_index)

    machine_state = %{
      machine_state
      | configuration: MapSet.delete(machine_state.configuration, state_index)
    }

    {machine_state, effects}
  end

  # `state.onexit` in document order, each block through the `execute_block/3`
  # seam with `{:onexit, state_index, ordinal}` - `ordinal` is the block's
  # position in the state's own `onexit` list, exactly what
  # `Machine.Content.owner()` documents it to be.
  @spec run_onexit_blocks(machine_state :: MachineState.t(), state_index :: non_neg_integer()) ::
          {MachineState.t(), [Effect.t()]}
  defp run_onexit_blocks(%MachineState{machine: machine} = machine_state, state_index) do
    machine
    |> Machine.at(state_index)
    |> Map.fetch!(:onexit)
    |> Enum.with_index()
    |> Enum.reduce({machine_state, []}, fn {block, ordinal}, {ms, effects} ->
      {ms, new_effects} = execute_block(ms, {:onexit, state_index, ordinal}, block.content)
      {ms, effects ++ new_effects}
    end)
  end

  # ADR-0002: the pseudocode's `executeContent(content)`. st-wju.5 owns the
  # block runner and the `Trace.ContentExecuted` emission that wraps it;
  # this bead owns only *where and in what order* blocks run, which is
  # what the exit/entry pseudocode defines. Replacing this body with a
  # call to that runner changes no call site and no ordering (Decision 6).
  @spec execute_block(
          machine_state :: MachineState.t(),
          owner :: Content.owner(),
          c_indexes :: [non_neg_integer()]
        ) :: {MachineState.t(), [Effect.t()]}
  defp execute_block(machine_state, _owner, _c_indexes), do: {machine_state, []}
end
