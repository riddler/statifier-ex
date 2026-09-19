defmodule Mix.Statifier.Corpus.Authored do
  @moduledoc """
  Reads the conformance cases this repository authors itself, the
  `statifier` suite (ADR-0070 decision 5), from `conformance/cases/`.

  Each case is two files in one directory per spec group:

      conformance/cases/<spec>/<name>.scxml   the SCXML document
      conformance/cases/<spec>/<name>.json    what the case expects

  The JSON file holds exactly the case fields a person writes -
  `description`, `initial_configuration`, `steps` and, optionally, `host` -
  in the shapes `conformance/schema/case.json` gives them. Everything else a
  corpus case carries is derived, so it cannot drift: `id` is
  `statifier/<spec>/<name>`, `suite` is `statifier`, `spec` is the directory,
  `conformance` is `null`, `source` is the `.scxml` file's text, and
  `required_features` is what the feature detector finds in it.

  The emitter runs every case it reads before it writes
  `conformance/corpus/statifier.json`, and `--check` re-derives that file
  from these files. No `conformance/cases/` directory means no authored
  case.
  """

  alias Mix.Statifier.Corpus.{Files, Upstream}

  @cases_dir "conformance/cases"
  @written ~w(description initial_configuration steps host)
  @required ~w(description initial_configuration steps)
  @segment ~r/\A[A-Za-z0-9][A-Za-z0-9_.+-]*\z/

  @doc """
  Reads every authored case under `root`'s `conformance/cases/`, sorted by
  id. Refuses, naming the file, a case whose JSON is invalid or carries a
  field outside the written ones, a `.json` or `.scxml` file without its
  partner, a file outside a spec directory, and a name the case id pattern
  does not allow.
  """
  @spec read(root :: Path.t()) :: {:ok, [map()]} | {:error, String.t()}
  def read(root) do
    dir = Path.join(root, @cases_dir)

    if File.dir?(dir) do
      files =
        dir |> Path.join("**/*") |> Path.wildcard() |> Enum.reject(&File.dir?/1) |> Enum.sort()

      with :ok <- all_paired(files, dir),
           {:ok, cases} <- read_cases(Enum.filter(files, &(Path.extname(&1) == ".json")), dir) do
        {:ok, Enum.sort_by(cases, & &1["id"])}
      end
    else
      {:ok, []}
    end
  end

  defp read_cases(jsons, dir) do
    Enum.reduce_while(jsons, {:ok, []}, fn json, {:ok, acc} ->
      case read_case(json, dir) do
        {:ok, corpus_case} -> {:cont, {:ok, [corpus_case | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp all_paired(files, dir) do
    present = MapSet.new(files)

    problems =
      Enum.flat_map(files, fn file ->
        relative = Path.relative_to(file, dir)

        cond do
          Path.extname(file) not in [".json", ".scxml"] ->
            ["#{@cases_dir}/#{relative} is neither a case's .json nor its .scxml"]

          length(Path.split(relative)) != 2 ->
            ["#{@cases_dir}/#{relative} is not in exactly one spec directory"]

          not MapSet.member?(present, partner(file)) ->
            ["#{@cases_dir}/#{relative} has no #{Path.basename(partner(file))} beside it"]

          true ->
            []
        end
      end)

    if problems == [],
      do: :ok,
      else: {:error, "the authored cases are malformed:\n" <> Enum.join(problems, "\n")}
  end

  defp partner(file) do
    other = if Path.extname(file) == ".json", do: ".scxml", else: ".json"
    Path.rootname(file) <> other
  end

  defp read_case(json, dir) do
    [spec, file] = json |> Path.relative_to(dir) |> Path.split()
    name = Path.rootname(file)
    label = "#{@cases_dir}/#{spec}/#{file}"

    with :ok <- segments(label, [spec, name]),
         {:ok, content} <- Files.read(json),
         {:ok, fields} <- decode(label, content),
         :ok <- written_fields(label, fields),
         {:ok, source} <- Files.read(partner(json)) do
      {:ok,
       Map.merge(fields, %{
         "id" => "statifier/#{spec}/#{name}",
         "suite" => "statifier",
         "spec" => spec,
         "conformance" => nil,
         "source" => source,
         "required_features" => Upstream.required_features(source)
       })}
    end
  end

  defp segments(label, segments) do
    if Enum.all?(segments, &Regex.match?(@segment, &1)),
      do: :ok,
      else:
        {:error, "#{label}: its directory and name must each match #{inspect(@segment.source)}"}
  end

  defp decode(label, content) do
    case JSON.decode(content) do
      {:ok, fields} when is_map(fields) -> {:ok, fields}
      {:ok, _other} -> {:error, "#{label} is not a JSON object"}
      {:error, reason} -> {:error, "invalid JSON in #{label}: #{inspect(reason)}"}
    end
  end

  defp written_fields(label, fields) do
    keys = Map.keys(fields)

    case {keys -- @written, @required -- keys} do
      {[], []} ->
        :ok

      {extra, []} ->
        {:error,
         "#{label} carries a field a case does not write: #{Enum.join(Enum.sort(extra), ", ")}"}

      {_extra, missing} ->
        {:error, "#{label} is missing: #{Enum.join(missing, ", ")}"}
    end
  end
end
