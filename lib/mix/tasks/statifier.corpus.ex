defmodule Mix.Tasks.Statifier.Corpus do
  @shortdoc "Emit or check the language-neutral conformance corpus under conformance/"

  @moduledoc """
  Emits the conformance corpus under `conformance/` from the fetched upstream
  suites, or checks the committed one (ADR-0070).
  `Mix.Statifier.Corpus.Emitter` holds the rules; this task is its command
  line.

  ## Usage

      # Run every upstream case and write conformance/corpus/, manifest.json,
      # exclusions.json and registry.json
      mix statifier.corpus

      # Write nothing; fail if a committed file differs from what the emitter
      # would write, or if there is nothing to check
      mix statifier.corpus --check

  ## Options

    * `--check` - check instead of emitting
    * `--scratch` - the upstream tree, defaults to `tools/corpus/scratch`

  Emitting needs the upstream tree that `mise run corpus:fetch` and
  `mise run corpus:transform` populate, and refuses without it; the task
  never fetches. `--check` needs neither the network nor that tree: it
  re-runs every committed case and recomputes every file derivable from the
  committed inputs, and compares the corpus against the upstream tree only
  when the tree is present, saying so when it is not.

  Both modes start the application and place `Statifier.Supervisor`, the
  session runtime, as the test suite does (ADR-0027: the library starts no
  processes of its own), because a case that uses `<send>`, `<invoke>` or a
  delay runs through a session. Every refusal is printed as a sentence and
  exits non-zero.
  """

  use Mix.Task

  alias Mix.Statifier.Corpus.Emitter

  @switches [check: :boolean, scratch: :string]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")
    start_runtime()

    case execute(argv) do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end
  end

  @doc """
  Runs the task and reports the outcome instead of raising.

  `opts[:root]` moves the whole project root - the exclusion lists, the
  ratchet and `conformance/` - to a fixture tree, so the tests can drive the
  task without touching the repository's own files.
  """
  @spec execute(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, String.t()}
  def execute(argv, opts \\ []) do
    {parsed, _rest} = OptionParser.parse!(argv, strict: @switches)
    config = Emitter.config(root: Keyword.get(opts, :root, "."), scratch: parsed[:scratch])

    if parsed[:check] do
      with {:ok, report} <- Emitter.check(config), do: print(report, "checked")
    else
      with {:ok, report} <- Emitter.emit(config), do: print(report, "ran")
    end
  end

  defp start_runtime do
    case Statifier.Supervisor.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp print(report, verb) do
    for {suite, run, agreeing} <- report.counts do
      Mix.shell().info(
        "#{suite}: #{verb} #{run} case(s), #{agreeing} agree with their expectation"
      )
    end

    Mix.shell().info("outside the ratchet (#{length(report.outside_ratchet)}):")

    for {id, outcome} <- report.outside_ratchet do
      Mix.shell().info("  #{id}: #{describe(outcome)}")
    end

    for {claim, count} <- Map.get(report, :claims, []) do
      Mix.shell().info("registry claim #{claim}: #{count} case(s)")
    end

    for file <- Map.get(report, :written, []), do: Mix.shell().info("wrote conformance/#{file}")

    case Map.get(report, :upstream) do
      {:skipped, scratch} ->
        Mix.shell().info("upstream comparison skipped: no upstream tree at #{scratch}")

      :compared ->
        Mix.shell().info("upstream comparison: the corpus matches the upstream tree")

      nil ->
        :ok
    end

    :ok
  end

  defp describe(:agree), do: "agrees"

  defp describe({:disagree, message}),
    do: "disagrees - " <> (message |> String.split("\n") |> hd())
end
