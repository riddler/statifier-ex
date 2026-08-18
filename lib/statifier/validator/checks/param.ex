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

  Two places today hold a `%Statifier.Document.Param{}`: a `<final>`'s
  `<donedata><param>` (`Statifier.Document.Donedata`) and any state's
  `<invoke><param>` (`Statifier.Document.Invoke`), so this check walks both.
  When `<send>` gains a `<param>` child, this walk grows a third arm; the
  rule itself is unchanged, since spec 5.7 states it on `<param>` rather than
  on whichever parent holds it.
  """

  alias Statifier.Document
  alias Statifier.Document.{Donedata, State}
  alias Statifier.Document.Param, as: DParam
  alias Statifier.Validator.{Context, Error}

  @doc """
  Walks every `<final>`'s `<donedata><param>` and every state's
  `<invoke><param>` in the document and returns a `:param_expr_and_location`
  or `:param_no_value` error for each one whose `expr` and `location`
  attributes violate spec 5.7's exactly-one rule. Returns `[]` when every
  `<param>` in the document specifies exactly one.
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

  defp params(%State{donedata: donedata, invoke: invokes}) do
    donedata_params(donedata) ++ Enum.flat_map(invokes, & &1.params)
  end

  defp donedata_params(%Donedata{params: params}), do: params
  defp donedata_params(nil), do: []

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
