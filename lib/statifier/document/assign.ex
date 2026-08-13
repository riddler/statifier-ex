defmodule Statifier.Document.Assign do
  @moduledoc """
  An `<assign>` executable-content element: spec 4.7.1's deep-path datamodel
  write.

  ## Two spans that are not the same thing

  This struct carries two fields that are easy to confuse and must not be:

  - `location` is the SCXML `location` attribute's own value - the raw,
    uncompiled path expression (`"foo.bar.baz"`, `"items[0]"`) an `<assign>`
    writes to. It is required (spec 5.4.2, "the value of the 'location'
    attribute MUST specify a valid location"), so it is `@enforce_keys`'d;
    resolving it against the datamodel happens at runtime
    (`Statifier.Machine.Content.Assign`), never here - `lib/statifier/document.ex`'s
    moduledoc forbids `Predicator` anywhere under `lib/statifier/document/`.
  - `node_location` is this `<assign>` element's own `Statifier.Parser.Location`
    span in the source document - what every other Document node calls
    `location`. It is renamed here specifically so a reader (or a pattern
    match) can never mistake the path string for the element's span, or vice
    versa; it is also `@enforce_keys`'d, since every node has one.

  `expr` is the value source read from the `expr` attribute - raw,
  uncompiled predicator source, nilable. `text` is
  `Statifier.Parser.DOM.text/1`'s verbatim, untrimmed concatenation of
  `<assign>`'s direct text children (mirroring `Statifier.Document.Data.text`
  and `Statifier.Document.Content.text`); `expr` and `text` are both
  representable on this struct at once, on purpose, so
  `Statifier.Validator.Checks.Assign` can report the pair rather than
  lowering refusing to build one (the same division of labour
  `Statifier.Document.Content`'s moduledoc states).
  """

  alias Statifier.Document
  alias Statifier.Parser.Location

  @enforce_keys [:location, :node_location]
  defstruct [:location, :node_location, expr: nil, text: nil, attribute_locations: %{}]

  @type t :: %__MODULE__{
          location: String.t(),
          node_location: Location.t(),
          expr: String.t() | nil,
          text: String.t() | nil,
          attribute_locations: Document.attribute_locations()
        }
end
