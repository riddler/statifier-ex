defmodule Statifier.Machine.Data do
  @moduledoc """
  One compiled `<data>` element - the interned counterpart to
  `Statifier.Document.Data`, dense from `d_index` 0 across the whole machine
  (ADR-0012 item 3), read via `Statifier.Machine.data/2`.

  `value` selects among the value-source precedence spec 5.3.2 gives
  `<data>` (`expr`, `src`, child content, or none), decided once at
  Machine-build time by `Statifier.Compiler`:

  - `expr` compiles through `Statifier.Compiler.Expressions.compile/3` like
    any other expression - **except** a compile failure is captured as
    `{:invalid, error}` on this struct rather than failing
    `Statifier.Compiler.compile/1` (Decision 2,
    `docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md`): spec
    5.9.4 permits either load-time rejection or a runtime `error.execution`,
    and `data_invalid_test.exs` in the corpus needs the latter.
  - `src` never resolves in this pure core (ADR-0003) - it is carried as
    `{:src, uri}` and always fails at binding time (spec 5.3.2's "empty data
    element" clause).
  - non-blank child text is folded to `{:static, _}` at compile time
    (Decision 8, `Statifier.Compiler.Expressions.inline_value/1`) - it is
    never a `{:compiled, ...}` read of the datamodel.
  - no value source at all is `{:static, nil}`.

  `value_location` is the diagnostic span, following `cond_location` and
  `expr_location`'s "caller's choice" contract
  (`lib/statifier/compiler/expressions.ex:36-45`): the written attribute's
  value span when written, the `<data>` node's own `location` otherwise.
  """

  alias Statifier.Compiler.Error
  alias Statifier.Machine
  alias Statifier.Parser.Location

  @enforce_keys [:d_index, :id, :value, :location]
  defstruct [:d_index, :id, :value, :location, value_location: nil]

  @type value :: Machine.expr() | {:invalid, Error.t()} | {:src, uri :: String.t()}

  @type t :: %__MODULE__{
          d_index: non_neg_integer(),
          id: String.t(),
          value: value(),
          location: Location.t(),
          value_location: Location.t() | nil
        }
end
