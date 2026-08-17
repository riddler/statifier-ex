defmodule Statifier.Document.Content do
  @moduledoc """
  A `<content>` element: static text, an `expr`, markup, or (representably,
  if not validly) any combination.

  Spec 5.6 allows `<content>` children to be "text, XML from any namespace,
  or a mixture of both". Preserving non-text markup would mean holding a DOM
  subtree inside a Document struct, crossing the layer boundary this rewrite
  is organized around - so `markup` holds a verbatim source slice instead
  (ADR-0041), not a subtree: no DOM node ever reaches this struct. The slice
  is opaque bytes here; the child document it describes is only compiled at
  invoke time, from `markup`, through `Statifier.Invoke.Source.resolve/2`.

  `markup` is `nil` unless `<content>` has at least one element child; when
  present, it is the exact source bytes from the start of the first
  non-whitespace child to the end of the last non-whitespace child, elements
  and text runs alike, so a 5.6.2 "mixture" slices whole. Unlike `text`
  below, this slice does **not** fold line breaks - it keeps its raw CRLFs
  and lone CRs exactly as written; the parser's XML 1.0 2.11 fold only
  applies when the child document `markup` describes is itself parsed, at
  invoke time (ADR-0045 decision item 5). `markup_location`
  is that slice's own span in the parent source - its `start_offset` is what
  makes a byte offset inside the child document translatable back into a
  parent-document offset by plain arithmetic (ADR-0014).

  `text` is `Statifier.Parser.DOM.text/1`'s concatenation of the direct text
  children, folded per the parser's XML 1.0 2.11 line-break fold
  (ADR-0045), and has no span of its own: an entity reference or a CDATA
  section can split that concatenation across more than one run in the
  source, so there is no single span to give it. This `Content` node's own
  `location` is what a diagnostic about the text points at instead.

  `expr`, `text`, and `markup` are all nilable and all representable at the
  same time, even though spec 5.6 says a document MUST NOT specify both
  `expr` and content. That mutual exclusion is a validator concern, not this
  layer's - holding all three is exactly what lets
  `Statifier.Validator.Checks.Content` report a document that violates it,
  as `{:content_expr_and_text, expr}` at this node's own `location`.
  Whitespace-only `text` is source formatting rather than a payload and is
  not reported.
  """

  alias Statifier.Document
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [
    :location,
    expr: nil,
    text: nil,
    markup: nil,
    markup_location: nil,
    attribute_locations: %{}
  ]

  @type t :: %__MODULE__{
          expr: String.t() | nil,
          text: String.t() | nil,
          markup: String.t() | nil,
          markup_location: Location.t() | nil,
          location: Location.t(),
          attribute_locations: Document.attribute_locations()
        }
end
