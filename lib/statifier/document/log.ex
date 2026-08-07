defmodule Statifier.Document.Log do
  @moduledoc """
  A `<log>` executable-content element: spec 4.7's diagnostic output point.

  Both `label` and `expr` are optional per the spec, so both default to
  `nil` rather than the empty string - a missing `label` is not the same
  fact as an author writing `label=""`. `expr` is raw predicator source, not
  a compiled expression (`docs/datamodel.md`); its ADR-0014 span lives at
  `attribute_locations[:expr]`, not on a field of this struct, matching how
  every other expression-bearing node stores its span.
  """

  alias Statifier.Document
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, label: nil, expr: nil, attribute_locations: %{}]

  @type t :: %__MODULE__{
          label: String.t() | nil,
          expr: String.t() | nil,
          location: Location.t(),
          attribute_locations: Document.attribute_locations()
        }
end
