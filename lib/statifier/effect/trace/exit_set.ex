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

  `configuration` is the full configuration (ADR-0005, ancestors included)
  as it stands *after* every state in `indexes` has left it, so a consumer
  can render the configuration per microstep without folding deltas. It is
  deliberately the only field taken from the post-exit
  state; `macrostep`/`microstep`/`round` are stamped from the state as it
  stood at the phase boundary the payload names, which is what keeps this
  payload an "exit set" marker rather than an after-the-fact report
  (`test/fixtures/adr_judge/0012_trace_prestate_captured.diff` is the
  sanctioned shape). At `Statifier.Interpreter.exit_interpreter/1` the sweep
  empties the configuration, so `configuration` is `MapSet.new()` there -
  which is the true resulting configuration and not a missing value;
  `Trace.Done.configuration`, which carries the configuration as it stood
  *at* exit, is the payload that answers "what was active when the run
  ended".

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
