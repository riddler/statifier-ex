defmodule Statifier.Parser.DOM.Attribute do
  @moduledoc """
  One attribute of an element, carrying two spans rather than one.

  `location` covers the whole `name="value"` text, quotes included -
  the span a diagnostic underlines when the attribute itself is the problem.
  `value_location` covers only the text inside the quotes, and exists for
  ADR-0014: an expression span is relative to the expression string, so
  `value_location.start_offset` is what turns it into a document position.

  The attribute's name begins at `location.start_line` /
  `location.start_column` exactly, so no separate name span is stored.

  `value` is Saxy's entity-expanded text while `value_location` covers raw
  source. When the raw text contains an entity or character reference the two
  differ in length, so an offset *inside* the value does not map 1:1 onto the
  source. No corpus attribute contains a reference; if one ever does, the fix
  is for the scanner to record the raw value text alongside its span.
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
