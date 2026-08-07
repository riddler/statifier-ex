defmodule Mix.Tasks.Test.Regression do
  @shortdoc "Run the regression ratchet - every test in test/passing_tests.json"

  @moduledoc """
  Runs exactly the tests listed in `test/passing_tests.json`.

  Those tests passed once, so any failure here is a regression rather than a
  missing feature. The conformance suites are excluded from `mix test` by
  default; this task includes the tags its registry entries need.

  ## Usage

      mix test.regression
      mix test.regression --registry test/passing_tests.json

  ## Options

    * `--registry` - registry to run, defaults to `test/passing_tests.json`

  Failures print ExUnit's own output, unedited. Growing the registry is
  `mix test.baseline`'s job - this task never writes to it.

  A registry entry that matches no file on disk fails the run. Skipping it
  would silently shrink the ratchet, which is the one thing it exists to
  prevent.
  """

  use Mix.Task

  alias Mix.Statifier.RegressionRegistry

  @switches [registry: :string]
  @tmp_root "tmp/regression"

  @impl Mix.Task
  def run(argv) do
    case execute(argv) do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end
  end

  @doc """
  Runs the ratchet and reports the outcome instead of halting.

  `opts[:runner]` replaces the `mix test` shell-out with a function of the
  argument list returning an exit status, which is how the tests drive this
  without spawning a nested `mix test`.
  """
  @spec execute(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, String.t()}
  def execute(argv, opts \\ []) do
    {parsed, _rest} = OptionParser.parse!(argv, strict: @switches)
    path = parsed[:registry] || RegressionRegistry.default_path()
    runner = Keyword.get(opts, :runner, &mix_test/1)

    with {:ok, registry} <- RegressionRegistry.load(path),
         {:ok, files} <- resolve(registry, path) do
      run_tests(files, runner)
    end
  end

  defp resolve(registry, path) do
    case RegressionRegistry.files(registry) do
      {_files, [_missing | _rest] = missing} ->
        {:error,
         "#{path} lists #{length(missing)} entry/entries matching no file on disk:\n" <>
           Enum.map_join(missing, "\n", &"  - #{&1}")}

      {[], []} ->
        {:error, "#{path} expands to no tests - nothing to guard against"}

      {files, []} ->
        {:ok, files}
    end
  end

  defp run_tests(files, runner) do
    count = length(files)
    Mix.shell().info("Running #{count} regression test file#{plural(files, "", "s")}...")

    case runner.(files ++ RegressionRegistry.test_args(files)) do
      0 ->
        Mix.shell().info("All #{count} regression test files passed.")
        :ok

      status ->
        {:error,
         "regression failure (mix test exited #{status}). " <>
           "Fix the code, or run `mix test.baseline` if the registry is wrong."}
    end
  end

  defp plural([_one], singular, _plural), do: singular
  defp plural(_many, _singular, plural), do: plural

  @doc """
  Environment for the spawned `mix test`.

  The ratchet runs concurrently with `mix quality`'s own Tests stage, in the
  same working directory, over largely the same modules. Scratch directories
  are rooted per OS process (`Statifier.TmpDir`), so without a distinct root
  the two runs delete each other's directories mid-test (st-0vz).
  """
  @spec test_env() :: [{String.t(), String.t()}]
  def test_env, do: [{"STATIFIER_TMP_ROOT", @tmp_root}]

  defp mix_test(args) do
    {_output, status} =
      System.cmd("mix", ["test" | args],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true,
        env: test_env()
      )

    status
  end
end
