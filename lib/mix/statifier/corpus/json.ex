defmodule Mix.Statifier.Corpus.Json do
  @moduledoc """
  The corpus emitter's JSON encoding, fixed so that two emits of one tree are
  byte-identical and a regeneration diff is readable.

  An object's keys are written in one fixed order - the order the schemas
  under `conformance/schema/` list them in, for every object the corpus files
  hold - and a key outside that order after them, sorted. `pretty/1` indents
  by two spaces with one array item per line; `compact/1` writes no
  whitespace at all. `corpus_file/2` combines the two: the file is pretty and
  each case is one compact line, so a changed case is a one-line diff.
  Strings are encoded by Elixir's `JSON`.
  """

  # Every key of every object the corpus files hold, in writing order. A case
  # is id, suite, spec, conformance, description, required_features, source,
  # initial_configuration, steps, upstream, host; a registry is
  # implementation, corpus_hash, claims, entries, and an entry case_id,
  # suite; each other object's keys appear here in its schema's order too.
  @key_order ~w(implementation id case_id corpus_hash claims entries suite file
                case_count name url revision key reason detail adr spec conformance description
                required_features source initial_configuration steps event data
                configuration upstream document license notice modified host send_types
                expect_sends cases suites upstreams exclusions)

  @rank @key_order |> Enum.with_index() |> Map.new()

  @doc """
  Encodes `value` with no whitespace.

  ## Examples

      iex> Mix.Statifier.Corpus.Json.compact(%{"suite" => "w3c", "id" => "w3c/test1", "steps" => []})
      ~s|{"id":"w3c/test1","suite":"w3c","steps":[]}|

  """
  @spec compact(value :: term()) :: String.t()
  def compact(map) when is_map(map) do
    body =
      map
      |> ordered()
      |> Enum.map_join(",", fn {k, v} -> JSON.encode!(k) <> ":" <> compact(v) end)

    "{" <> body <> "}"
  end

  def compact(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &compact/1) <> "]"
  def compact(scalar), do: JSON.encode!(scalar)

  @doc """
  Encodes `value` with two-space indentation and a trailing newline.

  ## Examples

      iex> Mix.Statifier.Corpus.Json.pretty(%{"b" => [1], "a" => %{}})
      ~s|{\\n  "a": {},\\n  "b": [\\n    1\\n  ]\\n}\\n|

  """
  @spec pretty(value :: term()) :: String.t()
  def pretty(value), do: pretty(value, "") <> "\n"

  @doc """
  Encodes a corpus file: the suite, then the cases, one compact case per line.
  """
  @spec corpus_file(suite :: String.t(), cases :: [map()]) :: String.t()
  def corpus_file(suite, cases) do
    lines = Enum.map_join(cases, ",\n", &("    " <> compact(&1)))
    "{\n  \"suite\": #{JSON.encode!(suite)},\n  \"cases\": [\n#{lines}\n  ]\n}\n"
  end

  defp pretty(map, indent) when is_map(map) and map_size(map) > 0 do
    inner = indent <> "  "

    body =
      map
      |> ordered()
      |> Enum.map_join(",\n", fn {k, v} ->
        inner <> JSON.encode!(k) <> ": " <> pretty(v, inner)
      end)

    "{\n" <> body <> "\n" <> indent <> "}"
  end

  defp pretty(list, indent) when is_list(list) and list != [] do
    inner = indent <> "  "
    "[\n" <> Enum.map_join(list, ",\n", &(inner <> pretty(&1, inner))) <> "\n" <> indent <> "]"
  end

  defp pretty(value, _indent), do: compact(value)

  defp ordered(map) do
    Enum.sort_by(map, fn {key, _value} -> {Map.get(@rank, key, length(@key_order)), key} end)
  end
end
