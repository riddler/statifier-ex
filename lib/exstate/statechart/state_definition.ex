defmodule Exstate.Statechart.StateDefinition do
  defstruct [:id, :initial, :states, :transitions]

  def new(id, initial, [first_state | _tail] = states, transitions) when initial == "" do
    %__MODULE__{id: id, initial: first_state.id, states: states, transitions: transitions}
  end

  def new id, initial, states, transitions do
    %__MODULE__{id: id, initial: initial, states: states, transitions: transitions}
  end

  def node_for %__MODULE__{} = node, path do
    node.states |> Enum.find(fn child -> child.id == path end)
  end
end
