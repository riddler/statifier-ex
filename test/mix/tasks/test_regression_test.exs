defmodule Mix.Tasks.Test.RegressionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Statifier.RegressionRegistry
  alias Mix.Tasks.Test.Regression

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

  @tag :tmp_dir
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

  @tag :tmp_dir
  test "a failing run is a regression, not a test-count report", %{tmp_dir: tmp_dir} do
    scion = test_file(tmp_dir, "scion_tests/basic0_test.exs")
    path = registry(tmp_dir, %{"scion_tests" => [scion]})

    capture_io(fn ->
      assert {:error, message} = Regression.execute(["--registry", path], runner: runner(1))
      assert message =~ "regression failure (mix test exited 1)"
      assert message =~ "mix test.baseline"
    end)
  end

  @tag :tmp_dir
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

  @tag :tmp_dir
  test "an empty registry does not fall through to the whole suite", %{tmp_dir: tmp_dir} do
    path = registry(tmp_dir, %{"scion_tests" => [], "w3c_tests" => []})

    assert {:error, message} = Regression.execute(["--registry", path], runner: runner(0))
    assert message =~ "expands to no tests"
    refute_received {:ran, _args}
  end

  @tag :tmp_dir
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

  test "defaults to the project registry path" do
    assert {:error, message} = Regression.execute(["--registry", "no/such.json"])
    assert message =~ "no/such.json"

    assert RegressionRegistry.default_path() == "test/passing_tests.json"
  end

  @tag :tmp_dir
  test "a single-file registry reports in the singular", %{tmp_dir: tmp_dir} do
    scion = test_file(tmp_dir, "scion_tests/basic0_test.exs")
    path = registry(tmp_dir, %{"scion_tests" => [scion]})

    output =
      capture_io(fn ->
        assert :ok = Regression.execute(["--registry", path], runner: runner(0))
      end)

    assert output =~ "Running 1 regression test file..."
  end
end
