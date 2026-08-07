defmodule Statifier.Parser.DOM.Element do
  @moduledoc """
  A generic XML element: a name, an ordered attribute list, an ordered child
  list, and the source span it occupies.

  Nothing here knows what any name means. The element is whatever the XML
  said - no validation, no normalization, no namespace resolution - and
  giving it meaning is the lowering pass's job
  (`docs/architecture.md`, "Parser: DOM first, then lowering").

  - `name` is the raw qualified name exactly as it appeared, prefix included.
  - `attributes` are in document order, with duplicates preserved: a document
    that declares the same attribute twice is a thing the validator gets to
    report, so the parser may not silently drop one of them.
  - `children` are in document order and interleave elements with
    `Statifier.Parser.DOM.Text`, so mixed markup is representable.
    Whitespace-only text is a child like any other;
    `Statifier.Parser.DOM.elements/1` is the filter for readers that do not
    want it.
  - `location` spans from the `<` of the start tag to the byte after the `>`
    of the end tag (for a self-closing element, the tag itself).
  """

  alias Statifier.Parser.DOM.Attribute
  alias Statifier.Parser.DOM.Text
  alias Statifier.Parser.Location

  @enforce_keys [:name, :attributes, :children, :location]
  defstruct [:name, :attributes, :children, :location]

  @type child :: t() | Text.t()

  @type t :: %__MODULE__{
          name: binary(),
          attributes: [Attribute.t()],
          children: [child()],
          location: Location.t()
        }
end
