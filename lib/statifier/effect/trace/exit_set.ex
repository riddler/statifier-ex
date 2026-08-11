defmodule Statifier.Effect.Trace.ExitSet do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted before any state is
  exited (`docs/observability.md` constraint 2's "exit set" row). `indexes`
  are the states to be exited (constraint 3, integer indexes), in exit
  order.

  Two sites emit it, matching the two places this engine exits states:
  `Statifier.Interpreter.ExitEntry.exit_states/2` over `compute_exit_set`'s
  result, and `Statifier.Interpreter.exit_interpreter/1` over the whole
  configuration at termination. Both are phase boundaries Appendix D names
  (`exitStates` and `exitInterpreter` compute the same `statesToExit`), so
  ADR-0012 item 2 asks for the row at both.

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
