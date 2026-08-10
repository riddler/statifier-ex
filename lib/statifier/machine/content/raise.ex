defmodule Statifier.Machine.Content.Raise do
  @moduledoc """
  A compiled `<raise>` executable-content node (spec 5.10) - the interned
  counterpart to `Statifier.Document.Raise`. `event` is the literal event
  name being enqueued - never tokenized, unlike a `<transition>`'s `event`
  attribute (`lib/statifier/document/raise.ex:6-13`). Its
  `Statifier.ExecutableContent` implementation lands in Phase 2.
  """

  alias Statifier.Parser.Location

  @enforce_keys [:c_index, :event, :location]
  defstruct [:c_index, :event, :location]

  @type t :: %__MODULE__{
          c_index: non_neg_integer(),
          event: String.t(),
          location: Location.t()
        }
end
