require IEx
defmodule Exstate.Guide do
  defstruct [:machine, :on_transition, :journey]

  def new machine do
    %__MODULE__{machine: machine, journey: Exstate.Journey.new(machine)}
  end

  def on_transition!(%__MODULE__{} = guide, transition_fn) do
    %__MODULE__{guide | on_transition: transition_fn}
  end

  def send(%__MODULE__{} = guide, event) do
    found_transition = Enum.find(guide.journey.current_state.transitions,
      fn transition -> transition.event == event end)

    new_journey = guide.journey |> Exstate.Journey.transition!(found_transition.target)
    %__MODULE__{guide | journey: new_journey}
  end
end
