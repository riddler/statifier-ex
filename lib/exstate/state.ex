defmodule Exstate.State do
  def get_initial(%Exstate.States.AtomicState{} = state) do
    [state]
  end

  def get_initial(%Exstate.States.CompoundState{} = state) do
    (Enum.find(state.states, fn child -> state.initial_attribute == child.id end) ||
      List.first state.states)
      |> get_initial
  end

  def get_initial(%Exstate.States.ParallelState{} = state) do
    state.states
      |> Enum.map(fn child -> child |> get_initial end)
      |> List.flatten
  end



  def gather_states(%Exstate.States.AtomicState{} = state) do
    [state]
  end

  def gather_states(%Exstate.States.CompoundState{} = state) do
    state.states
      |> Enum.map(fn child -> child |> gather_states end)
      |> List.flatten([state])
  end

  def gather_states(%Exstate.States.ParallelState{} = state) do
    state.states
      |> Enum.map(fn child -> child |> gather_states end)
      |> List.flatten([state])
  end


  def new(definition) do
    cond do
      length(definition.states) == 0 ->
        Exstate.States.AtomicState.new definition
      definition.type == "parallel" ->
        Exstate.States.ParallelState.new definition
      true ->
        Exstate.States.CompoundState.new definition
    end
  end
end
