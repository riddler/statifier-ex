defmodule Statifier.Parser.DOM.Text do
  @moduledoc """
  A run of character data between two markup constructs.

  `value` is the standard XML entities expanded, CDATA sections unwrapped,
  and XML 1.0 2.11 line-break folding applied (ADR-0045): a literal `\r\n`
  pair and a literal lone `\r` in the raw run each become one `\n`, while a
  `\r` decoded from a character reference such as `&#xD;` survives as `\r`.
  `location` spans the **raw** source the run came from, which is why the two
  are separate fields: the raw span still contains the `&amp;` sequences,
  `<![CDATA[` delimiters, any comment or processing instruction the run
  straddles, and the unfolded `\r`/`\r\n` bytes, none of which `value` does,
  so offsets inside `value` do not map onto the source one for one when any
  of them is present.

  One node covers a whole run. A single run reaches the handler as several
  events whenever an entity reference or a CDATA section splits it, and those
  are coalesced back into one node - a text run is a property of the
  document, not of Saxy's event granularity.
  """

  alias Statifier.Parser.Location

  @enforce_keys [:value, :location]
  defstruct [:value, :location]

  @type t :: %__MODULE__{
          value: binary(),
          location: Location.t()
        }
end
