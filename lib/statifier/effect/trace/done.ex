defmodule Statifier.Effect.Trace.Done do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted alongside
  `Statifier.Effect.Done` at top-level final entry / `exit_interpreter`
  (`docs/observability.md` constraint 2's "done" row). `donedata` mirrors
  the core `:done` effect's payload; `configuration` is the full
  configuration (ADR-0005, ancestors included) as it stood at exit, which
  the core `:done` effect does not carry.

  Built with `new/2`, never a struct literal, so `macrostep`/`microstep`
  are always stamped from the `Statifier.MachineState` at hand.
  """

  alias Statifier.MachineState

  @enforce_keys [:configuration, :macrostep, :microstep]
  defstruct [:donedata, :configuration, :macrostep, :microstep]

  @type t :: %__MODULE__{
          donedata: term() | nil,
          configuration: MapSet.t(non_neg_integer()),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }

  @doc """
  Stamps `macrostep`/`microstep` from `machine_state` and sets `fields`
  (`:configuration`, optional `:donedata`).
  """
  @spec new(machine_state :: MachineState.t(), fields :: keyword()) :: t()
  def new(%MachineState{macrostep: macrostep, microstep: microstep}, fields) do
    struct!(__MODULE__, Keyword.merge(fields, macrostep: macrostep, microstep: microstep))
  end
end
