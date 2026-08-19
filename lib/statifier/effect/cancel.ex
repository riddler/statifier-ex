defmodule Statifier.Effect.Cancel do
  @moduledoc """
  Payload for `{:cancel, %__MODULE__{}}` - spec 6.3's `<cancel>`. `send_id`
  is the `sendid`/`sendidexpr` attribute naming the delayed send to cancel;
  resolving it against the pending `SendDelayed` timers is
  `Statifier.Session`'s job.

  `c_index` identifies the `<cancel>` content node (constraint 3, never a
  compiled content-node struct); `owner` names which block emitted the
  cancel (the same gap `Statifier.Effect.Log`'s own moduledoc describes for
  `c_index` alone). `macrostep`/`microstep`/`round` are the counters
  as they stood at the moment of the cancel.

  `ordinal` is a per-execution sequence number minted from
  `Statifier.MachineState`'s session-global `timer_counter` (ADR-0059). It is
  what makes a durable host's dedup key per-instance where the counter triple
  and the content position cannot - two iterations of a `<foreach>` body
  execute the same content node, in the same microstep, under the same
  author-written id, and only `ordinal` tells them apart. It replays
  identically because the counter is pure fold state.
  """

  alias Statifier.Machine.Content

  @typedoc "Which block emitted the cancel - `Statifier.Machine.Content.owner/0`."
  @type owner :: Content.owner()

  @enforce_keys [:send_id, :macrostep, :microstep, :round, :ordinal]
  defstruct [:send_id, :c_index, :owner, :macrostep, :microstep, :round, :ordinal]

  @type t :: %__MODULE__{
          send_id: String.t(),
          c_index: non_neg_integer() | nil,
          owner: owner() | nil,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer(),
          ordinal: pos_integer()
        }
end
