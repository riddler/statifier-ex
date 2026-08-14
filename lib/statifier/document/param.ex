defmodule Statifier.Document.Param do
  @moduledoc """
  A `<param>` element under `<donedata>`: spec 5.7's key-value alternative to
  `<content>`.

  ## `location` holds the element span here - the opposite of `Document.Assign`

  This struct's `location` field is the ordinary convention every other
  Document node follows: this `<param>` element's own `Statifier.Parser.Location`
  span in the source document. `param_location` holds the SCXML `location`
  **attribute**'s raw, uncompiled path string.

  That is the mirror image of `Statifier.Document.Assign`, which names the
  same collision under "Two spans that are not the same thing" and resolves
  it the other way: there, `location` is the path string and `node_location`
  is the element span. A reader who assumes `Param` repeats `Assign`'s choice
  will build the fields backward, so the inversion is stated plainly rather
  than left to be discovered.

  Two reasons for the inversion, both specific to `<param>`:

  1. On `<assign>` the `location` attribute is **required** (spec 5.4.2), so
     the raw path is the field a reader reaches for first. On `<param>` it is
     **optional** and mutually exclusive with `expr` (spec 5.7), so making
     the always-present parser span the oddly-named field would be the worse
     trade.
  2. `Statifier.Lowering.Builders`'s generic `place/3` catch-all does
     `Map.fetch!(value, :location)` and hands the result to
     `Statifier.Lowering.Error.misplaced/3`, which pattern-matches
     `%Statifier.Parser.Location{}`. `Assign` needs a dedicated earlier
     `place/3` clause purely to avoid crashing that match on a binary.
     Keeping `location` as the span here means `{:param, _}` needs no such
     clause.

  `name` is the required `name` attribute (spec 5.7.1); a missing `name`
  means no struct can be built at all (`Statifier.Lowering.Builders.build_param/2`
  follows `build_raise/2`'s required-attribute pattern). `expr` and
  `param_location` are both nilable and simultaneously representable, on
  purpose, so `Statifier.Validator.Checks.Param` can report the pair rather
  than lowering refusing to build one - the same `<data>` `expr`/`src`
  precedent `Statifier.Document.Content`'s moduledoc also follows.
  """

  alias Statifier.Document
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, name: nil, expr: nil, param_location: nil, attribute_locations: %{}]

  @type t :: %__MODULE__{
          location: Location.t(),
          name: String.t() | nil,
          expr: String.t() | nil,
          param_location: String.t() | nil,
          attribute_locations: Document.attribute_locations()
        }
end
