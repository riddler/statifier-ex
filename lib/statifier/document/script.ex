defmodule Statifier.Document.Script do
  @moduledoc """
  A `<script>` element (spec 5.8): a predicator *statement program* body,
  run for its side effects on the datamodel (ADR-0026) - not an
  expression-bearing node like `<log>`/`<content>`, and compiled through
  `Statifier.Compiler.Expressions.compile_program/3` rather than
  `compile/3`. Legal both as executable content (`<onentry>`, `<onexit>`, a
  transition, an `<if>` branch, a `<foreach>` body) and, spec 5.8, as a
  direct child of `<scxml>`, evaluated at document load time -
  `Statifier.Lowering.Builders.place/3` sorts the two by parent.

  `text` is `Statifier.Parser.DOM.text/1`'s verbatim, untrimmed
  concatenation of `<script>`'s direct text children - the program source
  predicator compiles, mirroring `Statifier.Document.Assign.text` and
  `Statifier.Document.Data.text`.

  `location` is this element's own `Statifier.Parser.Location` span, the
  plain name every Document node but `Statifier.Document.Assign` uses for
  it: `<script>` carries no spec attribute named `location` (unlike
  `<assign>`'s own `location` attribute, the reason `Assign` renames its
  own span field to `node_location`), so there is no competing meaning for
  this name to collide with here.

  `src` is the raw `src` attribute value, nilable - carried here only so
  `Statifier.Lowering.Builders.build_script/2` can report a written one as
  `{:unsupported_attribute, "script", "src"}` (ADR-0026 decision 2: no
  external fetch, ever) before any struct is built; no `%Script{}` this
  engine's lowering actually produces ever has a non-nil `src`, because a
  written `src` short-circuits the build entirely.
  """

  alias Statifier.Document
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, text: nil, src: nil, attribute_locations: %{}]

  @type t :: %__MODULE__{
          location: Location.t(),
          text: String.t() | nil,
          src: String.t() | nil,
          attribute_locations: Document.attribute_locations()
        }
end
