defmodule Statifier.Validator.Checks.Assign do
  @moduledoc """
  Spec 5.4.2: "A conformant SCXML document MUST specify either 'expr' or
  children of `<assign>`, but not both." Reports `{:assign_expr_and_text,
  expr}` at the `<assign>`'s own element span.

  `lib/statifier/document/assign.ex` makes both `expr` and `text`
  representable at once precisely so this check can report the shape rather
  than lowering refusing to build it - the same division of labour
  `Checks.Content` has with `<content>` and `Checks.Data` has with `<data>`.

  **Whitespace-only text is not text.** `Statifier.Parser.DOM.text/1`
  concatenates `<assign>`'s direct text children verbatim and untrimmed, so
  a pretty-printed `<assign expr="1">\\n  </assign>` carries a `text` of
  `"\\n  "`. That is source formatting, not a payload, and firing on it
  would reject documents the spec allows - the same rule
  `Checks.Content.blank?/1` and `Checks.Data.blank?/1` already follow.

  This check walks every state's own `onentry`/`onexit` blocks, every
  state's own transitions (both plain and a `:history` state's default -
  `Statifier.Document.State.transitions` covers both), and every state's
  `<initial>` element's own transition - the three places
  `Statifier.Document.Assign` can appear as executable content
  (`Statifier.Document.Block.t()`'s and `Statifier.Document.Transition.t()`'s
  own `content` fields).
  """

  alias Statifier.Document
  alias Statifier.Document.Assign, as: DAssign
  alias Statifier.Document.Initial
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @doc """
  Walks every `<assign>` reachable through a state's `onentry`/`onexit`
  blocks or its own (and its `<initial>` element's) transitions, and returns
  an `:assign_expr_and_text` error for each one that carries both an `expr`
  attribute and non-blank child text. Returns `[]` when no `<assign>` in the
  document mixes the two forms.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.flat_map(&assigns/1)
    |> Enum.flat_map(&check_assign/1)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp assigns(%State{} = state) do
    block_assigns(state.onentry) ++
      block_assigns(state.onexit) ++
      transition_assigns(state.transitions) ++
      initial_assigns(state.initial_element)
  end

  defp block_assigns(blocks) do
    blocks
    |> Enum.flat_map(& &1.content)
    |> Enum.filter(&match?(%DAssign{}, &1))
  end

  defp transition_assigns(transitions) do
    transitions
    |> Enum.flat_map(& &1.content)
    |> Enum.filter(&match?(%DAssign{}, &1))
  end

  defp initial_assigns(nil), do: []
  defp initial_assigns(%Initial{transitions: transitions}), do: transition_assigns(transitions)

  defp check_assign(%DAssign{expr: nil}), do: []

  defp check_assign(%DAssign{expr: expr, text: text, node_location: node_location}) do
    if blank?(text) do
      []
    else
      [Error.assign_expr_and_text(expr, node_location)]
    end
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
end
