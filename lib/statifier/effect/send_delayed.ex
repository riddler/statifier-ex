defmodule Statifier.Effect.SendDelayed do
  @moduledoc """
  Payload for `{:send_delayed, %__MODULE__{}}` - spec 6.2's `<send>` when
  `delay`/`delayexpr` is present. Carries every field
  `Statifier.Effect.Send` does, plus `delay_ms`, the resolved delay in
  milliseconds. The timer that fires this send is `Statifier.Session`'s to
  schedule; this module only defines the shape it schedules.

  `c_index` identifies the `<send>` content node (constraint 3, never a
  compiled content-node struct); `owner` names which block emitted the send
  (the same gap `Statifier.Effect.Log`'s own moduledoc describes for
  `c_index` alone). `macrostep`/`microstep` are the counters
  as they stood when the send was scheduled, not when the timer fires.

  `id_from_author?` is `true` when the document wrote `id` or `idlocation`
  on this `<send>`, `false` when `send_id` was generated - the same C.1
  empty-`sendid` flag `Statifier.Effect.Send`'s own moduledoc explains.
  """

  alias Statifier.Machine.Content

  @typedoc "Which block emitted the send - `Statifier.Machine.Content.owner/0`."
  @type owner :: Content.owner()

  @enforce_keys [:event, :delay_ms, :macrostep, :microstep]
  defstruct [
    :event,
    :target,
    :type,
    :data,
    :send_id,
    :delay_ms,
    :c_index,
    :owner,
    :macrostep,
    :microstep,
    id_from_author?: false
  ]

  @type t :: %__MODULE__{
          event: String.t(),
          target: String.t() | nil,
          type: String.t() | nil,
          data: term(),
          send_id: String.t() | nil,
          delay_ms: non_neg_integer(),
          c_index: non_neg_integer() | nil,
          owner: owner() | nil,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          id_from_author?: boolean()
        }
end
