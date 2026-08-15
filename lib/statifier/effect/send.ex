defmodule Statifier.Effect.Send do
  @moduledoc """
  Payload for `{:send, %__MODULE__{}}` - spec 6.2's `<send>`, fired
  immediately (no `delay`/`delayexpr`; that variant is
  `Statifier.Effect.SendDelayed`). Fields are the element's own attribute
  names so the not-yet-implemented session/invoke support, which will give
  this effect its semantics, can extend rather than rename them: `event` is
  the event name being sent, `target` and `type` are the `target`/`type`
  attributes (`nil` when the element omits them), `data` is the resolved
  payload, `send_id` is the `id` attribute (generated when the element has
  none).

  `c_index` is the identity (`docs/observability.md` constraint 3) of the
  `<send>` content node that produced this effect - never a compiled
  content-node struct. `owner` names which block emitted the send (the same
  gap `Statifier.Effect.Log`'s own moduledoc describes: `c_index` alone does
  not say which `<onentry>`/`<onexit>` block or transition it belongs to).
  `macrostep`/`microstep` are the step counters as they stand at the moment
  of the send.

  `id_from_author?` is `true` when the document wrote `id` or `idlocation`
  on this `<send>`, `false` when `send_id` was generated. It exists for
  C.1's empty-`sendid` rule: a delivered event's `sendid` must be `nil` when
  the author never named the send, and `send_id` alone cannot express that
  distinction, since ADR-0035 always mints one either way.
  """

  alias Statifier.Machine.Content

  @typedoc "Which block emitted the send - `Statifier.Machine.Content.owner/0`."
  @type owner :: Content.owner()

  @enforce_keys [:event, :macrostep, :microstep]
  defstruct [
    :event,
    :target,
    :type,
    :data,
    :send_id,
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
          c_index: non_neg_integer() | nil,
          owner: owner() | nil,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          id_from_author?: boolean()
        }
end
