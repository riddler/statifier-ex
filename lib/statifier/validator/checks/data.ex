defmodule Statifier.Validator.Checks.Data do
  @moduledoc """
  Check 13: `<datamodel>` and `<data>` structural rules that lowering leaves
  representable on purpose (`lib/statifier/document/data.ex`,
  `lib/statifier/document/datamodel.ex`), following the same division of
  labour `Checks.Content` and `Checks.Donedata` already have with their own
  document nodes.

  Four reasons, over every `<datamodel>` the document holds - the root's own
  `document.datamodel_element` and every state's:

  - `{:data_expr_and_src, id}` - a `<data>` written with both `expr` and
    `src` (5.3.2: "MAY have either a 'src' or an 'expr' attribute, but MUST
    NOT have both").
  - `{:data_value_and_children, id}` - a `<data>` with `expr` or `src`
    written **and** non-blank child text (5.3.2: "if either attribute is
    present, the element MUST NOT have any children"). Whitespace-only text
    is not text - same `blank?/1` shape and reasoning as
    `Checks.Content.blank?/1` (`lib/statifier/validator/checks/content.ex:66-67`):
    pretty-printed XML leaves formatting text nodes that are not payload.
  - `{:data_reserved_id, id}` - a `<data id="...">` beginning with `_`
    (5.10: "A conformant SCXML document MUST NOT contain ids beginning with
    '_' in the `<data>` element").
  - `{:datamodel_bad_parent, kind}` - a `<datamodel>` on a `:final` or
    `:history` state. `<datamodel>` is legal under `<scxml>`, `<state>`, and
    `<parallel>` only (3.2.2 / 3.3.2 / 3.4.2); lowering cannot catch this
    because all four state kinds share one `%Document.State{}` struct
    (`lib/statifier/document/state.ex`'s kind-scoped fields table). Follows
    `Checks.Donedata.offending?/1`'s shape.

  Each `<data>`-level reason is reported at the offending `<data>`'s own
  span: `attribute_locations[:id]` when written, its own `location`
  otherwise (mirroring `Checks.Ids.id_location/1` - `id` is required to
  build a `Data` struct at all, so `attribute_locations[:id]` is always
  present in practice, but the fallback keeps the two checks' shape
  identical). `:datamodel_bad_parent` is reported at the `<datamodel>`'s own
  `location`.
  """

  alias Statifier.Document
  alias Statifier.Document.Data
  alias Statifier.Document.Datamodel
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @doc """
  Returns `:data_expr_and_src`, `:data_value_and_children`, and
  `:data_reserved_id` errors for every offending `<data>` in the document,
  and a `:datamodel_bad_parent` error for every `<datamodel>` on a `:final`
  or `:history` state. Returns `[]` when every `<datamodel>`/`<data>` in the
  document is well-formed and correctly placed.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states, datamodel_element: root_datamodel}, %Context{}) do
    flat_states = flatten(states)

    datamodels = datamodels(root_datamodel, flat_states)

    data_errors(datamodels) ++ bad_parent_errors(flat_states)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp datamodels(root_datamodel, flat_states) do
    state_datamodels = Enum.map(flat_states, & &1.datamodel_element)

    [root_datamodel | state_datamodels]
    |> Enum.filter(&match?(%Datamodel{}, &1))
  end

  defp data_errors(datamodels) do
    datamodels
    |> Enum.flat_map(& &1.data)
    |> Enum.flat_map(&check_data/1)
  end

  defp check_data(%Data{} = data) do
    expr_and_src_errors(data) ++ value_and_children_errors(data) ++ reserved_id_errors(data)
  end

  defp expr_and_src_errors(%Data{expr: nil}), do: []
  defp expr_and_src_errors(%Data{src: nil}), do: []

  defp expr_and_src_errors(%Data{id: id} = data) do
    [Error.data_expr_and_src(id, id_location(data))]
  end

  defp value_and_children_errors(%Data{expr: nil, src: nil}), do: []

  defp value_and_children_errors(%Data{id: id, text: text} = data) do
    if blank?(text) do
      []
    else
      [Error.data_value_and_children(id, id_location(data))]
    end
  end

  defp reserved_id_errors(%Data{id: id} = data) do
    if String.starts_with?(id, "_") do
      [Error.data_reserved_id(id, id_location(data))]
    else
      []
    end
  end

  defp bad_parent_errors(flat_states) do
    flat_states
    |> Enum.filter(&bad_parent?/1)
    |> Enum.map(fn state ->
      Error.datamodel_bad_parent(state.kind, state.datamodel_element.location)
    end)
  end

  defp bad_parent?(%State{kind: kind, datamodel_element: %Datamodel{}})
       when kind in [:final, :history],
       do: true

  defp bad_parent?(%State{}), do: false

  defp id_location(%Data{attribute_locations: attribute_locations, location: location}) do
    Map.get(attribute_locations, :id, location)
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
end
