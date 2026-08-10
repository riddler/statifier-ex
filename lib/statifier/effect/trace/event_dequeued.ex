defmodule Statifier.Effect.Trace.EventDequeued do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted when an external or
  internal event is selected for processing (`docs/observability.md`
  constraint 2's "event dequeued" row). `event` is the dequeued
  `Statifier.Event.t()`; `from` names which queue it came off.

  Built with `new/2`, never a struct literal, so `macrostep`/`microstep`
  are always stamped from the `Statifier.MachineState` at hand and no call
  site can forget or duplicate them.
  """

  alias Statifier.Event
  alias Statifier.MachineState

  @enforce_keys [:event, :from, :macrostep, :microstep]
  defstruct [:event, :from, :macrostep, :microstep]

  @type t :: %__MODULE__{
          event: Event.t(),
          from: :external | :internal,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }

  @doc """
  Stamps `macrostep`/`microstep` from `machine_state` and sets `fields`
  (`:event`, `:from`).
  """
  @spec new(machine_state :: MachineState.t(), fields :: keyword()) :: t()
  def new(%MachineState{macrostep: macrostep, microstep: microstep}, fields) do
    struct!(__MODULE__, Keyword.merge(fields, macrostep: macrostep, microstep: microstep))
  end
end
