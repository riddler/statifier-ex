defmodule Statifier.Machine.Donedata do
  @moduledoc """
  One compiled `<donedata>` element - the interned counterpart to
  `Statifier.Document.Donedata` (plan Phase 5), reachable only through its
  owning `:final` state as `elem(machine.states, i).donedata`.

  `expr` is the folded `<content>` value (plan Decision 7):
  `{:compiled, ...}` when the `<content>` child wrote an `expr` attribute,
  `{:static, text}` when it carried a text body instead, and `nil` when
  `<donedata>` has no `<content>` child at all. Validator check 9
  (`Statifier.Validator.Checks.Content`) already guarantees a `<content>`
  node never carries both forms at once, so the fold cannot lose
  information.

  `expr_location` is the diagnostic span for `expr`: the `<content>`
  node's `attribute_locations[:expr]` value span for the compiled arm, or
  the `<content>` node's own `location` for the static arm - `Content.text`
  has no span of its own by design
  (`lib/statifier/document/content.ex:17-21`). `nil` exactly when `expr` is
  `nil`.

  `expr` carries no `c_index` (plan Decision 8): it is not executable
  content, never appears in a block, and no `execute_block` ever runs it.
  """

  alias Statifier.Machine
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, expr: nil, expr_location: nil]

  @type t :: %__MODULE__{
          expr: Machine.expr() | nil,
          location: Location.t(),
          expr_location: Location.t() | nil
        }
end
