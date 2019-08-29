defmodule Exstate.Journey do
  defstruct [:machine, :current_state]

  def new machine do
    node = Exstate.StateNode.node_for machine, machine.initial
    %__MODULE__{machine: machine, current_state: node}
  end

  def transition!(%__MODULE__{} = journey, next_state) do
    node = Exstate.StateNode.node_for journey.machine, next_state
    %__MODULE__{journey | current_state: node}
  end
end
