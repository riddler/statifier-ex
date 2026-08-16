defmodule Statifier.Validator.Checks.Content do
  @moduledoc """
  Spec 5.6: a `<content>` element must not specify both an `expr`
  attribute and inline content, whether that content is text or markup
  (ADR-0041). Reports `{:content_expr_and_text, expr}` at the `<content>`
  element's own `location` - same reason, same shape, regardless of which
  form the content takes.

  `lib/statifier/document/content.ex` makes `expr`, `text`, and `markup` all
  nilable and all representable at once precisely so this check can report
  the shape rather than lowering refusing to build it - the same division of
  labour check 8 has with `<donedata>`.

  **Whitespace-only text is not text.** `Statifier.Parser.DOM.text/1`
  concatenates `<content>`'s direct text children verbatim and untrimmed, so
  a pretty-printed `<content expr="x">\\n  </content>` carries a `text` of
  `"\\n  "`. That is source formatting, not a payload, and firing on it
  would reject documents the spec allows. `markup`, when present, is never
  blank - it is nil unless `<content>` has at least one element child - so
  no equivalent whitespace carve-out applies to it.

  Two places today hold a `%Statifier.Document.Content{}`: a `<final>`'s
  `<donedata><content>` (`Statifier.Document.Donedata`) and any state's
  `<invoke><content>` (`Statifier.Document.Invoke`), so this check walks
  both. `<send>` has a `<content>` child too
  (`lib/statifier/document/send.ex:54`, `lib/statifier/compiler.ex:1113`),
  but it is executable content living inside a block's `content` list
  (`lib/statifier/document/send.ex:27-30`), not a state field this walk
  already reaches - reaching it needs a block walk this check does not have.
  That gap predates this change and stays open here; the rule itself is
  unchanged regardless, since spec 5.6 states it on `<content>` rather than
  on whichever parent holds it.

  The `Content` alias below is `Statifier.Document.Content`, the document
  node - not this module.
  """

  alias Statifier.Document
  alias Statifier.Document.Content
  alias Statifier.Document.Donedata
  alias Statifier.Document.State
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  @doc """
  Walks every `<final>`'s `<donedata><content>` and every state's
  `<invoke><content>` in the document and returns a `:content_expr_and_text`
  error for each one that carries both an `expr` attribute and non-blank
  inline text. Returns `[]` when no `<content>` element mixes the two forms.
  """
  @spec check(document :: Document.t(), context :: Context.t()) :: [Error.t()]
  def check(%Document{states: states}, %Context{}) do
    states
    |> flatten()
    |> Enum.flat_map(&contents/1)
    |> Enum.flat_map(&check_content/1)
  end

  defp flatten(states) do
    Enum.flat_map(states, fn state -> [state | flatten(state.states)] end)
  end

  defp contents(%State{donedata: donedata, invoke: invokes}) do
    donedata_content(donedata) ++ invoke_content(invokes)
  end

  defp donedata_content(%Donedata{content: %Content{} = content}), do: [content]
  defp donedata_content(_donedata), do: []

  defp invoke_content(invokes) do
    invokes
    |> Enum.map(& &1.content)
    |> Enum.filter(&match?(%Content{}, &1))
  end

  defp check_content(%Content{expr: nil}), do: []

  defp check_content(%Content{expr: expr, text: text, markup: markup, location: location}) do
    cond do
      not is_nil(markup) -> [Error.content_expr_and_text(expr, location, :markup)]
      not blank?(text) -> [Error.content_expr_and_text(expr, location, :text)]
      true -> []
    end
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
end
