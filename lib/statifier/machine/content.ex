defmodule Statifier.Machine.Content do
  @moduledoc """
  One compiled `<raise>` or `<log>` executable-content node - the interned
  counterpart to `Statifier.Document.Raise` / `Statifier.Document.Log` (plan
  Phase 5).

  `c_index` is a dense document-order identity assigned to **every**
  `<raise>`/`<log>` node reachable through `onentry`, `onexit`, or a
  `<transition>`'s own content, across the whole machine (ADR-0012 item 3).
  `<donedata>`'s own `<content>` child is deliberately excluded (plan
  Decision 8): it is not executable content, never appears in a block, and
  no `execute_block` ever runs it, so giving it a `c_index` would stop
  `c_index` meaning "the nth executable-content node".

  ## Fields that are kind-scoped

  | Field | Meaningful on |
  |---|---|
  | `event` | `:raise` - the literal event name being enqueued |
  | `label` | `:log` - the optional diagnostic label |
  | `expr` | `:log` - the optional `Machine.expr()` to evaluate and log |
  | `expr_location` | `:log` - `attribute_locations[:expr]`'s value span, `nil` when `expr` was never written |
  """

  alias Statifier.Machine
  alias Statifier.Parser.Location

  @enforce_keys [:c_index, :kind, :location]
  defstruct [
    :c_index,
    :kind,
    :location,
    event: nil,
    label: nil,
    expr: nil,
    expr_location: nil
  ]

  @type t :: %__MODULE__{
          c_index: non_neg_integer(),
          kind: :raise | :log,
          event: String.t() | nil,
          label: String.t() | nil,
          expr: Machine.expr() | nil,
          location: Location.t(),
          expr_location: Location.t() | nil
        }
end
