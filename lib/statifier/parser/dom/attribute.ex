defmodule Statifier.Parser.DOM.Attribute do
  @moduledoc """
  One attribute of an element, carrying two spans rather than one.

  `location` covers the whole `name="value"` text, quotes included -
  the span a diagnostic underlines when the attribute itself is the problem.
  `value_location` covers only the text inside the quotes, and exists for
  ADR-0014: an expression span is relative to the expression string, and
  `value_location` is the anchor `Statifier.Parser.Location.resolve_span/4`
  composes it against to produce a document position.

  The attribute's name begins at `location.start_line` /
  `location.start_column` exactly, so no separate name span is stored.

  `value` is Saxy's entity-expanded text while `value_location` covers raw
  source. When the raw text contains an entity or character reference the two
  differ in length, so an offset *inside* the value does not map 1:1 onto the
  source. `resolve_span/4` accounts for the difference by walking the raw
  slice against the expanded value; `Location.slice(value_location, source)`
  recovers the raw text on demand, so nothing needs to be stored here.
  """

  alias Statifier.Parser.Location

  @enforce_keys [:name, :value]
  defstruct [:name, :value, :location, :value_location]

  @type t :: %__MODULE__{
          name: binary(),
          value: binary(),
          location: Location.t() | nil,
          value_location: Location.t() | nil
        }
end
