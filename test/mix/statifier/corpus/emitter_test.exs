defmodule Mix.Statifier.Corpus.EmitterTest do
  use ExUnit.Case, async: true

  import Statifier.TmpDir, only: [setup_tmp_dir: 1]

  doctest Mix.Statifier.Corpus.Emitter

  alias Mix.Statifier.Corpus.{Emitter, Upstream}
  alias Statifier.CorpusSchemaChecker, as: Checker

  # The emitter against a fixture upstream tree (test/fixtures/corpus_emitter/
  # scratch, read-only) and a fixture project root copied into a scratch
  # directory per test: its own exclusion lists and ratchet, plus the
  # repository's licence texts and the two tools/corpus scripts the emitter
  # loads. Nothing here needs the gitignored upstream fetch.
  #
  # The fixture tree: SCION ads/impression (ratcheted, agrees), ads/unclaimed
  # (outside the ratchet, disagrees) and retired/expired (excluded by the
  # directory key); W3C test9001 (ratcheted, agrees), test9003 (outside the
  # ratchet, disagrees), test9002 (excluded), test9002sub1 (a sub-document)
  # and optional test9004 (left on the ecmascript datamodel).

  # The two tools/corpus scripts the emitter loads, required from this
  # repository once, as their own tests do: the copies under each fixture root
  # exist for the emitter's presence checks and are never loaded a second time.
  for script <- ~w(tools/corpus/normalize.exs tools/corpus/scxml_w3/sub_documents.exs),
      do: Code.require_file(script)

  @fixtures "test/fixtures/corpus_emitter"
  @scratch Path.join(@fixtures, "scratch")
  @schema_dir "conformance/schema"
  @copied ~w(conformance/LICENSES tools/corpus/normalize.exs tools/corpus/scxml_w3/sub_documents.exs)

  setup :setup_tmp_dir

  setup :fixture_root

  # Doctests carry no tmp_dir tag and need no fixture root.
  defp fixture_root(%{tmp_dir: root}) do
    File.cp_r!(Path.join(@fixtures, "root"), root)

    for path <- @copied do
      target = Path.join(root, path)
      File.mkdir_p!(Path.dirname(target))
      File.cp_r!(path, target)
    end

    %{root: root, config: Emitter.config(root: root, scratch: @scratch)}
  end

  defp fixture_root(_context), do: :ok

  defp read(root, file), do: root |> Path.join("conformance/#{file}") |> File.read!()
  defp decoded(root, file), do: root |> read(file) |> JSON.decode!()

  defp cases(root, suite), do: decoded(root, "corpus/#{suite}.json")["cases"]

  defp emit!(config) do
    assert {:ok, report} = Emitter.emit(config)
    report
  end

  defp edit(root, file, fun),
    do: File.write!(Path.join(root, "conformance/#{file}"), fun.(read(root, file)))

  defp absent_scratch(root), do: Path.join(root, "no-upstream")

  defp rewrite_ratchet(root, fun) do
    path = Path.join(root, "test/passing_tests.json")

    path
    |> File.read!()
    |> JSON.decode!()
    |> fun.()
    |> JSON.encode!()
    |> then(&File.write!(path, &1))
  end

  defp touch(root, relative) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end

  describe "emit/1" do
    @tag :isolated_tmp_dir
    # sabotage: render/2 keeping a suite with no cases (dropping the
    # suite_cases != [] filter) -> red, a statifier.json appears
    test "writes a corpus file per suite with cases, the manifest and the exclusions", %{
      config: config,
      root: root
    } do
      report = emit!(config)

      assert report.written ==
               ~w(corpus/scion.json corpus/w3c.json exclusions.json manifest.json registry.json)

      refute File.exists?(Path.join(root, "conformance/corpus/statifier.json"))

      assert Enum.map(cases(root, "scion"), & &1["id"]) == [
               "scion/ads/impression",
               "scion/ads/unclaimed"
             ]

      assert Enum.map(cases(root, "w3c"), & &1["id"]) == ["w3c/test9001", "w3c/test9003"]
    end

    @tag :isolated_tmp_dir
    # sabotage: Runner.run/1 streaming every case to :agree without running
    # it -> red on the outcomes
    test "runs every case and reports the ones outside the ratchet with their outcome", %{
      config: config
    } do
      report = emit!(config)

      assert report.counts == [{"scion", 2, 1}, {"w3c", 2, 1}]

      assert [{"scion/ads/unclaimed", {:disagree, unclaimed}}, {"w3c/test9003", {:disagree, w3c}}] =
               report.outside_ratchet

      assert unclaimed =~ ~s|Expected active states ["clicked"], but got ["viewed"]|
      assert w3c =~ ~s|Expected active states ["pass"], but got ["fail"]|
    end

    @tag :isolated_tmp_dir
    # sabotage: Upstream's w3c_case/3 passing the raw document on instead of
    # XmlFormat's -> red on the source
    test "writes each case in the case schema's shape, with the upstream expectation", %{
      config: config,
      root: root
    } do
      emit!(config)
      case_schema = Checker.load(@schema_dir, "case.json")

      for suite <- ~w(scion w3c), corpus_case <- cases(root, suite) do
        assert Checker.errors(case_schema, corpus_case, @schema_dir) == [], corpus_case["id"]
      end

      [impression, _unclaimed] = cases(root, "scion")
      [w3c | _rest] = cases(root, "w3c")

      assert impression["steps"] == [
               %{"event" => %{"name" => "view"}, "configuration" => ["viewed"]},
               %{"event" => %{"name" => "click"}, "configuration" => ["clicked"]}
             ]

      assert impression["upstream"] == %{
               "document" => "test/ads/impression.scxml",
               "license" => "Apache-2.0",
               "notice" => "LICENSES/Apache-2.0.txt"
             }

      assert impression["source"] ==
               File.read!(Path.join(@scratch, "scion/cases/ads/impression.scxml"))

      assert %{
               "spec" => "impressions",
               "conformance" => "mandatory",
               "description" => "An impression is counted once.",
               "initial_configuration" => ["pass"],
               "steps" => [],
               "upstream" => %{
                 "document" => "9001/test9001.txml",
                 "license" => "BSD-3-Clause-W3C"
               }
             } = w3c

      refute w3c["source"] =~ "<!--"
      refute w3c["source"] =~ "xmlns:conf"
    end

    @tag :isolated_tmp_dir
    # sabotage: Json.corpus_file/2 joining the compact cases with "," on one
    # line -> red
    test "writes files that validate against their schemas, one case per line", %{
      config: config,
      root: root
    } do
      emit!(config)

      for {file, schema} <- [
            {"corpus/scion.json", "corpus.json"},
            {"corpus/w3c.json", "corpus.json"},
            {"manifest.json", "manifest.json"},
            {"exclusions.json", "exclusions.json"},
            {"registry.json", "registry.json"}
          ] do
        assert Checker.errors(Checker.load(@schema_dir, schema), decoded(root, file), @schema_dir) ==
                 [],
               file
      end

      case_lines =
        root |> read("corpus/w3c.json") |> String.split("\n") |> Enum.filter(&(&1 =~ ~s|"id":|))

      assert length(case_lines) == 2
    end

    @tag :isolated_tmp_dir
    # sabotage: render/2's manifest carrying
    # "emitted_at" => System.monotonic_time() -> red
    test "a second emit of the same tree is byte-identical", %{config: config, root: root} do
      emit!(config)
      files = ~w(corpus/scion.json corpus/w3c.json manifest.json exclusions.json registry.json)
      first = Map.new(files, &{&1, read(root, &1)})

      emit!(config)
      assert Map.new(files, &{&1, read(root, &1)}) == first
    end

    @tag :isolated_tmp_dir
    # sabotage: corpus_hash/1 hashing the files in reverse suite order -> red
    test "the manifest pins the corpus by the sha256 of its files in suite order", %{
      config: config,
      root: root
    } do
      emit!(config)
      manifest = decoded(root, "manifest.json")
      bytes = read(root, "corpus/scion.json") <> read(root, "corpus/w3c.json")

      assert manifest["corpus_hash"] ==
               "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      assert manifest["suites"] == [
               %{"suite" => "scion", "file" => "corpus/scion.json", "case_count" => 2},
               %{"suite" => "w3c", "file" => "corpus/w3c.json", "case_count" => 2}
             ]
    end

    @tag :isolated_tmp_dir
    # sabotage: render/2's manifest carrying
    # "statifier_version" => Mix.Project.config()[:version] again -> red
    test "the manifest carries no version, so a version bump cannot move --check", %{
      config: config,
      root: root
    } do
      emit!(config)
      manifest = read(root, "manifest.json")

      assert manifest |> JSON.decode!() |> Map.keys() |> Enum.sort() ==
               ~w(corpus_hash suites upstreams)

      refute manifest =~ Mix.Project.config()[:version]
    end

    @tag :isolated_tmp_dir
    # sabotage: Exclusions.to_document/1 dropping the adr member -> red
    test "writes the exclusions with each cited record's number, directory keys unexpanded", %{
      config: config,
      root: root
    } do
      emit!(config)

      assert decoded(root, "exclusions.json")["exclusions"] == [
               %{
                 "suite" => "scion",
                 "key" => "retired",
                 "reason" => "needs_external_fetch",
                 "detail" => "a retired campaign's documents (ADR-0026 decision 2)",
                 "adr" => 26
               },
               %{
                 "suite" => "w3c",
                 "key" => "test9002",
                 "reason" => "needs_basichttp",
                 "detail" => "posts the click to a tracking endpoint"
               }
             ]
    end

    @tag :isolated_tmp_dir
    # sabotage: registry/4 passing every case's path as the ratchet -> red,
    # the unclaimed cases appear
    test "writes the registry from the ratchet, pinned by the manifest's corpus hash", %{
      config: config,
      root: root
    } do
      report = emit!(config)

      assert decoded(root, "registry.json") == %{
               "implementation" => "statifier-ex",
               "corpus_hash" => decoded(root, "manifest.json")["corpus_hash"],
               "claims" => ["scion", "w3c-mandatory"],
               "entries" => [
                 %{"case_id" => "scion/ads/impression", "suite" => "scion"},
                 %{"case_id" => "w3c/test9001", "suite" => "w3c"}
               ]
             }

      assert report.claims == [{"scion", 1}, {"w3c-mandatory", 1}]
    end

    @tag :isolated_tmp_dir
    # sabotage: ratchet/1 reading every category, internal included -> red,
    # scion/ads/unclaimed is claimed (and disagrees)
    test "no entry derives from an internal_tests glob", %{config: config, root: root} do
      rewrite_ratchet(root, fn ratchet ->
        Map.put(ratchet, "internal_tests", ["test/scion_tests/**/*_test.exs"])
      end)

      for name <- ~w(impression unclaimed),
          do: touch(root, "test/scion_tests/ads/#{name}_test.exs")

      emit!(config)

      assert Enum.map(decoded(root, "registry.json")["entries"], & &1["case_id"]) ==
               ["scion/ads/impression", "w3c/test9001"]
    end

    @tag :isolated_tmp_dir
    # sabotage: emit/1 writing the files when registry/4 refuses (dropping it
    # from the with) -> red, files exist
    test "stops when a ratchet path names no corpus case, naming it, and writes nothing", %{
      config: config,
      root: root
    } do
      rewrite_ratchet(root, fn ratchet ->
        Map.update!(ratchet, "scion_tests", &["test/scion_tests/ads/retired_test.exs" | &1])
      end)

      assert {:error, message} = Emitter.emit(config)
      assert message =~ "test/scion_tests/ads/retired_test.exs: names no corpus case"
      refute File.exists?(Path.join(root, "conformance/manifest.json"))
      refute File.exists?(Path.join(root, "conformance/registry.json"))
    end

    @tag :isolated_tmp_dir
    # sabotage: Registry.derive/4 accepting an empty ratchet ({:ok, []}) -> red
    test "stops when the ratchet names no corpus case at all", %{config: config, root: root} do
      rewrite_ratchet(root, &Map.merge(&1, %{"scion_tests" => [], "w3c_tests" => []}))

      assert Emitter.emit(config) ==
               {:error, "the ratchet names no corpus case; an empty registry is refused"}

      refute File.exists?(Path.join(root, "conformance/registry.json"))
    end

    @tag :isolated_tmp_dir
    # sabotage: emit/1 ignoring ratcheted_agree/4's refusal -> red, files exist
    test "stops when a ratcheted case disagrees with its expectation, writing nothing", %{
      config: config,
      root: root
    } do
      ratchet = Path.join(root, "test/passing_tests.json")

      ratchet
      |> File.read!()
      |> String.replace("impressions/test9001_test.exs", "impressions/*_test.exs")
      |> then(&File.write!(ratchet, &1))

      # The glob matches generated modules on disk, as the ratchet's own do.
      for id <- ~w(test9001 test9003) do
        path = Path.join(root, "test/scxml_tests/mandatory/impressions/#{id}_test.exs")
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "")
      end

      assert {:error, message} = Emitter.emit(config)
      assert message =~ "nothing was written"
      assert message =~ "w3c/test9003 (test/scxml_tests/mandatory/impressions/test9003_test.exs)"
      refute message =~ "w3c/test9001"
      refute File.exists?(Path.join(root, "conformance/corpus"))
      refute File.exists?(Path.join(root, "conformance/manifest.json"))
    end

    @tag :isolated_tmp_dir
    # sabotage: upstream_present/1 returning :ok -> red
    test "refuses without the upstream tree, naming the fetch, and writes nothing", %{root: root} do
      config = Emitter.config(root: root, scratch: absent_scratch(root))

      assert {:error, message} = Emitter.emit(config)
      assert message =~ "the upstream tree is absent"
      assert message =~ "mise run corpus:fetch"
      refute File.exists?(Path.join(root, "conformance/manifest.json"))
    end

    @tag :isolated_tmp_dir
    # sabotage: no_stale_keys/3 finding no stale key (case [] do) -> red
    test "refuses an exclusion key that matches no upstream document", %{
      config: config,
      root: root
    } do
      path = Path.join(root, "tools/corpus/scxml_w3/exclusions.exs")

      File.write!(
        path,
        String.replace(File.read!(path), "%{", ~s|%{\n  "test9999" => {:gone, "no such test"},|)
      )

      assert {:error, message} = Emitter.emit(config)
      assert message == "W3C exclusion key(s) matched no upstream document: test9999"
    end

    @tag :isolated_tmp_dir
    # sabotage: notices_present/2 finding nothing missing (case [] do) -> red
    test "refuses when a licence notice a case points at is missing", %{
      config: config,
      root: root
    } do
      File.rm!(Path.join(root, "conformance/LICENSES/BSD-3-Clause-W3C.txt"))

      assert {:error, message} = Emitter.emit(config)

      assert message =~
               "a licence notice is missing or empty under conformance/: LICENSES/BSD-3-Clause-W3C.txt"
    end
  end

  describe "check/1" do
    @tag :isolated_tmp_dir
    # sabotage: upstream_drift/2 comparing whether or not the tree is present
    # -> red
    test "passes on an emitted tree with the upstream tree absent, saying the comparison was skipped",
         %{
           config: config,
           root: root
         } do
      emit!(config)
      scratch = absent_scratch(root)

      assert {:ok, report} = Emitter.check(Emitter.config(root: root, scratch: scratch))
      assert report.upstream == {:skipped, scratch}
      assert report.counts == [{"scion", 2, 1}, {"w3c", 2, 1}]
      refute Map.has_key?(report, :written)
    end

    @tag :isolated_tmp_dir
    # sabotage: check/1 dropping disagreements/4 from the problems -> red on
    # the named case (the manifest line alone would remain)
    test "(a) fails on one mutated case line, naming the case", %{config: config, root: root} do
      emit!(config)

      edit(root, "corpus/w3c.json", fn content ->
        String.replace(
          content,
          ~s|"initial_configuration":["pass"],"steps":[],"upstream":{"document":"9001/|,
          ~s|"initial_configuration":["fail"],"steps":[],"upstream":{"document":"9001/|
        )
      end)

      assert {:error, message} =
               Emitter.check(Emitter.config(root: root, scratch: absent_scratch(root)))

      assert message =~ "w3c/test9001 (test/scxml_tests/mandatory/impressions/test9001_test.exs)"
      assert message =~ "conformance/manifest.json: differs from what the emitter writes"
    end

    @tag :isolated_tmp_dir
    # sabotage: read_committed/1 reading only the corpus files that exist -> red
    test "(b) fails on a deleted corpus file", %{config: config, root: root} do
      emit!(config)
      File.rm!(Path.join(root, "conformance/corpus/scion.json"))

      assert {:error, message} =
               Emitter.check(Emitter.config(root: root, scratch: absent_scratch(root)))

      assert message =~ "the committed corpus is incomplete"
      assert message =~ "corpus/scion.json"
    end

    @tag :isolated_tmp_dir
    # sabotage: suite_cases/2 accepting "cases": [] as {:ok, []} -> red on the
    # second half
    test "(c) fails on an emptied corpus file, whether truncated or holding no cases", %{
      config: config,
      root: root
    } do
      emit!(config)
      check = fn -> Emitter.check(Emitter.config(root: root, scratch: absent_scratch(root))) end

      edit(root, "corpus/w3c.json", fn _content -> "" end)
      assert {:error, truncated} = check.()
      assert truncated =~ "invalid JSON in conformance/corpus/w3c.json"

      edit(root, "corpus/w3c.json", fn _content -> ~s|{"suite": "w3c", "cases": []}\n| end)
      assert {:error, no_cases} = check.()

      assert no_cases ==
               "conformance/corpus/w3c.json has no cases; an empty corpus file is refused"
    end

    @tag :isolated_tmp_dir
    # sabotage: drifted_files/2 comparing only the corpus files -> red
    test "fails when a derived file was edited by hand", %{config: config, root: root} do
      emit!(config)

      edit(
        root,
        "exclusions.json",
        &String.replace(&1, "a retired campaign's", "an old campaign's")
      )

      assert {:error, message} =
               Emitter.check(Emitter.config(root: root, scratch: absent_scratch(root)))

      assert message =~ "conformance/exclusions.json: differs from what the emitter writes"
    end

    @tag :isolated_tmp_dir
    # sabotage: feature_drift/1 returning [] -> red
    test "fails when a case's required_features is not what its source needs", %{
      config: config,
      root: root
    } do
      emit!(config)

      edit(
        root,
        "corpus/scion.json",
        &String.replace(&1, ~s|"required_features":["basic_states",|, ~s|"required_features":[|,
          global: false
        )
      )

      assert {:error, message} =
               Emitter.check(Emitter.config(root: root, scratch: absent_scratch(root)))

      assert message =~
               "scion/ads/impression: required_features is not what the feature detector finds"
    end

    @tag :isolated_tmp_dir
    # sabotage: check/1 comparing the registry against the committed file
    # instead of re-deriving it (expected = rendered) -> red
    test "fails when the registry drifts from the ratchet file", %{config: config, root: root} do
      emit!(config)
      rewrite_ratchet(root, &Map.put(&1, "w3c_tests", []))

      assert {:error, message} =
               Emitter.check(Emitter.config(root: root, scratch: absent_scratch(root)))

      assert message =~ "conformance/registry.json: differs from what the emitter writes"
    end

    @tag :isolated_tmp_dir
    # sabotage: check/1 dropping Registry.stale/2 from the problems -> red
    test "fails on a registry with zero entries, and on one naming a case the corpus lacks", %{
      config: config,
      root: root
    } do
      emit!(config)
      check = fn -> Emitter.check(Emitter.config(root: root, scratch: absent_scratch(root))) end

      edit(root, "registry.json", fn content ->
        String.replace(content, ~r/"entries": \[.*\]/s, ~s|"entries": []|)
      end)

      assert {:error, empty} = check.()
      assert empty =~ "conformance/registry.json has no entries; an empty registry is refused"

      emit!(config)
      edit(root, "registry.json", &String.replace(&1, "w3c/test9001", "w3c/test9099"))

      assert {:error, stale} = check.()
      assert stale =~ "w3c/test9099: in the registry but not in the corpus"
    end

    @tag :isolated_tmp_dir
    # sabotage: read_committed/1 leaving registry.json out of the files -> red
    test "fails when the registry is missing", %{config: config, root: root} do
      emit!(config)
      File.rm!(Path.join(root, "conformance/registry.json"))

      assert {:error, message} =
               Emitter.check(Emitter.config(root: root, scratch: absent_scratch(root)))

      assert message =~ "the committed corpus is incomplete"
      assert message =~ "registry.json"
    end

    @tag :isolated_tmp_dir
    # sabotage: case_drift/2 treating a changed case as equal
    # ({_ours, _theirs} -> []) -> red
    test "compares the corpus with the upstream tree when it is present", %{
      config: config,
      root: root
    } do
      emit!(config)
      assert {:ok, %{upstream: :compared}} = Emitter.check(config)

      edit(
        root,
        "corpus/w3c.json",
        &String.replace(&1, "counted twice is refused", "counted twice")
      )

      assert {:error, message} = Emitter.check(config)
      assert message =~ "w3c/test9003: differs from what the upstream tree emits"
    end

    @tag :isolated_tmp_dir
    # sabotage: shaped/3 accepting every case -> red (the run disagrees
    # instead of the file being refused)
    test "refuses a case it cannot run, naming the file", %{config: config, root: root} do
      emit!(config)

      edit(
        root,
        "corpus/w3c.json",
        &String.replace(&1, ~s|"steps":[]|, ~s|"steps":[{}]|, global: false)
      )

      assert {:error, message} =
               Emitter.check(Emitter.config(root: root, scratch: absent_scratch(root)))

      assert message =~
               ~s|conformance/corpus/w3c.json holds 1 case(s) that cannot be run: "w3c/test9001"|
    end
  end

  # One authored `statifier` case under the fixture root's conformance/cases/,
  # copied from the repository's own, so the emitter reads it beside the
  # fixture upstream suites.
  defp author!(root, name \\ "registered_immediate") do
    dir = Path.join(root, "conformance/cases/send")
    File.mkdir_p!(dir)

    for ext <- ~w(.json .scxml),
        do: File.cp!("conformance/cases/send/#{name}#{ext}", Path.join(dir, name <> ext))

    Path.join(dir, name <> ".json")
  end

  describe "authored statifier cases" do
    @tag :isolated_tmp_dir
    # sabotage: emit/1 dropping `authored` from its cases (cases = upstream)
    # -> red, no statifier.json is written; render/2 sorting the manifest's
    # suites by name -> red on the suite order
    test "emit runs them and writes corpus/statifier.json, after the upstream suites in the hash",
         %{config: config, root: root} do
      author!(root)
      report = emit!(config)

      assert "corpus/statifier.json" in report.written
      assert {"statifier", 1, 1} in report.counts

      assert [%{"id" => "statifier/send/registered_immediate", "host" => host}] =
               cases(root, "statifier")

      assert host["send_types"] == ["myapp:sink"]

      contents = Enum.map(~w(scion w3c statifier), &read(root, "corpus/#{&1}.json"))
      manifest = decoded(root, "manifest.json")
      assert manifest["corpus_hash"] == Emitter.corpus_hash(contents)

      # The manifest lists the files in the hash's suite order, not sorted by
      # name, which would put statifier before w3c.
      assert Enum.map(manifest["suites"], & &1["suite"]) == ~w(scion w3c statifier)

      assert Checker.errors(
               Checker.load(@schema_dir, "corpus.json"),
               decoded(root, "corpus/statifier.json"),
               @schema_dir
             ) == []
    end

    @tag :isolated_tmp_dir
    # sabotage: disagreements/4 filtering on ratcheted?/3 alone (the
    # statifier arm dropped) -> red, the disagreeing authored case is written
    test "emit stops when an authored case disagrees when run, writing nothing", %{
      config: config,
      root: root
    } do
      json = author!(root)
      File.write!(json, String.replace(File.read!(json), ~s|"imp-1"|, ~s|"imp-2"|))

      assert {:error, message} = Emitter.emit(config)
      assert message =~ "nothing was written"

      assert message =~
               "statifier/send/registered_immediate (authored): Expected the sends handed"

      refute File.exists?(Path.join(root, "conformance/manifest.json"))
    end

    @tag :isolated_tmp_dir
    # sabotage: check/1 reading the statifier suite's cases from its committed
    # file (committed_cases/1 over @suites) -> red, the hand edit renders
    # back unchanged
    test "check fails when corpus/statifier.json was edited by hand", %{
      config: config,
      root: root
    } do
      author!(root)
      emit!(config)
      edit(root, "corpus/statifier.json", &String.replace(&1, "joined_records", "other_records"))

      assert {:error, message} =
               Emitter.check(Emitter.config(root: root, scratch: absent_scratch(root)))

      assert message =~ "conformance/corpus/statifier.json: differs from what the emitter writes"
    end

    @tag :isolated_tmp_dir
    # sabotage: drifted_files/2 dropping its underived arm -> red, a corpus
    # file no input derives passes the check
    test "check fails on a committed corpus/statifier.json with no authored case behind it", %{
      config: config,
      root: root
    } do
      author!(root)
      emit!(config)
      File.rm_rf!(Path.join(root, "conformance/cases"))

      assert {:error, message} =
               Emitter.check(Emitter.config(root: root, scratch: absent_scratch(root)))

      assert message =~
               "conformance/corpus/statifier.json: committed, but the emitter writes no such file"
    end

    @tag :isolated_tmp_dir
    # sabotage: check/1 dropping `authored` from its cases -> red, the
    # authored case is never run and its disagreement passes
    test "check re-runs the authored cases and fails on one that disagrees", %{
      config: config,
      root: root
    } do
      author!(root)
      emit!(config)

      File.write!(Path.join(root, "conformance/cases/send/registered_immediate.scxml"), """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator" initial="awaiting_click">
          <state id="awaiting_click"/>
      </scxml>
      """)

      assert {:error, message} =
               Emitter.check(Emitter.config(root: root, scratch: absent_scratch(root)))

      assert message =~ "statifier/send/registered_immediate (authored): Expected active states"
    end
  end

  describe "Upstream.modified/0" do
    @tag :isolated_tmp_dir
    # sabotage: Upstream's @modified keyed on a document the fetch does not
    # edit (internal-transitions/test9) -> red
    test "names exactly the SCION documents corpus:fetch:scion edits after cloning" do
      [_before, task] =
        String.split(File.read!("mise.toml"), ~s|[tasks."corpus:fetch:scion"]|, parts: 2)

      [task | _rest] = String.split(task, "\n[tasks.", parts: 2)

      edited =
        ~r/sed -i[^\n]*"\$CORPUS_SCION_CASES\/([^"]+)\.scxml"/
        |> Regex.scan(task, capture: :all_but_first)
        |> List.flatten()
        |> Enum.sort()

      assert edited != [], "the fetch task edits no document, so nothing is checked"
      assert edited == Upstream.modified() |> Map.keys() |> Enum.sort()
    end
  end

  describe "generated_path/2" do
    @tag :isolated_tmp_dir
    # sabotage: generated_path/2 passing the scion spec unnormalized -> red
    test "names the generated module the ratchet lists a case by" do
      assert Emitter.generated_path(
               %{"suite" => "scion", "id" => "scion/actionSend/send1", "spec" => "actionSend"},
               "."
             ) ==
               "test/scion_tests/action_send/send1_test.exs"

      assert Emitter.generated_path(
               %{
                 "suite" => "w3c",
                 "id" => "w3c/test330",
                 "spec" => "SystemVariables",
                 "conformance" => "mandatory"
               },
               "."
             ) == "test/scxml_tests/mandatory/system_variables/test330_test.exs"

      assert Emitter.generated_path(%{"suite" => "statifier", "id" => "statifier/send/x"}, ".") ==
               nil
    end
  end
end
