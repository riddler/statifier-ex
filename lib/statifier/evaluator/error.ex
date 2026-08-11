defmodule Statifier.Evaluator.Error do
  @moduledoc """
  `Statifier.Evaluator.evaluate/2`'s own error value (ADR-0014 item 4).

  `source` is the original expression string
  (`Statifier.Machine.expr()`'s `{:compiled, _, source}` third element),
  carried alongside `error` so a reporting site never has to thread the
  source string separately just to render a message. `error` is predicator's
  own error struct verbatim - `%Predicator.Errors.UndefinedVariableError{}`,
  `%Predicator.Errors.TypeMismatchError{}`, `%Predicator.Errors.EvaluationError{}`,
  or `%Predicator.Errors.ParseError{}` - never re-wrapped or reduced to a
  message string, so a caller that wants to pattern-match the specific
  failure still can.

  `span` is lifted out of `error` for convenience (`Predicator.Errors.ParseError`
  has no `:span` field, hence `Map.get/2` rather than `error.span`) and is
  `nil` exactly when predicator itself could not attribute one - ADR-0014
  item 4's own "nil when predicator cannot attribute one", not a sentinel
  this module invents.

  This struct carries no `owner` field: the raise site
  (`Statifier.Interpreter.Content.raise_execution_error/4`) already stamps
  `{:content, c_index, owner}` on the platform event, so the owner would be
  a duplicate of information the caller already has, not something the
  evaluator needs to originate.
  """

  @enforce_keys [:source, :error]
  defstruct [:source, :error, :span]

  @type t :: %__MODULE__{
          source: String.t(),
          error: struct(),
          span: term() | nil
        }

  @doc """
  Builds an error value from the failing expression's `source` and
  predicator's own `error` struct, lifting `error`'s `:span` field (when it
  has one) up to the top level.
  """
  @spec new(source :: String.t(), error :: struct()) :: t()
  def new(source, error) do
    %__MODULE__{source: source, error: error, span: Map.get(error, :span)}
  end
end
