defmodule Statifier.Document.Donedata do
  @moduledoc """
  A `<donedata>` element: the optional payload a `:final` state's
  `done.state.*` event carries (spec 5.7).

  `content` is `nil` when the element is present but empty, and a
  `Statifier.Document.Content.t()` when it has a `<content>` child. `params`
  holds however many `<param>` children are present, in document order,
  including zero. Spec 5.5 states the content model: "either a single
  `<content>` element or one or more `<param>` elements as children of
  `<donedata>`, but not both" - `content` and `params` are both
  representable on this struct at once, on purpose, so
  `Statifier.Validator.Checks.Donedata` can report the violation rather than
  lowering refusing to build it (the same division of labour that check
  already has for `<donedata>` sitting on a non-`:final` state).

  `Statifier.Document.State.donedata` is only meaningful on a `:final`
  state; `donedata` on any other kind is a shape the validator's check 8
  exists to report, not one this layer refuses to build.
  """

  alias Statifier.Document.{Content, Param}
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, content: nil, params: []]

  @type t :: %__MODULE__{
          content: Content.t() | nil,
          params: [Param.t()],
          location: Location.t()
        }
end
