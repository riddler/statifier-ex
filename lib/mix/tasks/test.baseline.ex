defmodule Mix.Tasks.Test.Baseline do
  @shortdoc "Report newly passing conformance tests and ratchet them in"

  @moduledoc """
  Finds conformance tests that pass but are not yet in the regression
  registry, and adds them once they are verified.

  ## Usage

      # Report what could be ratcheted in, without writing anything
      mix test.baseline

      # Report, then add everything that passed
      mix test.baseline --add

      # Verify specific files and add them
      mix test.baseline add test/scion_tests/basic/basic0_test.exs

  ## Options

    * `--add` - ratchet in every newly passing test the scan found
    * `--only` - restrict the scan to one suite, `scion` or `w3c`
    * `--registry` - registry to update, defaults to `test/passing_tests.json`

  Both forms run each candidate on its own before writing anything, so a test
  can only enter the registry by passing. `add` is all-or-nothing: if any named
  file fails, the registry is left untouched.

  The ratchet only moves forward. Nothing here removes an entry - a test that
  used to pass and now does not is a regression to fix, not a line to delete.

  A scan also prints a per-corpus coverage block: for each suite the scan
  covered, `passing/total (percent%)` against the suite's emitted corpus
  files. The numerator is every registry-tracked file plus whatever this scan
  found newly passing - tracked files this invocation skipped re-running are
  still counted, because `mix test.regression` is what guarantees them. `add`
  prints no such block: it verifies named files and never scans, so it has no
  denominator in hand.
  """

  use Mix.Task

  alias Mix.Statifier.RegressionRegistry

  @switches [add: :boolean, only: :string, registry: :string]

  @impl Mix.Task
  def run(argv) do
    case execute(argv) do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end
  end

  @doc """
  Runs the task and reports the outcome instead of halting.

  `opts[:runner]` replaces the `mix test` shell-out with a function of the
  argument list returning an exit status, `opts[:root]` moves the corpus scan
  to a fixture tree, and `opts[:today]` fixes the date stamped into the
  registry. All three exist so the tests can drive this without spawning a
  nested `mix test`.
  """
  @spec execute(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, String.t()}
  def execute(argv, opts \\ []) do
    {parsed, rest} = OptionParser.parse!(argv, strict: @switches)

    context = %{
      path: parsed[:registry] || RegressionRegistry.default_path(),
      root: Keyword.get(opts, :root, "."),
      runner: Keyword.get(opts, :runner, &mix_test/1),
      today: Keyword.get(opts, :today, Date.utc_today())
    }

    with {:ok, categories} <- categories(parsed[:only]),
         {:ok, registry} <- RegressionRegistry.load(context.path) do
      dispatch(rest, registry, categories, parsed[:add] == true, context)
    end
  end

  defp dispatch(["add"], _registry, _categories, _add?, _context) do
    {:error, "usage: mix test.baseline add <test_file> [<test_file> ...]"}
  end

  defp dispatch(["add" | files], registry, _categories, _add?, context) do
    add_named(registry, files, context)
  end

  defp dispatch([], registry, categories, add?, context) do
    scan(registry, categories, add?, context)
  end

  defp dispatch([command | _rest], _registry, _categories, _add?, _context) do
    {:error, "unknown command #{inspect(command)} - see `mix help test.baseline`"}
  end

  defp categories(nil), do: {:ok, RegressionRegistry.conformance_categories()}
  defp categories("scion"), do: {:ok, [:scion]}
  defp categories("w3c"), do: {:ok, [:w3c]}
  defp categories(other), do: {:error, "unknown suite #{inspect(other)} - use scion or w3c"}

  defp scan(registry, categories, add?, context) do
    {candidates, tracked} = candidates(registry, categories, context.root)

    case candidates do
      [] ->
        Mix.shell().info("No untracked conformance tests found - nothing to check.")
        print_coverage(tracked, categories, context.root)
        :ok

      candidates ->
        Mix.shell().info("Checking #{length(candidates)} untracked conformance test files...")
        {passing, failing} = partition(candidates, context.runner)
        report(passing, failing)
        print_coverage(tracked ++ passing, categories, context.root)
        maybe_ratchet(registry, passing, add?, context)
    end
  end

  defp candidates(registry, categories, root) do
    Enum.reduce(categories, {[], []}, fn category, {candidates, tracked} ->
      {found, _missing} = RegressionRegistry.expand(registry, category)
      {candidates ++ (RegressionRegistry.corpus_files(category, root) -- found), tracked ++ found}
    end)
  end

  defp print_coverage(passing, categories, root) do
    case RegressionRegistry.stats_lines(passing, categories, root) do
      [] ->
        :ok

      lines ->
        Mix.shell().info("Corpus coverage (ratcheted + newly passing / emitted corpus files):")
        Enum.each(lines, &Mix.shell().info/1)
    end
  end

  defp partition(files, runner) do
    Enum.split_with(files, &(runner.(RegressionRegistry.test_args([&1]) ++ [&1]) == 0))
  end

  defp report(passing, failing) do
    Mix.shell().info(
      "#{length(passing)} newly passing, #{length(failing)} still failing (not a regression - these were never tracked)."
    )

    Enum.each(passing, &Mix.shell().info("  + #{&1}"))
  end

  defp maybe_ratchet(_registry, [], _add?, _context) do
    Mix.shell().info("Nothing to add.")
    :ok
  end

  defp maybe_ratchet(_registry, passing, false, _context) do
    Mix.shell().info(
      "Run `mix test.baseline --add` to ratchet #{length(passing)} test file(s) in."
    )

    :ok
  end

  defp maybe_ratchet(registry, passing, true, context) do
    ratchet(registry, passing, context)
  end

  defp add_named(registry, files, context) do
    Mix.shell().info("Verifying #{length(files)} test file(s) before adding...")

    case Enum.reject(files, &(context.runner.(RegressionRegistry.test_args([&1]) ++ [&1]) == 0)) do
      [] ->
        ratchet(registry, files, context)

      failing ->
        {:error,
         "these files do not pass, so the registry was left unchanged:\n" <>
           Enum.map_join(failing, "\n", &"  - #{&1}")}
    end
  end

  defp ratchet(registry, files, context) do
    {updated, added, skipped} = RegressionRegistry.add(registry, files, context.today)

    Enum.each(
      skipped,
      &Mix.shell().info("Skipped #{&1}: internal tests are covered by the registry's globs.")
    )

    case added do
      [] ->
        Mix.shell().info("Nothing to add.")
        :ok

      added ->
        with :ok <- RegressionRegistry.save(updated, context.path) do
          Mix.shell().info(
            "Added #{length(added)} test file(s) to #{context.path}. " <>
              "Run `mix test.regression` to verify."
          )
        end
    end
  end

  defp mix_test(args) do
    {_output, status} = System.cmd("mix", ["test" | args], stderr_to_stdout: true, into: "")
    status
  end
end
