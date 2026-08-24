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
  `c_index` alone). `macrostep`/`microstep`/`round` are the counters
  as they stood when the send was scheduled, not when the timer fires.

  `id_from_author?` is `true` when the document wrote `id` or `idlocation`
  on this `<send>`, `false` when `send_id` was generated - the same C.1
  empty-`sendid` flag `Statifier.Effect.Send`'s own moduledoc explains.

  `ordinal` is a per-execution sequence number minted from
  `Statifier.MachineState`'s session-global `timer_counter` (ADR-0059). It is
  what makes a durable host's dedup key per-instance where the counter triple
  and the content position cannot - two iterations of a `<foreach>` body
  execute the same content node, in the same microstep, under the same
  author-written id, and only `ordinal` tells them apart. It replays
  identically because the counter is pure fold state.

  `caller_context` is the opaque host term the current macrostep's
  triggering external event carried (ADR-0063), copied off
  `Statifier.MachineState`'s transient slot at construction - `nil` when
  no context was attached. A durable store carries it as row data beside
  the key components (never a key component itself, ADR-0063 decision 6)
  and restores it at firing time so the firing site can attribute back to
  the scheduling trace. The library never reads the value.
  """

  alias Statifier.Machine.Content

  @typedoc "Which block emitted the send - `t:Statifier.Machine.Content.owner/0`."
  @type owner :: Content.owner()

  @enforce_keys [:event, :delay_ms, :macrostep, :microstep, :round, :ordinal]
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
    :round,
    :ordinal,
    id_from_author?: false,
    caller_context: nil
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
          round: non_neg_integer(),
          ordinal: pos_integer(),
          id_from_author?: boolean(),
          caller_context: term()
        }
end
