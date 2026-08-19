defmodule Mix.Tasks.Adr.Check do
  @shortdoc "Report likely violations of the mechanically-checkable ADRs"

  @moduledoc """
  Reports lines the branch adds that look like violations of ADR-0002 (Appendix
  D naming), ADR-0003 (pure core with effects), ADR-0004 (predicator as the
  datamodel), ADR-0008 (generated identifier formats), or ADR-0018 (process
  artifacts are not code comments) - plus, since ADR-0056, two checks that are
  not about the diff at all: `docs/adr/` numbers colliding and
  `docs/adr/README.md`'s table falling out of bijection with the directory.

  It runs as the `ADR guard` custom stage of `mix quality`, so drift from an
  accepted decision is a named gate failure rather than something review has to
  catch. Every finding names the ADR it is about. The ADR-0002/0003/0004/0008
  findings clear with an inline comment on or above the line citing that ADR or
  the word "deviation" - the same justification CLAUDE.md already asks for. The
  ADR-0018 bead-ID finding does not: an ADR citation is exactly what it is
  checking against, so it clears only with its own marker, `ADR-0018-exempt`,
  placed on or above the line.

  The ADR-0056 numbering findings (`adr-0056-duplicate-number`,
  `adr-0056-readme-index`) clear on neither escape hatch. They carry no line
  number - they are invariants over the working tree's filenames and README
  table, not patterns over an added line - and there is no comment that makes a
  duplicate ADR number or a missing table row correct. The fix is a renumber
  and a README row move.

  ## Usage

      mix adr.check
      mix adr.check --base upstream/trunk
      mix adr.check --format json

  ## Options

    * `--base` - ref to diff against, tried before `origin/main` and `main`
    * `--format json` - print the ExQuality finding contract instead of prose

  Exit status is 0 when nothing looks off, 1 when something does, and 2 when no
  base ref resolves - **but 2 no longer means nothing ran.** The
  `docs/adr/` numbering invariant needs no base ref, so it runs regardless; 2
  means only that the diff-based and base-ref checks had no base ref to run
  against, and that the numbering invariant ran and was clean. Exit 1 is
  possible with no base ref at all, when the numbering invariant itself finds
  a collision - a duplicate number or a README bijection failure sitting in
  the tree fails the stage whether or not `origin/main` resolves. The
  `skip_exit_code: 2` stage config turns a real exit-2 skip into a reasoned
  skip rather than a pass; a diff that simply touches no `lib/` file is a
  pass, not a skip, since there was something to check and nothing was wrong
  with it.
  """

  use Mix.Task

  alias Mix.Statifier.AdrGuard

  @switches [base: :string, format: :string]

  @skip_reason "no base ref: neither origin/main nor main resolves; " <>
                 "the docs/adr/ numbering invariant ran and is clean"

  @advice """
  Each finding names the ADR it is about; docs/adr/ has the reasoning. If the
  line is right anyway, say why on it or above it: for an ADR-0002/0003/0004/0008
  finding, a comment naming the ADR or the word "deviation" clears it, and
  leaves the reason where the next reader will find it. An ADR-0018 bead-ID
  finding does not clear on an ADR citation - write `ADR-0018-exempt` on or
  above the line instead, since that finding is checking whether the line cites
  a bead, and an ADR citation would clear it by accident. An ADR-0056 numbering
  finding (`adr-0056-duplicate-number`, `adr-0056-readme-index`) does not clear
  on any comment at all - the fix is to renumber the colliding record and move
  its docs/adr/README.md row, not to justify the collision in place.\
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
      {:no_base_ref, source} -> source |> AdrGuard.analyze() |> respond_partial(json?)
      {:error, reason} -> {:error, failed(reason, json?)}
    end
  end

  defp collect_opts(parsed, opts) do
    if parsed[:base], do: Keyword.put(opts, :base, parsed[:base]), else: opts
  end

  defp respond([], json?), do: {:ok, document("No likely ADR violations", [], json?)}

  defp respond(findings, json?), do: {:error, document(summary(findings), findings, json?)}

  # The no-base-ref path: the tree-local numbering invariant still ran (it
  # needs no base ref), so a real finding fails the stage exactly as it would
  # with a base ref - a collision sitting in the tree is not excused by a
  # missing origin/main. Only a clean tree-local result falls through to the
  # skip, and the skip reason says what still ran so it is never mistaken for
  # nothing having run at all.
  defp respond_partial([], json?), do: {:skip, skipped(json?)}

  defp respond_partial(findings, json?),
    do: {:error, document(summary(findings), findings, json?)}

  defp summary(findings), do: "#{length(findings)} likely ADR #{violations(findings)}"

  defp violations([_one]), do: "violation"
  defp violations(_many), do: "violations"

  # third arg: JSON output?
  defp document(summary, findings, true) do
    JSON.encode!(%{
      summary: summary,
      stats: %{finding_count: length(findings)},
      findings: findings
    })
  end

  defp document(summary, [], false), do: summary

  defp document(summary, findings, false) do
    body = Enum.map_join(findings, "\n\n", &human/1)

    "#{summary}\n\n#{body}\n\n#{@advice}"
  end

  # The diff-based checks (ADR-0002/0003/0004/0008/0018) always fire on a line
  # the diff adds, so they carry a line number. The ADR-0056 numbering
  # invariant is different: it is a question about filenames and a README
  # table, not about a line of code, so its findings carry `line: nil` and
  # print just the path.
  defp human(%{line: nil} = finding) do
    "#{finding.file}\n  #{finding.message} (#{finding.check})"
  end

  defp human(finding) do
    "#{finding.file}:#{finding.line}\n  #{finding.message} (#{finding.check})"
  end

  # The skip reason is written rather than left to the first line of output:
  # ExQuality falls back to that line, and `mix` is free to print a build-lock
  # notice ahead of ours.
  # arg: JSON output?
  defp skipped(true),
    do: JSON.encode!(%{summary: @skip_reason, stats: %{finding_count: 0}, findings: []})

  defp skipped(false), do: @skip_reason

  # second arg: JSON output?
  defp failed(reason, true) do
    JSON.encode!(%{
      summary: "ADR check could not read git",
      stats: %{finding_count: 1},
      findings: [%{file: "", severity: "error", check: "adr-check", message: reason}]
    })
  end

  defp failed(reason, false), do: "ADR check could not read git: #{reason}"

  defp report(output, 0) do
    Mix.shell().info(output)
    :ok
  end

  defp report(output, status) do
    Mix.shell().info(output)
    System.at_exit(fn _code -> exit({:shutdown, status}) end)
  end
end
