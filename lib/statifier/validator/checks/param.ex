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

  Three places hold a `%Statifier.Document.Param{}`: a `<final>`'s
  `<donedata><param>` (`Statifier.Document.Donedata`), any state's
  `<invoke><param>` (`Statifier.Document.Invoke`) and any `<send>`'s own
  `<param>` children (`Statifier.Document.Send`), so this check walks all
  three. The rule is the same for each, since spec 5.7 states it on
  `<param>` rather than on whichever parent holds it, and so are the two
  reasons: a host matching on `:param_no_value` or
  `:param_expr_and_location` sees one vocabulary whatever the parent. A
  `<send>` sits in executable content rather than on a state, so its arm
  reaches every `<send>` through `Checks.Send`'s own walk (every block a
  `<send>` can appear in, `<if>` and `<foreach>` bodies and `<finalize>`
  included) rather than a second walker that could disagree with it.
  """

  alias Statifier.Document
  alias Statifier.Document.{Donedata, State}
  alias Statifier.Document.Param, as: DParam
  alias Statifier.Validator.Checks.Send
  alias Statifier.Validator.{Context, Error}

  @doc """
  Walks every `<final>`'s `<donedata><param>`, every state's
  `<invoke><param>` and every `<send>`'s `<param>` in the document and
  returns a `:param_expr_and_location`
  or `:param_no_value` error for each one whose `expr` and `location`
  attributes violate spec 5.7's exactly-one rule. Returns `[]` when every
  `<param>` in the document specifies exactly one.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states} = document, %Context{}) do
    state_params = states |> flatten() |> Enum.flat_map(&params/1)
    Enum.flat_map(state_params ++ send_params(document), &check_param/1)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp params(%State{donedata: donedata, invoke: invokes}) do
    donedata_params(donedata) ++ Enum.flat_map(invokes, & &1.params)
  end

  defp donedata_params(%Donedata{params: params}), do: params
  defp donedata_params(nil), do: []

  defp send_params(document) do
    document
    |> Send.sends()
    |> Enum.flat_map(& &1.params)
  end

  defp check_param(%DParam{expr: nil, param_location: nil, name: name, location: location}) do
    [Error.param_no_value(name, location)]
  end

  defp check_param(%DParam{expr: nil}), do: []
  defp check_param(%DParam{param_location: nil}), do: []

  defp check_param(%DParam{name: name, location: location}) do
    [Error.param_expr_and_location(name, location)]
  end
end
