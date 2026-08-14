defmodule Mix.Tasks.Test.BaselineTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Statifier.TmpDir, only: [setup_tmp_dir: 1]

  alias Mix.Statifier.RegressionRegistry
  alias Mix.Tasks.Test.Baseline

  setup :setup_tmp_dir

  @today ~D[2026-08-02]

  # `failing` names the files the stub runner should report as failures; every
  # other file "passes". The task must never write a file it did not run.
  defp runner(failing \\ []) do
    parent = self()

    fn args ->
      file = List.last(args)
      send(parent, {:ran, file})
      if file in failing, do: 1, else: 0
    end
  end

  defp registry(tmp_dir, contents \\ %{}) do
    path = Path.join(tmp_dir, "passing_tests.json")
    File.write!(path, RegressionRegistry.encode(contents))
    path
  end

  defp corpus(tmp_dir, relative) do
    path = Path.join([tmp_dir, "test", relative])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    path
  end

  defp reload(path) do
    {:ok, registry} = RegressionRegistry.load(path)
    registry
  end

  defp opts(tmp_dir, extra \\ []) do
    Keyword.merge([root: tmp_dir, runner: runner(), today: @today], extra)
  end

  describe "scan" do
    @tag :isolated_tmp_dir
    test "reports newly passing candidates without writing", %{tmp_dir: tmp_dir} do
      passing = corpus(tmp_dir, "scion_tests/basic0_test.exs")
      failing = corpus(tmp_dir, "scion_tests/basic1_test.exs")
      path = registry(tmp_dir)

      output =
        capture_io(fn ->
          assert :ok =
                   Baseline.execute(
                     ["--registry", path],
                     opts(tmp_dir, runner: runner([failing]))
                   )
        end)

      assert output =~ "Checking 2 untracked conformance test files..."
      assert output =~ "1 newly passing, 1 still failing"
      assert output =~ "+ #{passing}"
      assert output =~ "mix test.baseline --add"
      assert reload(path) == %{}
    end

    @tag :isolated_tmp_dir
    test "--add ratchets the passing candidates in", %{tmp_dir: tmp_dir} do
      passing = corpus(tmp_dir, "scion_tests/basic0_test.exs")
      failing = corpus(tmp_dir, "scxml_tests/test144_test.exs")
      path = registry(tmp_dir)

      capture_io(fn ->
        assert :ok =
                 Baseline.execute(
                   ["--add", "--registry", path],
                   opts(tmp_dir, runner: runner([failing]))
                 )
      end)

      assert reload(path) == %{"scion_tests" => [passing], "last_updated" => "2026-08-02"}
    end

    @tag :isolated_tmp_dir
    test "skips tests the registry already tracks", %{tmp_dir: tmp_dir} do
      tracked = corpus(tmp_dir, "scion_tests/basic0_test.exs")
      path = registry(tmp_dir, %{"scion_tests" => [tracked]})

      output =
        capture_io(fn -> assert :ok = Baseline.execute(["--registry", path], opts(tmp_dir)) end)

      assert output =~ "No untracked conformance tests found"
      refute_received {:ran, _file}
    end

    @tag :isolated_tmp_dir
    test "--only restricts the scan to one suite", %{tmp_dir: tmp_dir} do
      scion = corpus(tmp_dir, "scion_tests/basic0_test.exs")
      corpus(tmp_dir, "scxml_tests/test144_test.exs")
      path = registry(tmp_dir)

      capture_io(fn ->
        assert :ok = Baseline.execute(["--only", "scion", "--registry", path], opts(tmp_dir))
      end)

      assert_received {:ran, ^scion}
      refute_received {:ran, _other}
    end

    # sabotage: have categories("w3c") return {:ok, [:scion]} instead of
    #           {:ok, [:w3c]} -> red
    @tag :isolated_tmp_dir
    test "--only w3c restricts the scan to the w3c suite", %{tmp_dir: tmp_dir} do
      w3c = corpus(tmp_dir, "scxml_tests/test144_test.exs")
      corpus(tmp_dir, "scion_tests/basic0_test.exs")
      path = registry(tmp_dir)

      capture_io(fn ->
        assert :ok = Baseline.execute(["--only", "w3c", "--registry", path], opts(tmp_dir))
      end)

      assert_received {:ran, ^w3c}
      refute_received {:ran, _other}
    end

    @tag :isolated_tmp_dir
    test "rejects an unknown suite", %{tmp_dir: tmp_dir} do
      path = registry(tmp_dir)

      assert {:error, message} =
               Baseline.execute(["--only", "tck", "--registry", path], opts(tmp_dir))

      assert message =~ "unknown suite"
    end

    @tag :isolated_tmp_dir
    test "reports when nothing passes", %{tmp_dir: tmp_dir} do
      failing = corpus(tmp_dir, "scion_tests/basic0_test.exs")
      path = registry(tmp_dir)

      output =
        capture_io(fn ->
          assert :ok =
                   Baseline.execute(
                     ["--add", "--registry", path],
                     opts(tmp_dir, runner: runner([failing]))
                   )
        end)

      assert output =~ "0 newly passing, 1 still failing"
      assert output =~ "Nothing to add."
      assert reload(path) == %{}
    end

    # sabotage: have scan/4's coverage numerator use only `passing`, dropping
    #           `tracked` -> red
    @tag :isolated_tmp_dir
    test "the coverage block counts ratcheted files plus newly passing ones",
         %{tmp_dir: tmp_dir} do
      tracked = corpus(tmp_dir, "scion_tests/already_test.exs")
      _newly_passing = corpus(tmp_dir, "scion_tests/basic0_test.exs")
      still_failing = corpus(tmp_dir, "scion_tests/basic1_test.exs")
      path = registry(tmp_dir, %{"scion_tests" => [tracked]})

      output =
        capture_io(fn ->
          assert :ok =
                   Baseline.execute(
                     ["--registry", path],
                     opts(tmp_dir, runner: runner([still_failing]))
                   )
        end)

      assert output =~ "Corpus coverage (ratcheted + newly passing / emitted corpus files):"
      assert output =~ "SCION: 2/3 (66.7%)"
      assert output =~ "tools/corpus/README.md"
    end

    # sabotage: have scan/4 print the coverage block only on the non-empty
    #           candidates branch, not the "nothing untracked" one -> red
    @tag :isolated_tmp_dir
    test "the nothing-untracked path still prints the coverage block", %{tmp_dir: tmp_dir} do
      tracked = corpus(tmp_dir, "scion_tests/basic0_test.exs")
      path = registry(tmp_dir, %{"scion_tests" => [tracked]})

      output =
        capture_io(fn -> assert :ok = Baseline.execute(["--registry", path], opts(tmp_dir)) end)

      assert output =~ "No untracked conformance tests found"
      assert output =~ "Corpus coverage (ratcheted + newly passing / emitted corpus files):"
      assert output =~ "SCION: 1/1 (100.0%)"
    end

    # sabotage: have print_coverage/3's scan call pass
    #           RegressionRegistry.conformance_categories() instead of the
    #           `--only`-filtered `categories` -> red
    @tag :isolated_tmp_dir
    test "--only scion prints only the SCION coverage line", %{tmp_dir: tmp_dir} do
      scion = corpus(tmp_dir, "scion_tests/basic0_test.exs")
      corpus(tmp_dir, "scxml_tests/test144_test.exs")
      path = registry(tmp_dir)

      output =
        capture_io(fn ->
          assert :ok = Baseline.execute(["--only", "scion", "--registry", path], opts(tmp_dir))
        end)

      assert output =~ "SCION:"
      refute output =~ "W3C:"
      assert_received {:ran, ^scion}
    end
  end

  describe "add" do
    @tag :isolated_tmp_dir
    test "verifies each file, then ratchets it in", %{tmp_dir: tmp_dir} do
      scion = corpus(tmp_dir, "scion_tests/basic0_test.exs")
      w3c = corpus(tmp_dir, "scxml_tests/test144_test.exs")
      path = registry(tmp_dir, %{"scion_tests" => ["already_test.exs"]})

      output =
        capture_io(fn ->
          assert :ok = Baseline.execute(["add", scion, w3c, "--registry", path], opts(tmp_dir))
        end)

      assert output =~ "Verifying 2 test file(s) before adding..."
      assert output =~ "Added 2 test file(s)"

      registry = reload(path)
      assert registry["scion_tests"] == Enum.sort(["already_test.exs", scion])
      assert registry["w3c_tests"] == [w3c]
      assert registry["last_updated"] == "2026-08-02"
    end

    @tag :isolated_tmp_dir
    test "a failing file leaves the registry untouched", %{tmp_dir: tmp_dir} do
      good = corpus(tmp_dir, "scion_tests/basic0_test.exs")
      bad = corpus(tmp_dir, "scion_tests/basic1_test.exs")
      path = registry(tmp_dir)

      capture_io(fn ->
        assert {:error, message} =
                 Baseline.execute(
                   ["add", good, bad, "--registry", path],
                   opts(tmp_dir, runner: runner([bad]))
                 )

        assert message =~ "do not pass"
        assert message =~ bad
      end)

      assert reload(path) == %{}
    end

    @tag :isolated_tmp_dir
    test "an internal test is skipped, not added", %{tmp_dir: tmp_dir} do
      internal = corpus(tmp_dir, "statifier/document_test.exs")
      path = registry(tmp_dir)

      output =
        capture_io(fn ->
          assert :ok = Baseline.execute(["add", internal, "--registry", path], opts(tmp_dir))
        end)

      assert output =~ "internal tests are covered by the registry's globs"
      assert output =~ "Nothing to add."
      assert reload(path) == %{}
    end

    @tag :isolated_tmp_dir
    test "add with no files explains itself", %{tmp_dir: tmp_dir} do
      path = registry(tmp_dir)

      assert {:error, message} = Baseline.execute(["add", "--registry", path], opts(tmp_dir))
      assert message =~ "usage: mix test.baseline add"
    end

    @tag :isolated_tmp_dir
    test "an unknown command is not silently a scan", %{tmp_dir: tmp_dir} do
      path = registry(tmp_dir)

      assert {:error, message} = Baseline.execute(["drop", "--registry", path], opts(tmp_dir))
      assert message =~ "unknown command"
    end

    # sabotage: n/a - asserts the absence of behavior add_named/4 never had;
    #           there is no lib/ code path to break that would print a
    #           coverage block from `add`
    @tag :isolated_tmp_dir
    test "add prints no coverage block", %{tmp_dir: tmp_dir} do
      scion = corpus(tmp_dir, "scion_tests/basic0_test.exs")
      path = registry(tmp_dir)

      output =
        capture_io(fn ->
          assert :ok = Baseline.execute(["add", scion, "--registry", path], opts(tmp_dir))
        end)

      refute output =~ "Corpus coverage"
    end
  end

  describe "run/1" do
    @tag :isolated_tmp_dir
    test "returns :ok when there is nothing to check", %{tmp_dir: tmp_dir} do
      path = registry(tmp_dir, %{"scion_tests" => []})

      capture_io(fn ->
        assert :ok = Baseline.execute(["--registry", path], opts(tmp_dir))
      end)
    end

    test "turns a failure into a Mix error, so the shell exits non-zero" do
      assert_raise Mix.Error, ~r/could not read/, fn ->
        Baseline.run(["--registry", "no/such.json"])
      end
    end

    # Exercises the real `mix test` shell-out (mix_test/1, the default
    # `opts[:runner]`) rather than a stub, and calls run/1 itself - the only
    # way to reach run/1's `:ok -> :ok` clause, which no other test in this
    # file reaches. run/1 has no `opts` parameter to inject a stub through, so
    # this spawns exactly one real nested `mix test` process (`add` verifies
    # one file at a time) against a throwaway file that always passes,
    # instead of the whole suite. The file is `internal`-categorized (no
    # scion_tests/scxml_tests in its path), so it is verified but not written
    # to the registry - internal tests are covered by the registry's globs
    # already.
    # sabotage: have mix_test/1 return a hardcoded 1 instead of the real
    #           status -> red (the always-passing dummy file would then be
    #           reported as not passing)
    @tag :isolated_tmp_dir
    test "run/1 returns :ok for a real passing add", %{tmp_dir: tmp_dir} do
      dummy = Path.join(tmp_dir, "baseline_dummy_test.exs")

      File.write!(dummy, """
      defmodule Statifier.BaselineDummyTest do
        use ExUnit.Case, async: true

        test "trivially true" do
          assert true
        end
      end
      """)

      path = registry(tmp_dir)

      capture_io(fn ->
        assert :ok = Baseline.run(["add", dummy, "--registry", path])
      end)
    end
  end

  @tag :isolated_tmp_dir
  test "a broken registry is reported before anything runs", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "passing_tests.json")
    File.write!(path, "{oops")

    assert {:error, message} = Baseline.execute(["--registry", path], opts(tmp_dir))
    assert message =~ "invalid JSON"
    refute_received {:ran, _file}
  end
end
