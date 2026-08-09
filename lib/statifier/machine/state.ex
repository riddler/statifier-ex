defmodule Statifier.Machine.State do
  @moduledoc """
  One compiled `<scxml>`, `<state>`, `<parallel>`, `<final>`, or `<history>`
  element - the interned, indexed counterpart to `Statifier.Document.State`
  (and, for index 0, to `Statifier.Document` itself; plan Decision 2).

  `kind :: :scxml | :state | :parallel | :final | :history`. Unlike the
  Document layer, `:scxml` is a real kind here: the root is state index 0,
  `parent: nil`, `id: nil` (`Statifier.Machine`'s moduledoc), so LCCA and
  `get_transition_domain` need no root special case.

  `atomic?`/`compound?` are not stored - `Statifier.Machine.atomic?/2` and
  `compound?/2` derive them from `children` (plan Decision 4), the same
  divergence-avoidance reasoning `Statifier.Document.State` already states
  for why `kind` stays the element kind.

  ## Fields that are kind-scoped

  | Field | Meaningful on | Landed in |
  |---|---|---|
  | `id` | any (nilable except it is always `nil` on `:scxml`) | Phase 2 |
  | `parent` | any (`nil` only at index 0) | Phase 2 |
  | `last` | any - the high end of this state's self-inclusive descendant range, `index` being the low end (plan Decision 3) | Phase 2 |
  | `children` | any (`[]` on an atomic state) | Phase 2 |
  | `initial` | `:state`, `:scxml` - `[]` on `:parallel`, `:final`, `:history`, and any atomic state | Phase 2 |
  | `history_type` | `:history` | Phase 2 |
  | `history_children` | any compound/parallel state - its own direct `:history` children, so exit-time recording finds them without scanning | Phase 2 |
  | `transitions` | `:state`, `:parallel`, `:history` - the state's own selectable transitions' `t_index` list | Phase 4 |
  | `onentry` / `onexit` | any | Phase 5 |
  | `initial_transition` | `:state`, `:scxml` - the `<initial>` element's transition `t_index`, or `nil` | Phase 4 |
  | `history_default` | `:history` - its default transition's `t_index` | Phase 4 |
  | `donedata` | `:final` | Phase 5 |

  `transitions`, `onentry`, `onexit`, `initial_transition`, `history_default`,
  and `donedata` are declared here but left at their empty defaults until
  Phases 4 and 5 populate them, so the struct shape does not change under a
  later phase.
  """

  alias Statifier.Parser.Location

  @enforce_keys [:index, :kind, :last, :location]
  defstruct [
    :index,
    :kind,
    :parent,
    :last,
    :location,
    id: nil,
    children: [],
    initial: [],
    history_type: nil,
    history_children: [],
    transitions: [],
    onentry: [],
    onexit: [],
    initial_transition: nil,
    history_default: nil,
    donedata: nil
  ]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          id: String.t() | nil,
          kind: :scxml | :state | :parallel | :final | :history,
          parent: non_neg_integer() | nil,
          last: non_neg_integer(),
          children: [non_neg_integer()],
          initial: [non_neg_integer()],
          history_type: :shallow | :deep | nil,
          history_children: [non_neg_integer()],
          transitions: [non_neg_integer()],
          onentry: [term()],
          onexit: [term()],
          initial_transition: non_neg_integer() | nil,
          history_default: non_neg_integer() | nil,
          donedata: term() | nil,
          location: Location.t()
        }
end
