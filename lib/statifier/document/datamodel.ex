defmodule Statifier.Document.Datamodel do
  @moduledoc """
  A `<datamodel>` element: an ordered list of `<data>` children.

  `<datamodel>` has no attributes of its own (spec 5.2.1), but carries its
  own `location` so `Statifier.Validator.Checks.Data`'s placement rule
  (`{:datamodel_bad_parent, kind}`) has something of its own to point at,
  distinct from the `<data>` children's own spans.

  Spec 3.2.2/3.3.2/3.4.2 allow `<datamodel>` under `<scxml>`, `<state>`, and
  `<parallel>` only - never under `<final>` or `<history>`. Lowering does not
  enforce that placement: `Statifier.Document.State` is one struct for all
  four state kinds, so `Statifier.Lowering.Builders.place/3` has no way to
  distinguish them by kind. A `<datamodel>` under a `:final` or `:history`
  state is representable here and left for `Statifier.Validator.Checks.Data`
  to catch.
  """

  alias Statifier.Document.Data
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, data: []]

  @type t :: %__MODULE__{
          location: Location.t(),
          data: [Data.t()]
        }
end
