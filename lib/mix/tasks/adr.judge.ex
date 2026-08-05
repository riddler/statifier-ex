defmodule Mix.Tasks.Adr.Judge do
  @shortdoc "LLM-judge likely ADR-0012 violations, verified by an adversarial refute pass"

  @moduledoc """
  Reports likely violations of ADR-0012 (debuggability designed into the
  core) in the current branch's diff against its base, each one proposed by
  one model call and required to survive an independent second call prompted
  to refute it.

  It runs as the `ADR judge` custom stage of `mix quality`, scoped to the one
  ADR in scope whose rule is a judgment call rather than a name or call-site
  pattern. It is local-only by design: it makes real model calls, so it never
  runs in CI or `--profile loop`, and it skips cleanly rather than failing
  when it has nothing it can check.

  ## Usage

      mix adr.judge
      mix adr.judge --base upstream/trunk
      mix adr.judge --format json

  ## Options

    * `--base` - ref to diff against, tried before `origin/main` and `main`
    * `--format json` - print the ExQuality finding contract instead of prose

  Exit status is 0 when nothing looks off, 1 when a finding survived the
  refute pass, and 2 for any of three skip conditions, each with its own
  reason: the `claude` CLI not on `PATH`, the diff touching no
  `lib/statifier/` files, or no base ref resolving. `skip_exit_code: 2` turns
  each into a skip rather than a failure or a silent pass.
  """

  use Mix.Task

  alias Mix.Statifier.AdrJudge

  @switches [base: :string, format: :string]

  @no_cli_reason "claude CLI not on PATH"
  @no_core_changes_reason "no lib/statifier/ files in this diff"
  @no_base_ref_reason "no base ref: neither origin/main nor main resolves"

  @advice """
  Each finding here survived an independent refute pass, so it is not a
  single model's first guess at a violation. ADR-0012's reasoning is in
  docs/adr/0012-debuggability-designed-into-the-core.md.\
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
  Runs the judge and reports the outcome instead of halting.

  `opts` are passed through to both `Mix.Statifier.AdrJudge.collect/1` and
  `Mix.Statifier.AdrJudge.analyze/2`, so `opts[:runner]`, `opts[:cli_available]`
  and `opts[:caller]` drive this without a real git history, a real `claude`
  CLI on `PATH`, or a real network call.
  """
  @spec execute(argv :: [String.t()], opts :: keyword()) ::
          {:ok, iodata()} | {:skip, String.t()} | {:error, iodata()}
  def execute(argv, opts \\ []) do
    {parsed, _rest} = OptionParser.parse!(argv, strict: @switches)
    json? = parsed[:format] == "json"
    opts = collect_opts(parsed, opts)

    case AdrJudge.collect(opts) do
      {:ok, source} -> source |> AdrJudge.analyze(opts) |> respond(json?)
      :no_cli -> {:skip, skipped(@no_cli_reason, json?)}
      :no_core_changes -> {:skip, skipped(@no_core_changes_reason, json?)}
      :no_base_ref -> {:skip, skipped(@no_base_ref_reason, json?)}
      {:error, reason} -> {:error, failed(reason, json?)}
    end
  end

  defp collect_opts(parsed, opts) do
    if parsed[:base], do: Keyword.put(opts, :base, parsed[:base]), else: opts
  end

  defp respond([], json?), do: {:ok, document("No likely ADR-0012 violations", [], json?)}

  defp respond(findings, json?), do: {:error, document(summary(findings), findings, json?)}

  defp summary(findings), do: "#{length(findings)} likely ADR-0012 #{violations(findings)}"

  defp violations([_one]), do: "violation"
  defp violations(_many), do: "violations"

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
    "#{finding.file}:#{finding.line}\n  #{finding.message} (#{finding.check})"
  end

  # The skip reason is written rather than left to the first line of output:
  # ExQuality falls back to that line, and `mix` is free to print a build-lock
  # notice ahead of ours.
  defp skipped(reason, true = _json?),
    do: JSON.encode!(%{summary: reason, stats: %{finding_count: 0}, findings: []})

  defp skipped(reason, false = _json?), do: reason

  defp failed(reason, true = _json?) do
    JSON.encode!(%{
      summary: "ADR judge could not read git",
      stats: %{finding_count: 1},
      findings: [%{file: "", severity: "error", check: "adr-judge", message: reason}]
    })
  end

  defp failed(reason, false = _json?), do: "ADR judge could not read git: #{reason}"

  defp report(output, 0) do
    Mix.shell().info(output)
    :ok
  end

  defp report(output, status) do
    Mix.shell().info(output)
    System.at_exit(fn _code -> exit({:shutdown, status}) end)
  end
end
