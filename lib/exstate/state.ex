defmodule Exstate.State do
  defstruct [
    :definition,
    :id,
    :initial,
    :states,
    :transitions
  ]

  def new(definition) do
    states = definition.states
      |> Enum.map(fn child -> __MODULE__.new(child) end)

    transitions = definition.transitions
                  |> Enum.map(fn transition ->
                    Exstate.Transition.new(definition.id, transition.target, transition.event)
                  end)

    initial = Enum.find(states, fn state -> definition.initial == state.id end) ||
      List.first states

    self = %__MODULE__{
      id: definition.id,
      initial: initial,
      states: states,
      transitions: transitions
    }
  end

  #def new(id, initial, [first_state | _tail] = states, transitions) when initial == "" do
  #  %__MODULE__{id: id, initial: first_state.id, states: states, transitions: transitions}
  #end

  #def new id, initial, states, transitions do
  #  %__MODULE__{id: id, initial: initial, states: states, transitions: transitions}
  #end
end
