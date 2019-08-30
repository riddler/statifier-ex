require IEx
defmodule Exstate.States.CompoundState do
  defstruct [
    :id,
    :initial_attribute,
    #:initial,
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

    #initial = Enum.find(states, fn state -> definition.initial == state.id end) ||
    #  List.first states

    #if initial.states do
    #  initial = Enum.find(initial.states, fn state -> initial.initial_attribute == state.id end) ||
    #    List.first initial.states
    #end

    #initial = Enum.find(states, fn state -> 
    #  state |> get_initial(definition.
    #  definition.initial == state.id end) ||
    #  List.first states

    #if initial.states do
    #  initial = Enum.find(initial.states, fn state -> initial.initial_attribute == state.id end) ||
    #    List.first initial.states
    #end




    #if definition.id == "" do
    #  IEx.pry
    #end

    %__MODULE__{
      id: definition.id,
      initial_attribute: definition.initial,
      #initial: initial,
      states: states,
      transitions: transitions
    }
  end

  #def initial(%__MODULE__{} = state) do
  #  initial = Enum.find(state.states, fn child ->
  #    child |> initial
  #    state.initial_attribute == child.id end) ||
  #    List.first state.states
  #end
end
