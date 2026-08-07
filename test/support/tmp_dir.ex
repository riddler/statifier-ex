defmodule Statifier.TmpDir do
  @moduledoc """
  Per-test scratch directories with a settable root.

  Stands in for ExUnit's `@tag :tmp_dir`, which hardcodes a `tmp/` root under
  the current working directory (`ex_unit/lib/ex_unit/runner.ex`) with no way
  to configure it. That root is process-global, so two `mix test` runs in the
  same directory - which is exactly what the `Tests` and `Regression ratchet`
  stages of a bare `mix quality` are - race on the same paths (st-0vz).

  Tag a test `@tag :isolated_tmp_dir` and it receives `:tmp_dir` in its
  context, same as ExUnit's tag provides. The root is `STATIFIER_TMP_ROOT`,
  defaulting to `"tmp"`; `mix test.regression` sets it so the ratchet's child
  run cannot collide with the Tests stage.

  Like ExUnit, the directory is emptied at setup and left in place afterwards
  so a failure can be inspected.
  """

  @default_root "tmp"
  @env_var "STATIFIER_TMP_ROOT"
  @escape Enum.map(~c" [~#%&*{}\\:<>?/+|\"]", &<<&1::utf8>>)

  @doc "Scratch root for this OS process."
  @spec root() :: String.t()
  def root, do: System.get_env(@env_var) || @default_root

  @doc "Name of the environment variable that overrides the root."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc "Default root used when the environment variable is unset."
  @spec default_root() :: String.t()
  def default_root, do: @default_root

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
