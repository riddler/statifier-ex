defmodule Mix.Statifier.Corpus.Exclusions do
  @moduledoc """
  Reads this repository's corpus exclusion lists and the W3C sub-document set,
  as input for the conformance corpus emitter (ADR-0070).

  Two exclusion lists live under `tools/corpus/` as Elixir map literals, one
  per upstream suite, each entry `key => {reason_atom, "prose"}` (ADR-0004's
  reason atoms):

    * `tools/corpus/scion/exclusions.exs` - suite `"scion"`; a key is a SCION
      spec directory (every case under it) or one `directory/name` pair.
    * `tools/corpus/scxml_w3/exclusions.exs` - suite `"w3c"`; a key is a bare
      W3C test id (`"test509"`).

  `read/1` returns one entry per key, sorted by suite then key. A key is
  emitted as written: a directory key stays one directory entry and is never
  expanded against the fetched upstream tree, so what this reader returns does
  not depend on whether that tree is present. Where an entry's prose cites a
  decision record (`ADR-NNNN`), the entry carries that record's number in
  `:adr`. `to_document/1` renders the entries as the
  `conformance/exclusions.json` document, in the shape
  `conformance/schema/exclusions.json` fixes; that schema has no field for the
  record number, so the document does not carry it.

  The files are parsed, never evaluated: each must be one map literal whose
  keys are strings and whose values are `{atom, string}` tuples, and anything
  else - a function call, an interpolated string, a repeated key - is refused
  with the file named.

  `sub_documents/2` returns the W3C manifest's sub-documents (the `<dep>`
  documents an `<invoke>` loads, which are never standalone tests) by running
  `Cases.SubDocuments` from `tools/corpus/scxml_w3/sub_documents.exs` over the
  manifest. They are a separate list, not exclusions.

  Nothing here returns an empty list: an exclusion file with no entries, an
  absent manifest and a manifest that names no sub-document are each refused
  with a sentence, so the emitter never writes an empty list in their place.
  """

  # `@sobelow_skip` is read out of this file's AST by Sobelow, never at
  # runtime, so the compiler sees an attribute that is set and never used and
  # rejects the build under `--warnings-as-errors`. Registering it as
  # persisted is what makes it a declaration rather than dead code; see its
  # one use site below, and .sobelow-conf for the mechanism.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @sources [
    {"scion", "tools/corpus/scion/exclusions.exs"},
    {"w3c", "tools/corpus/scxml_w3/exclusions.exs"}
  ]

  @sub_documents_file "tools/corpus/scxml_w3/sub_documents.exs"
  @manifest_path "tools/corpus/scratch/scxml_w3/cases/manifest.xml"
  @adr_pattern ~r/ADR-(\d{4})/

  @typedoc "An upstream suite, as the exclusions schema names it."
  @type suite :: String.t()

  @typedoc "One exclusion: the upstream key, its reason atom and prose, and the record its prose cites."
  @type entry :: %{
          suite: suite(),
          key: String.t(),
          reason: atom(),
          detail: String.t(),
          adr: pos_integer() | nil
        }

  @doc """
  The exclusion files, as `{suite, path}` pairs with paths relative to the
  project root.

  ## Examples

      iex> Mix.Statifier.Corpus.Exclusions.sources()
      [{"scion", "tools/corpus/scion/exclusions.exs"}, {"w3c", "tools/corpus/scxml_w3/exclusions.exs"}]

  """
  @spec sources() :: [{suite(), Path.t()}]
  def sources, do: @sources

  @doc """
  Where `mise run corpus:fetch` puts the W3C manifest, relative to the project
  root. The path is gitignored scratch; a fresh checkout does not have it.
  """
  @spec manifest_path() :: Path.t()
  def manifest_path, do: @manifest_path

  @doc """
  Reads both exclusion files under `root` into entries sorted by suite, then
  key.
  """
  @spec read(root :: Path.t()) :: {:ok, [entry()]} | {:error, String.t()}
  def read(root \\ ".") do
    read_all =
      Enum.reduce_while(@sources, {:ok, []}, fn {suite, relative}, {:ok, acc} ->
        path = Path.join(root, relative)

        with {:ok, source} <- read_source(path),
             {:ok, entries} <- parse(source, suite, path) do
          {:cont, {:ok, acc ++ entries}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    with {:ok, entries} <- read_all do
      {:ok, Enum.sort_by(entries, &{&1.suite, &1.key})}
    end
  end

  @doc """
  Parses one exclusion file's `source` into entries for `suite`, sorted by
  key. `label` names the file in a refusal.
  """
  @spec parse(source :: String.t(), suite :: suite(), label :: String.t()) ::
          {:ok, [entry()]} | {:error, String.t()}
  def parse(source, suite, label) do
    with {:ok, pairs} <- map_literal(source, label),
         :ok <- unique_keys(pairs, label),
         {:ok, entries} <- entries(pairs, suite, label) do
      if entries == [],
        do: {:error, "#{label} has no entries; an empty exclusion list is refused"},
        else: {:ok, Enum.sort_by(entries, & &1.key)}
    end
  end

  @doc """
  Renders entries as the `conformance/exclusions.json` document, with string
  keys and the reason atom as a string.

  ## Examples

      iex> Mix.Statifier.Corpus.Exclusions.to_document([
      ...>   %{suite: "w3c", key: "test509", reason: :needs_basichttp, detail: "POST", adr: nil}
      ...> ])
      %{"exclusions" => [%{"suite" => "w3c", "key" => "test509", "reason" => "needs_basichttp", "detail" => "POST"}]}

  """
  @spec to_document(entries :: [entry()]) :: %{String.t() => [map()]}
  def to_document(entries) do
    %{
      "exclusions" =>
        Enum.map(entries, fn entry ->
          %{
            "suite" => entry.suite,
            "key" => entry.key,
            "reason" => Atom.to_string(entry.reason),
            "detail" => entry.detail
          }
        end)
    }
  end

  @doc """
  Returns the W3C sub-document ids, sorted, by running `Cases.SubDocuments`
  from `root`'s `tools/corpus/scxml_w3/sub_documents.exs` over
  `manifest_path`.

  Refuses an absent manifest, and a manifest that names no sub-document,
  rather than returning an empty list.
  """
  @spec sub_documents(manifest_path :: Path.t(), root :: Path.t()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def sub_documents(manifest_path, root \\ ".") do
    if File.regular?(manifest_path) do
      Code.require_file(Path.join(root, @sub_documents_file))

      # Resolved at runtime: the module is defined by the required script, not
      # compiled with the project.
      ids = Module.safe_concat(["Cases", "SubDocuments"]).ids(manifest_path)

      if Enum.empty?(ids),
        do:
          {:error,
           "the W3C manifest at #{manifest_path} names no sub-document; " <>
             "an empty sub-document list is refused"},
        else: {:ok, Enum.sort(ids)}
    else
      {:error,
       "the W3C manifest is absent at #{manifest_path}; run `mise run corpus:fetch` " <>
         "to fetch it - the sub-document list is never emitted without it"}
    end
  end

  # Mix task support, run under `mix` on a developer's machine against the
  # repository's own tools/corpus/ files: the path is never
  # attacker-controlled and this module is not in the released package
  # (mix.exs's package files list). Only this one read is silenced; every
  # other Sobelow check stays live on the module.
  @sobelow_skip ["Traversal.FileModule"]
  defp read_source(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp map_literal(source, label) do
    case Code.string_to_quoted(source) do
      {:ok, {:%{}, _meta, pairs}} ->
        {:ok, pairs}

      {:ok, _other} ->
        {:error, "#{label} is not a single map literal"}

      {:error, {_meta, message, token}} ->
        {:error, "#{label} does not parse: #{inspect(message)} #{inspect(token)}"}
    end
  end

  defp unique_keys(pairs, label) do
    duplicates =
      pairs
      |> Enum.map(fn
        {key, _value} -> key
        other -> other
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_key, count} -> count > 1 end)
      |> Enum.map(&elem(&1, 0))

    if duplicates == [],
      do: :ok,
      else: {:error, "#{label} repeats the key(s) #{inspect(Enum.sort(duplicates))}"}
  end

  defp entries(pairs, suite, label) do
    Enum.reduce_while(pairs, {:ok, []}, fn pair, {:ok, acc} ->
      case entry(pair, suite, label) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp entry({key, {reason, detail}}, suite, label)
       when is_binary(key) and key != "" and is_atom(reason) and is_binary(detail) and
              detail != "" do
    with {:ok, adr} <- adr(detail, key, label) do
      {:ok, %{suite: suite, key: key, reason: reason, detail: detail, adr: adr}}
    end
  end

  defp entry(pair, _suite, label) do
    {:error,
     "#{label}: #{Macro.to_string(pair)} is not a literal entry " <>
       ~s|"key" => {:reason_atom, "prose"}|}
  end

  defp adr(detail, key, label) do
    case @adr_pattern |> Regex.scan(detail, capture: :all_but_first) |> Enum.uniq() do
      [] ->
        {:ok, nil}

      [[number]] ->
        {:ok, String.to_integer(number)}

      several ->
        {:error,
         "#{label}: the entry #{inspect(key)} cites more than one record " <>
           "(#{Enum.map_join(several, ", ", &("ADR-" <> hd(&1)))}); an entry carries one"}
    end
  end
end
