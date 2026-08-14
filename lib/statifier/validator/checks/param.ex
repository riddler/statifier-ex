defmodule Statifier.Validator.Checks.Param do
  @moduledoc """
  Spec 5.7: "A conformant SCXML document MUST specify either the 'expr'
  attribute of `<param>` or the 'location' attribute, but MUST NOT specify
  both." Reports `{:param_expr_and_location, name}` when both are present
  and `{:param_no_value, name}` when neither is, both at the `<param>`
  element's own `location`.

  `lib/statifier/document/param.ex` makes `expr` and `param_location` both
  nilable and representable at once precisely so this check can report the
  shape rather than lowering refusing to build it - the same division of
  labour `Checks.Content` has with `<content>`.

  The only `%Statifier.Document.Param{}` a document can hold today is a
  `<final>`'s `<donedata><param>` (`Statifier.Document.Donedata`), so that is
  the one place this check walks. When `<send>`/`<invoke>` gain a `<param>`
  child, this walk grows an arm; the rule itself is unchanged, since spec 5.7
  states it on `<param>` rather than on whichever parent holds it.
  """

  alias Statifier.Document
  alias Statifier.Document.Donedata
  alias Statifier.Document.Param, as: DParam
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @doc """
  Walks every `<final>`'s `<donedata><param>` in the document and returns a
  `:param_expr_and_location` or `:param_no_value` error for each one whose
  `expr` and `location` attributes violate spec 5.7's exactly-one rule.
  Returns `[]` when every `<param>` in the document specifies exactly one.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.flat_map(&params/1)
    |> Enum.flat_map(&check_param/1)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp params(%State{donedata: %Donedata{params: params}}), do: params
  defp params(%State{}), do: []

  defp check_param(%DParam{expr: nil, param_location: nil, name: name, location: location}) do
    [Error.param_no_value(name, location)]
  end

  defp check_param(%DParam{
         expr: expr,
         param_location: param_location,
         name: name,
         location: location
       })
       when not is_nil(expr) and not is_nil(param_location) do
    [Error.param_expr_and_location(name, location)]
  end

  defp check_param(%DParam{}), do: []
end
