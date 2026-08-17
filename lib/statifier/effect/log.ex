defmodule Statifier.Effect.Log do
  @moduledoc """
  Payload for `{:log, %__MODULE__{}}` - spec 4.7's `<log>`. `label` is the
  `label` attribute (`nil` when the element omits it); `value` is the
  resolved `expr` (or `nil` for a label-only `<log>`).

  `c_index` identifies the `<log>` content node (constraint 3, never a
  compiled content-node struct); a bare `c_index` alone is not enough to
  correlate the log back to its place in the document, the same gap
  `Statifier.Event.Cause`'s post-review correction found for `origin`
  (`lib/statifier/event/cause.ex:13-26`) - it resolves to the node's own
  `Location` but names nothing about which `<onentry>`/`<onexit>` block or
  transition emitted it - so `owner` rides alongside it. `macrostep`/
  `microstep`/`round` are the counters as they stood when the log ran.
  This is the only effect the interpreter produces today.
  """

  alias Statifier.Machine.Content

  @typedoc "Which block emitted the log - `Statifier.Machine.Content.owner/0`."
  @type owner :: Content.owner()

  @enforce_keys [:macrostep, :microstep, :round]
  defstruct [:label, :value, :c_index, :owner, :macrostep, :microstep, :round]

  @type t :: %__MODULE__{
          label: String.t() | nil,
          value: term(),
          c_index: non_neg_integer() | nil,
          owner: owner() | nil,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }
end
