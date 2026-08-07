defmodule Statifier.Document.Transition do
  @moduledoc """
  A `<transition>` element: spec 3.5, matched against events and guarded by
  a condition to move the configuration from one set of states to another.

  `event` and `target` are both already-split lists (`[String.t()]`), not
  the raw whitespace-separated attribute strings. `event` holds the
  transition's event *descriptors* - each one still an unparsed token that
  may itself use dot-separated wildcards (`"error.*"`) - and `target` holds
  the tokenized target ids. The re-splitting this avoids is what
  `../statifier/lib/statifier/event.ex:64-79` does on every match attempt in
  v1: tokenizing once at lowering means no consumer downstream re-splits.
  The *second*-level split of a descriptor into its dot-separated tokens is
  not done here - that is st-wju.1's job, once the descriptor is being
  matched against a compiled event name, not stored. An empty `event` list
  means an eventless transition; an empty `target` list means a targetless
  one - both spec-legal, and both distinguishable from "one descriptor" or
  "one target" without a sentinel.

  `cond` is raw predicator source, `String.t() | nil`, never compiled here
  (`docs/datamodel.md`). Its ADR-0014 span lives at
  `attribute_locations[:cond]`, the base offset ADR-0014's arithmetic adds
  a within-expression span to - not a field of this struct, matching how
  every other expression-bearing node stores its span.

  `type` defaults to `:external`, the value lowering applies when the
  attribute is absent (spec 3.5's own default). That default is applied,
  not left for every consumer to re-derive, but it is not by itself proof
  the author wrote `type="external"`: `attribute_locations` carries no
  `:type` key when the default applied, and does when the author wrote
  either value explicitly (Decision 7 in the plan). The same rule holds for
  every other field with a non-nil default in this layer.

  `content` is the transition's executable content directly,
  `[Document.content_node()]`, not wrapped in a `Statifier.Document.Block`:
  there is no wrapping element in the source to give a block its own
  location, and the transition's own `location` already is that span.
  """

  alias Statifier.Document
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [
    :location,
    :cond,
    event: [],
    target: [],
    type: :external,
    content: [],
    attribute_locations: %{}
  ]

  @type t :: %__MODULE__{
          event: [String.t()],
          cond: String.t() | nil,
          target: [String.t()],
          type: :internal | :external,
          content: [Document.content_node()],
          location: Location.t(),
          attribute_locations: Document.attribute_locations()
        }
end
