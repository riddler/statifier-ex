defmodule Statifier.Effect.Invoke do
  @moduledoc """
  Payload for `{:invoke, %__MODULE__{}}` - spec 6.4's `<invoke>`. Fields are
  the element's own attribute names: `invoke_id` (`id`/`idlocation`,
  generated when the element has none), `type`, `src`, `params` (the
  resolved `<param>`/`<content>` payload), `autoforward` (the `autoforward`
  attribute).

  `<invoke>` is attached to a state, not to a block of executable content,
  so this payload carries `source` - the invoking state's index (constraint
  3) - rather than a `c_index`; there is no content node to identify.
  `macrostep`/`microstep` are the counters as they stood when the invoke was
  produced (Decision 5). st-cmq owns invoke semantics and may add fields.
  """

  @enforce_keys [:invoke_id, :source, :macrostep, :microstep]
  defstruct [
    :invoke_id,
    :type,
    :src,
    :params,
    :autoforward,
    :source,
    :macrostep,
    :microstep
  ]

  @type t :: %__MODULE__{
          invoke_id: String.t(),
          type: String.t() | nil,
          src: String.t() | nil,
          params: term(),
          autoforward: boolean() | nil,
          source: non_neg_integer(),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
end
