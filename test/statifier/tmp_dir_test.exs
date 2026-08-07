defmodule Statifier.TmpDirTest do
  # async: false - root/0 exercises STATIFIER_TMP_ROOT, which is process-global
  # environment. A concurrent test in another module could observe a value set
  # here mid-run.
  use ExUnit.Case, async: false

  alias Statifier.TmpDir

  describe "root/0" do
    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "defaults to \"tmp\" when STATIFIER_TMP_ROOT is unset" do
      System.delete_env(TmpDir.env_var())

      assert TmpDir.root() == "tmp"
    end

    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "honors STATIFIER_TMP_ROOT when set" do
      previous = System.get_env(TmpDir.env_var())
      System.put_env(TmpDir.env_var(), "tmp/probe")

      on_exit(fn ->
        if previous do
          System.put_env(TmpDir.env_var(), previous)
        else
          System.delete_env(TmpDir.env_var())
        end
      end)

      assert TmpDir.root() == "tmp/probe"
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
      System.put_env(TmpDir.env_var(), "tmp/path_for_test")

      on_exit(fn ->
        if previous do
          System.put_env(TmpDir.env_var(), previous)
        else
          System.delete_env(TmpDir.env_var())
        end
      end)

      :ok
    end

    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    test "nests under root/0" do
      path = TmpDir.path_for(__MODULE__, :some_test)

      assert String.starts_with?(path, Path.expand("tmp/path_for_test"))
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
      System.put_env(TmpDir.env_var(), "tmp/setup_tmp_dir_test")

      on_exit(fn ->
        if previous do
          System.put_env(TmpDir.env_var(), previous)
        else
          System.delete_env(TmpDir.env_var())
        end

        File.rm_rf!(Path.expand("tmp/setup_tmp_dir_test"))
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

    # sabotage: n/a - harness plumbing, asserts test/support/ not lib/
    @tag :isolated_tmp_dir
    test "the tag hands the test a real, empty directory under root/0", %{tmp_dir: tmp_dir} do
      assert File.dir?(tmp_dir)
      assert File.ls!(tmp_dir) == []
      assert String.starts_with?(tmp_dir, Path.expand(TmpDir.root()))
    end
  end
end
