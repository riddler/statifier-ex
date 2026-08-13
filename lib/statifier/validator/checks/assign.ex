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
  alias Statifier.Document.If, as: DIf
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
    |> Enum.flat_map(&descend/1)
    |> Enum.filter(&match?(%DAssign{}, &1))
  end

  defp transition_assigns(transitions) do
    transitions
    |> Enum.flat_map(& &1.content)
    |> Enum.flat_map(&descend/1)
    |> Enum.filter(&match?(%DAssign{}, &1))
  end

  # A content node walk stops at the top level unless it descends into every
  # *composite* node's own partitions - a `%DIf{}` does not carry an
  # `<assign>` itself, it carries branches that carry one. Without this, an
  # `<assign>` written inside an `<if>` partition is invisible to any check
  # that only sees the block/transition's own flat `content` list, exactly
  # the gap `Statifier.Validator.Checks.If`'s moduledoc calls out for this
  # walk specifically. Recurses so a `<assign>` nested inside a *nested*
  # `<if>` (SCION's `if_else/test0`) is not missed either. `<foreach>` will
  # be the next composite executable-content element; when it lands, it gets
  # a clause here alongside `%DIf{}` rather than a second walk elsewhere.
  #
  # Only two checks need this at all, and the boundary is worth stating so
  # the next composite element does not re-run the audit from scratch: this
  # one and `Statifier.Validator.Checks.If` are the only checks that walk
  # executable-content *nodes*. The other checks that reach a state's
  # transitions - `Checks.InitialElement`, `Checks.InitialTargets`,
  # `Checks.Targets`, `Checks.Final`, `Checks.DefaultTransition` and
  # `Checks.History` - read transitions as *structures* (targets,
  # cardinality, ordering) and never touch their `content` lists, so no
  # amount of nesting inside a partition can hide anything from them.
  defp descend(%DIf{branches: branches}) do
    branches |> Enum.flat_map(& &1.content) |> Enum.flat_map(&descend/1)
  end

  defp descend(other), do: [other]

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
