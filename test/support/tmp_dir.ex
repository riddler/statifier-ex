defmodule Statifier.TmpDir do
  @moduledoc """
  Per-test scratch directories with a settable root.

  Stands in for ExUnit's `@tag :tmp_dir`, which hardcodes a `tmp/` root under
  the current working directory (`ex_unit/lib/ex_unit/runner.ex`) with no way
  to configure it. That root is process-global, so two `mix test` runs in the
  same directory - which is exactly what the `Tests` and `Regression ratchet`
  stages of a bare `mix quality` are - race on the same paths.

  Tag a test `@tag :isolated_tmp_dir` and it receives `:tmp_dir` in its
  context, same as ExUnit's tag provides.

  `root/0` is scoped by `System.pid()`: every concurrent `mix test`
  OS process gets a distinct segment appended to its root, so two runs cannot
  compute the same scratch path even if `STATIFIER_TMP_ROOT` somehow resolves
  to the same value in both - which is exactly what happened before this
  segment existed, when `test/statifier/tmp_dir_test.exs` briefly set the
  variable to the same hardcoded literal in two concurrent processes and their
  `setup_tmp_dir/1` calls raced each other's `rm_rf!`. `STATIFIER_TMP_ROOT`
  (default `"tmp"`) is no longer load-bearing for isolation; it now only picks
  where a run's pid-scoped tree lives, e.g. `mix test.regression` sets it to
  `tmp/regression` so the ratchet's directories are easy to find by eye rather
  than to keep them out of another process's way.

  Directories accumulate: every OS process leaves its own `tmp/<root>/<pid>/`
  subtree behind (like ExUnit, so a failure can be inspected), and OS pids get
  reused, but not while this repo has any `mix test` process alive - a stale
  subtree from a finished process and a live one from a current process cannot
  collide within a single run. Nothing here sweeps old subtrees automatically:
  distinguishing "stale" from "a concurrent run that just hasn't reached this
  test yet" is not safely decidable from inside a `setup` callback, and
  deleting a live run's directory is exactly the bug this module exists to
  prevent. Run `rm -rf tmp/` by hand between sessions if the accumulation
  bothers you; `.gitignore` already excludes all of `tmp/`.

  Like ExUnit, the directory is emptied at setup and left in place afterwards
  so a failure can be inspected.
  """

  @default_root "tmp"
  @env_var "STATIFIER_TMP_ROOT"
  @escape Enum.map(~c" [~#%&*{}\\:<>?/+|\"]", &<<&1::utf8>>)

  @doc """
  Scratch root for this OS process.

  Always ends in a `System.pid()` segment (`process_id/0`), so no two
  concurrent OS processes ever resolve to the same root regardless of what
  `STATIFIER_TMP_ROOT` is set to in either.
  """
  @spec root() :: String.t()
  def root, do: Path.join(configured_root(), process_id())

  @doc "Name of the environment variable that overrides the configured root."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "Default configured root used when the environment variable is unset."
  @spec default_root() :: String.t()
  def default_root, do: @default_root

  @doc """
  This OS process's discriminator, appended to `root/0` unconditionally.

  `System.pid/0` as a string. No two concurrent OS processes ever share one,
  which is what makes `root/0` collision-proof by construction.
  """
  @spec process_id() :: String.t()
  def process_id, do: to_string(System.pid())

  defp configured_root, do: System.get_env(@env_var) || @default_root

  @doc """
  Absolute scratch path for `module` and `test_name` under `root/0`.

  Pure - builds the path and touches nothing. Mirrors ExUnit's own escaping
  and 8-character md5 suffix (`ex_unit/lib/ex_unit/runner.ex`) so escaped
  names cannot alias each other.
  """
  @spec path_for(module :: module(), test_name :: atom() | String.t()) :: String.t()
  def path_for(module, test_name) do
    module_string = inspect(module)
    name_string = to_string(test_name)

    escaped_module = escape_path(module_string)
    escaped_name = escape_path(name_string)
    short_hash = short_hash(module_string, name_string)

    [root(), escaped_module, "#{escaped_name}-#{short_hash}"]
    |> Path.join()
    |> Path.expand()
  end

  @doc "ExUnit `setup` callback; a no-op unless the test is tagged."
  @spec setup_tmp_dir(context :: map()) :: :ok | {:ok, keyword()}
  def setup_tmp_dir(%{isolated_tmp_dir: true, module: module, test: test_name}) do
    path = path_for(module, test_name)
    File.rm_rf!(path)
    File.mkdir_p!(path)
    {:ok, tmp_dir: path}
  end

  def setup_tmp_dir(_context), do: :ok

  defp short_hash(module_string, name_string) do
    (module_string <> "/" <> name_string)
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
    |> binary_slice(0..7)
  end

  defp escape_path(path), do: String.replace(path, @escape, "-")
end
