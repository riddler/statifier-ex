defmodule Statifier.Effect.Done do
  @moduledoc """
  Payload for `{:done, %__MODULE__{}}` - the terminal effect
  `exit_interpreter` (Appendix D) produces once, after top-level final
  entry, when `Statifier.MachineState.status` becomes `:done` (Decision 6).
  `donedata` is the top-level final's resolved `<donedata>` content, or
  `nil` when the final carries none.

  There is no `c_index`: this effect is produced by `exit_interpreter`
  itself, not by one executable-content node. `macrostep`/`microstep` are
  the counters as they stood at the moment of termination (Decision 5). See
  `Statifier.Effect.Trace.Done` for the trace-effect counterpart, which
  additionally carries the configuration as it stood at exit.
  """

  @enforce_keys [:macrostep, :microstep]
  defstruct [:donedata, :macrostep, :microstep]

  @type t :: %__MODULE__{
          donedata: term() | nil,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
end
