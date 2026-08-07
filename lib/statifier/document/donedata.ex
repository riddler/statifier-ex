defmodule Statifier.Document.Donedata do
  @moduledoc """
  A `<donedata>` element: the optional payload a `:final` state's
  `done.state.*` event carries (spec 5.7).

  `content` is `nil` when the element is present but empty, and a
  `Statifier.Document.Content.t()` when it has a `<content>` child. Phase 3
  adds `<param>` as an alternative to `<content>`; Phase 1 only needs the
  static-content case (see the plan's Decision 5), so `content` is the only
  field besides `location` for now.

  `Statifier.Document.State.donedata` is only meaningful on a `:final`
  state; `donedata` on any other kind is a shape the validator (st-l5k.5
  check 8) exists to report, not one this layer refuses to build.
  """

  alias Statifier.Document.Content
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, content: nil]

  @type t :: %__MODULE__{
          content: Content.t() | nil,
          location: Location.t()
        }
end
