defmodule Statifier.Document.Data do
  @moduledoc """
  A `<data>` element: an `id`, and at most one of `expr`, `src`, or child
  text as its value source.

  `expr` and `src` are raw, uncompiled strings - `lib/statifier/document.ex`'s
  moduledoc forbids `Predicator` anywhere under `lib/statifier/document/`, so
  neither is compiled here. `text` is `Statifier.Parser.DOM.text/1`'s
  verbatim, untrimmed concatenation of `<data>`'s direct text children
  (verbatim except for the parser's XML 1.0 2.11 line-break fold -
  ADR-0045), exactly as `Statifier.Document.Content.text` is defined.

  Spec 5.3.2 makes `expr`, `src`, and children mutually exclusive ("`<data>`
  MAY have either a 'src' or an 'expr' attribute, but MUST NOT have both...
  if either attribute is present, the element MUST NOT have any children").
  All three are representable on this struct at once **on purpose**, so
  `Statifier.Validator.Checks.Data` can report the shape rather than lowering
  refusing to build it - the same division of labour
  `Statifier.Document.Content` already has with `Statifier.Validator.Checks.Content`
  (`lib/statifier/validator/checks/content.ex:6-10`).

  `id` is required (spec 5.3.1); a `<data>` with no `id` cannot be built at
  all and lowering reports `{:missing_attribute, "data", "id"}` instead.
  """

  alias Statifier.Document
  alias Statifier.Parser.Location

  @enforce_keys [:id, :location]
  defstruct [:id, :location, expr: nil, src: nil, text: nil, attribute_locations: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          expr: String.t() | nil,
          src: String.t() | nil,
          text: String.t() | nil,
          location: Location.t(),
          attribute_locations: Document.attribute_locations()
        }
end
