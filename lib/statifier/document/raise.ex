defmodule Statifier.Document.Raise do
  @moduledoc """
  A `<raise>` executable-content element: spec 4.2's way to enqueue an
  internal event.

  `event` is the plain event name the author wrote (a required NMTOKEN per
  the spec), not a dot-separated descriptor list. This is deliberately not
  tokenized the way `Statifier.Document.Transition.event` is: a transition's
  `event` attribute is a whitespace-separated list of *descriptors* matched
  against the event name, each of which may itself use dot-separated
  wildcards, while `<raise>`'s `event` is a single literal name being
  produced, not a pattern being matched. Splitting it would manufacture
  structure the source never had.
  """

  alias Statifier.Document
  alias Statifier.Parser.Location

  @enforce_keys [:event, :location]
  defstruct [:event, :location, attribute_locations: %{}]

  @type t :: %__MODULE__{
          event: String.t(),
          location: Location.t(),
          attribute_locations: Document.attribute_locations()
        }
end
