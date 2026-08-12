defmodule Statifier.Validator.Checks.Content do
  @moduledoc """
  Spec 5.6: a `<content>` element must not specify both an `expr`
  attribute and inline text. Reports `{:content_expr_and_text, expr}` at the
  `<content>` element's own `location`.

  `lib/statifier/document/content.ex` makes both fields nilable and both
  representable at once precisely so this check can report the shape rather
  than lowering refusing to build it - the same division of labour check 8
  has with `<donedata>`.

  **Whitespace-only text is not text.** `Statifier.Parser.DOM.text/1`
  concatenates `<content>`'s direct text children verbatim and untrimmed, so
  a pretty-printed `<content expr="x">\\n  </content>` carries a `text` of
  `"\\n  "`. That is source formatting, not a payload, and firing on it
  would reject documents the spec allows.

  The only `%Statifier.Document.Content{}` a document can hold today is a
  `<final>`'s `<donedata><content>` (`Statifier.Document.Donedata`), so that
  is the one place this check walks. When `<send>` gains a
  `<content>` child, this walk grows an arm; the rule itself is unchanged,
  since spec 5.6 states it on `<content>` rather than on either parent.

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
  Walks every `<final>`'s `<donedata><content>` in the document and returns a
  `:content_expr_and_text` error for each one that carries both an `expr`
  attribute and non-blank inline text. Returns `[]` when no `<content>`
  element mixes the two forms.
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

  defp contents(%State{donedata: %Donedata{content: %Content{} = content}}), do: [content]
  defp contents(%State{}), do: []

  defp check_content(%Content{expr: nil}), do: []

  defp check_content(%Content{expr: expr, text: text, location: location}) do
    if blank?(text) do
      []
    else
      [Error.content_expr_and_text(expr, location)]
    end
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
end
