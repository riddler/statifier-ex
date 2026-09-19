defmodule Corpus.CorpusFilesTest do
  # Not async: the check re-runs every committed case, sessions and timers
  # included, and the harness's settle windows are tuned for the corpus
  # running as the regression ratchet runs it, not beside the whole suite.
  use ExUnit.Case, async: false

  import Statifier.TmpDir, only: [setup_tmp_dir: 1]

  alias Mix.Statifier.Corpus.{Emitter, Upstream}
  alias Mix.Statifier.RegressionRegistry
  alias Statifier.CorpusSchemaChecker, as: Checker

  Code.require_file(Path.join([__DIR__, "..", "..", "tools/corpus/normalize.exs"]))

  # The committed corpus under conformance/, written by `mix statifier.corpus`
  # (ADR-0070), against the schemas, the generated test modules it
  # corresponds to, and the emitter's own check. Nothing here needs the
  # gitignored upstream tree.

  @schema_dir "conformance/schema"
  @suites %{"scion" => "test/scion_tests", "w3c" => "test/scxml_tests"}

  setup :setup_tmp_dir

  defp corpus(suite), do: "conformance/corpus/#{suite}.json" |> File.read!() |> JSON.decode!()
  defp cases(suite), do: corpus(suite)["cases"]
  defp all_cases, do: Enum.flat_map(Map.keys(@suites), &cases/1)

  # A fresh count of the generated test tree, read from disk rather than
  # through the emitter.
  defp generated(suite),
    do: (@suites[suite] <> "/**/*_test.exs") |> Path.wildcard() |> Enum.sort()

  # The document a generated module holds: the string bound to `xml`.
  defp module_xml(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_ast, xml} =
      Macro.prewalk(ast, nil, fn
        {:=, _meta, [{:xml, _xml_meta, _context}, xml]} = node, _acc when is_binary(xml) ->
          {node, xml}

        node, acc ->
          {node, acc}
      end)

    xml
  end

  describe "the committed files" do
    # sabotage: n/a - asserts the committed generated files, no lib/ behavior;
    # deleting "required_features" from one line of corpus/w3c.json -> red
    test "every case, corpus file, the manifest and the exclusions validate against their schemas" do
      case_schema = Checker.load(@schema_dir, "case.json")

      for corpus_case <- all_cases() ++ cases("statifier") do
        assert Checker.errors(case_schema, corpus_case, @schema_dir) == [], corpus_case["id"]
      end

      for {file, schema} <- [
            {"corpus/scion.json", "corpus.json"},
            {"corpus/w3c.json", "corpus.json"},
            {"corpus/statifier.json", "corpus.json"},
            {"manifest.json", "manifest.json"},
            {"exclusions.json", "exclusions.json"},
            {"registry.json", "registry.json"}
          ] do
        instance = "conformance/#{file}" |> File.read!() |> JSON.decode!()

        assert Checker.errors(Checker.load(@schema_dir, schema), instance, @schema_dir) == [],
               file
      end
    end

    # sabotage: n/a - asserts the committed generated files, no lib/ behavior;
    # deleting conformance/cases/ and re-emitting -> red on the missing file
    test "the statifier suite is the authored cases, each carrying a host object" do
      authored =
        "conformance/cases/*/*.json"
        |> Path.wildcard()
        |> Enum.map(
          &("statifier/" <> (&1 |> Path.relative_to("conformance/cases") |> Path.rootname()))
        )
        |> Enum.sort()

      assert authored != [], "no authored case, so nothing is checked"
      assert Enum.map(cases("statifier"), & &1["id"]) == authored
      assert Enum.all?(cases("statifier"), &Map.has_key?(&1, "host"))
    end

    # sabotage: Emitter.generated_path/2 dropping the conformance segment -> red
    test "each suite's cases are exactly its generated test modules, one for one" do
      manifest = "conformance/manifest.json" |> File.read!() |> JSON.decode!()

      for suite <- Map.keys(@suites) do
        modules = generated(suite)
        paths = suite |> cases() |> Enum.map(&Emitter.generated_path(&1, ".")) |> Enum.sort()

        assert modules != [], "no generated #{suite} modules to count"
        assert paths == modules

        assert %{"case_count" => count} = Enum.find(manifest["suites"], &(&1["suite"] == suite))
        assert count == length(modules)
      end
    end

    # sabotage: n/a - asserts the committed generated files, no lib/ behavior;
    # reformatting one W3C source in corpus/w3c.json -> red
    test "every case's source is the document its generated module runs" do
      for corpus_case <- all_cases() do
        assert corpus_case["source"] == module_xml(Emitter.generated_path(corpus_case, ".")),
               corpus_case["id"]
      end
    end

    @tag :isolated_tmp_dir
    # sabotage: n/a - asserts the committed generated files, no lib/ behavior;
    # one byte changed in an assertion line of a committed generated module,
    # outside its document and header -> red
    test "every generated module is byte for byte what its generator writes from the committed corpus",
         %{tmp_dir: tmp_dir} do
      for {suite, script} <- [{"scion", "scion"}, {"w3c", "scxml_w3"}] do
        out = Path.join(tmp_dir, suite)
        File.mkdir_p!(out)

        {output, status} =
          System.cmd(
            "elixir",
            [Path.join(["tools/corpus", script, "cases.exs"]), out, Path.expand("conformance")],
            stderr_to_stdout: true
          )

        assert status == 0, output

        written =
          (out <> "/**/*_test.exs") |> Path.wildcard() |> Enum.map(&Path.relative_to(&1, out))

        committed = Enum.map(generated(suite), &Path.relative_to(&1, @suites[suite]))

        assert committed != [], "no generated #{suite} modules to compare"
        assert Enum.sort(written) == committed

        for path <- committed do
          assert File.read!(Path.join(@suites[suite], path)) == File.read!(Path.join(out, path)),
                 "#{Path.join(@suites[suite], path)} differs from what " <>
                   "tools/corpus/#{script}/cases.exs writes from conformance/corpus/"
        end
      end
    end

    # sabotage: n/a - asserts the committed licence texts; truncating
    # LICENSES/BSD-3-Clause-W3C.txt after its conditions -> red
    test "every upstream case names its licence and a notice file that carries it" do
      w3c = File.read!("conformance/LICENSES/BSD-3-Clause-W3C.txt")
      apache = File.read!("conformance/LICENSES/Apache-2.0.txt")

      assert w3c =~ "Copyright © 2015 W3C® (MIT, ERCIM, Keio, Beihang), All Rights Reserved."
      assert w3c =~ "Redistributions of works must retain the original copyright notice"

      assert w3c =~
               "THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \"AS IS\""

      assert apache =~ "Apache License\n                           Version 2.0, January 2004"

      for %{"suite" => suite, "upstream" => upstream} = corpus_case <- all_cases() do
        expected =
          if suite == "w3c",
            do: {"BSD-3-Clause-W3C", "LICENSES/BSD-3-Clause-W3C.txt"},
            else: {"Apache-2.0", "LICENSES/Apache-2.0.txt"}

        assert {upstream["license"], upstream["notice"]} == expected, corpus_case["id"]
      end
    end
  end

  describe "the registry" do
    # sabotage: n/a - asserts the committed generated file against the
    # committed ratchet, no lib/ behavior; deleting one entry line from
    # conformance/registry.json -> red
    test "has one entry per SCION and W3C ratchet path, read from both files" do
      registry = "conformance/registry.json" |> File.read!() |> JSON.decode!()
      {:ok, ratchet} = RegressionRegistry.load()

      ratcheted = length(ratchet["scion_tests"]) + length(ratchet["w3c_tests"])

      assert ratcheted > 0, "the ratchet names no conformance test, so nothing is checked"
      assert length(registry["entries"]) == ratcheted
    end

    # sabotage: n/a - asserts the committed generated file, no lib/ behavior;
    # changing one entry's suite in conformance/registry.json -> red
    test "every entry is a corpus case with the same suite, none from an internal glob" do
      suites = Map.new(all_cases(), &{&1["id"], &1["suite"]})
      registry = "conformance/registry.json" |> File.read!() |> JSON.decode!()
      {:ok, ratchet} = RegressionRegistry.load()

      internal =
        ratchet
        |> RegressionRegistry.expand(:internal)
        |> elem(0)
        |> MapSet.new()

      assert registry["entries"] != []

      for %{"case_id" => id, "suite" => suite} <- registry["entries"] do
        assert Map.fetch(suites, id) == {:ok, suite}, id

        corpus_case = Enum.find(all_cases(), &(&1["id"] == id))
        refute MapSet.member?(internal, Emitter.generated_path(corpus_case, ".")), id
      end

      manifest = "conformance/manifest.json" |> File.read!() |> JSON.decode!()
      assert registry["corpus_hash"] == manifest["corpus_hash"]
    end
  end

  describe "the modified-document notice" do
    # sabotage: Upstream's @modified notice text changed without a re-emit -> red
    test "exactly the SCION cases whose document the fetch changes carry upstream.modified" do
      carrying =
        for %{"id" => id, "upstream" => %{"modified" => notice}} <- all_cases(),
            do: {id, notice}

      expected = Enum.map(Upstream.modified(), fn {key, notice} -> {"scion/" <> key, notice} end)

      assert carrying != [], "no case carries a modified notice, so nothing is checked"
      assert Enum.sort(carrying) == Enum.sort(expected)
    end
  end

  describe "mix statifier.corpus --check over the committed corpus" do
    @tag :isolated_tmp_dir
    # sabotage: check/1 running no case (results = []) -> red
    test "passes with no upstream tree, and the cases outside the ratchet are exactly the unlisted modules",
         %{tmp_dir: tmp_dir} do
      absent = Path.join(tmp_dir, "no-upstream")

      assert {:ok, report} = Emitter.check(Emitter.config(scratch: absent))
      assert report.upstream == {:skipped, absent}

      {:ok, registry} = RegressionRegistry.load()

      unlisted =
        for {category, suite} <- [scion: "scion", w3c: "w3c"],
            listed = registry |> RegressionRegistry.expand(category) |> elem(0) |> MapSet.new(),
            path <- generated(suite),
            path not in listed,
            do: path

      outside =
        for {id, _outcome} <- report.outside_ratchet,
            not String.starts_with?(id, "statifier/"),
            do: id

      by_path = Map.new(all_cases(), &{Emitter.generated_path(&1, "."), &1["id"]})

      assert unlisted != [], "every generated module is ratcheted, so nothing is checked here"
      assert Enum.sort(outside) == unlisted |> Enum.map(&by_path[&1]) |> Enum.sort()

      for {suite, run, _agreeing} <- report.counts,
          suite != "statifier",
          do: assert(run == length(generated(suite)))

      # An authored case has no generated module and no ratchet entry; every
      # one ran, and the check refuses one that disagrees.
      statifier = length(cases("statifier"))
      assert {"statifier", ^statifier, ^statifier} = List.keyfind(report.counts, "statifier", 0)
    end
  end
end
