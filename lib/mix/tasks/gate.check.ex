defmodule Mix.Tasks.Gate.Check do
  @shortdoc "Report quality-gate config changes that no ledger entry justifies"

  @moduledoc """
  Reports changes to the quality gate's own configuration that the branch does
  not also record in `docs/quality-gate-changes.md`.

  ADR-0011 says the gate's config is not agent-editable. This task is how a
  `mix quality` run notices: it runs as the `Gate guard` custom stage, and fails
  it when a guarded file changed with no ledger entry naming that file.

  ## Usage

      mix gate.check
      mix gate.check --base upstream/trunk
      mix gate.check --format json

  ## Options

    * `--base` - ref to diff against, tried before `origin/main` and `main`
    * `--format json` - print the ExQuality finding contract instead of prose

  Exit status is 0 when nothing is unjustified, 1 when something is, and 2 when
  no base ref resolves and there is nothing to diff against - which the stage's
  `skip_exit_code: 2` turns into a skip with its own reason rather than a pass.
  """

  use Mix.Task

  alias Mix.Statifier.GateGuard

  @switches [base: :string, format: :string]

  @skip_reason "no base ref: neither origin/main nor main resolves"

  @advice """
  These are changes to what the gate checks, not to what it found. ADR-0011: an
  agent does not decide that a check is wrong. Take it to a human. If they call
  it, the call is recorded in #{GateGuard.ledger_path()} with their name on it.\
  """

  @impl Mix.Task
  def run(argv) do
    case execute(argv) do
      {:ok, output} -> report(output, 0)
      {:skip, output} -> report(output, 2)
      {:error, output} -> report(output, 1)
    end
  end

  @doc """
  Runs the guard and reports the outcome instead of halting.

  `opts` are passed through to `Mix.Statifier.GateGuard.collect/1`, so
  `opts[:runner]` drives this without a real git history.
  """
  @spec execute(argv :: [String.t()], opts :: keyword()) ::
          {:ok, iodata()} | {:skip, String.t()} | {:error, iodata()}
  def execute(argv, opts \\ []) do
    {parsed, _rest} = OptionParser.parse!(argv, strict: @switches)
    json? = parsed[:format] == "json"

    case GateGuard.collect(collect_opts(parsed, opts)) do
      {:ok, source} -> source |> GateGuard.analyze() |> respond(json?)
      :no_base_ref -> {:skip, skipped(json?)}
      {:error, reason} -> {:error, failed(reason, json?)}
    end
  end

  defp collect_opts(parsed, opts) do
    if parsed[:base], do: Keyword.put(opts, :base, parsed[:base]), else: opts
  end

  defp respond([], json?), do: {:ok, document("No unjustified gate changes", [], json?)}

  defp respond(findings, json?),
    do: {:error, document(summary(findings), findings, json?)}

  defp summary(findings), do: "#{length(findings)} unjustified gate #{changes(findings)}"

  defp changes([_one]), do: "change"
  defp changes(_many), do: "changes"

  defp document(summary, findings, true = _json?) do
    JSON.encode!(%{
      summary: summary,
      stats: %{finding_count: length(findings)},
      findings: findings
    })
  end

  defp document(summary, [], false = _json?), do: summary

  defp document(summary, findings, false = _json?) do
    body = Enum.map_join(findings, "\n\n", &human/1)

    "#{summary}\n\n#{body}\n\n#{@advice}"
  end

  defp human(finding) do
    "#{finding.file}#{at(finding.line)}\n  #{finding.message} (#{finding.check})"
  end

  defp at(nil), do: ""
  defp at(line), do: ":#{line}"

  # The skip reason is written rather than left to the first line of output:
  # ExQuality falls back to that line, and `mix` is free to print a build-lock
  # notice ahead of ours.
  defp skipped(true = _json?),
    do: JSON.encode!(%{summary: @skip_reason, stats: %{finding_count: 0}, findings: []})

  defp skipped(false = _json?), do: @skip_reason

  defp failed(reason, true = _json?) do
    JSON.encode!(%{
      summary: "gate check could not read git",
      stats: %{finding_count: 1},
      findings: [
        %{file: "", severity: "error", check: "gate-check", message: reason}
      ]
    })
  end

  defp failed(reason, false = _json?), do: "gate check could not read git: #{reason}"

  defp report(output, 0) do
    Mix.shell().info(output)
    :ok
  end

  defp report(output, status) do
    Mix.shell().info(output)
    System.at_exit(fn _code -> exit({:shutdown, status}) end)
  end
end
