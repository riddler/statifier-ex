defmodule Statifier.Effect.Trace.EntrySet do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted with
  `compute_entry_set`'s result, before any state is entered
  (`docs/observability.md` constraint 2's "entry set" row). `indexes` are
  the states to be entered (constraint 3, integer indexes), in entry order.

  `configuration` is the full configuration (ADR-0005, ancestors included)
  as it stands *after* every state in `indexes` has been added, including
  the parallel entry ordering `enter_states/2` performs, so a consumer can
  render the configuration per microstep without folding deltas.
  It is deliberately the only field taken from the post-entry state;
  `macrostep`/`microstep`/`round` are stamped from the state as it stood at
  the phase boundary the payload names, which is what keeps this payload an
  "entry set" marker rather than an after-the-fact report.

  Built with `new/2`, never a struct literal, so `macrostep`/`microstep`/
  `round` are always stamped from the `Statifier.MachineState` at hand.
  """

  alias Statifier.MachineState

  @enforce_keys [:indexes, :configuration, :macrostep, :microstep, :round]
  defstruct [:indexes, :configuration, :macrostep, :microstep, :round]

  @type t :: %__MODULE__{
          indexes: [non_neg_integer()],
          configuration: MapSet.t(non_neg_integer()),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }

  @doc """
  Stamps `macrostep`/`microstep`/`round` from `machine_state` and sets
  `fields` (`:indexes`, `:configuration`).
  """
  @spec new(machine_state :: MachineState.t(), fields :: keyword()) :: t()
  def new(%MachineState{macrostep: macrostep, microstep: microstep, round: round}, fields) do
    struct!(
      __MODULE__,
      Keyword.merge(fields, macrostep: macrostep, microstep: microstep, round: round)
    )
  end
end
