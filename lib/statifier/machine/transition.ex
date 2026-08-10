defmodule Statifier.Machine.Transition do
  @moduledoc """
  One compiled `<transition>` element - the interned counterpart to
  `Statifier.Document.Transition`, built by the compiler's transition pass.

  `t_index` is a dense document-order identity assigned to **every**
  `<transition>` element in the machine, including the transition inside an
  `<initial>` element and a `:history` state's own default transition - both
  run executable content (spec 3.3, 3.6) and both need a stable index trace
  effects and tooling can name. Selectability is a property of *where* a
  `t_index` is stored, not of the index itself:
  `Statifier.Machine.State.transitions` holds only the selectable ones a
  state's own event matching walks; the `<initial>` element's transition and
  a history's default live in `initial_transition` / `history_default`
  instead, so `select_transitions` never has to filter this struct by kind.

  `source` is the owning state's index - for a plain transition, the state
  it is a direct child of; for an `<initial>` element's transition or a
  history default, the state the `<initial>`/`<history>` element itself
  belongs to.

  `targets` is `[non_neg_integer()]`, resolved from
  `Statifier.Document.Transition.target`'s id list - `[]` for a targetless
  transition, both spec-legal and distinguishable from "one target" without
  a sentinel (`Statifier.Document.Transition`'s own moduledoc).

  `events` is `[[String.t()]]` - one dot-split token list per whitespace-
  separated descriptor. `Statifier.Document.Transition.event` already did
  the first (whitespace) split at lowering time; this struct does the
  *second* (dot) split, so `event="a.b c"` compiles to `[["a", "b"], ["c"]]`
  and event matching walks tokens without ever splitting a string at
  runtime.

  `cond` is `Machine.expr() | nil`, compiled through
  `Statifier.Compiler.Expressions.compile/3` with owner
  `{:transition, t_index}`. `cond_location` is the `cond` attribute's own
  value span (`attribute_locations[:cond]`), falling back to the
  transition's own `location` when the attribute has no recorded span -
  retained so a runtime `cond` failure can point inside the expression
  (ADR-0014 item 4). Both are `nil` exactly when `cond` was not written.

  `content` is `[c_index]`, the transition's own executable content in
  document order - `[]` until the compiler's executable-content pass
  populates it.
  """

  alias Statifier.Machine
  alias Statifier.Parser.Location

  @enforce_keys [:t_index, :source, :targets, :events, :type, :content, :location]
  defstruct [
    :t_index,
    :source,
    :targets,
    :events,
    :cond,
    :type,
    :content,
    :location,
    :cond_location
  ]

  @type t :: %__MODULE__{
          t_index: non_neg_integer(),
          source: non_neg_integer(),
          targets: [non_neg_integer()],
          events: [[String.t()]],
          cond: Machine.expr() | nil,
          type: :internal | :external,
          content: [non_neg_integer()],
          location: Location.t(),
          cond_location: Location.t() | nil
        }
end
