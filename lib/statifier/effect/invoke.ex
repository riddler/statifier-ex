defmodule Statifier.Effect.Invoke do
  @moduledoc """
  Payload for `{:invoke, %__MODULE__{}}` - spec 6.4's `<invoke>`. Fields are
  the element's own attribute names: `invoke_id` (`id`/`idlocation`,
  generated when the element has none), `type`, `src`, `params` (the
  resolved `<param>`/namelist payload), `content` (the resolved `<content>`
  payload), `autoforward` (the `autoforward` attribute).

  `<invoke>` is attached to a state, not to a block of executable content,
  so this payload carries `state_index` - the invoking state's index
  (constraint 3) - rather than a `c_index`; there is no content node to
  identify. `state_index` is named apart from `src` (spec 6.4's URI
  attribute) on purpose - the two fields are two letters apart with
  unrelated meanings, and the original `source` name invited confusing them
  (post-review correction).
  `macrostep`/`microstep` are the counters as they stand when the invoke is
  produced.

  ## `src` and `content` are two fields, not one

  Spec 6.4 collapses the data channels an invoked service can receive to two
  pairs treated identically: "these services MUST treat values specified by
  `<param>` and namelist identically" and "MUST also treat values specified
  by 'src' and `<content>` identically." The first pair shares one field
  (`params`) because both lower to the same `Statifier.Machine.Param.t()`
  shape and coerce through the same `Statifier.EventData.coerce({:params,
  _})` ladder. The second pair cannot: `src` is a URI string the core never
  dereferences (ADR-0031 - whether anything downstream fetches it is a later
  concern), while `content` is markup or a value already resolved in hand,
  coerced through `Statifier.EventData.coerce({:value, _})` or `{:text, _}`.
  One field cannot hold both a reference and a resolved value without a
  sentinel that collapses "no content, use src" with "content resolved to
  nil" - so 6.4's "treat identically" becomes two fields the reader of the
  effect payload treats identically, not one field that already has.
  """

  @enforce_keys [:invoke_id, :state_index, :macrostep, :microstep]
  defstruct [
    :invoke_id,
    :type,
    :src,
    :params,
    :content,
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
          content: term(),
          autoforward: boolean() | nil,
          state_index: non_neg_integer(),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
end
