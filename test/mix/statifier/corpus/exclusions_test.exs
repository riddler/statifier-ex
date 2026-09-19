defmodule Mix.Statifier.Corpus.ExclusionsTest do
  use ExUnit.Case, async: true

  Code.require_file(
    Path.join([__DIR__, "..", "..", "..", "..", "tools/corpus/scxml_w3/sub_documents.exs"])
  )

  doctest Mix.Statifier.Corpus.Exclusions

  alias Mix.Statifier.Corpus.Exclusions
  alias Statifier.CorpusSchemaChecker, as: Checker

  # The corpus emitter's reader for the two exclusion lists and the W3C
  # sub-document set (ADR-0070). The real-file tests read the committed
  # tools/corpus/ files; the sub-document tests use the fixture manifests in
  # test/fixtures/corpus_exclusions/, so nothing here needs the gitignored
  # scratch tree.

  @schema_dir "conformance/schema"
  @fixtures "test/fixtures/corpus_exclusions"
  @key_line ~r/^\s*"([^"]+)"\s*=>/m

  # A fresh count of each file's keys, read from its text rather than through
  # the reader under test: one `"key" =>` per entry line.
  defp keys_in(path), do: Regex.scan(@key_line, File.read!(path), capture: :all_but_first)

  defp read! do
    assert {:ok, entries} = Exclusions.read()
    entries
  end

  describe "read/1 over the committed exclusion files" do
    # sabotage: parse/3 dropping the last pair (Enum.drop(pairs, -1)) -> red
    test "returns one entry per key in each file, directory keys unexpanded" do
      entries = read!()

      for {suite, path} <- Exclusions.sources() do
        keys = path |> keys_in() |> List.flatten() |> Enum.sort()

        assert keys != [], "#{path} has no keys to count"
        assert entries |> Enum.filter(&(&1.suite == suite)) |> Enum.map(& &1.key) == keys
      end

      total = Exclusions.sources() |> Enum.map(fn {_suite, path} -> length(keys_in(path)) end)
      assert length(entries) == Enum.sum(total)
    end

    # sabotage: read/1 sorting by key alone (&1.key) -> red
    test "sorts the entries by suite, then key" do
      entries = read!()
      pairs = Enum.map(entries, &{&1.suite, &1.key})

      assert pairs == Enum.sort(pairs)
      assert entries |> Enum.map(& &1.suite) |> Enum.uniq() == ["scion", "w3c"]
    end

    # sabotage: to_document/1 writing the reason as the atom itself -> red
    test "renders a document that validates against the exclusions schema" do
      document = Exclusions.to_document(read!())
      schema = Checker.load(@schema_dir, "exclusions.json")

      assert Checker.errors(schema, document, @schema_dir) == []
      assert length(document["exclusions"]) == length(read!())
    end

    # sabotage: adr/3 always returning {:ok, nil} -> red
    test "an entry whose prose cites a record carries that record's number" do
      entries = read!()
      citing = Enum.filter(entries, &(&1.detail =~ ~r/ADR-\d{4}/))

      assert citing != [], "no committed entry cites a record, so nothing is checked"

      for entry <- entries do
        expected =
          case Regex.run(~r/ADR-(\d{4})/, entry.detail, capture: :all_but_first) do
            [number] -> String.to_integer(number)
            nil -> nil
          end

        assert entry.adr == expected, "#{entry.key}: adr #{inspect(entry.adr)}"
      end
    end
  end

  describe "read/1 refusals" do
    # sabotage: read_source/1 returning {:ok, ""} on an error -> red
    test "refuses a missing file, naming it" do
      assert {:error, message} = Exclusions.read("test/fixtures/corpus_exclusions/absent")
      assert message =~ "could not read test/fixtures/corpus_exclusions/absent/tools/corpus"
    end
  end

  describe "parse/3" do
    # sabotage: parse/3 returning {:ok, []} for an empty map -> red
    test "refuses an empty map rather than returning no entries" do
      assert {:error, message} = Exclusions.parse("%{}", "w3c", "empty.exs")
      assert message == "empty.exs has no entries; an empty exclusion list is refused"
    end

    # sabotage: map_literal/2 accepting any quoted form as the pair list -> red
    test "refuses a file that is not a single map literal" do
      assert {:error, "calls.exs is not a single map literal"} =
               Exclusions.parse(~s|Map.new([{"test1", {:a, "b"}}])|, "w3c", "calls.exs")
    end

    # sabotage: map_literal/2's parse-error clause returning {:ok, []} -> red
    test "refuses source that does not parse" do
      assert {:error, message} = Exclusions.parse("%{", "w3c", "broken.exs")
      assert message =~ "broken.exs does not parse"
    end

    # sabotage: deleting the unique_keys/2 step from parse/3 -> red
    test "refuses a repeated key instead of keeping the last value" do
      source = ~s|%{"test1" => {:a, "one"}, "test1" => {:b, "two"}}|

      assert {:error, message} = Exclusions.parse(source, "w3c", "twice.exs")
      assert message =~ ~s|twice.exs repeats the key(s) ["test1"]|
    end

    # sabotage: entry/3's guard dropping is_binary(detail) -> red
    test "refuses an entry that is not a literal key => {atom, string}" do
      for source <- [
            ~s|%{"test1" => {:a, "x \#{1} y"}}|,
            ~s|%{"test1" => :a}|,
            ~s|%{"test1" => {"a", "prose"}}|,
            ~s|%{"test1" => {:a, ""}}|
          ] do
        assert {:error, message} = Exclusions.parse(source, "w3c", "shape.exs")
        assert message =~ "shape.exs: "
        assert message =~ "is not a literal entry"
      end
    end

    # sabotage: adr/3 taking the first of several cites -> red
    test "refuses prose that cites two different records" do
      source = ~s|%{"test1" => {:a, "see ADR-0022 and ADR-0026"}}|

      assert {:error, message} = Exclusions.parse(source, "scion", "two.exs")
      assert message =~ "cites more than one record (ADR-0022, ADR-0026)"
    end

    # sabotage: @adr_pattern matching any digit run (~r/(\d+)/) -> red
    test "lifts one cited record, repeated or not, as an integer" do
      source =
        ~s|%{"dir/case" => {:needs_x, "since 2019, ADR-0022, and again ADR-0022"}, "dir" => {:y, "none"}}|

      assert {:ok, [directory, pair]} = Exclusions.parse(source, "scion", "one.exs")
      assert %{key: "dir", adr: nil, reason: :y, suite: "scion"} = directory
      assert %{key: "dir/case", adr: 22, reason: :needs_x} = pair
    end
  end

  describe "sub_documents/2" do
    # sabotage: sub_documents/2 sorting descending (Enum.sort(ids, :desc)) -> red
    test "runs Cases.SubDocuments over the manifest and returns its ids, sorted" do
      manifest = Path.join(@fixtures, "manifest.xml")

      assert {:ok, ids} = Exclusions.sub_documents(manifest)
      assert ids == ["test216sub1", "test239sub1"]
      assert ids == manifest |> Cases.SubDocuments.ids() |> Enum.sort()
    end

    # sabotage: sub_documents/2 returning {:ok, []} for an absent manifest -> red
    test "refuses an absent manifest with a sentence rather than an empty list" do
      manifest = Path.join(@fixtures, "absent.xml")

      assert {:error, message} = Exclusions.sub_documents(manifest)
      assert message =~ "the W3C manifest is absent at #{manifest}"
      assert message =~ "mise run corpus:fetch"
    end

    # sabotage: deleting the Enum.empty?/1 branch in sub_documents/2 -> red
    test "refuses a manifest that names no sub-document" do
      manifest = Path.join(@fixtures, "manifest_without_deps.xml")

      assert {:error, message} = Exclusions.sub_documents(manifest)
      assert message =~ "names no sub-document; an empty sub-document list is refused"
    end

    # sabotage: n/a - asserts a path constant; changing @manifest_path -> red
    test "names the scratch manifest path corpus:fetch writes" do
      assert Exclusions.manifest_path() == "tools/corpus/scratch/scxml_w3/cases/manifest.xml"
    end
  end
end
