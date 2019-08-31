defmodule Exstate.States.ParallelState do
  defstruct [
    :id,
    :initial_attribute,
    :states,
    :transitions
  ]

  def new(definition) do
    transitions = definition.transitions
                  |> Enum.map(fn transition ->
                    Exstate.Transition.new(definition.id, transition.target, transition.event)
                  end)

    states = definition.states
      |> Enum.map(fn child -> Exstate.State.new(child) end)

    %__MODULE__{
      id: definition.id,
      initial_attribute: definition.initial,
      states: states,
      transitions: transitions
    }
  end
end
