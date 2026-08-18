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

  alias Statifier.{Effect, Evaluator, Machine}
  alias Statifier.ExecutableContent.Context
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
    # is untouched - <log> has an effect and nothing else, ADR-0003's whole
    # point being that the core does not log, it returns log entries.
    #
    # spec 5.9.3/5.9.4: a value expression that fails to evaluate is a
    # platform-reported execution error at the point of evaluation. 4.7's
    # "<log> MUST have no side-effects on document interpretation" governs
    # the logging mechanism (how the message is displayed), not the error
    # model - an unevaluatable expression is an error wherever it sits, and
    # the block runner is the only place that names the execution-failure
    # event (ADR-0003). See `content_acceptance_test.exs`'s AC3, which
    # structurally forbids this file from spelling the event name out.
    @spec execute(node :: Log.t(), context :: Context.t()) ::
            {:ok, Context.t(), [{:log, Effect.Log.t()}]} | {:error, term()}
    def execute(%Log{} = node, %Context{} = context) do
      %{machine_state: machine_state, owner: owner} = context

      case value(node, context) do
        {:ok, value} ->
          log_effect = %Effect.Log{
            label: node.label,
            value: value,
            c_index: node.c_index,
            owner: owner,
            macrostep: machine_state.macrostep,
            microstep: machine_state.microstep,
            round: machine_state.round
          }

          {:ok, context, [{:log, log_effect}]}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # `{:static, _}` folds into `Evaluator.evaluate/2` (which returns
    # `{:ok, v}` for it) rather than staying a separate clause here - one
    # fewer place that knows about `Machine.expr()`'s arms. No coercion: a
    # `<log>` value is displayed, not placed in event data, so B.2.8.1 does
    # not apply.
    @spec value(node :: Log.t(), context :: Context.t()) :: {:ok, term()} | {:error, term()}
    defp value(%Log{expr: nil}, _context), do: {:ok, nil}

    defp value(%Log{expr: expr}, %Context{datamodel_context: datamodel_context}),
      do: Evaluator.evaluate(datamodel_context, expr)
  end
end
