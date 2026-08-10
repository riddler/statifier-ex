defmodule Statifier.Machine.Content.Log do
  @moduledoc """
  A compiled `<log>` executable-content node (spec 4.7) - the interned
  counterpart to `Statifier.Document.Log`. `label` is the optional
  diagnostic label; `expr` is the optional `Machine.expr()` to evaluate and
  log; `expr_location` is `attribute_locations[:expr]`'s value span, `nil`
  when `expr` was never written.

  Its `Statifier.ExecutableContent` implementation lives right below the
  struct: this file is the whole node, top to bottom, with no dispatcher
  anywhere else in the tree.
  """

  alias Statifier.Effect
  alias Statifier.ExecutableContent.Context
  alias Statifier.Machine
  alias Statifier.Machine.Content.Log
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

  defimpl Statifier.ExecutableContent do
    @moduledoc false

    # spec 4.7's <log>: "log the label and the value of expr". `machine_state`
    # is untouched (plan Decision 7) - <log> has an effect and nothing else,
    # ADR-0003's whole point being that the core does not log, it returns log
    # entries.
    @spec execute(node :: Log.t(), context :: Context.t()) ::
            {:ok, Context.t(), [{:log, Effect.Log.t()}]}
    def execute(%Log{} = node, %Context{} = context) do
      %{machine_state: machine_state, owner: owner} = context

      log_effect = %Effect.Log{
        label: node.label,
        value: value(node),
        c_index: node.c_index,
        owner: owner,
        macrostep: machine_state.macrostep,
        microstep: machine_state.microstep
      }

      {:ok, context, [{:log, log_effect}]}
    end

    # `value`'s expr slot is compiled but not yet evaluated (plan Decision
    # 10): st-af3 evaluates a compiled expr against the datamodel. Until
    # then `value` is the static value or `nil` - not a rescue-to-default,
    # nothing failed, the expression simply has not been evaluated yet
    # (`docs/datamodel.md`). Exactly the shape and reasoning
    # `static_donedata/2` used (`lib/statifier/interpreter/exit_entry.ex`),
    # so the two places carrying an unevaluated expression until st-af3
    # look the same and are found by the same grep.
    @spec value(node :: Log.t()) :: term()
    defp value(%Log{expr: nil}), do: nil
    defp value(%Log{expr: {:static, term}}), do: term
    defp value(%Log{expr: {:compiled, _compiled, _source}}), do: nil
  end
end
