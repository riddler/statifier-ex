defmodule Statifier.Document.Invoke do
  @moduledoc """
  An `<invoke>` element: spec 6.4's instruction to create an instance of an
  external service.

  Every mutually exclusive attribute pairing 6.4.1 names is nonetheless
  simultaneously representable here, on purpose, so
  `Statifier.Validator.Checks.Invoke` can report the shape rather than
  lowering refusing to build it - the same division of labour
  `Statifier.Document.Donedata`, `Statifier.Document.Content`, and
  `Statifier.Document.Param` already follow for their own mutually exclusive
  pairs:

  - `type` "Must not occur with the 'typeexpr' attribute."
  - `src` "Must not occur with the 'srcexpr' attribute or the `<content>`
    element."
  - `id` "Must not occur with the 'idlocation' attribute."
  - `namelist` "Must not occur with the `<param>` element."

  `namelist` is `[String.t()]` from a whitespace-split `namelist` attribute
  (5.9.2's space-separated list of location expressions); `autoforward` is a
  `boolean()` mapped from `"true"`/`"false"`, defaulting `false` per 6.4.1's
  own stated default - an out-of-range value is
  `Statifier.Validator.Checks.Enums`'s `{:invoke_bad_autoforward, raw}` to
  report, the same "lowering maps to the default, the validator slices the
  source" division every other enumerated attribute here follows.

  `finalize` distinguishes an absent `<finalize>` child from an empty one,
  which spec 6.5 requires: `nil` means the `<invoke>` has no `<finalize>` at
  all, and `%Statifier.Document.Block{content: []}` means it has one with no
  executable content inside. This is the same absent-versus-empty shape
  `content`/`params` already carry for `<donedata>`, told apart structurally
  rather than by a sentinel.
  """

  alias Statifier.Document
  alias Statifier.Document.Block
  alias Statifier.Document.Content
  alias Statifier.Document.Param
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [
    :location,
    type: nil,
    typeexpr: nil,
    src: nil,
    srcexpr: nil,
    id: nil,
    idlocation: nil,
    namelist: [],
    autoforward: false,
    params: [],
    content: nil,
    finalize: nil,
    attribute_locations: %{}
  ]

  @type t :: %__MODULE__{
          location: Location.t(),
          type: String.t() | nil,
          typeexpr: String.t() | nil,
          src: String.t() | nil,
          srcexpr: String.t() | nil,
          id: String.t() | nil,
          idlocation: String.t() | nil,
          namelist: [String.t()],
          autoforward: boolean(),
          params: [Param.t()],
          content: Content.t() | nil,
          finalize: Block.t() | nil,
          attribute_locations: Document.attribute_locations()
        }
end
