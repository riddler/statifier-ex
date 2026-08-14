defmodule Mix.Statifier.RegressionRegistry do
  @moduledoc """
  Reads and writes `test/passing_tests.json`, the regression ratchet registry.

  The registry names the tests that must always pass. It has three lists, one
  per suite, and entries may be literal paths or globs:

      {
        "description": "...",
        "internal_tests": ["test/statifier/**/*_test.exs"],
        "last_updated": "2026-08-02",
        "scion_tests": [],
        "w3c_tests": []
      }

  `mix test.regression` runs exactly what this file expands to; `mix
  test.baseline` is the only supported way to grow it. This module holds the
  pure part of both tasks - load, expand, categorize, add, encode - so the
  tasks themselves stay thin wrappers around `System.cmd/3`.

  Encoding is deliberately hand-rolled rather than delegated to a JSON pretty
  printer: keys are sorted and arrays are one entry per line, so ratcheting a
  test in produces a one-line diff.
  """

  @default_path "test/passing_tests.json"

  @keys %{internal: "internal_tests", scion: "scion_tests", w3c: "w3c_tests"}
  @categories [:internal, :scion, :w3c]

  @suite_dirs %{scion: "test/scion_tests", w3c: "test/scxml_tests"}
  @suite_tags %{scion: "scion", w3c: "scxml_w3"}
  @suite_labels %{scion: "SCION", w3c: "W3C"}

  @type category :: :internal | :scion | :w3c
  @type t :: %{String.t() => term()}
  @type stats :: %{passing: non_neg_integer(), total: non_neg_integer(), percent: float() | nil}

  @doc "Path of the registry file, relative to the project root."
  @spec default_path() :: String.t()
  def default_path, do: @default_path

  @doc "The conformance suites, the only categories the ratchet grows by hand."
  @spec conformance_categories() :: [category()]
  def conformance_categories, do: @categories -- [:internal]

  @doc """
  The registry key holding `category`.

  ## Examples

      iex> Mix.Statifier.RegressionRegistry.key(:scion)
      "scion_tests"

  """
  @spec key(category :: category()) :: String.t()
  def key(category), do: Map.fetch!(@keys, category)

  @doc """
  Directory holding the corpus for a conformance `category`.

  ## Examples

      iex> Mix.Statifier.RegressionRegistry.suite_dir(:w3c)
      "test/scxml_tests"

  """
  @spec suite_dir(category :: category()) :: String.t() | nil
  def suite_dir(category), do: Map.get(@suite_dirs, category)

  @doc """
  Loads the registry from `path`.

  Returns `{:error, reason}` rather than raising: both tasks report the reason
  and exit non-zero, and a malformed registry must never be mistaken for an
  empty one.
  """
  @spec load(path :: String.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path \\ @default_path) do
    with {:ok, content} <- read(path) do
      decode(content, path)
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(content, path) do
    case JSON.decode(content) do
      {:ok, registry} when is_map(registry) -> {:ok, registry}
      {:ok, _other} -> {:error, "#{path} does not contain a JSON object"}
      {:error, reason} -> {:error, "invalid JSON in #{path}: #{inspect(reason)}"}
    end
  end

  @doc "Writes `registry` back to `path`, pretty-printed."
  @spec save(registry :: t(), path :: String.t()) :: :ok | {:error, String.t()}
  def save(registry, path) do
    case File.write(path, encode(registry)) do
      :ok -> :ok
      {:error, reason} -> {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc """
  Encodes `registry` as JSON with sorted keys, two-space indent, and one array
  entry per line, so that ratcheting in a test is a minimal diff.

  ## Examples

      iex> Mix.Statifier.RegressionRegistry.encode(%{"scion_tests" => ["a.exs"], "n" => 1})
      ~s|{\\n  "n": 1,\\n  "scion_tests": [\\n    "a.exs"\\n  ]\\n}\\n|

  """
  @spec encode(registry :: t()) :: String.t()
  def encode(registry), do: encode_value(registry, "") <> "\n"

  defp encode_value(map, indent) when is_map(map) and map_size(map) > 0 do
    inner = indent <> "  "

    body =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",\n", fn {key, value} ->
        inner <> JSON.encode!(to_string(key)) <> ": " <> encode_value(value, inner)
      end)

    "{\n" <> body <> "\n" <> indent <> "}"
  end

  defp encode_value(list, indent) when is_list(list) and list != [] do
    inner = indent <> "  "
    body = Enum.map_join(list, ",\n", &(inner <> encode_value(&1, inner)))

    "[\n" <> body <> "\n" <> indent <> "]"
  end

  defp encode_value(scalar, _indent), do: JSON.encode!(scalar)

  @doc """
  Expands the patterns held under `category` into test files.

  Returns `{files, missing}`, where `missing` lists entries that matched
  nothing on disk. A registry entry that no longer exists is a hole in the
  ratchet, so callers report it rather than skipping it.
  """
  @spec expand(registry :: t(), category :: category()) :: {[String.t()], [String.t()]}
  def expand(registry, category) do
    registry
    |> Map.get(key(category), [])
    |> expand_patterns()
  end

  @doc """
  Expands a list of literal paths and globs into existing test files.

  Returns `{sorted_unique_files, patterns_that_matched_nothing}`.

  ## Examples

      iex> Mix.Statifier.RegressionRegistry.expand_patterns(["test/no_such_test.exs"])
      {[], ["test/no_such_test.exs"]}

  """
  @spec expand_patterns(patterns :: [String.t()]) :: {[String.t()], [String.t()]}
  def expand_patterns(patterns) when is_list(patterns) do
    {found, missing} =
      Enum.reduce(patterns, {[], []}, fn pattern, {found, missing} ->
        case expand_pattern(pattern) do
          [] -> {found, [pattern | missing]}
          files -> {files ++ found, missing}
        end
      end)

    {found |> Enum.uniq() |> Enum.sort(), Enum.reverse(missing)}
  end

  defp expand_pattern(pattern) do
    if String.contains?(pattern, "*") do
      pattern |> Path.wildcard() |> Enum.filter(&String.ends_with?(&1, "_test.exs"))
    else
      if File.regular?(pattern), do: [pattern], else: []
    end
  end

  @doc """
  Every test file the registry expands to, across all categories.

  Returns `{files, missing}` with the same meaning as `expand/2`.
  """
  @spec files(registry :: t()) :: {[String.t()], [String.t()]}
  def files(registry) do
    {files, missing} =
      Enum.reduce(@categories, {[], []}, fn category, {files, missing} ->
        {found, gone} = expand(registry, category)
        {files ++ found, missing ++ gone}
      end)

    {files |> Enum.uniq() |> Enum.sort(), missing}
  end

  @doc """
  The suite a test file belongs to, decided by its path.

  ## Examples

      iex> Mix.Statifier.RegressionRegistry.categorize("test/scion_tests/basic/basic0_test.exs")
      :scion

      iex> Mix.Statifier.RegressionRegistry.categorize("test/statifier/document_test.exs")
      :internal

  """
  @spec categorize(path :: String.t()) :: category()
  def categorize(path) do
    Enum.find_value(@suite_dirs, :internal, fn {category, dir} ->
      if String.contains?(path, Path.basename(dir) <> "/"), do: category
    end)
  end

  @doc """
  `mix test` arguments that make `paths` runnable.

  Conformance suites are excluded by default, so their tag has to be included
  explicitly.

  ## Examples

      iex> Mix.Statifier.RegressionRegistry.test_args(["test/scion_tests/basic/basic0_test.exs"])
      ["--include", "scion"]

  """
  @spec test_args(paths :: [String.t()]) :: [String.t()]
  def test_args(paths) do
    paths
    |> Enum.map(&categorize/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn category ->
      case Map.get(@suite_tags, category) do
        nil -> []
        tag -> ["--include", tag]
      end
    end)
  end

  @doc """
  Adds `paths` to the registry, dated `today`.

  Returns `{registry, added, skipped}`. Internal tests are skipped: they are
  covered by globs already, so listing them individually would only add churn.
  Entries are deduplicated and sorted, and the ratchet never removes anything.
  """
  @spec add(registry :: t(), paths :: [String.t()], today :: Date.t()) ::
          {t(), [String.t()], [String.t()]}
  def add(registry, paths, today) do
    {addable, skipped} = Enum.split_with(paths, &(categorize(&1) != :internal))

    registry =
      addable
      |> Enum.group_by(&categorize/1)
      |> Enum.reduce(registry, fn {category, paths}, acc ->
        merged = ((acc[key(category)] || []) ++ paths) |> Enum.uniq() |> Enum.sort()
        Map.put(acc, key(category), merged)
      end)

    added = addable |> Enum.uniq() |> Enum.sort()

    registry =
      if added == [],
        do: registry,
        else: Map.put(registry, "last_updated", Date.to_iso8601(today))

    {registry, added, skipped}
  end

  @doc """
  Every test file on disk for a conformance `category`, sorted.

  Used by `mix test.baseline` to find candidates the registry does not know
  about yet. `root` prefixes the suite directory; it defaults to the project
  root and exists so the tasks can be pointed at a fixture tree under test.
  """
  @spec corpus_files(category :: category(), root :: String.t()) :: [String.t()]
  def corpus_files(category, root \\ ".") do
    case suite_dir(category) do
      nil ->
        []

      dir ->
        dir
        |> then(&if root == ".", do: &1, else: Path.join(root, &1))
        |> Path.join("**/*_test.exs")
        |> Path.wildcard()
        |> Enum.sort()
    end
  end

  @doc """
  Human-readable name of a conformance suite.

  ## Examples

      iex> Mix.Statifier.RegressionRegistry.suite_label(:scion)
      "SCION"

      iex> Mix.Statifier.RegressionRegistry.suite_label(:internal)
      nil

  """
  @spec suite_label(category :: category()) :: String.t() | nil
  def suite_label(category), do: Map.get(@suite_labels, category)

  @doc """
  How much of `category`'s emitted corpus `passing` covers.

  `total` counts the test files on disk under the suite directory, which is the
  only denominator the ratchet can reach 100% of - cases excluded at generation
  time (`tools/corpus/*/exclusions.exs`) never emit a file. The numerator is the
  intersection of `passing` with those files, never a plain length, because a
  registry entry may be a glob or may name a path outside the suite directory.
  `percent` is `nil` when the corpus is empty, so callers report "no files"
  rather than dividing by zero.
  """
  @spec corpus_stats(passing :: [String.t()], category :: category(), root :: String.t()) ::
          stats()
  def corpus_stats(passing, category, root \\ ".") do
    total = corpus_files(category, root)
    hit = passing |> MapSet.new() |> MapSet.intersection(MapSet.new(total)) |> MapSet.size()
    %{passing: hit, total: length(total), percent: percent(hit, length(total))}
  end

  defp percent(_hit, 0), do: nil
  defp percent(hit, total), do: Float.round(hit * 100 / total, 1)

  @caveat "Emitted files only; cases excluded at generation time are not counted " <>
            "(tools/corpus/README.md)."

  @doc """
  One report line per conformance category, plus the denominator caveat.

  Each per-category line reads `"  LABEL: passing/total (percent%)"`, with
  labels padded so the counts line up. A category whose `total` is `0` is
  omitted entirely. Callers prefix these lines with their own header (the
  numerator's meaning differs between a scan and a ratchet run, so the header
  text is not this function's job) and print the block as-is otherwise.
  Returns `[]` - no lines, no caveat - when no category has any emitted files,
  so a fixture tree with no corpus prints nothing at all.
  """
  @spec stats_lines(passing :: [String.t()], categories :: [category()], root :: String.t()) ::
          [String.t()]
  def stats_lines(passing, categories, root \\ ".") do
    entries =
      categories
      |> Enum.map(&{&1, corpus_stats(passing, &1, root)})
      |> Enum.reject(fn {_category, stats} -> stats.total == 0 end)

    case entries do
      [] ->
        []

      entries ->
        width =
          entries
          |> Enum.map(fn {category, _stats} -> String.length(suite_label(category)) end)
          |> Enum.max()

        Enum.map(entries, &stats_line(&1, width)) ++ [@caveat]
    end
  end

  defp stats_line({category, stats}, width) do
    label = String.pad_trailing(suite_label(category) <> ":", width + 1)
    "  #{label} #{stats.passing}/#{stats.total} (#{stats.percent}%)"
  end
end
