defmodule Mix.Tasks.Test.RegressionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Statifier.TmpDir, only: [setup_tmp_dir: 1]

  alias Mix.Statifier.RegressionRegistry
  alias Mix.Tasks.Test.Regression

  setup :setup_tmp_dir

  # The task's only side effect is a `mix test` shell-out, so every test drives
  # it with a stub runner that records the arguments it was handed.
  defp runner(status) do
    parent = self()

    fn args ->
      send(parent, {:ran, args})
      status
    end
  end

  defp registry(tmp_dir, contents) do
    path = Path.join(tmp_dir, "passing_tests.json")
    File.write!(path, RegressionRegistry.encode(contents))
    path
  end

  defp test_file(tmp_dir, relative) do
    path = Path.join(tmp_dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    path
  end

  @tag :isolated_tmp_dir
  test "runs exactly the registry, with the tags its suites need", %{tmp_dir: tmp_dir} do
    scion = test_file(tmp_dir, "scion_tests/basic0_test.exs")
    internal = test_file(tmp_dir, "statifier/document_test.exs")
    path = registry(tmp_dir, %{"internal_tests" => [internal], "scion_tests" => [scion]})

    output =
      capture_io(fn ->
        assert :ok = Regression.execute(["--registry", path], runner: runner(0))
      end)

    assert_received {:ran, args}
    assert args == Enum.sort([scion, internal]) ++ ["--include", "scion"]
    assert output =~ "Running 2 regression test files..."
    assert output =~ "All 2 regression test files passed."
  end

  @tag :isolated_tmp_dir
  test "a failing run is a regression, not a test-count report", %{tmp_dir: tmp_dir} do
    scion = test_file(tmp_dir, "scion_tests/basic0_test.exs")
    path = registry(tmp_dir, %{"scion_tests" => [scion]})

    capture_io(fn ->
      assert {:error, message} = Regression.execute(["--registry", path], runner: runner(1))
      assert message =~ "regression failure (mix test exited 1)"
      assert message =~ "mix test.baseline"
    end)
  end

  @tag :isolated_tmp_dir
  test "an entry matching no file fails instead of silently shrinking the ratchet", %{
    tmp_dir: tmp_dir
  } do
    path =
      registry(tmp_dir, %{"scion_tests" => [Path.join(tmp_dir, "scion_tests/gone_test.exs")]})

    assert {:error, message} = Regression.execute(["--registry", path], runner: runner(0))
    assert message =~ "lists 1 entry/entries matching no file on disk"
    assert message =~ "gone_test.exs"
    refute_received {:ran, _args}
  end

  @tag :isolated_tmp_dir
  test "an empty registry does not fall through to the whole suite", %{tmp_dir: tmp_dir} do
    path = registry(tmp_dir, %{"scion_tests" => [], "w3c_tests" => []})

    assert {:error, message} = Regression.execute(["--registry", path], runner: runner(0))
    assert message =~ "expands to no tests"
    refute_received {:ran, _args}
  end

  @tag :isolated_tmp_dir
  test "a broken registry is reported, not treated as empty", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "passing_tests.json")
    File.write!(path, "{oops")

    assert {:error, message} = Regression.execute(["--registry", path], runner: runner(0))
    assert message =~ "invalid JSON"
  end

  test "run/1 turns a failure into a Mix error, so the shell exits non-zero" do
    assert_raise Mix.Error, ~r/could not read/, fn ->
      Regression.run(["--registry", "no/such.json"])
    end
  end

  # Exercises the real `mix test` shell-out (mix_test/1, the default
  # `opts[:runner]`) rather than a stub, and calls run/1 itself rather than
  # execute/2 - the only way to reach run/1's `:ok -> :ok` clause, which no
  # other test in this file reaches. run/1 has no `opts` parameter to inject a
  # stub through, so this spawns exactly one real nested `mix test` process
  # against a throwaway file that always passes, instead of the whole suite.
  # sabotage: have mix_test/1 return a hardcoded 1 instead of the real
  #           status -> red (the always-passing dummy file would then be
  #           reported as a regression)
  @tag :isolated_tmp_dir
  test "run/1 returns :ok for a real passing run", %{tmp_dir: tmp_dir} do
    dummy = Path.join(tmp_dir, "regression_dummy_test.exs")

    File.write!(dummy, """
    defmodule Statifier.RegressionDummyTest do
      use ExUnit.Case, async: true

      test "trivially true" do
        assert true
      end
    end
    """)

    path = registry(tmp_dir, %{"internal_tests" => [dummy]})

    capture_io(fn ->
      assert :ok = Regression.run(["--registry", path])
    end)
  end

  test "defaults to the project registry path" do
    assert {:error, message} = Regression.execute(["--registry", "no/such.json"])
    assert message =~ "no/such.json"

    assert RegressionRegistry.default_path() == "test/passing_tests.json"
  end

  @tag :isolated_tmp_dir
  test "a single-file registry reports in the singular", %{tmp_dir: tmp_dir} do
    scion = test_file(tmp_dir, "scion_tests/basic0_test.exs")
    path = registry(tmp_dir, %{"scion_tests" => [scion]})

    output =
      capture_io(fn ->
        assert :ok = Regression.execute(["--registry", path], runner: runner(0))
      end)

    assert output =~ "Running 1 regression test file..."
  end

  # sabotage: change test_env/0 to return [] -> red
  test "the spawned run gets its own scratch root" do
    assert [{var, root}] = Regression.test_env()
    assert var == Statifier.TmpDir.env_var()
    refute root == Statifier.TmpDir.default_root()
  end
end
