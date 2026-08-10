defmodule Statifier.Effect.Trace.TransitionsSelected do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted whenever
  `select_transitions` returns, including the empty set
  (`docs/observability.md` constraint 2's "transitions selected" row).
  `t_indexes` are the selected transitions' `t_index` identities (constraint
  3, never `%Statifier.Machine.Transition{}` structs), in the order
  selection returned them. `event` is the event the selection matched
  against, or `nil` for an eventless round.

  Built with `new/2`, never a struct literal, so `macrostep`/`microstep`
  are always stamped from the `Statifier.MachineState` at hand.
  """

  alias Statifier.Event
  alias Statifier.MachineState

  @enforce_keys [:t_indexes, :macrostep, :microstep]
  defstruct [:t_indexes, :event, :macrostep, :microstep]

  @type t :: %__MODULE__{
          t_indexes: [non_neg_integer()],
          event: Event.t() | nil,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }

  @doc """
  Stamps `macrostep`/`microstep` from `machine_state` and sets `fields`
  (`:t_indexes`, optional `:event`).
  """
  @spec new(machine_state :: MachineState.t(), fields :: keyword()) :: t()
  def new(%MachineState{macrostep: macrostep, microstep: microstep}, fields) do
    struct!(__MODULE__, Keyword.merge(fields, macrostep: macrostep, microstep: microstep))
  end
end
