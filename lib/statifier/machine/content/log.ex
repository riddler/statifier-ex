defmodule Statifier.Machine.Content.Log do
  @moduledoc """
  A compiled `<log>` executable-content node (spec 5.8) - the interned
  counterpart to `Statifier.Document.Log`. `label` is the optional
  diagnostic label; `expr` is the optional `Machine.expr()` to evaluate and
  log; `expr_location` is `attribute_locations[:expr]`'s value span, `nil`
  when `expr` was never written. Its `Statifier.ExecutableContent`
  implementation lands in Phase 2.
  """

  alias Statifier.Machine
  alias Statifier.Parser.Location

  @enforce_keys [:c_index, :location]
  defstruct [:c_index, :location, label: nil, expr: nil, expr_location: nil]

  @type t :: %__MODULE__{
          c_index: non_neg_integer(),
          location: Location.t(),
          label: String.t() | nil,
          expr: Machine.expr() | nil,
          expr_location: Location.t() | nil
        }
end
