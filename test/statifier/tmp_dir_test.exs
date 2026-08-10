defmodule Statifier.TmpDirTest do
  # async: false - root/0 exercises STATIFIER_TMP_ROOT, which is process-global
  # environment. A concurrent test in another module could observe a value set
  # here mid-run.
  use ExUnit.Case, async: false

  alias Statifier.TmpDir

  # Every override below derives from this process's own current root
  # (`TmpDir.root()`) rather than a hardcoded literal, and every mutation is
  # restored in `on_exit`. A hardcoded literal is exactly what let two
  # concurrent `mix test` OS processes running this file agree on the same
  # `STATIFIER_TMP_ROOT` value transiently and race each other's
  # `setup_tmp_dir/1` `rm_rf!` calls; deriving from this process's
  # own root keeps every override unique to it regardless.
  defp restore_env(nil), do: System.delete_env(TmpDir.env_var())
  defp restore_env(value), do: System.put_env(TmpDir.env_var(), value)

  describe "root/0" do
    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "defaults to \"tmp\" when STATIFIER_TMP_ROOT is unset" do
      previous = System.get_env(TmpDir.env_var())
      System.delete_env(TmpDir.env_var())

      on_exit(fn -> restore_env(previous) end)

      assert TmpDir.root() == Path.join(TmpDir.default_root(), TmpDir.process_id())
    end

    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "honors STATIFIER_TMP_ROOT when set" do
      previous = System.get_env(TmpDir.env_var())
      override = Path.join(TmpDir.root(), "probe")
      System.put_env(TmpDir.env_var(), override)

      on_exit(fn -> restore_env(previous) end)

      assert TmpDir.root() == Path.join(override, TmpDir.process_id())
    end
  end

  describe "env_var/0 and default_root/0" do
    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "name the environment variable and its default" do
      assert TmpDir.env_var() == "STATIFIER_TMP_ROOT"
      assert TmpDir.default_root() == "tmp"
    end
  end

  describe "path_for/2" do
    setup do
      previous = System.get_env(TmpDir.env_var())
      System.put_env(TmpDir.env_var(), Path.join(TmpDir.root(), "path_for_test"))

      on_exit(fn -> restore_env(previous) end)

      :ok
    end

    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "nests under root/0" do
      path = TmpDir.path_for(__MODULE__, :some_test)

      assert String.starts_with?(path, Path.expand(TmpDir.root()))
    end

    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "returns an absolute path" do
      path = TmpDir.path_for(__MODULE__, :some_test)

      assert Path.expand(path) == path
    end

    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "distinguishes two different test names in the same module" do
      first = TmpDir.path_for(__MODULE__, :first_test)
      second = TmpDir.path_for(__MODULE__, :second_test)

      refute first == second
    end

    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "accepts a string test name" do
      atom_path = TmpDir.path_for(__MODULE__, :"some test")
      string_path = TmpDir.path_for(__MODULE__, "some test")

      assert atom_path == string_path
    end
  end

  describe "setup_tmp_dir/1" do
    setup do
      previous = System.get_env(TmpDir.env_var())
      override = Path.join(TmpDir.root(), "setup_tmp_dir_test")
      System.put_env(TmpDir.env_var(), override)
      scratch_root = TmpDir.root()

      on_exit(fn ->
        restore_env(previous)
        File.rm_rf!(Path.expand(scratch_root))
      end)

      :ok
    end

    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "creates an empty directory for a tagged context" do
      context = %{isolated_tmp_dir: true, module: __MODULE__, test: :creates_test}

      assert {:ok, [tmp_dir: path]} = TmpDir.setup_tmp_dir(context)
      assert File.dir?(path)
      assert File.ls!(path) == []
    end

    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "empties a directory that already has files in it" do
      context = %{isolated_tmp_dir: true, module: __MODULE__, test: :dirty_test}

      path = TmpDir.path_for(__MODULE__, :dirty_test)
      File.mkdir_p!(path)
      File.write!(Path.join(path, "stale.txt"), "leftover")

      assert {:ok, [tmp_dir: ^path]} = TmpDir.setup_tmp_dir(context)
      assert File.ls!(path) == []
    end

    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "is a no-op for an untagged context" do
      assert TmpDir.setup_tmp_dir(%{module: __MODULE__, test: :untagged_test}) == :ok
    end
  end

  describe "wired through the :isolated_tmp_dir tag" do
    setup {TmpDir, :setup_tmp_dir}

    @tag :isolated_tmp_dir
    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "the tag hands the test a real, empty directory under root/0", %{tmp_dir: tmp_dir} do
      assert File.dir?(tmp_dir)
      assert File.ls!(tmp_dir) == []
      assert String.starts_with?(tmp_dir, Path.expand(TmpDir.root()))
    end
  end

  # sabotage: n/a - harness plumbing, guards a convention rather than lib/
  test "no test file uses ExUnit's built-in tmp_dir tag" do
    # Built at runtime so this file does not match its own assertion.
    pattern = ~r/@(?:describe)?tag\s+:#{"tmp" <> "_dir"}\b/

    offenders =
      "test/**/*.exs"
      |> Path.wildcard()
      |> Enum.filter(&(&1 |> File.read!() |> then(fn src -> Regex.match?(pattern, src) end)))

    assert offenders == [],
           "use @tag :isolated_tmp_dir (Statifier.TmpDir) - ExUnit's tag hardcodes a shared tmp/ root, letting concurrent runs compute byte-identical scratch paths and race: " <>
             Enum.join(offenders, ", ")
  end
end
