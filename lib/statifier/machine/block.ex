defmodule Statifier.Machine.Block do
  @moduledoc """
  One compiled `<onentry>` or `<onexit>` element - the interned counterpart
  to `Statifier.Document.Block` (plan Phase 5).

  `content` is `[c_index]`, the block's own executable content in document
  order. A block exists because `<onentry>`/`<onexit>` are real elements
  with their own `location`; a transition's own executable content has no
  wrapping element in the source
  (`lib/statifier/document/transition.ex:34-37`) and so stays a bare
  `[c_index]` directly on `Statifier.Machine.Transition.content` rather than
  wrapped in a `Block.t()`.
  """

  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, content: []]

  @type t :: %__MODULE__{
          content: [non_neg_integer()],
          location: Location.t()
        }
end
