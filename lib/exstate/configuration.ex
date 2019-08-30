defmodule Exstate.Configuration do
  defstruct [:active]

  def initial(state) do
    initial_config = state |> Exstate.State.get_initial
    %__MODULE__{active: [initial_config]}
  end

  def new(state) do
    %__MODULE__{active: [state]}
  end

  def literal(%__MODULE__{} = configuration) do
    Enum.map(configuration.active, fn state -> state.id end)
  end
end
