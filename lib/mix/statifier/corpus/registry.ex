defmodule Mix.Statifier.Corpus.Registry do
  @moduledoc """
  Derives `conformance/registry.json`, statifier-ex's claim against its own
  corpus, from the regression ratchet (ADR-0070 decisions 3 and 4).

  `test/passing_tests.json` stays ADR-0006's ratchet file and `mix
  test.baseline` the only thing that grows it; the emitter calls `derive/4`
  with the ratchet's SCION, W3C and statifier paths and writes what
  `encode/1` returns. Nothing else writes the registry. The `internal_tests`
  globs never reach this module: they name this repository's unit tests, not
  corpus cases.

  Each ratchet path names exactly one corpus case - an upstream case by its
  generated test module, an authored `statifier` case, which has none, by
  its JSON file under `conformance/cases/` - and that case becomes one entry
  `{case_id, suite}`. A path that names no case, or a path two cases share,
  stops the derivation naming it. A case in the corpus but not in the
  ratchet has no entry: its absence is the claim that statifier-ex does not
  pass it.

  Claims are per suite, with no tiers: `scion`, `w3c-mandatory`,
  `w3c-optional` and `statifier`, the W3C suite split by each case's
  conformance class. A suite with no entries is not claimed, and a registry
  with no entries is refused: a claim of nothing is a defect.

  The file is sorted - claims by name, entries by suite then case id - with
  one entry per line, so ratcheting a case in is a one-line diff.
  """

  alias Mix.Statifier.Corpus.Json

  @implementation "statifier-ex"

  @typedoc "A registry document, in `conformance/schema/registry.json`'s shape."
  @type t :: %{String.t() => term()}

  @doc """
  Derives the registry from `cases` (the corpus), `ratchet` (the ratchet's
  SCION, W3C and statifier paths, globs already expanded), the corpus hash
  the cases were written under, and `ratchet_path`, which names the path the
  ratchet names a case by or returns `nil` when it has none.

  ## Examples

      iex> cases = [
      ...>   %{"id" => "scion/ads/view", "suite" => "scion"},
      ...>   %{"id" => "w3c/test9", "suite" => "w3c", "conformance" => "optional"},
      ...>   %{"id" => "w3c/test8", "suite" => "w3c", "conformance" => "mandatory"}
      ...> ]
      iex> path = fn c -> "test/" <> c["id"] <> "_test.exs" end
      iex> {:ok, registry} =
      ...>   Mix.Statifier.Corpus.Registry.derive(
      ...>     cases, ["test/w3c/test9_test.exs", "test/scion/ads/view_test.exs"], "sha256:00", path)
      iex> registry["claims"]
      ["scion", "w3c-optional"]
      iex> registry["entries"]
      [%{"case_id" => "scion/ads/view", "suite" => "scion"}, %{"case_id" => "w3c/test9", "suite" => "w3c"}]

  """
  @spec derive(
          cases :: [map()],
          ratchet :: Enumerable.t(),
          corpus_hash :: String.t(),
          ratchet_path :: (map() -> Path.t() | nil)
        ) :: {:ok, t()} | {:error, String.t()}
  def derive(cases, ratchet, corpus_hash, ratchet_path) do
    by_path =
      cases
      |> Enum.map(&{ratchet_path.(&1), &1})
      |> Enum.reject(fn {path, _case} -> is_nil(path) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    paths = ratchet |> Enum.uniq() |> Enum.sort()

    with {:ok, claimed} <- claimed(paths, by_path) do
      entries =
        claimed
        |> Enum.map(&%{"case_id" => &1["id"], "suite" => &1["suite"]})
        |> Enum.sort_by(&{&1["suite"], &1["case_id"]})

      {:ok,
       %{
         "implementation" => @implementation,
         "corpus_hash" => corpus_hash,
         "claims" => claimed |> Enum.map(&claim/1) |> Enum.uniq() |> Enum.sort(),
         "entries" => entries
       }}
    end
  end

  defp claimed([], _by_path),
    do: {:error, "the ratchet names no corpus case; an empty registry is refused"}

  defp claimed(paths, by_path) do
    {cases, problems} =
      Enum.reduce(paths, {[], []}, fn path, {cases, problems} ->
        case Map.get(by_path, path, []) do
          [one] -> {[one | cases], problems}
          [] -> {cases, ["#{path}: names no corpus case" | problems]}
          many -> {cases, ["#{path}: names #{ids(many)}, not exactly one case" | problems]}
        end
      end)

    if problems == [],
      do: {:ok, cases},
      else:
        {:error,
         "a ratchet path does not map to exactly one corpus case, so the registry cannot be derived:\n" <>
           Enum.join(Enum.reverse(problems), "\n")}
  end

  defp ids(cases), do: cases |> Enum.map(& &1["id"]) |> Enum.sort() |> Enum.join(" and ")

  @doc """
  The claim a corpus case's entry counts toward.

  ## Examples

      iex> Mix.Statifier.Corpus.Registry.claim(%{"suite" => "w3c", "conformance" => "mandatory"})
      "w3c-mandatory"

      iex> Mix.Statifier.Corpus.Registry.claim(%{"suite" => "scion"})
      "scion"

  """
  @spec claim(corpus_case :: map()) :: String.t()
  def claim(%{"suite" => "w3c", "conformance" => conformance}), do: "w3c-" <> conformance
  def claim(%{"suite" => suite}), do: suite

  @doc """
  Encodes a registry: pretty, with the claims on one line and one compact
  entry per line.
  """
  @spec encode(registry :: t()) :: String.t()
  def encode(registry) do
    entries = Enum.map_join(registry["entries"], ",\n", &("    " <> Json.compact(&1)))

    "{\n" <>
      "  \"implementation\": #{Json.compact(registry["implementation"])},\n" <>
      "  \"corpus_hash\": #{Json.compact(registry["corpus_hash"])},\n" <>
      "  \"claims\": #{Json.compact(registry["claims"])},\n" <>
      "  \"entries\": [\n#{entries}\n  ]\n}\n"
  end

  @doc """
  Checks a committed registry against the corpus `cases`, returning one
  sentence per problem: no entries at all, or an entry whose case the corpus
  lacks or holds under another suite.
  """
  @spec stale(committed :: binary(), cases :: [map()]) :: [String.t()]
  def stale(committed, cases) do
    suites = Map.new(cases, &{&1["id"], &1["suite"]})

    case JSON.decode(committed) do
      {:ok, %{"entries" => [_first | _rest] = entries}} ->
        for entry <- entries, problem = stale_entry(entry, suites), do: problem

      {:ok, _no_entries} ->
        ["conformance/registry.json has no entries; an empty registry is refused"]

      {:error, reason} ->
        ["invalid JSON in conformance/registry.json: #{inspect(reason)}"]
    end
  end

  defp stale_entry(%{"case_id" => id, "suite" => suite}, suites) do
    case Map.fetch(suites, id) do
      {:ok, ^suite} -> nil
      {:ok, other} -> "#{id}: the registry says suite #{suite}, the corpus says #{other}"
      :error -> "#{id}: in the registry but not in the corpus"
    end
  end

  defp stale_entry(entry, _suites),
    do: "conformance/registry.json holds an entry that is not {case_id, suite}: #{inspect(entry)}"
end
