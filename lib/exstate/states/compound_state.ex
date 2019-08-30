defmodule Exstate.States.CompoundState do
  defstruct [
    :id,
    :initial_attribute,
    :states,
    #:states_by_key,
    :transitions
  ]

  def new(definition) do
    transitions = definition.transitions
                  |> Enum.map(fn transition ->
                    Exstate.Transition.new(definition.id, transition.target, transition.event)
                  end)

    states = definition.states
      |> Enum.map(fn child -> Exstate.State.new(child) end)

    #states_by_key = states |> Map.new(fn child -> {child.id, child} end)

    %__MODULE__{
      id: definition.id,
      initial_attribute: definition.initial,
      states: states,
      #states_by_key: states_by_key,
      transitions: transitions
    }
  end
end
