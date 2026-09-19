defmodule Mix.Statifier.Corpus.Emitter do
  @moduledoc """
  Writes the language-neutral conformance corpus under `conformance/`, and
  checks the committed one (ADR-0070). `mix statifier.corpus` is its command
  line.

  ## Emit

  `emit/1` reads the fetched and transformed upstream suites
  (`Mix.Statifier.Corpus.Upstream`) with this repository's exclusion lists
  and the W3C sub-document set (`Mix.Statifier.Corpus.Exclusions`), RUNS
  every case through statifier (`Mix.Statifier.Corpus.Runner`), and only
  then writes:

    * `conformance/corpus/<suite>.json` - one file per suite that has cases,
      the cases sorted by id, one case per line. A suite with no cases gets
      no file and no manifest entry, so no empty corpus file is ever written.
    * `conformance/manifest.json` - the `corpus_hash`, one entry per corpus
      file with its case count, and the upstream suites with their licences.
      It carries no statifier-ex version: a claim is pinned by the
      `corpus_hash` and the statifier-ex tag the corpus was vendored from
      (ADR-0070 decision 4), so a version bump changes nothing it holds.
    * `conformance/exclusions.json` - the exclusion lists, each entry with its
      reason atom, its prose and, where the prose cites a decision record,
      that record's number as `adr`. A SCION directory key stays one entry
      naming the directory: it is not expanded into the upstream cases under
      it, so the file does not depend on the fetched tree.
    * `conformance/registry.json` - statifier-ex's claim against the corpus,
      derived from the ratchet's SCION and W3C lists by
      `Mix.Statifier.Corpus.Registry` and pinned by the `corpus_hash`. A
      ratchet path that names no corpus case, or a ratchet that names none,
      stops the emit and nothing is written.

  A case's configurations are the upstream's expectation, and a case that
  the regression ratchet (`test/passing_tests.json`) lists must agree with
  it when run: one that disagrees stops the emit and nothing is written. A
  case outside the ratchet is written with the upstream expectation whatever
  its run found; its absence from the ratchet is what says statifier-ex does
  not claim it, and the emit reports each such case with its outcome.

  `corpus_hash` is `"sha256:"` followed by the lowercase hex SHA-256 of the
  corpus files' bytes concatenated in suite order - `scion`, `w3c`,
  `statifier` - skipping a suite with no file. Nothing written depends on the
  time or on a filesystem path, so two emits of one tree are byte-identical.

  The licence texts under `conformance/LICENSES/` are committed copies of the
  upstream licences, not generated; `emit/1` and `check/1` refuse when a
  notice a case points at is missing.

  ## Check

  `check/1` writes nothing and needs neither the network nor the upstream
  tree. From the committed files alone it re-runs every committed case from
  its committed source, recomputes every file derivable from committed
  inputs - each corpus file's canonical form, each case's
  `required_features`, the manifest with its `corpus_hash`,
  `exclusions.json`, and the registry derived from `test/passing_tests.json` -
  and fails on any difference, on a registry with no entries or with an entry
  naming a case the corpus lacks or holds under another suite, and on any
  ratcheted case whose run disagrees. When the upstream tree is present it
  also rebuilds the corpus from it and fails on any case that differs; when
  it is absent it says that comparison was skipped. A check that finds a
  corpus file missing or empty, or that visited no case, fails: a green
  result on nothing is a defect.
  """

  alias Mix.Statifier.Corpus.{Exclusions, Files, Json, Registry, Runner, Upstream}
  alias Mix.Statifier.RegressionRegistry

  @suites ~w(scion w3c statifier)
  @upstream_suites ~w(scion w3c)
  @normalize_script "tools/corpus/normalize.exs"

  @typedoc "Where the emitter reads and writes: the project root and the upstream tree."
  @type config :: %{root: Path.t(), scratch: Path.t()}

  @typedoc "What an emit or a check found, for the task to print."
  @type report :: %{
          required(:counts) => [{String.t(), non_neg_integer(), non_neg_integer()}],
          required(:outside_ratchet) => [{String.t(), Runner.outcome()}],
          optional(:claims) => [{String.t(), pos_integer()}],
          optional(:written) => [Path.t()],
          optional(:upstream) => :compared | {:skipped, Path.t()}
        }

  @doc """
  Builds a config from `opts`: `:root` (default `"."`) and `:scratch`
  (default `tools/corpus/scratch` under the root).

  ## Examples

      iex> Mix.Statifier.Corpus.Emitter.config([])
      %{root: ".", scratch: "./tools/corpus/scratch"}

  """
  @spec config(opts :: keyword()) :: config()
  def config(opts) do
    root = Keyword.get(opts, :root, ".")
    %{root: root, scratch: Keyword.get(opts, :scratch) || Path.join(root, "tools/corpus/scratch")}
  end

  @doc """
  Reads the upstream tree, runs every case, and writes the corpus, the
  manifest, the exclusions and the registry under `conformance/`. Writes
  nothing when any step refuses.
  """
  @spec emit(config :: config()) :: {:ok, report()} | {:error, String.t()}
  def emit(config) do
    with :ok <- upstream_present(config.scratch),
         {:ok, exclusions} <- Exclusions.read(config.root),
         {:ok, sub_documents} <-
           Exclusions.sub_documents(w3c_manifest(config.scratch), config.root),
         {:ok, cases} <- Upstream.read(config.scratch, exclusions, sub_documents),
         :ok <- notices_present(config.root, cases),
         {:ok, ratchet} <- ratchet(config.root) do
      results = Runner.run(cases)

      with :ok <- ratcheted_agree(cases, results, ratchet, config.root),
           {:ok, {files, claims}} <-
             registry(render(cases, exclusions), cases, ratchet, config.root) do
        write(config.root, files, Map.merge(report(cases, results, ratchet, config.root), claims))
      end
    end
  end

  @doc """
  Checks the committed corpus, manifest, exclusions and registry without
  writing anything, as the moduledoc describes.
  """
  @spec check(config :: config()) :: {:ok, report()} | {:error, String.t()}
  def check(config) do
    with {:ok, committed} <- read_committed(config.root),
         {:ok, cases} <- committed_cases(committed),
         {:ok, exclusions} <- Exclusions.read(config.root),
         :ok <- notices_present(config.root, cases),
         {:ok, ratchet} <- ratchet(config.root),
         {:ok, upstream} <- upstream_drift(config, cases) do
      results = Runner.run(cases)
      rendered = render(cases, exclusions)

      {expected, registry_report, registry_problems} =
        case registry(rendered, cases, ratchet, config.root) do
          {:ok, {files, claims}} -> {files, claims, []}
          {:error, reason} -> {rendered, %{}, [reason]}
        end

      problems =
        drifted_files(committed, expected) ++
          registry_problems ++
          Registry.stale(committed["registry.json"], cases) ++
          feature_drift(cases) ++
          disagreements(cases, results, ratchet, config.root) ++ elem(upstream, 1)

      problems
      |> finish_check(cases, results, ratchet, config.root, elem(upstream, 0))
      |> with_claims(registry_report)
    end
  end

  @doc """
  Renders `cases` and `exclusions` as the files `emit/1` writes, keyed by
  path relative to `conformance/`.
  """
  @spec render(cases :: [map()], exclusions :: [Exclusions.entry()]) :: %{Path.t() => binary()}
  def render(cases, exclusions) do
    by_suite = Enum.group_by(cases, & &1["suite"])

    corpus =
      for suite <- @suites, suite_cases = Map.get(by_suite, suite, []), suite_cases != [] do
        {suite, corpus_file(suite),
         Json.corpus_file(suite, Enum.sort_by(suite_cases, & &1["id"])), length(suite_cases)}
      end

    manifest = %{
      "corpus_hash" => corpus_hash(Enum.map(corpus, &elem(&1, 2))),
      "suites" =>
        Enum.map(corpus, fn {suite, file, _content, count} ->
          %{"suite" => suite, "file" => file, "case_count" => count}
        end),
      "upstreams" => Upstream.upstreams()
    }

    corpus
    |> Map.new(fn {_suite, file, content, _count} -> {file, content} end)
    |> Map.put("manifest.json", Json.pretty(manifest))
    |> Map.put("exclusions.json", exclusions |> Exclusions.to_document() |> Json.pretty())
  end

  @doc """
  The `corpus_hash` of corpus file contents given in suite order.

  ## Examples

      iex> Mix.Statifier.Corpus.Emitter.corpus_hash(["a", "b"])
      "sha256:fb8e20fc2e4c3f248c60c39bd652f3c1347298bb977b8b4d5903b85055620603"

  """
  @spec corpus_hash(contents :: [binary()]) :: String.t()
  def corpus_hash(contents) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, contents), case: :lower)
  end

  @doc """
  The path, relative to the project root, of the generated test module a
  corpus case corresponds to - the path `test/passing_tests.json` names it by.
  A `statifier` case has none.
  """
  @spec generated_path(corpus_case :: map(), root :: Path.t()) :: Path.t() | nil
  def generated_path(%{"suite" => "scion", "id" => id, "spec" => spec}, root) do
    n = normalizer(root)
    Path.join(["test/scion_tests", n.(spec), n.(Path.basename(id)) <> "_test.exs"])
  end

  def generated_path(
        %{"suite" => "w3c", "id" => id, "spec" => spec, "conformance" => conformance},
        root
      ) do
    n = normalizer(root)
    Path.join(["test/scxml_tests", conformance, n.(spec), n.(Path.basename(id)) <> "_test.exs"])
  end

  def generated_path(_corpus_case, _root), do: nil

  # --- emit ----------------------------------------------------------------

  defp upstream_present(scratch) do
    missing = Enum.reject([Upstream.scion_dir(scratch), Upstream.w3c_dir(scratch)], &File.dir?/1)

    if missing == [],
      do: :ok,
      else:
        {:error,
         "the upstream tree is absent (#{Enum.join(missing, ", ")}); run `mise run corpus:fetch` " <>
           "and `mise run corpus:transform` to fetch and transform it - the emitter never fetches"}
  end

  # Absolute: Exclusions.sub_documents/2 resolves a relative manifest path
  # against the project root, and the upstream tree need not be under it.
  defp w3c_manifest(scratch),
    do: Path.expand(Path.join(Upstream.w3c_dir(scratch), "manifest.xml"))

  defp ratcheted_agree(cases, results, ratchet, root) do
    case disagreements(cases, results, ratchet, root) do
      [] ->
        :ok

      problems ->
        {:error,
         "a ratcheted case disagrees with the upstream expectation, so nothing was written:\n" <>
           Enum.join(problems, "\n")}
    end
  end

  defp write(root, files, report) do
    dir = Path.join(root, "conformance")

    files
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {file, content}, :ok ->
      case Files.write(Path.join(dir, file), content) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
    |> then(fn written ->
      with :ok <- written,
           do: {:ok, Map.put(report, :written, files |> Map.keys() |> Enum.sort())}
    end)
  end

  # --- check ---------------------------------------------------------------

  defp read_committed(root) do
    dir = Path.join(root, "conformance")

    present =
      Enum.filter(
        @suites,
        &(&1 in @upstream_suites or File.exists?(Path.join(dir, corpus_file(&1))))
      )

    files =
      Enum.map(present, &corpus_file/1) ++ ["manifest.json", "exclusions.json", "registry.json"]

    Enum.reduce_while(files, {:ok, %{}}, fn file, {:ok, acc} ->
      case Files.read(Path.join(dir, file)) do
        {:ok, content} -> {:cont, {:ok, Map.put(acc, file, content)}}
        {:error, reason} -> {:halt, {:error, "the committed corpus is incomplete: #{reason}"}}
      end
    end)
  end

  defp committed_cases(committed) do
    @suites
    |> Enum.filter(&Map.has_key?(committed, corpus_file(&1)))
    |> Enum.reduce_while({:ok, []}, fn suite, {:ok, acc} ->
      case suite_cases(suite, committed[corpus_file(suite)]) do
        {:ok, cases} -> {:cont, {:ok, acc ++ cases}}
        error -> {:halt, error}
      end
    end)
  end

  defp suite_cases(suite, content) do
    file = "conformance/" <> corpus_file(suite)

    case JSON.decode(content) do
      {:ok, %{"suite" => ^suite, "cases" => [_first | _rest] = cases}} ->
        shaped(cases, suite, file)

      {:ok, %{"suite" => ^suite, "cases" => []}} ->
        {:error, "#{file} has no cases; an empty corpus file is refused"}

      {:ok, _other} ->
        {:error, "#{file} is not a #{suite} corpus file"}

      {:error, reason} ->
        {:error, "invalid JSON in #{file}: #{inspect(reason)}"}
    end
  end

  # The shape `Runner.run_case/1` and the recomputations read. The full shape
  # is conformance/schema/case.json's; this refuses only what would make the
  # check itself unable to run a case.
  defp shaped(cases, suite, file) do
    bad =
      Enum.reject(cases, fn
        %{
          "id" => id,
          "suite" => ^suite,
          "source" => source,
          "initial_configuration" => initial,
          "steps" => steps
        }
        when is_binary(id) and is_binary(source) and is_list(initial) and is_list(steps) ->
          String.starts_with?(id, suite <> "/") and Enum.all?(steps, &step?/1)

        _other ->
          false
      end)

    if bad == [],
      do: {:ok, cases},
      else:
        {:error,
         "#{file} holds #{length(bad)} case(s) that cannot be run: #{Enum.map_join(bad, ", ", &inspect(&1["id"]))}"}
  end

  defp step?(%{"event" => %{"name" => name}, "configuration" => configuration}),
    do: is_binary(name) and is_list(configuration)

  defp step?(_step), do: false

  defp upstream_drift(config, cases) do
    if File.dir?(Upstream.scion_dir(config.scratch)) and
         File.dir?(Upstream.w3c_dir(config.scratch)) do
      with {:ok, exclusions} <- Exclusions.read(config.root),
           {:ok, sub_documents} <-
             Exclusions.sub_documents(w3c_manifest(config.scratch), config.root),
           {:ok, upstream} <- Upstream.read(config.scratch, exclusions, sub_documents) do
        {:ok,
         {:compared, case_drift(Enum.filter(cases, &(&1["suite"] in @upstream_suites)), upstream)}}
      end
    else
      {:ok, {{:skipped, config.scratch}, []}}
    end
  end

  defp case_drift(committed, upstream) do
    ours = Map.new(committed, &{&1["id"], &1})
    theirs = Map.new(upstream, &{&1["id"], &1})

    ids = ours |> Map.keys() |> Enum.concat(Map.keys(theirs)) |> Enum.uniq() |> Enum.sort()

    Enum.flat_map(ids, fn id ->
      case {Map.get(ours, id), Map.get(theirs, id)} do
        {same, same} -> []
        {nil, _theirs} -> ["#{id}: in the upstream tree but not in the corpus"]
        {_ours, nil} -> ["#{id}: in the corpus but not in the upstream tree"]
        {_ours, _theirs} -> ["#{id}: differs from what the upstream tree emits"]
      end
    end)
  end

  defp drifted_files(committed, expected) do
    expected
    |> Enum.sort()
    |> Enum.flat_map(fn {file, content} ->
      if Map.get(committed, file) == content,
        do: [],
        else: [
          "conformance/#{file}: differs from what the emitter writes from the committed inputs"
        ]
    end)
  end

  defp feature_drift(cases) do
    for %{"id" => id, "source" => source} = corpus_case <- cases,
        corpus_case["required_features"] != Upstream.required_features(source) do
      "#{id}: required_features is not what the feature detector finds in its source"
    end
  end

  defp with_claims({:ok, report}, registry_report), do: {:ok, Map.merge(report, registry_report)}
  defp with_claims(error, _registry_report), do: error

  defp finish_check(problems, cases, results, ratchet, root, upstream) do
    if problems == [],
      do: {:ok, Map.put(report(cases, results, ratchet, root), :upstream, upstream)},
      else: {:error, "the committed corpus has drifted:\n" <> Enum.join(problems, "\n")}
  end

  # --- shared --------------------------------------------------------------

  defp corpus_file(suite), do: "corpus/#{suite}.json"

  # Adds registry.json to the rendered files: derived from the ratchet's
  # paths against the rendered corpus, pinned by the rendered corpus hash.
  # Returns the files and the report's per-claim entry counts.
  defp registry(files, cases, ratchet, root) do
    hash = @suites |> Enum.flat_map(&List.wrap(files[corpus_file(&1)])) |> corpus_hash()

    with {:ok, registry} <-
           Registry.derive(cases, ratchet, hash, &generated_path(&1, root)) do
      by_id = Map.new(cases, &{&1["id"], &1})

      claims =
        registry["entries"]
        |> Enum.frequencies_by(&Registry.claim(by_id[&1["case_id"]]))
        |> Enum.sort()

      {:ok, {Map.put(files, "registry.json", Registry.encode(registry)), %{claims: claims}}}
    end
  end

  defp notices_present(root, cases) do
    wanted = cases |> Enum.flat_map(&List.wrap(get_in(&1, ["upstream", "notice"]))) |> Enum.uniq()
    wanted = Enum.uniq(wanted ++ Upstream.notices())

    case Enum.reject(wanted, &non_empty?(Path.join([root, "conformance", &1]))) do
      [] ->
        :ok

      missing ->
        {:error,
         "a licence notice is missing or empty under conformance/: #{Enum.join(Enum.sort(missing), ", ")}"}
    end
  end

  defp non_empty?(path),
    do: match?({:ok, %File.Stat{type: :regular, size: size}} when size > 0, File.stat(path))

  defp ratchet(root) do
    with {:ok, registry} <-
           RegressionRegistry.load(Path.join(root, RegressionRegistry.default_path())) do
      patterns =
        Enum.flat_map(
          RegressionRegistry.conformance_categories(),
          &Map.get(registry, RegressionRegistry.key(&1), [])
        )

      {:ok,
       patterns
       |> Enum.flat_map(fn pattern ->
         if String.contains?(pattern, "*"),
           do:
             root
             |> Path.join(pattern)
             |> Path.wildcard()
             |> Enum.map(&Path.relative_to(&1, root)),
           else: [pattern]
       end)
       |> MapSet.new()}
    end
  end

  defp ratcheted?(corpus_case, ratchet, root) do
    case generated_path(corpus_case, root) do
      nil -> false
      path -> MapSet.member?(ratchet, path)
    end
  end

  defp disagreements(cases, results, ratchet, root) do
    for {corpus_case, {id, {:disagree, message}}} <- Enum.zip(cases, results),
        ratcheted?(corpus_case, ratchet, root) do
      "#{id} (#{generated_path(corpus_case, root)}): #{message}"
    end
  end

  defp report(cases, results, ratchet, root) do
    pairs = Enum.zip(cases, results)

    counts =
      for suite <- @suites,
          in_suite = Enum.filter(pairs, fn {c, _r} -> c["suite"] == suite end),
          in_suite != [] do
        {suite, length(in_suite),
         Enum.count(in_suite, fn {_c, {_id, outcome}} -> outcome == :agree end)}
      end

    outside = for {c, {id, outcome}} <- pairs, not ratcheted?(c, ratchet, root), do: {id, outcome}
    %{counts: counts, outside_ratchet: outside}
  end

  defp normalizer(root) do
    # The generators' own normalization (tools/corpus/normalize.exs), loaded
    # once: the same file the generated module paths came from. Named at
    # runtime, because the module is the script's, not compiled with the
    # project.
    if !Code.ensure_loaded?(Cases.Normalize),
      do: Code.require_file(Path.join(root, @normalize_script))

    module = Module.safe_concat(["Cases", "Normalize"])
    &module.identifier/1
  end
end
