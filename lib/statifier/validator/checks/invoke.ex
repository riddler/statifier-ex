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

  ## The 6.5.2 warning: forbidden content inside `<finalize>`

  `warn/2` walks each `<invoke>`'s `finalize` block and reports spec 6.5.2's
  rule: "the executable content inside `<finalize>` MUST NOT raise events or
  invoke external actions. In particular, the `<send>` and `<raise>`
  elements MUST NOT occur." The forbidden set is `%Document.Raise{}` and
  `%Document.Send{}` - both are lowered, executable content nodes with a
  defined engine behavior (each executes like any other executable content
  inside `<finalize>`), so a document that writes one there is told about
  the violation rather than refused. `Statifier.Validator.Checks.Send`
  enforces 6.2.2/6.2.3's own attribute constraints on the same `<send>`
  independently of this warning - the two checks are not mutually
  exclusive, and a `<send>` inside `<finalize>` can trip both at once. This
  is a warning, not an error: `forbidden/1` carries the offending element's
  own name as data (`"raise"` or `"send"`) rather than one reason tag per
  element, per ADR-0033's consequences.
  """

  alias Statifier.Document
  alias Statifier.Document.Block
  alias Statifier.Document.Foreach, as: DForeach
  alias Statifier.Document.If, as: DIf
  alias Statifier.Document.Invoke, as: DInvoke
  alias Statifier.Document.Raise, as: DRaise
  alias Statifier.Document.Send, as: DSend
  alias Statifier.Validator.{Context, Error, Warning}

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

  defp type_and_typeexpr(%DInvoke{type: nil}, _location), do: []
  defp type_and_typeexpr(%DInvoke{typeexpr: nil}, _location), do: []

  defp type_and_typeexpr(%DInvoke{}, location),
    do: [Error.invoke_type_and_typeexpr(location)]

  defp src_and_srcexpr(%DInvoke{src: nil}, _location), do: []
  defp src_and_srcexpr(%DInvoke{srcexpr: nil}, _location), do: []

  defp src_and_srcexpr(%DInvoke{}, location),
    do: [Error.invoke_src_and_srcexpr(location)]

  defp src_and_content(%DInvoke{content: nil}, _location), do: []
  defp src_and_content(%DInvoke{src: nil, srcexpr: nil}, _location), do: []

  defp src_and_content(%DInvoke{}, location),
    do: [Error.invoke_src_and_content(location)]

  defp id_and_idlocation(%DInvoke{id: nil}, _location), do: []
  defp id_and_idlocation(%DInvoke{idlocation: nil}, _location), do: []

  defp id_and_idlocation(%DInvoke{}, location),
    do: [Error.invoke_id_and_idlocation(location)]

  defp namelist_and_param(%DInvoke{namelist: namelist, params: params}, location)
       when namelist != [] and params != [] do
    [Error.invoke_namelist_and_param(location)]
  end

  defp namelist_and_param(%DInvoke{}, _location), do: []

  @doc """
  Walks every `<invoke>`'s `finalize` block and returns one warning per
  6.5.2 forbidden node found, at that node's own location. Returns `[]`
  when no `<invoke>` in the document carries forbidden content inside
  `<finalize>` - including when `finalize` is `nil` (no `<finalize>` child)
  or `%Block{content: []}` (a written but childless one).
  """
  @spec warn(document :: Document.t(), context :: Context.t()) :: [Warning.t()]
  def warn(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.flat_map(& &1.invoke)
    |> Enum.flat_map(&warn_finalize/1)
  end

  defp warn_finalize(%DInvoke{finalize: nil}), do: []

  defp warn_finalize(%DInvoke{finalize: %Block{content: content}}) do
    content
    |> Enum.flat_map(&descend/1)
    |> Enum.flat_map(&forbidden/1)
  end

  # Mirrors `Checks.Script.descend/1`: a `%DIf{}`/`%DForeach{}` carries no
  # forbidden content itself, only branches/content that might, so the walk
  # must descend into both to reach a nested one.
  defp descend(%DIf{branches: branches}) do
    branches |> Enum.flat_map(& &1.content) |> Enum.flat_map(&descend/1)
  end

  defp descend(%DForeach{content: content}), do: Enum.flat_map(content, &descend/1)

  defp descend(other), do: [other]

  defp forbidden(%DRaise{location: location}),
    do: [Warning.finalize_forbidden_content("raise", location)]

  defp forbidden(%DSend{location: location}),
    do: [Warning.finalize_forbidden_content("send", location)]

  defp forbidden(_other), do: []
end
