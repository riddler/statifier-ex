defmodule Statifier.Effect.SendDelayed do
  @moduledoc """
  Payload for `{:send_delayed, %__MODULE__{}}` - spec 6.2's `<send>` when
  `delay`/`delayexpr` is present. Carries every field
  `Statifier.Effect.Send` does, plus `delay_ms`, the resolved delay in
  milliseconds; st-cmq's session owns the timer that eventually fires this
  send, this bead only defines the shape it schedules.

  `c_index` identifies the `<send>` content node (constraint 3, never a
  `%Statifier.Machine.Content{}`); `macrostep`/`microstep` are the counters
  as they stood when the send was scheduled (Decision 5), not when the
  timer fires.
  """

  @enforce_keys [:event, :delay_ms, :macrostep, :microstep]
  defstruct [
    :event,
    :target,
    :type,
    :data,
    :send_id,
    :delay_ms,
    :c_index,
    :macrostep,
    :microstep
  ]

  @type t :: %__MODULE__{
          event: String.t(),
          target: String.t() | nil,
          type: String.t() | nil,
          data: term(),
          send_id: String.t() | nil,
          delay_ms: non_neg_integer(),
          c_index: non_neg_integer() | nil,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
end
