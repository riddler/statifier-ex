defmodule Statifier.Effect.Cancel do
  @moduledoc """
  Payload for `{:cancel, %__MODULE__{}}` - spec 6.3's `<cancel>`. `send_id`
  is the `sendid`/`sendidexpr` attribute naming the delayed send to cancel;
  resolving it against the pending `SendDelayed` timers is
  `Statifier.Session`'s job.

  `c_index` identifies the `<cancel>` content node (constraint 3, never a
  compiled content-node struct); `owner` names which block emitted the
  cancel (the same gap `Statifier.Effect.Log`'s own moduledoc describes for
  `c_index` alone). `macrostep`/`microstep` are the counters
  as they stood at the moment of the cancel.
  """

  alias Statifier.Machine.Content

  @typedoc "Which block emitted the cancel - `Statifier.Machine.Content.owner/0`."
  @type owner :: Content.owner()

  @enforce_keys [:send_id, :macrostep, :microstep]
  defstruct [:send_id, :c_index, :owner, :macrostep, :microstep]

  @type t :: %__MODULE__{
          send_id: String.t(),
          c_index: non_neg_integer() | nil,
          owner: owner() | nil,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
end
