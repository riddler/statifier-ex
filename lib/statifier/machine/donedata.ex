defmodule Statifier.Machine.Donedata do
  @moduledoc """
  One compiled `<donedata>` element - the interned counterpart to
  `Statifier.Document.Donedata`, built by the compiler's executable-content
  pass, reachable only through its owning `:final` state as
  `elem(machine.states, i).donedata`.

  `expr` is the folded `<content>` value: `{:compiled, ...}` when the
  `<content>` child wrote an `expr` attribute,
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

  `expr` carries no `c_index`: it is not executable content, never appears
  in a block, and no `execute_block` ever runs it.

  `params` is the compiled, document-ordered list of `<param>` children -
  `[]` when `<donedata>` has none. `expr` (the `<content>` arm) and `params`
  are mutually exclusive by validator check (`Statifier.Validator.Checks.Donedata`,
  spec 5.5: "either a single `<content>` element or one or more `<param>`
  elements ... but not both"), so a `%Donedata{}` with both non-empty never
  reaches the interpreter fold. Like `expr`, no entry in `params` carries a
  `c_index`: `<donedata>` is not executable content.
  """

  alias Statifier.Machine
  alias Statifier.Machine.Param
  alias Statifier.Parser.Location

  @enforce_keys [:location]
  defstruct [:location, expr: nil, expr_location: nil, params: []]

  @type t :: %__MODULE__{
          expr: Machine.expr() | nil,
          location: Location.t(),
          expr_location: Location.t() | nil,
          params: [Param.t()]
        }
end
