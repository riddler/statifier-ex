defmodule Statifier.Document.Block do
  @moduledoc """
  One `<onentry>` or `<onexit>` element: an ordered list of executable
  content plus the location of the element that contains it.

  A bare `[Document.content_node()]` on `Statifier.Document.State` would
  preserve the block boundary the spec requires - 3.8 and 3.9 each treat
  `<onentry>`/`<onexit>` as one unit, and section 4's error rule makes each
  block a separate error-isolation unit, so `State.onentry` and
  `State.onexit` are each `[Block.t()]`, not a flattened content list - but
  it would give the block itself no location, so a diagnostic could name the
  failing `<raise>` inside it and not the `<onentry>` that contains it.
  Locations are retained on executable-content nodes wherever the source has
  one to give (`docs/observability.md` Constraint 3); the `<onentry>` or
  `<onexit>` element **is** such a node, and one small struct is the whole
  cost of not losing it.

  There is no `kind` field here the way `Statifier.Parser.Markup` has one
  for `:start`/`:end`. The field name on `State` (`onentry` vs `onexit`)
  already says which this is, and unlike `Markup`'s records the two never
  share a list to be told apart within.

  A transition's own executable content is `[Document.content_node()]`
  directly, not wrapped in a `Block.t()` - there is no `<onentry>`-like
  element in the source to give a block its own location, and the
  transition's own `location` already is that span.
  """

  alias Statifier.Document
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, content: []]

  @type t :: %__MODULE__{
          content: [Document.content_node()],
          location: Location.t()
        }
end
