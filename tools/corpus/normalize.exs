defmodule Cases.Normalize do
  @moduledoc """
  Upstream spec/name path segments are not Elixir-idiomatic - concatenated
  camelCase and acronyms (`actionSend`, `SCXMLEventProcessor`), a couple of
  concatenated lowercase words with no case boundary to split on
  (`onentry`), and non-identifier separators (`more-parallel`,
  `hierarchy+documentOrder`). `identifier/1` normalizes a single path segment
  to snake_case; camelizing that result gives the matching Elixir module
  segment, so module names derive cleanly from generated file paths. Shared
  by tools/corpus/scion/cases.exs and tools/corpus/scxml_w3/cases.exs so the
  two generators can't drift.
  """

  # Upstream segments with no case boundary for Macro.underscore/1 to split
  # on. Add an entry here only when a new upstream name needs it - everything
  # else splits algorithmically.
  @word_splits %{
    "onentry" => "on_entry",
    "onexit" => "on_exit"
  }

  @spec identifier(String.t()) :: String.t()
  def identifier(segment) do
    segment
    |> String.replace(~r/[^a-zA-Z0-9]+/, "_")
    |> then(&Map.get(@word_splits, &1, &1))
    |> Macro.underscore()
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end
end
