defmodule Exstate.StateNode do
  #defstruct [:config, :key, :id, :version, :type, :path, :states, :parent, :machine, :order]
  defstruct [:id, :initial, :states]

  def new(id, initial, [first_state | _tail] = states) when initial == "" do
    %__MODULE__{id: id, initial: first_state.id, states: states}
  end

  def new id, initial, states do
    %__MODULE__{id: id, initial: initial, states: states}
  end
end
