defmodule Statifier.Document.Initial do
  @moduledoc """
  An `<initial>` element: spec 3.6's way to name a compound state's default
  entry point via a `<transition>` rather than an `initial` attribute.

  This is a slot on its parent, `Statifier.Document.State.initial_element`,
  not a `kind` on `Statifier.Document.State`.
  `<initial>` has no `id` attribute at all (spec 3.6), so it fails the rule
  the kind set follows ("a kind is a thing with an id a transition can
  target"). v1 gave it a synthetic id
  (`../statifier/lib/statifier/parser/scxml/element_builder.ex:522-525`)
  purely to fit it into an id-bearing struct, and then had to exclude that
  synthetic id by hand from unique-id checking and from the compiler's id
  map. A slot has no id to exclude in the first place.

  `transitions` is a **list**, not a single nilable `Transition.t()`, even
  though the spec requires exactly one `<transition>` child. Both the
  zero-transition case and the two-or-more case must survive lowering long
  enough to be named: the validator's check 4 reports a `<state>` with both an
  `initial` attribute and an `<initial>` element, and the same "hold the
  wrong shape long enough to report it" principle applies to `<initial>`'s
  own transition count. A `%Statifier.Document.State{kind: :history}`
  already has this shape for free - its default transition is
  `transitions: [Transition.t()]` with no special casing - so the list
  representation costs nothing extra to reuse here.

  The `<initial>` transition's executable content, which spec 3.6 permits,
  is representable at no extra cost: `Transition.content` already holds it.
  """

  alias Statifier.Document.Transition
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, transitions: []]

  @type t :: %__MODULE__{
          transitions: [Transition.t()],
          location: Location.t()
        }
end
