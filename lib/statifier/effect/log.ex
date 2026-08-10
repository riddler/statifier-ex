defmodule Statifier.Effect.Log do
  @moduledoc """
  Payload for `{:log, %__MODULE__{}}` - spec 5.8's `<log>`. `label` is the
  `label` attribute (`nil` when the element omits it); `value` is the
  resolved `expr` (or `nil` for a label-only `<log>`).

  `c_index` identifies the `<log>` content node (constraint 3, never a
  compiled content-node struct); `macrostep`/`microstep` are the counters
  as they stood when the log ran (Decision 5). This is the effect the
  core-engine epic actually produces today, alongside `:done` (plan
  Decision 14).
  """

  @enforce_keys [:macrostep, :microstep]
  defstruct [:label, :value, :c_index, :macrostep, :microstep]

  @type t :: %__MODULE__{
          label: String.t() | nil,
          value: term(),
          c_index: non_neg_integer() | nil,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
end
