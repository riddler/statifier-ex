defmodule Statifier.Validator.Checks.Cancel do
  @moduledoc """
  Spec 6.3.1's single constraint on `<cancel>`: "A conformant SCXML document
  MUST specify exactly one of sendid or sendidexpr." Reports
  `{:cancel_sendid_and_sendidexpr}` when both are present and
  `{:cancel_no_sendid}` when neither is, both at the `<cancel>` element's
  own `location`.

  `lib/statifier/document/cancel.ex` makes both `sendid` and `sendidexpr`
  simultaneously representable, and both absent representable too,
  precisely so this check can report the shape rather than lowering
  refusing to build it - the same division of labour `Checks.Send` has for
  its own mutually exclusive pairs. `<cancel>` gets its own file per the
  house pattern (`Checks.Invoke`, `Checks.Assign`, `Checks.Param`): one
  constraint is enough to justify one file at this repo's granularity.

  The walk reaches every block a `<cancel>` can appear in: a state's
  `onentry`/`onexit`, its own (and its `<initial>` element's) transitions,
  `<if>`/`<foreach>` bodies nested in any of those, and every `<invoke>`'s
  `<finalize>` block - the same reach `Checks.Send` needs, since both
  elements are executable content that can occur wherever the other can.
  """

  alias Statifier.Document
  alias Statifier.Document.{Block, Initial, State}
  alias Statifier.Document.Cancel, as: DCancel
  alias Statifier.Document.Foreach, as: DForeach
  alias Statifier.Document.If, as: DIf
  alias Statifier.Validator.{Context, Error}

  @doc """
  Walks every `<cancel>` in the document and returns a
  `:cancel_sendid_and_sendidexpr` or `:cancel_no_sendid` error for each one
  whose `sendid`/`sendidexpr` attributes violate 6.3.1's exactly-one rule.
  Returns `[]` when every `<cancel>` in the document specifies exactly one.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.flat_map(&cancels_of/1)
    |> Enum.flat_map(&check_cancel/1)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp cancels_of(%State{} = state) do
    block_cancels(state.onentry) ++
      block_cancels(state.onexit) ++
      transition_cancels(state.transitions) ++
      initial_cancels(state.initial_element) ++
      invoke_finalize_cancels(state.invoke)
  end

  defp block_cancels(blocks) do
    blocks
    |> Enum.flat_map(& &1.content)
    |> Enum.flat_map(&descend/1)
    |> Enum.filter(&match?(%DCancel{}, &1))
  end

  defp transition_cancels(transitions) do
    transitions
    |> Enum.flat_map(& &1.content)
    |> Enum.flat_map(&descend/1)
    |> Enum.filter(&match?(%DCancel{}, &1))
  end

  # Mirrors `Checks.Send.descend/1`: a `%DIf{}`/`%DForeach{}` carries no
  # `<cancel>` itself, only branches/content that might, so the walk must
  # descend into both to reach a nested one.
  defp descend(%DIf{branches: branches}) do
    branches |> Enum.flat_map(& &1.content) |> Enum.flat_map(&descend/1)
  end

  defp descend(%DForeach{content: content}), do: Enum.flat_map(content, &descend/1)

  defp descend(other), do: [other]

  defp initial_cancels(nil), do: []
  defp initial_cancels(%Initial{transitions: transitions}), do: transition_cancels(transitions)

  defp invoke_finalize_cancels(invokes) do
    invokes
    |> Enum.map(& &1.finalize)
    |> Enum.flat_map(&finalize_cancels/1)
  end

  defp finalize_cancels(nil), do: []

  defp finalize_cancels(%Block{content: content}) do
    content
    |> Enum.flat_map(&descend/1)
    |> Enum.filter(&match?(%DCancel{}, &1))
  end

  defp check_cancel(%DCancel{sendid: nil, sendidexpr: nil, location: location}) do
    [Error.cancel_no_sendid(location)]
  end

  defp check_cancel(%DCancel{sendid: sendid, sendidexpr: sendidexpr, location: location})
       when not is_nil(sendid) and not is_nil(sendidexpr) do
    [Error.cancel_sendid_and_sendidexpr(location)]
  end

  defp check_cancel(%DCancel{}), do: []
end
