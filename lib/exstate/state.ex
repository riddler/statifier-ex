defmodule Exstate.State do
  def get_initial(%Exstate.States.AtomicState{} = state) do
    state
  end

  def get_initial(%Exstate.States.CompoundState{} = state) do
    (Enum.find(state.states, fn child -> state.initial_attribute == child.id end) ||
      List.first state.states)
      |> get_initial
  end

  def new(definition) do
    if length(definition.states) == 0 do
      Exstate.States.AtomicState.new definition
    else
      Exstate.States.CompoundState.new definition
    end
  end
end
