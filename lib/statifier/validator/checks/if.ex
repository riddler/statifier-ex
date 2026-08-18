defmodule Statifier.Validator.Checks.If do
  @moduledoc """
  Spec 4.3.2: "In a conformant SCXML document, `<else>` MUST occur after all
  `<elseif>` tags." `Statifier.Lowering.Builders.build_if/2` has already
  partitioned an `<if>`'s children into `branches` by the time a
  `%Statifier.Document.If{}` reaches the validator, so this check reads
  branch order directly rather than re-parsing `<elseif>`/`<else>` element
  names.

  A branch's `cond` is `nil` only for the `<else>` branch. `cond` is
  required on both `<if>` (4.3.1) and `<elseif>` (4.4.1), and
  `Statifier.Lowering.Builders.build_if/2` and `build_elseif/2` report
  `missing_attribute` and build no node at all when it is absent, so a
  cond-less non-`<else>` branch never reaches the validator. This check
  still keys off `cond: nil` rather than an explicit "is an `<else>`" flag,
  because that is the shape `Statifier.Document.If.Branch` actually carries;
  it just does not have a second case to distinguish. Once the first
  `nil`-cond branch in document order is seen, every branch after it is
  illegal:

  - another `nil`-cond branch is a second `<else>`, reported
    `{:if_duplicate_else}` at *that* branch's own `location`
  - a `cond`-carrying branch is an `<elseif>` after an `<else>`, reported
    `{:if_elseif_after_else}` at *that* branch's own `location`

  Classifying by the *offending* branch's own shape (rather than, say,
  flagging the first `nil`-cond branch for "not being last") is what keeps
  the two-`<else>`s case reporting exactly once, at the second `<else>`,
  instead of also flagging the first as "not last".

  This check walks every state's own `onentry`/`onexit` blocks, every
  state's own transitions (both plain and a `:history` state's default),
  and every state's `<initial>` element's own transition - the same three
  places `Statifier.Validator.Checks.Assign` walks - and recurses into every
  `<if>` nested inside another `<if>`'s branch content (SCION's
  `if_else/test0` nests two deep), since spec 4.3.2 explicitly allows
  nested `<if>` as executable content. It recurses into a `<foreach>`'s own
  content the same way, so an `<if>` written inside a loop body (`test153`)
  is not invisible to this check either.
  """

  alias Statifier.Document
  alias Statifier.Document.Foreach, as: DForeach
  alias Statifier.Document.If, as: DIf
  alias Statifier.Document.If.Branch
  alias Statifier.Document.{Initial, State}
  alias Statifier.Validator.{Context, Error}

  @doc """
  Walks every `<if>` reachable through a state's `onentry`/`onexit` blocks or
  its own (and its `<initial>` element's) transitions, recursing into nested
  `<if>`s, and returns an `:if_elseif_after_else` or `:if_duplicate_else`
  error for each branch that follows the first `nil`-cond branch of its own
  `<if>`. Returns `[]` when every `<if>` in the document keeps its `<else>`
  (if any) last and singular.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.flat_map(&ifs/1)
    |> Enum.flat_map(&check_if/1)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp ifs(%State{} = state) do
    block_ifs(state.onentry) ++
      block_ifs(state.onexit) ++
      transition_ifs(state.transitions) ++
      initial_ifs(state.initial_element)
  end

  defp block_ifs(blocks) do
    blocks
    |> Enum.flat_map(& &1.content)
    |> Enum.flat_map(&collect_ifs/1)
  end

  defp transition_ifs(transitions) do
    transitions
    |> Enum.flat_map(& &1.content)
    |> Enum.flat_map(&collect_ifs/1)
  end

  defp initial_ifs(nil), do: []
  defp initial_ifs(%Initial{transitions: transitions}), do: transition_ifs(transitions)

  # Every `%DIf{}` reachable from a content node: itself, plus every `%DIf{}`
  # nested inside its own branches' content, recursively.
  defp collect_ifs(%DIf{branches: branches} = if_node) do
    nested = branches |> Enum.flat_map(& &1.content) |> Enum.flat_map(&collect_ifs/1)
    [if_node | nested]
  end

  defp collect_ifs(%DForeach{content: content}), do: Enum.flat_map(content, &collect_ifs/1)

  defp collect_ifs(_other), do: []

  # Folds each `<if>`'s own branches in document order, flagging every
  # branch that comes after the first `nil`-cond branch already seen.
  defp check_if(%DIf{branches: branches}) do
    {errors, _seen_nil_cond?} =
      Enum.reduce(branches, {[], false}, fn branch, {errors, seen_nil_cond?} ->
        classify_branch(branch, seen_nil_cond?, errors)
      end)

    Enum.reverse(errors)
  end

  defp classify_branch(%Branch{cond: nil} = branch, true, errors),
    do: {[Error.if_duplicate_else(branch.location) | errors], true}

  defp classify_branch(%Branch{} = branch, true, errors),
    do: {[Error.if_elseif_after_else(branch.location) | errors], true}

  defp classify_branch(%Branch{cond: nil}, false, errors), do: {errors, true}
  defp classify_branch(%Branch{}, false, errors), do: {errors, false}
end
