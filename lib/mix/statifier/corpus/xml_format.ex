defmodule Mix.Statifier.Corpus.XmlFormat do
  @moduledoc """
  Re-serializes a transformed W3C `.scxml` document the way the committed W3C
  test modules hold it: an XML declaration, four-space indentation, comments
  and processing instructions dropped, whitespace-only text dropped, and the
  `xmlns:conf` declaration the predicator transform leaves behind removed.

  This is the corpus emitter's port of the formatter in
  `tools/corpus/scxml_w3/cases.exs`, parsed with Saxy (a runtime dependency
  already) instead of xmerl, which Mix prunes from a project's code path. The
  output is held to that formatter's by a test comparing every committed W3C
  case's source with the document its generated module holds.
  """

  @indent "    "
  @dropped_attrs ["xmlns:conf"]

  @doc """
  Formats `xml`, returning the formatted document and the root element's
  `datamodel` attribute (`nil` when absent), or the parser's refusal as a
  sentence.

  ## Examples

      iex> Mix.Statifier.Corpus.XmlFormat.format(~s|<scxml datamodel="predicator"><!-- c --><state id="a">\\n</state></scxml>|)
      {:ok, {~s|<?xml version="1.0" encoding="UTF-8"?>\\n<scxml datamodel="predicator">\\n    <state id="a" />\\n</scxml>\\n|, "predicator"}}

  """
  @spec format(xml :: String.t()) :: {:ok, {String.t(), String.t() | nil}} | {:error, String.t()}
  def format(xml) do
    case Saxy.SimpleForm.parse_string(xml, cdata_as_characters: true) do
      {:ok, {_name, attrs, _content} = root} ->
        formatted = ~s|<?xml version="1.0" encoding="UTF-8"?>\n| <> render(root, 0) <> "\n"
        {:ok, {formatted, attribute(attrs, "datamodel")}}

      {:error, error} ->
        {:error, "the document does not parse: #{Exception.message(error)}"}
    end
  end

  defp attribute(attrs, name) do
    Enum.find_value(attrs, fn {key, value} -> if key == name, do: value end)
  end

  defp render({tag, attrs, content}, depth) do
    indent = String.duplicate(@indent, depth)
    attr_str = render_attrs(attrs)
    {texts, elements} = content |> significant() |> Enum.split_with(&is_binary/1)

    cond do
      texts == [] and elements == [] ->
        "#{indent}<#{tag}#{attr_str} />"

      elements == [] ->
        text = texts |> Enum.join("") |> String.trim() |> escape_text()
        "#{indent}<#{tag}#{attr_str}>#{text}</#{tag}>"

      true ->
        inner = Enum.map_join(elements, "\n", &render(&1, depth + 1))
        "#{indent}<#{tag}#{attr_str}>\n#{inner}\n#{indent}</#{tag}>"
    end
  end

  defp render_attrs(attrs) do
    attrs
    |> Enum.reject(fn {name, _value} -> name in @dropped_attrs end)
    |> Enum.map_join("", fn {name, value} -> " #{name}=\"#{escape_attr(value)}\"" end)
  end

  defp significant(content) do
    Enum.filter(content, fn
      text when is_binary(text) -> String.trim(text) != ""
      {_tag, _attrs, _content} -> true
    end)
  end

  defp escape_attr(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_text(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
  end
end
