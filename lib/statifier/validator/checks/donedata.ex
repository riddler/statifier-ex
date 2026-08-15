defmodule Statifier.Validator.Checks.Donedata do
  @moduledoc """
  Check 8 (spec 3.7, 5.7): `<donedata>` is only legal on a `:final` state.
  Reports `{:donedata_not_on_final, id}` for any non-`:final` state
  carrying a non-nil `donedata`, at the `donedata`'s own `location` -
  `lib/statifier/document/donedata.ex` names this check as the layer that
  reports the shape rather than one that refuses to build it.

  A second rule, spec 5.5's content model: "either a single `<content>`
  element or one or more `<param>` elements as children of `<donedata>`, but
  not both." Reports `{:donedata_content_and_params, id}` for a `<donedata>`
  carrying both a `<content>` child and one or more `<param>` children, at
  the `<donedata>`'s own `location`. `lib/statifier/document/donedata.ex`
  makes `content` and `params` both representable at once precisely so this
  arm can report the shape rather than lowering refusing to build it - the
  same division of labour the first rule above already has. This arm is
  inert until `<param>` is supported, and it is written now so it lands with
  `<param>` rather than being rediscovered then.
  """

  alias Statifier.Document
  alias Statifier.Document.Donedata, as: DDonedata
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @doc """
  Returns a `:donedata_not_on_final` error for every state that carries a
  non-nil `donedata` but is not itself a `:final` state, and a
  `:donedata_content_and_params` error for every `<donedata>` that carries
  both a `<content>` child and one or more `<param>` children. Returns `[]`
  when every `<donedata>` element in the document sits on a `<final>` and
  specifies at most one of `<content>`/`<param>`.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    flat = flatten(states)

    not_on_final =
      flat
      |> Enum.filter(&offending?/1)
      |> Enum.map(&Error.donedata_not_on_final(&1.id, &1.donedata.location))

    content_and_params =
      flat
      |> Enum.flat_map(&donedatas/1)
      |> Enum.filter(&content_and_params?/1)
      |> Enum.map(&Error.donedata_content_and_params(&1.id, &1.donedata.location))

    not_on_final ++ content_and_params
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp offending?(%State{kind: :final}), do: false
  defp offending?(%State{donedata: nil}), do: false
  defp offending?(%State{}), do: true

  defp donedatas(%State{donedata: nil}), do: []
  defp donedatas(%State{donedata: %DDonedata{}} = state), do: [state]

  defp content_and_params?(%State{donedata: %DDonedata{content: nil}}), do: false
  defp content_and_params?(%State{donedata: %DDonedata{params: []}}), do: false
  defp content_and_params?(%State{donedata: %DDonedata{}}), do: true
end
