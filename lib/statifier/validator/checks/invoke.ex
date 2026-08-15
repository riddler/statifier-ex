defmodule Statifier.Validator.Checks.Invoke do
  @moduledoc """
  Spec 6.4.1's five mutual-exclusion constraints on `<invoke>`'s attributes
  and children, each reported at the `<invoke>` element's own `location`:

  - `{:invoke_type_and_typeexpr}` - "type: Must not occur with the
    'typeexpr' attribute."
  - `{:invoke_src_and_srcexpr}` - "src: Must not occur with the 'srcexpr'
    attribute or the `<content>` element."
  - `{:invoke_src_and_content}` - the other half of that same constraint:
    `src` or `srcexpr` alongside a `<content>` child.
  - `{:invoke_id_and_idlocation}` - "id: Must not occur with the
    'idlocation' attribute."
  - `{:invoke_namelist_and_param}` - "namelist: Must not occur with the
    `<param>` element."

  `lib/statifier/document/invoke.ex` makes every one of these pairs
  simultaneously representable precisely so this check can report the shape
  rather than lowering refusing to build it - the same division of labour
  `Checks.Donedata`, `Checks.Content`, and `Checks.Param` already have for
  their own mutually exclusive pairs. Collect-all: an `<invoke>` that trips
  more than one of the five reports every one it trips, not just the first.
  """

  alias Statifier.Document
  alias Statifier.Document.Invoke, as: DInvoke
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @doc """
  Walks every `<invoke>` in the document and returns one error per 6.4.1
  constraint it violates. Returns `[]` when every `<invoke>` in the document
  satisfies all five.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.flat_map(& &1.invoke)
    |> Enum.flat_map(&check_invoke/1)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp check_invoke(%DInvoke{location: location} = invoke) do
    type_and_typeexpr(invoke, location) ++
      src_and_srcexpr(invoke, location) ++
      src_and_content(invoke, location) ++
      id_and_idlocation(invoke, location) ++
      namelist_and_param(invoke, location)
  end

  defp type_and_typeexpr(%DInvoke{type: type, typeexpr: typeexpr}, location)
       when not is_nil(type) and not is_nil(typeexpr) do
    [Error.invoke_type_and_typeexpr(location)]
  end

  defp type_and_typeexpr(%DInvoke{}, _location), do: []

  defp src_and_srcexpr(%DInvoke{src: src, srcexpr: srcexpr}, location)
       when not is_nil(src) and not is_nil(srcexpr) do
    [Error.invoke_src_and_srcexpr(location)]
  end

  defp src_and_srcexpr(%DInvoke{}, _location), do: []

  defp src_and_content(%DInvoke{src: src, srcexpr: srcexpr, content: content}, location)
       when not is_nil(content) and (not is_nil(src) or not is_nil(srcexpr)) do
    [Error.invoke_src_and_content(location)]
  end

  defp src_and_content(%DInvoke{}, _location), do: []

  defp id_and_idlocation(%DInvoke{id: id, idlocation: idlocation}, location)
       when not is_nil(id) and not is_nil(idlocation) do
    [Error.invoke_id_and_idlocation(location)]
  end

  defp id_and_idlocation(%DInvoke{}, _location), do: []

  defp namelist_and_param(%DInvoke{namelist: namelist, params: params}, location)
       when namelist != [] and params != [] do
    [Error.invoke_namelist_and_param(location)]
  end

  defp namelist_and_param(%DInvoke{}, _location), do: []
end
