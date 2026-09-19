defmodule Mix.Statifier.Corpus.Upstream do
  @moduledoc """
  Reads the fetched and transformed upstream suites into corpus cases, in the
  shape `conformance/schema/case.json` fixes, without running them.

  The upstream tree is the gitignored scratch directory `mise run corpus:fetch`
  and `mise run corpus:transform` populate (`tools/corpus/README.md`):
  `scion/cases/<spec>/<name>.{json,scxml}` and
  `scxml_w3/cases/<conformance>/<spec>/<id>.{scxml,description}` beside the
  W3C IRP `manifest.xml`. Nothing here fetches or transforms.

  The filters are the ones the test generators under `tools/corpus/` apply,
  in the same order, so a case is in the corpus exactly when a generated test
  module exists for it:

    * SCION: a case is left out when its spec directory, or its
      `directory/name` pair, is a key in the SCION exclusion list.
    * W3C: a test is left out when its id is a key in the W3C exclusion list,
      when it is a manifest sub-document, or when the predicator transform
      left it on another datamodel.

  An exclusion key that matches no upstream document is refused, as the
  generators refuse it.

  A SCION case carries its upstream document unmodified (with the upstream's
  own licence header comment, where it has one) and the configurations its
  `.json` file expects. A W3C case carries the transformed document as
  `Mix.Statifier.Corpus.XmlFormat` formats it, and the IRP's own expectation:
  a test passes by reaching the final state `pass` with no event sent.
  """

  alias Mix.Statifier.Corpus.{Files, XmlFormat}
  alias Statifier.Testing.FeatureDetector

  @scion_notice "LICENSES/Apache-2.0.txt"
  @w3c_notice "LICENSES/BSD-3-Clause-W3C.txt"

  @upstreams [
    %{
      "suite" => "scion",
      "name" => "SCION scxml-test-framework",
      "url" => "https://github.com/jbeard4/scxml-test-framework",
      "license" => "Apache-2.0",
      "notice" => @scion_notice
    },
    %{
      "suite" => "w3c",
      "name" => "W3C SCXML Implementation Report Plan test suite",
      "url" => "https://www.w3.org/Voice/2013/scxml-irp/",
      "license" => "BSD-3-Clause-W3C",
      "notice" => @w3c_notice
    }
  ]

  @typedoc "One corpus case, with the string keys of `conformance/schema/case.json`."
  @type corpus_case :: %{String.t() => term()}

  @doc """
  The manifest's `upstreams` entries: each upstream suite, where it is
  published, its licence and the notice file under `conformance/` it is
  redistributed with.
  """
  @spec upstreams() :: [map()]
  def upstreams, do: @upstreams

  @doc "The notice files every upstream case points at, relative to `conformance/`."
  @spec notices() :: [String.t()]
  def notices, do: [@scion_notice, @w3c_notice]

  @doc "The SCION cases directory under `scratch`."
  @spec scion_dir(scratch :: Path.t()) :: Path.t()
  def scion_dir(scratch), do: Path.join(scratch, "scion/cases")

  @doc "The W3C cases directory under `scratch`, which also holds the IRP manifest."
  @spec w3c_dir(scratch :: Path.t()) :: Path.t()
  def w3c_dir(scratch), do: Path.join(scratch, "scxml_w3/cases")

  @doc """
  Reads every SCION and W3C case under `scratch`, sorted by id, leaving out
  what `exclusions` (the entries `Mix.Statifier.Corpus.Exclusions.read/1`
  returns) and `sub_documents` (W3C test ids) name.
  """
  @spec read(scratch :: Path.t(), exclusions :: [map()], sub_documents :: [String.t()]) ::
          {:ok, [corpus_case()]} | {:error, String.t()}
  def read(scratch, exclusions, sub_documents) do
    keys = fn suite ->
      for %{suite: ^suite, key: key} <- exclusions, into: MapSet.new(), do: key
    end

    with {:ok, scion} <- scion_cases(scion_dir(scratch), keys.("scion")),
         {:ok, uris} <- w3c_uris(w3c_dir(scratch)),
         {:ok, w3c} <- w3c_cases(w3c_dir(scratch), keys.("w3c"), MapSet.new(sub_documents), uris) do
      {:ok, Enum.sort_by(scion ++ w3c, & &1["id"])}
    end
  end

  # --- SCION ---------------------------------------------------------------

  defp scion_cases(dir, keys) do
    inputs = dir |> Path.join("**/*.json") |> Path.wildcard() |> Enum.sort()

    {kept, matched} =
      Enum.reduce(inputs, {[], MapSet.new()}, fn input, {kept, matched} ->
        {spec, name} = spec_and_name(input, dir, ".json")

        case Enum.find([spec, "#{spec}/#{name}"], &MapSet.member?(keys, &1)) do
          nil -> {[{input, spec, name} | kept], matched}
          key -> {kept, MapSet.put(matched, key)}
        end
      end)

    with :ok <- no_stale_keys("SCION", keys, matched) do
      collect(Enum.reverse(kept), fn {input, spec, name} -> scion_case(input, spec, name) end)
    end
  end

  defp spec_and_name(input, dir, extension) do
    relative = Path.relative_to(input, dir)
    {Path.dirname(relative), Path.basename(relative, extension)}
  end

  defp scion_case(input, spec, name) do
    with {:ok, source} <- Files.read(Path.rootname(input) <> ".scxml"),
         {:ok, json} <- Files.read(input),
         {:ok, %{"initialConfiguration" => initial, "events" => events}} <- decode(json, input) do
      {:ok,
       %{
         "id" => "scion/#{spec}/#{name}",
         "suite" => "scion",
         "spec" => spec,
         "conformance" => nil,
         "description" => "",
         "required_features" => required_features(source),
         "source" => source,
         "initial_configuration" => initial,
         "steps" => Enum.map(events, &scion_step/1),
         "upstream" => %{
           "document" => "test/#{spec}/#{name}.scxml",
           "license" => "Apache-2.0",
           "notice" => @scion_notice
         }
       }}
    end
  end

  # A SCION step's other keys (`after`) have no field in the case shape and
  # no reader in `Statifier.Testing.Case.test_scxml/4`; the generated module
  # drops them the same way.
  defp scion_step(%{"event" => event, "nextConfiguration" => configuration}) do
    %{"event" => Map.take(event, ["name", "data"]), "configuration" => configuration}
  end

  defp decode(json, path) do
    case JSON.decode(json) do
      {:ok, %{"initialConfiguration" => _initial, "events" => _events} = decoded} ->
        {:ok, decoded}

      {:ok, _other} ->
        {:error, "#{path} has no initialConfiguration and events"}

      {:error, reason} ->
        {:error, "invalid JSON in #{path}: #{inspect(reason)}"}
    end
  end

  # --- W3C -----------------------------------------------------------------

  defp w3c_uris(dir) do
    path = Path.join(dir, "manifest.xml")

    with {:ok, manifest} <- Files.read(path) do
      {:ok,
       ~r/uri="([^"]+\.txml)"/
       |> Regex.scan(manifest, capture: :all_but_first)
       |> Map.new(fn [uri] -> {Path.basename(uri, ".txml"), uri} end)}
    end
  end

  defp w3c_cases(dir, keys, sub_documents, uris) do
    inputs = dir |> Path.join("**/*.scxml") |> Path.wildcard() |> Enum.sort()

    matched =
      for input <- inputs,
          (name = Path.basename(input, ".scxml")) in keys,
          into: MapSet.new(),
          do: name

    kept =
      Enum.reject(inputs, fn input ->
        name = Path.basename(input, ".scxml")
        MapSet.member?(keys, name) or MapSet.member?(sub_documents, name)
      end)

    with :ok <- no_stale_keys("W3C", keys, matched),
         {:ok, cases} <- collect(kept, &w3c_case(&1, dir, uris)) do
      {:ok, Enum.reject(cases, &is_nil/1)}
    end
  end

  defp w3c_case(input, dir, uris) do
    [conformance, spec | _rest] = input |> Path.relative_to(dir) |> Path.split()
    name = Path.basename(input, ".scxml")

    with {:ok, xml} <- Files.read(input),
         {:ok, {source, datamodel}} <- format(xml, input) do
      if datamodel == "predicator",
        do: w3c_predicator_case(input, name, conformance, spec, source, uris),
        else: {:ok, nil}
    end
  end

  defp w3c_predicator_case(input, name, conformance, spec, source, uris) do
    with {:ok, description} <- Files.read(Path.rootname(input) <> ".description"),
         {:ok, uri} <- fetch_uri(uris, name) do
      {:ok,
       %{
         "id" => "w3c/#{name}",
         "suite" => "w3c",
         "spec" => spec,
         "conformance" => conformance,
         "description" => description |> String.split() |> Enum.join(" "),
         "required_features" => required_features(source),
         "source" => source,
         "initial_configuration" => ["pass"],
         "steps" => [],
         "upstream" => %{
           "document" => uri,
           "license" => "BSD-3-Clause-W3C",
           "notice" => @w3c_notice
         }
       }}
    end
  end

  defp format(xml, input) do
    case XmlFormat.format(xml) do
      {:ok, formatted} -> {:ok, formatted}
      {:error, reason} -> {:error, "#{input}: #{reason}"}
    end
  end

  defp fetch_uri(uris, name) do
    case Map.fetch(uris, name) do
      {:ok, uri} -> {:ok, uri}
      :error -> {:error, "the W3C manifest names no document for #{name}"}
    end
  end

  # --- shared --------------------------------------------------------------

  @doc """
  The feature names `Statifier.Testing.FeatureDetector` finds in `source`, as
  sorted strings: a case's `required_features`.
  """
  @spec required_features(source :: String.t()) :: [String.t()]
  def required_features(source) do
    source |> FeatureDetector.detect_features() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
  end

  defp no_stale_keys(label, keys, matched) do
    case keys |> MapSet.difference(matched) |> Enum.sort() do
      [] ->
        :ok

      stale ->
        {:error,
         "#{label} exclusion key(s) matched no upstream document: #{Enum.join(stale, ", ")}"}
    end
  end

  defp collect(items, fun) do
    collected =
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
        case fun.(item) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, values} <- collected, do: {:ok, Enum.reverse(values)}
  end
end
