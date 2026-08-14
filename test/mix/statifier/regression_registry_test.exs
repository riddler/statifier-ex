defmodule Mix.Statifier.RegressionRegistryTest do
  use ExUnit.Case, async: true

  import Statifier.TmpDir, only: [setup_tmp_dir: 1]

  doctest Mix.Statifier.RegressionRegistry

  alias Mix.Statifier.RegressionRegistry

  setup :setup_tmp_dir

  @today ~D[2026-08-02]

  describe "load/1" do
    @tag :isolated_tmp_dir
    # sabotage: swap decode/2's is_map guard for is_list -> red
    test "reads a JSON object", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, ~s|{"scion_tests": ["a_test.exs"]}|)

      assert {:ok, %{"scion_tests" => ["a_test.exs"]}} = RegressionRegistry.load(path)
    end

    @tag :isolated_tmp_dir
    # sabotage: reword read/1's "could not read" prefix -> red
    test "reports a missing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "absent.json")

      assert {:error, message} = RegressionRegistry.load(path)
      assert message =~ "could not read #{path}"
    end

    @tag :isolated_tmp_dir
    # sabotage: reword decode/2's "invalid JSON in" message -> red
    test "reports malformed JSON rather than reading as empty", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "{not json")

      assert {:error, message} = RegressionRegistry.load(path)
      assert message =~ "invalid JSON"
    end

    @tag :isolated_tmp_dir
    # sabotage: reword decode/2's "does not contain a JSON object" message -> red
    test "rejects valid JSON that is not an object", %{tmp_dir: tmp_dir} do
      path = write(tmp_dir, "[]")

      assert {:error, message} = RegressionRegistry.load(path)
      assert message =~ "does not contain a JSON object"
    end
  end

  describe "the checked-in registry" do
    # sabotage: narrow expand_pattern/1's glob filter from "_test.exs" to
    #           "_test.ex" -> red
    test "loads, and every entry it holds still matches a file" do
      assert {:ok, registry} = RegressionRegistry.load()
      assert {files, []} = RegressionRegistry.files(registry)
      refute files == []
    end
  end

  describe "encode/1 and save/2" do
    # sabotage: sort encode_value/2's map keys :desc instead of ascending -> red
    test "sorts keys and puts one array entry per line" do
      encoded =
        RegressionRegistry.encode(%{
          "w3c_tests" => [],
          "scion_tests" => ["b_test.exs", "a_test.exs"],
          "last_updated" => "2026-08-02"
        })

      assert encoded == """
             {
               "last_updated": "2026-08-02",
               "scion_tests": [
                 "b_test.exs",
                 "a_test.exs"
               ],
               "w3c_tests": []
             }
             """
    end

    # sabotage: recurse encode_value/2 with the outer indent instead of the
    #           nested one, dropping the nesting bump -> red
    test "escapes strings and nests maps" do
      assert RegressionRegistry.encode(%{"a" => %{"b" => ~s|say "hi"|}}) ==
               ~s|{\n  "a": {\n    "b": "say \\"hi\\""\n  }\n}\n|
    end

    @tag :isolated_tmp_dir
    # sabotage: have save/2 write a constant "{}\n" instead of encode(registry) -> red
    test "round-trips through the filesystem", %{tmp_dir: tmp_dir} do
      registry = %{"scion_tests" => ["a_test.exs"], "w3c_tests" => []}
      path = Path.join(tmp_dir, "passing_tests.json")

      assert :ok = RegressionRegistry.save(registry, path)
      assert {:ok, ^registry} = RegressionRegistry.load(path)
    end

    @tag :isolated_tmp_dir
    # sabotage: reword save/2's "could not write" message -> red
    test "reports an unwritable path", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "no_such_dir", "passing_tests.json"])

      assert {:error, message} = RegressionRegistry.save(%{}, path)
      assert message =~ "could not write"
    end
  end

  describe "expand_patterns/1" do
    @tag :isolated_tmp_dir
    # sabotage: drop the Enum.sort() from expand_patterns/1's result -> red
    test "expands globs, keeps literals, sorts and deduplicates", %{tmp_dir: tmp_dir} do
      a = touch(tmp_dir, "b_test.exs")
      b = touch(tmp_dir, "a_test.exs")

      assert {[^b, ^a], []} =
               RegressionRegistry.expand_patterns([Path.join(tmp_dir, "*_test.exs"), a])
    end

    @tag :isolated_tmp_dir
    # sabotage: widen expand_pattern/1's glob filter from "_test.exs" to
    #           ".exs" -> red
    test "ignores non-test files caught by a glob", %{tmp_dir: tmp_dir} do
      touch(tmp_dir, "helper.exs")
      test_file = touch(tmp_dir, "a_test.exs")

      assert {[^test_file], []} =
               RegressionRegistry.expand_patterns([Path.join(tmp_dir, "*.exs")])
    end

    @tag :isolated_tmp_dir
    # sabotage: have expand_patterns/1's empty-match clause drop the pattern
    #           instead of accumulating it into missing -> red
    test "reports patterns matching nothing instead of dropping them", %{tmp_dir: tmp_dir} do
      gone = Path.join(tmp_dir, "deleted_test.exs")
      empty_glob = Path.join(tmp_dir, "nowhere/*_test.exs")

      assert {[], [^gone, ^empty_glob]} = RegressionRegistry.expand_patterns([gone, empty_glob])
    end

    @tag :isolated_tmp_dir
    # sabotage: drop expand_pattern/1's File.regular?/1 check for literal
    #           paths -> red
    test "a directory is not a test file", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "nested_test.exs")
      File.mkdir_p!(dir)

      assert {[], [^dir]} = RegressionRegistry.expand_patterns([dir])
    end
  end

  describe "files/1" do
    @tag :isolated_tmp_dir
    # sabotage: have files/1's reduce drop `gone` from the accumulated
    #           missing list -> red
    test "merges every category and reports every hole", %{tmp_dir: tmp_dir} do
      internal = touch(tmp_dir, "internal_test.exs")
      scion = touch(tmp_dir, "scion_tests/basic0_test.exs")

      registry = %{
        "internal_tests" => [internal],
        "scion_tests" => [scion],
        "w3c_tests" => [Path.join(tmp_dir, "scxml_tests/test1_test.exs")]
      }

      assert {files, [missing]} = RegressionRegistry.files(registry)
      assert files == Enum.sort([internal, scion])
      assert missing =~ "scxml_tests/test1_test.exs"
    end

    # sabotage: have expand/2's Map.get default a non-empty pattern list
    #           instead of [] -> red
    test "an absent category is not an error" do
      assert {[], []} = RegressionRegistry.files(%{})
    end
  end

  describe "categorize/1 and test_args/1" do
    # sabotage: swap categorize/1's String.contains?/2 for String.starts_with?/2 -> red
    test "categorizes by corpus directory" do
      assert RegressionRegistry.categorize("test/scion_tests/basic/basic0_test.exs") == :scion
      assert RegressionRegistry.categorize("test/scxml_tests/w3c/test144_test.exs") == :w3c
      assert RegressionRegistry.categorize("test/mix/tasks/thing_test.exs") == :internal
    end

    # sabotage: drop test_args/1's Enum.uniq() before mapping to tags -> red
    test "includes each excluded suite tag exactly once" do
      args =
        RegressionRegistry.test_args([
          "test/scion_tests/a_test.exs",
          "test/scion_tests/b_test.exs",
          "test/scxml_tests/c_test.exs",
          "test/statifier/d_test.exs"
        ])

      assert args == ["--include", "scion", "--include", "scxml_w3"]
    end

    # sabotage: have test_args/1's nil clause emit an "internal" tag -> red
    test "internal tests need no extra tags" do
      assert RegressionRegistry.test_args(["test/statifier/d_test.exs"]) == []
    end
  end

  describe "add/3" do
    # sabotage: drop add/3's Enum.uniq() when merging a category's paths -> red
    test "files each path under its suite, sorted and deduplicated" do
      registry = %{"scion_tests" => ["test/scion_tests/b_test.exs"]}

      {updated, added, []} =
        RegressionRegistry.add(
          registry,
          [
            "test/scion_tests/a_test.exs",
            "test/scion_tests/b_test.exs",
            "test/scxml_tests/c_test.exs"
          ],
          @today
        )

      assert updated["scion_tests"] == [
               "test/scion_tests/a_test.exs",
               "test/scion_tests/b_test.exs"
             ]

      assert updated["w3c_tests"] == ["test/scxml_tests/c_test.exs"]
      assert updated["last_updated"] == "2026-08-02"

      assert added == [
               "test/scion_tests/a_test.exs",
               "test/scion_tests/b_test.exs",
               "test/scxml_tests/c_test.exs"
             ]
    end

    # sabotage: flip add/3's split_with/2 predicate from != :internal to
    #           == :internal -> red
    test "skips internal tests, which the registry globs already cover" do
      {updated, [], ["test/statifier/a_test.exs"]} =
        RegressionRegistry.add(%{}, ["test/statifier/a_test.exs"], @today)

      refute Map.has_key?(updated, "last_updated")
    end

    # sabotage: have add/3's merge replace a category's list with `paths`
    #           instead of appending to the existing entries -> red
    test "never removes an entry" do
      registry = %{"scion_tests" => ["test/scion_tests/old_test.exs"]}

      {updated, _added, _skipped} =
        RegressionRegistry.add(registry, ["test/scion_tests/new_test.exs"], @today)

      assert "test/scion_tests/old_test.exs" in updated["scion_tests"]
    end
  end

  describe "corpus_files/2" do
    @tag :isolated_tmp_dir
    # sabotage: drop the "**/" recursion segment from corpus_files/2's glob -> red
    test "finds test files recursively under the suite directory", %{tmp_dir: tmp_dir} do
      nested = touch(tmp_dir, "test/scion_tests/basic/basic0_test.exs")
      touch(tmp_dir, "test/scion_tests/basic/fixture.scxml")

      assert RegressionRegistry.corpus_files(:scion, tmp_dir) == [nested]
      assert RegressionRegistry.corpus_files(:w3c, tmp_dir) == []
    end

    # sabotage: have corpus_files/2's :internal clause return a non-empty
    #           list instead of [] -> red
    test "internal tests have no corpus directory" do
      assert RegressionRegistry.corpus_files(:internal) == []
    end
  end

  describe "corpus_stats/3" do
    @tag :isolated_tmp_dir
    # sabotage: have corpus_stats/3's hit computation use length(passing)
    #           instead of the MapSet intersection -> red
    test "the numerator is the intersection with the emitted corpus", %{tmp_dir: tmp_dir} do
      inside = touch(tmp_dir, "test/scion_tests/basic0_test.exs")
      touch(tmp_dir, "test/scion_tests/basic1_test.exs")
      outside = Path.join(tmp_dir, "test/scion_tests_extra/basic2_test.exs")

      assert RegressionRegistry.corpus_stats([inside, outside], :scion, tmp_dir) == %{
               passing: 1,
               total: 2,
               percent: 50.0
             }
    end

    @tag :isolated_tmp_dir
    # sabotage: have percent/2's zero-total clause return 0.0 instead of nil -> red
    test "percent is nil when the corpus is empty", %{tmp_dir: tmp_dir} do
      assert RegressionRegistry.corpus_stats([], :scion, tmp_dir) == %{
               passing: 0,
               total: 0,
               percent: nil
             }
    end

    @tag :isolated_tmp_dir
    # sabotage: have percent/2 round to 2 decimals instead of 1 -> red
    test "percent rounds to one decimal", %{tmp_dir: tmp_dir} do
      touch(tmp_dir, "test/scion_tests/a_test.exs")
      passing = touch(tmp_dir, "test/scion_tests/b_test.exs")
      touch(tmp_dir, "test/scion_tests/c_test.exs")

      assert %{percent: 33.3} = RegressionRegistry.corpus_stats([passing], :scion, tmp_dir)
    end
  end

  describe "stats_lines/3" do
    @tag :isolated_tmp_dir
    # sabotage: have stats_lines/3 keep a category whose total is 0 instead of
    #           rejecting it -> red
    test "omits a category with no emitted files", %{tmp_dir: tmp_dir} do
      scion = touch(tmp_dir, "test/scion_tests/a_test.exs")

      lines = RegressionRegistry.stats_lines([scion], [:scion, :w3c], tmp_dir)

      assert Enum.any?(lines, &(&1 =~ "SCION"))
      refute Enum.any?(lines, &(&1 =~ "W3C"))
    end

    @tag :isolated_tmp_dir
    # sabotage: have stats_lines/3 return the per-category lines with no
    #           caveat appended -> red
    test "returns [] when no category has any emitted files", %{tmp_dir: tmp_dir} do
      assert RegressionRegistry.stats_lines([], [:scion, :w3c], tmp_dir) == []
    end

    @tag :isolated_tmp_dir
    # sabotage: have stats_line/2 pad to a fixed width of 3 instead of the
    #           computed max label width -> red
    test "pads labels so counts line up", %{tmp_dir: tmp_dir} do
      scion = touch(tmp_dir, "test/scion_tests/a_test.exs")
      w3c = touch(tmp_dir, "test/scxml_tests/a_test.exs")

      [scion_line, w3c_line, caveat] =
        RegressionRegistry.stats_lines([scion, w3c], [:scion, :w3c], tmp_dir)

      assert scion_line == "  SCION: 1/1 (100.0%)"
      assert w3c_line == "  W3C:   1/1 (100.0%)"
      assert caveat =~ "tools/corpus/README.md"
    end
  end

  defp write(tmp_dir, content) do
    path = Path.join(tmp_dir, "passing_tests.json")
    File.write!(path, content)
    path
  end

  defp touch(tmp_dir, relative) do
    path = Path.join(tmp_dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    path
  end
end
