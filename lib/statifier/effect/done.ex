defmodule Statifier.Effect.Done do
  @moduledoc """
  Payload for `{:done, %__MODULE__{}}` - the terminal effect
  `exit_interpreter` (Appendix D) produces once, after top-level final
  entry, when `Statifier.MachineState.status` becomes `:done`. `donedata`
  is the top-level final's resolved `<donedata>` content, or `nil` when the
  final carries none. `configuration` is the full configuration (ADR-0005,
  ancestors included) as it stood at exit: the full set, so a consumer can
  observe the terminal position without switching tracing on, since
  `MachineState.configuration` is empty by then and
  `Statifier.active_leaf_states/1` correctly reports nothing active. See
  `Statifier.Interpreter.exit_interpreter/1`.

  There is no `c_index`: this effect is produced by `exit_interpreter`
  itself, not by one executable-content node. `macrostep`/`microstep`/
  `round` are the counters as they stand at the moment of termination. See
  `Statifier.Effect.Trace.Done` for the trace-effect counterpart, built from
  the same `configuration_at_exit` binding.
  """

  @enforce_keys [:configuration, :macrostep, :microstep, :round]
  defstruct [:donedata, :configuration, :macrostep, :microstep, :round]

  @type t :: %__MODULE__{
          donedata: term() | nil,
          configuration: MapSet.t(non_neg_integer()),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }
end
