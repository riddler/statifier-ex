defmodule Exstate.States.AtomicState do
  defstruct [
    :id,
    :transitions
  ]

  def new(definition) do
    transitions = definition.transitions
                  |> Enum.map(fn transition ->
                    Exstate.Transition.new(definition.id, transition.target, transition.event)
                  end)

    %__MODULE__{
      id: definition.id,
      transitions: transitions
    }
  end
end
