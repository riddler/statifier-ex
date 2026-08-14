defmodule Mix.Tasks.Adr.Check do
  @shortdoc "Report likely violations of the mechanically-checkable ADRs"

  @moduledoc """
  Reports lines the branch adds that look like violations of ADR-0002 (Appendix
  D naming), ADR-0003 (pure core with effects), ADR-0004 (predicator as the
  datamodel), ADR-0008 (UXIDs for identifiers), or ADR-0018 (process artifacts
  are not code comments).

  It runs as the `ADR guard` custom stage of `mix quality`, so drift from an
  accepted decision is a named gate failure rather than something review has to
  catch. Every finding names the ADR it is about. The ADR-0002/0003/0004/0008
  findings clear with an inline comment on or above the line citing that ADR or
  the word "deviation" - the same justification CLAUDE.md already asks for. The
  ADR-0018 bead-ID finding does not: an ADR citation is exactly what it is
  checking against, so it clears only with its own marker, `ADR-0018-exempt`,
  placed on or above the line.

  ## Usage

      mix adr.check
      mix adr.check --base upstream/trunk
      mix adr.check --format json

  ## Options

    * `--base` - ref to diff against, tried before `origin/main` and `main`
    * `--format json` - print the ExQuality finding contract instead of prose

  Exit status is 0 when nothing looks off, 1 when something does, and 2 when no
  base ref resolves and there is nothing to diff against - which the stage's
  `skip_exit_code: 2` turns into a skip with its own reason rather than a pass.
  A diff that simply touches no `lib/` file is a pass, not a skip: there was
  something to check and nothing was wrong with it.
  """

  use Mix.Task

  alias Mix.Statifier.AdrGuard

  @switches [base: :string, format: :string]

  @skip_reason "no base ref: neither origin/main nor main resolves"

  @advice """
  Each finding names the ADR it is about; docs/adr/ has the reasoning. If the
  line is right anyway, say why on it or above it: for an ADR-0002/0003/0004/0008
  finding, a comment naming the ADR or the word "deviation" clears it, and
  leaves the reason where the next reader will find it. An ADR-0018 bead-ID
  finding does not clear on an ADR citation - write `ADR-0018-exempt` on or
  above the line instead, since that finding is checking whether the line cites
  a bead, and an ADR citation would clear it by accident.\
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

  `opts` are passed through to `Mix.Statifier.AdrGuard.collect/1`, so
  `opts[:runner]` drives this without a real git history.
  """
  @spec execute(argv :: [String.t()], opts :: keyword()) ::
          {:ok, iodata()} | {:skip, String.t()} | {:error, iodata()}
  def execute(argv, opts \\ []) do
    {parsed, _rest} = OptionParser.parse!(argv, strict: @switches)
    json? = parsed[:format] == "json"

    case AdrGuard.collect(collect_opts(parsed, opts)) do
      {:ok, source} -> source |> AdrGuard.analyze() |> respond(json?)
      :no_base_ref -> {:skip, skipped(json?)}
      {:error, reason} -> {:error, failed(reason, json?)}
    end
  end

  defp collect_opts(parsed, opts) do
    if parsed[:base], do: Keyword.put(opts, :base, parsed[:base]), else: opts
  end

  defp respond([], json?), do: {:ok, document("No likely ADR violations", [], json?)}

  defp respond(findings, json?), do: {:error, document(summary(findings), findings, json?)}

  defp summary(findings), do: "#{length(findings)} likely ADR #{violations(findings)}"

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

  # Every finding here fires on a line the diff adds, so unlike the gate guard's
  # file-level findings there is always a line number to point at.
  defp human(finding) do
    "#{finding.file}:#{finding.line}\n  #{finding.message} (#{finding.check})"
  end

  # The skip reason is written rather than left to the first line of output:
  # ExQuality falls back to that line, and `mix` is free to print a build-lock
  # notice ahead of ours.
  defp skipped(true = _json?),
    do: JSON.encode!(%{summary: @skip_reason, stats: %{finding_count: 0}, findings: []})

  defp skipped(false = _json?), do: @skip_reason

  defp failed(reason, true = _json?) do
    JSON.encode!(%{
      summary: "ADR check could not read git",
      stats: %{finding_count: 1},
      findings: [%{file: "", severity: "error", check: "adr-check", message: reason}]
    })
  end

  defp failed(reason, false = _json?), do: "ADR check could not read git: #{reason}"

  defp report(output, 0) do
    Mix.shell().info(output)
    :ok
  end

  defp report(output, status) do
    Mix.shell().info(output)
    System.at_exit(fn _code -> exit({:shutdown, status}) end)
  end
end
