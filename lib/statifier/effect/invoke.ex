defmodule Statifier.Effect.Invoke do
  @moduledoc """
  Payload for `{:invoke, %__MODULE__{}}` - spec 6.4's `<invoke>`. Fields are
  the element's own attribute names: `invoke_id` (`id`/`idlocation`,
  generated when the element has none), `type`, `src`, `params` (the
  resolved `<param>`/`<content>` payload), `autoforward` (the `autoforward`
  attribute).

  `<invoke>` is attached to a state, not to a block of executable content,
  so this payload carries `state_index` - the invoking state's index
  (constraint 3) - rather than a `c_index`; there is no content node to
  identify. `state_index` is named apart from `src` (spec 6.4's URI
  attribute) on purpose - the two fields are two letters apart with
  unrelated meanings, and the original `source` name invited confusing them
  (post-review correction).
  `macrostep`/`microstep` are the counters as they stand when the invoke is
  produced. The not-yet-implemented invoke/session support may add fields
  to this payload once it exists.
  """

  @enforce_keys [:invoke_id, :state_index, :macrostep, :microstep]
  defstruct [
    :invoke_id,
    :type,
    :src,
    :params,
    :autoforward,
    :state_index,
    :macrostep,
    :microstep
  ]

  @type t :: %__MODULE__{
          invoke_id: String.t(),
          type: String.t() | nil,
          src: String.t() | nil,
          params: term(),
          autoforward: boolean() | nil,
          state_index: non_neg_integer(),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
end
