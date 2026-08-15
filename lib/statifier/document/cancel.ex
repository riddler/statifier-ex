defmodule Statifier.Document.Cancel do
  @moduledoc """
  A `<cancel>` element: spec 6.3's instruction to cancel a delayed `<send>`.

  Both `sendid` and `sendidexpr` are nonetheless simultaneously
  representable here, on purpose, mirroring `Statifier.Document.Send`'s own
  moduledoc: 6.3.1 says exactly one of the two must occur, and
  `Statifier.Validator.Checks.Cancel` reports the shape rather than
  lowering refusing to build it.

  `<cancel>` is executable content, exactly as `<send>` is: it is tagged
  `{:content_node, cancel}` by `Statifier.Lowering.Builders.build_cancel/2`
  and lands in a block's own `content` list through the placement clauses
  every other content node already uses, rather than through a dedicated
  state-level slot. Unlike `<send>`, it has no children of its own.
  """

  alias Statifier.Document
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [
    :location,
    sendid: nil,
    sendidexpr: nil,
    attribute_locations: %{}
  ]

  @type t :: %__MODULE__{
          location: Location.t(),
          sendid: String.t() | nil,
          sendidexpr: String.t() | nil,
          attribute_locations: Document.attribute_locations()
        }
end
