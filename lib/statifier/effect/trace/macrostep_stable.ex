defmodule Statifier.Effect.Trace.MacrostepStable do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted when the
  configuration reaches quiescence, i.e. the macrostep's microstep loop has
  no more eventless transitions or internal events to drain
  (`docs/observability.md` constraint 2's "macrostep stable" row).
  `configuration` is the full configuration (ADR-0005, ancestors included)
  as it stood at quiescence.

  Built with `new/2`, never a struct literal, so `macrostep`/`microstep`/
  `round` are always stamped from the `Statifier.MachineState` at hand.
  """

  alias Statifier.MachineState

  @enforce_keys [:configuration, :macrostep, :microstep, :round]
  defstruct [:configuration, :macrostep, :microstep, :round]

  @type t :: %__MODULE__{
          configuration: MapSet.t(non_neg_integer()),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }

  @doc """
  Stamps `macrostep`/`microstep`/`round` from `machine_state` and sets
  `fields` (`:configuration`).
  """
  @spec new(machine_state :: MachineState.t(), fields :: keyword()) :: t()
  def new(%MachineState{macrostep: macrostep, microstep: microstep, round: round}, fields) do
    struct!(
      __MODULE__,
      Keyword.merge(fields, macrostep: macrostep, microstep: microstep, round: round)
    )
  end
end
