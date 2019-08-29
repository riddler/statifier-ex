defmodule Exstate.Machine do
  defstruct [:initial_state]

  def new initial_state do
    %__MODULE__{initial_state: initial_state}
  end

  def initial_state %__MODULE__{initial_state: foo} do
    foo
  end
end
