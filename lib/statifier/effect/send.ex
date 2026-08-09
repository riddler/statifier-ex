defmodule Statifier.Effect.Send do
  @moduledoc """
  Payload for `{:send, %__MODULE__{}}` - spec 6.2's `<send>`, fired
  immediately (no `delay`/`delayexpr`; that variant is
  `Statifier.Effect.SendDelayed`). Fields are the element's own attribute
  names so st-cmq (the session/invoke bead, which gives this effect its
  semantics) extends rather than renames: `event` is the event name being
  sent, `target` and `type` are the `target`/`type` attributes (`nil` when
  the element omits them), `data` is the resolved payload, `send_id` is the
  `id` attribute (generated when the element has none).

  `c_index` is the identity (`docs/observability.md` constraint 3) of the
  `<send>` content node that produced this effect - never a
  `%Statifier.Machine.Content{}` struct. `macrostep`/`microstep` are the
  step counters as they stood at the moment of the send (Decision 5).
  """

  @enforce_keys [:event, :macrostep, :microstep]
  defstruct [
    :event,
    :target,
    :type,
    :data,
    :send_id,
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
          c_index: non_neg_integer() | nil,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
end
