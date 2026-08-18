defmodule Statifier.Machine.State do
  @moduledoc """
  One compiled `<scxml>`, `<state>`, `<parallel>`, `<final>`, or `<history>`
  element - the interned, indexed counterpart to `Statifier.Document.State`
  (and, for index 0, to `Statifier.Document` itself).

  `kind :: :scxml | :state | :parallel | :final | :history`. Unlike the
  Document layer, `:scxml` is a real kind here: the root is state index 0,
  `parent: nil`, `id: nil` (`Statifier.Machine`'s moduledoc), so LCCA and
  `get_transition_domain` need no root special case.

  `atomic?`/`compound?` are not stored - `Statifier.Machine.atomic?/2` and
  `compound?/2` derive them from `children`, the same divergence-avoidance
  reasoning `Statifier.Document.State` already states for why `kind` stays
  the element kind.

  ## Fields that are kind-scoped

  | Field | Meaningful on |
  |---|---|
  | `id` | any (nilable except it is always `nil` on `:scxml`) |
  | `parent` | any (`nil` only at index 0) |
  | `last` | any - the high end of this state's self-inclusive descendant range, `index` being the low end |
  | `children` | any (`[]` on an atomic state) |
  | `initial` | `:state`, `:scxml` - `[]` on `:parallel`, `:final`, `:history`, and any atomic state |
  | `history_type` | `:history` |
  | `history_children` | any compound/parallel state - its own direct `:history` children, so exit-time recording finds them without scanning |
  | `transitions` | `:state`, `:parallel`, `:history` - the state's own selectable transitions' `t_index` list |
  | `onentry` / `onexit` | any - `[Machine.Block.t()]`, one entry per `<onentry>`/`<onexit>` element the state wrote |
  | `initial_transition` | `:state`, `:scxml` - the `<initial>` element's transition `t_index`, or `nil` |
  | `history_default` | `:history` - its default transition's `t_index` |
  | `donedata` | `:final` - the compiled `Machine.Donedata.t()`, or `nil` |
  | `data` | `:state`, `:parallel`, `:scxml` - the `d_index`es this state's own `<datamodel>` declares, `[]` when it has none |
  | `invoke` | `:state`, `:parallel` - the compiled `Machine.Invoke.t()` list this state's own `<invoke>` children produced, in document order, `[]` when it has none |

  Every field above `donedata` is written in one pass: the compiler's
  state-interning walk builds each `%Statifier.Machine.State{}` whole, index
  and `t_index`/`c_index` references included. `donedata` and `invoke` are
  the exception - each is filled in after that walk, once its own
  compilation pass has run, so they are the only fields whose values are not
  known when the struct is first built.
  """

  alias Statifier.Machine.{Block, Donedata, Invoke}
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
    donedata: nil,
    data: [],
    invoke: []
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
          onentry: [Block.t()],
          onexit: [Block.t()],
          initial_transition: non_neg_integer() | nil,
          history_default: non_neg_integer() | nil,
          donedata: Donedata.t() | nil,
          data: [non_neg_integer()],
          invoke: [Invoke.t()],
          location: Location.t()
        }
end
