defmodule Statifier.Document.Send do
  @moduledoc """
  A `<send>` element: spec 6.2's instruction to send an event, immediately or
  after a delay.

  Every mutually exclusive attribute pairing 6.2.1 names is nonetheless
  simultaneously representable here, on purpose, so
  `Statifier.Validator.Checks.Send` can report the shape rather than
  lowering refusing to build it - the same division of labour
  `Statifier.Document.Invoke`'s moduledoc describes for its own attributes:

  - `event` "Must not occur with the 'eventexpr' attribute."
  - `target` "Must not occur with the 'targetexpr' attribute."
  - `type` "Must not occur with the 'typeexpr' attribute."
  - `id` "Must not occur with the 'idlocation' attribute."
  - `delay` "Must not occur with the 'delayexpr' attribute or when the
    attribute 'target' has the value '_internal'."
  - `namelist` "Must not occur with the `<param>` element."

  `namelist` is `[String.t()]` from a whitespace-split `namelist` attribute
  (5.9.2's space-separated list of location expressions), mirroring
  `Statifier.Document.Invoke.namelist`. `params` and `content` are built the
  same way `Statifier.Document.Invoke`'s own `params`/`content` are - one
  slot each, filled by `Statifier.Lowering.Builders.place/3`'s `%Send{}`
  clauses as `<param>`/`<content>` children are walked.

  Unlike `<invoke>`, `<send>` is executable content: it is tagged
  `{:content_node, send}` by `Statifier.Lowering.Builders.build_send/2` and
  lands in a block's own `content` list through the placement clauses every
  other content node already uses, rather than through a dedicated
  state-level slot.
  """

  alias Statifier.Document
  alias Statifier.Document.{Content, Param}
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [
    :location,
    event: nil,
    eventexpr: nil,
    target: nil,
    targetexpr: nil,
    type: nil,
    typeexpr: nil,
    id: nil,
    idlocation: nil,
    delay: nil,
    delayexpr: nil,
    namelist: [],
    params: [],
    content: nil,
    attribute_locations: %{}
  ]

  @type t :: %__MODULE__{
          location: Location.t(),
          event: String.t() | nil,
          eventexpr: String.t() | nil,
          target: String.t() | nil,
          targetexpr: String.t() | nil,
          type: String.t() | nil,
          typeexpr: String.t() | nil,
          id: String.t() | nil,
          idlocation: String.t() | nil,
          delay: String.t() | nil,
          delayexpr: String.t() | nil,
          namelist: [String.t()],
          params: [Param.t()],
          content: Content.t() | nil,
          attribute_locations: Document.attribute_locations()
        }
end
