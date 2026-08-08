defmodule Statifier.Document.Content do
  @moduledoc """
  A `<content>` element: static text, or an `expr`, or (representably, if
  not validly) both.

  Spec 5.6 allows `<content>` children to be "text, XML from any namespace,
  or a mixture of both". Preserving non-text markup would mean holding a DOM
  subtree inside a Document struct, crossing the layer boundary this rewrite
  is organized around, and nothing in the conformance corpus needs it: every
  static `<content>` there is plain text
  (`test/scxml_tests/mandatory/content/test529_test.exs:30` is `21`,
  `test/scxml_tests/mandatory/donedata/test294_test.exs:48` is `foo`).
  Lowering is expected to error on an element child inside `<content>`
  rather than silently drop it, the mirror image of st-l5k.4's rule for
  stray non-whitespace text elsewhere.

  `text` is `Statifier.Parser.DOM.text/1`'s concatenation of the direct text
  children and has no span of its own: an entity reference or a CDATA
  section can split that concatenation across more than one run in the
  source, so there is no single span to give it. This `Content` node's own
  `location` is what a diagnostic about the text points at instead.

  `expr` and `text` are both nilable and both representable at the same
  time, even though spec 5.6 says a document MUST NOT specify both. That
  mutual exclusion is a validator concern, not this layer's - holding both
  is exactly what lets `Statifier.Validator.Checks.Content` report a
  document that violates it (st-f6k), as `{:content_expr_and_text, expr}`
  at this node's own `location`. Whitespace-only `text` is source
  formatting rather than a payload and is not reported.
  """

  alias Statifier.Document
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, expr: nil, text: nil, attribute_locations: %{}]

  @type t :: %__MODULE__{
          expr: String.t() | nil,
          text: String.t() | nil,
          location: Location.t(),
          attribute_locations: Document.attribute_locations()
        }
end
