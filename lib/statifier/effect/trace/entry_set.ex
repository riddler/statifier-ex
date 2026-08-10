defmodule Statifier.Effect.Trace.EntrySet do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted with
  `compute_entry_set`'s result, before any state is entered
  (`docs/observability.md` constraint 2's "entry set" row). `indexes` are
  the states to be entered (constraint 3, integer indexes), in entry order.

  Built with `new/2`, never a struct literal, so `macrostep`/`microstep`
  are always stamped from the `Statifier.MachineState` at hand.
  """

  alias Statifier.MachineState

  @enforce_keys [:indexes, :macrostep, :microstep]
  defstruct [:indexes, :macrostep, :microstep]

  @type t :: %__MODULE__{
          indexes: [non_neg_integer()],
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }

  @doc """
  Stamps `macrostep`/`microstep` from `machine_state` and sets `fields`
  (`:indexes`).
  """
  @spec new(machine_state :: MachineState.t(), fields :: keyword()) :: t()
  def new(%MachineState{macrostep: macrostep, microstep: microstep}, fields) do
    struct!(__MODULE__, Keyword.merge(fields, macrostep: macrostep, microstep: microstep))
  end
end
