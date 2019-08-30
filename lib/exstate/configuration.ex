defmodule Exstate.Configuration do
  defstruct [:active]

  def new(state) do
    %__MODULE__{active: [state]}
  end

  def literal(%__MODULE__{} = configuration) do
    Enum.map(configuration.active, fn state -> state.id end)
  end

  #def new(id, initial, [first_state | _tail] = states, transitions) when initial == "" do
  #  %__MODULE__{id: id, initial: first_state.id, states: states, transitions: transitions}
  #end

  #def new id, initial, states, transitions do
  #  %__MODULE__{id: id, initial: initial, states: states, transitions: transitions}
  #end
end
