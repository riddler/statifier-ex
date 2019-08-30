defmodule Exstate.Machine do
  defstruct [
    # Definition of the machine
    :statechart,

    # Root state
    :root,

    # Currently active states
    :configuration
  ]

  def new statechart do
    root = Exstate.State.new(statechart)
    %__MODULE__{
      statechart: statechart,
      root: root,
      configuration: Exstate.Configuration.new(root.initial)
    }
  end

  # Literal representation of the configuration
  def configuration_literal(%__MODULE__{} = machine) do
    Exstate.Configuration.literal machine.configuration
  end

  # Transitions defined on current configuration
  def transitions(%__MODULE__{} = machine) do
    machine.configuration.active
    |> Enum.map(fn state -> state.transitions end)
    |> List.flatten
  end

  def send(%__MODULE__{} = machine, event) do
    found_transition = machine
      |> transitions
      |> Enum.find(fn transition -> transition.event == event end)

    IO.inspect found_transition

    if is_nil(found_transition) do
      machine
    else
      machine
      |> transition!(found_transition)
    end
  end

  def transition!(%__MODULE__{} = machine, transition) do
    target_state = machine |> find_state_by_key(transition.target)

    %__MODULE__{machine | configuration: Exstate.Configuration.new(target_state)}
  end

  def find_state_by_key(%__MODULE__{} = machine, key) do
    machine.root.states
    |> Enum.find(fn state -> state.id == key end)
  end
end
