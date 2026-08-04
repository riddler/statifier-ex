defmodule Mix.Statifier.GateGuard do
  @moduledoc """
  Finds changes to the quality gate's own configuration that no one has
  justified in writing.

  ADR-0011 says the gate's config is not agent-editable: a red gate is never
  turned green by lowering a threshold, skipping a check, tagging a test
  `@tag :skip`, or shrinking the regression ratchet. This module is the
  mechanical half of that policy. It reads a diff of the current branch against
  its base and reports a finding for every guarded change the diff does not also
  record in `docs/quality-gate-changes.md`.

  The check deliberately cannot tell a weakening from a strengthening, and does
  not try. Any guarded change needs a ledger entry; the entry is where a human
  says which it was.

  `analyze/1` is pure - it takes a diff and two registry snapshots and returns
  findings. `collect/1` is the part that talks to git, and takes an
  `opts[:runner]` so tests never need a fixture repository.
  """

  @type finding :: %{
          file: String.t(),
          line: pos_integer() | nil,
          severity: String.t(),
          check: String.t(),
          message: String.t()
        }

  @type source :: %{
          diff: String.t(),
          base_registry: String.t() | nil,
          head_registry: String.t() | nil
        }

  @guarded_paths [".quality.exs", ".credo.exs", "coveralls.json", ".sobelow-conf"]
  @ledger_path "docs/quality-gate-changes.md"
  @registry_path "test/passing_tests.json"

  # `mix.exs` is matched by line content rather than by path: most edits to it
  # (a dep bump, an unrelated alias) have nothing to do with the gate, and a
  # path-level guard would make every dependency change need a ledger entry.
  @mix_exs_pattern ~r/test_coverage|dialyzer:|warnings_as_errors|aliases|:ex_quality|:credo|:excoveralls|:dialyxir/

  # The prefixes are pinned because `diff.mnemonicPrefix` in a developer's git
  # config would otherwise rename them out from under the parser.
  @diff_flags ["--unified=0", "--src-prefix=a/", "--dst-prefix=b/"]

  # Anchored at the start of the line, which is where the formatter puts a real
  # module attribute. An unanchored pattern fires on every string literal and
  # heredoc that merely quotes a skip tag - this module's own tests, for one.
  @skip_tag_pattern ~r/^\s*@(?:module)?tag\s+(?::(?:skip|pending)\b|(?:skip|pending):)/

  @doc "The gate-config files any edit to which needs a ledger entry."
  @spec guarded_paths() :: [String.t()]
  def guarded_paths, do: @guarded_paths

  @doc "Path of the justification ledger, relative to the project root."
  @spec ledger_path() :: String.t()
  def ledger_path, do: @ledger_path

  @doc """
  Turns a diff and two registry snapshots into unjustified-change findings.

  Findings cleared by a ledger entry added in the same diff are dropped, so a
  ledger entry written on some other branch clears nothing here.
  """
  @spec analyze(source :: source()) :: [finding()]
  def analyze(source) do
    files = parse_diff(source.diff)
    cleared = cleared_paths(files)

    (gate_config_findings(files) ++
       mix_exs_findings(files) ++
       skip_tag_findings(files) ++
       ratchet_findings(source))
    |> Enum.reject(fn finding -> Enum.any?(cleared, &String.contains?(&1, finding.file)) end)
  end

  @doc """
  Reads the diff and registry snapshots the guard needs out of git.

  Base ref resolution is `opts[:base]`, then `origin/main`, then `main`. When
  none of them resolves there is nothing to diff against, so this returns
  `:no_base_ref` rather than guessing a base; the task turns that into a skipped
  stage.

  `opts[:runner]` replaces the `git` shell-out with a function of an argument
  list returning `{output, status}`, mirroring `Mix.Tasks.Test.Regression`.
  """
  @spec collect(opts :: keyword()) :: {:ok, source()} | {:error, String.t()} | :no_base_ref
  def collect(opts) do
    runner = Keyword.get(opts, :runner, &git/1)
    candidates = Enum.reject([opts[:base], "origin/main", "main"], &is_nil/1)

    case Enum.find(candidates, &resolves?(&1, runner)) do
      nil -> :no_base_ref
      ref -> collect_from(ref, runner, opts)
    end
  end

  defp collect_from(ref, runner, opts) do
    with {:ok, base} <- run(runner, ["merge-base", ref, "HEAD"]),
         base = String.trim(base),
         {:ok, diff} <- run(runner, diff_args(base)) do
      {:ok,
       %{
         diff: diff <> untracked_diff(runner),
         base_registry: show(runner, base, registry_path(opts)),
         head_registry: read(registry_path(opts))
       }}
    end
  end

  defp registry_path(opts), do: Keyword.get(opts, :registry_path, @registry_path)

  # Plain `diff`, not `diff ...`, so uncommitted working-tree changes are in
  # scope: the guard has to see a gate change before it is committed. The
  # prefixes are pinned because `diff.mnemonicPrefix` in a developer's git
  # config would otherwise rename them out from under the parser.
  defp diff_args(base), do: ["diff", base | @diff_flags]

  # A file git has never seen is absent from `git diff` entirely, which would
  # make a brand-new `.credo.exs`, a new test file carrying a skip tag, or the
  # ledger entry meant to clear one of them all invisible. Only paths a check
  # could fire on are diffed, so an untracked scratch directory costs nothing.
  defp untracked_diff(runner) do
    case run(runner, ["ls-files", "--others", "--exclude-standard"]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&interesting?/1)
        |> Enum.map_join(&added_file_diff(runner, &1))

      {:error, _reason} ->
        ""
    end
  end

  defp interesting?(path) do
    path in [@ledger_path, "mix.exs" | @guarded_paths] or String.starts_with?(path, "test/")
  end

  # `git diff --no-index` exits 1 when the files differ, which is every call here.
  defp added_file_diff(runner, path) do
    case runner.(["diff", "--no-index" | @diff_flags] ++ ["/dev/null", path]) do
      {output, status} when status in [0, 1] -> output
      _other -> ""
    end
  end

  defp resolves?(ref, runner) do
    match?({:ok, _output}, run(runner, ["rev-parse", "--verify", "--quiet", ref]))
  end

  defp show(runner, base, path) do
    case run(runner, ["show", "#{base}:#{path}"]) do
      {:ok, content} -> content
      {:error, _reason} -> nil
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _reason} -> nil
    end
  end

  defp run(runner, args) do
    case runner.(args) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, "git #{Enum.join(args, " ")} exited #{status}: #{output}"}
    end
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)

  # -- checks ---------------------------------------------------------------

  defp gate_config_findings(files) do
    for path <- @guarded_paths, Map.has_key?(files, path) do
      finding(path, nil, "gate-config", "gate config changed")
    end
  end

  defp mix_exs_findings(files) do
    entries = Map.get(files, "mix.exs", [])
    matching = Enum.filter(entries, &Regex.match?(@mix_exs_pattern, text(&1)))

    case matching do
      [] -> []
      [first | _rest] -> [finding("mix.exs", line(first), "gate-config", "gate config changed")]
    end
  end

  defp skip_tag_findings(files) do
    for {path, entries} <- files,
        String.starts_with?(path, "test/"),
        {:added, line, text} <- entries,
        Regex.match?(@skip_tag_pattern, text) do
      finding(path, line, "skip-tag", "test skipped by a new #{String.trim(text)}")
    end
  end

  defp ratchet_findings(%{base_registry: nil}), do: []

  defp ratchet_findings(source) do
    with {:ok, base} <- decode(source.base_registry),
         {:ok, head} <- decode(source.head_registry) do
      # Comparing parsed pattern sets rather than diff lines, so reformatting by
      # `mix test.baseline` is invisible and only a removed pattern is a finding.
      base
      |> Enum.filter(fn {_key, value} -> is_list(value) end)
      |> Enum.flat_map(fn {key, patterns} -> removed_patterns(key, patterns, head) end)
    else
      :error -> []
    end
  end

  defp removed_patterns(key, patterns, head) do
    case patterns -- Map.get(head, key, []) do
      [] ->
        []

      removed ->
        [
          finding(
            @registry_path,
            nil,
            "ratchet-shrink",
            "#{key} lost #{Enum.join(removed, ", ")}"
          )
        ]
    end
  end

  defp decode(nil), do: :error

  defp decode(content) do
    case JSON.decode(content) do
      {:ok, registry} when is_map(registry) -> {:ok, registry}
      _other -> :error
    end
  end

  defp finding(path, line, check, what) do
    %{
      file: path,
      line: line,
      severity: "error",
      check: check,
      message: "#{what} with no entry in #{@ledger_path} naming it"
    }
  end

  # -- ledger ---------------------------------------------------------------

  # A ledger entry clears a path only when the same diff adds both the path and
  # an `Approved-by:` line, so the approval and the change travel together.
  defp cleared_paths(files) do
    added = for {:added, _line, text} <- Map.get(files, @ledger_path, []), do: text

    if Enum.any?(added, &String.contains?(&1, "Approved-by:")), do: added, else: []
  end

  # -- diff parsing ---------------------------------------------------------

  defp parse_diff(diff) do
    {_path, _line, acc} =
      diff
      |> String.split("\n")
      |> Enum.reduce({nil, 0, %{}}, &parse_line/2)

    Map.new(acc, fn {path, entries} -> {path, Enum.reverse(entries)} end)
  end

  # A deleted file has no `+++ b/` line, so the `--- a/` path stands in for it:
  # deleting `.credo.exs` outright is a gate change like any other.
  defp parse_line("--- a/" <> path, {_path, _line, acc}), do: {path, 0, acc}
  defp parse_line("--- " <> _rest, state), do: state
  defp parse_line("+++ /dev/null", state), do: state
  defp parse_line("+++ b/" <> path, {_path, _line, acc}), do: {path, 0, acc}
  defp parse_line("@@" <> _rest = header, {path, _line, acc}), do: {path, hunk_start(header), acc}

  defp parse_line("+" <> text, {path, line, acc}) when is_binary(path),
    do: {path, line + 1, push(acc, path, {:added, line, text})}

  defp parse_line("-" <> text, {path, line, acc}) when is_binary(path),
    do: {path, line, push(acc, path, {:removed, text})}

  defp parse_line(" " <> _rest, {path, line, acc}), do: {path, line + 1, acc}
  defp parse_line(_other, state), do: state

  defp push(acc, path, entry), do: Map.update(acc, path, [entry], &[entry | &1])

  defp hunk_start(header) do
    case Regex.run(~r/^@@ -\S+ \+(\d+)/, header) do
      [_all, start] -> String.to_integer(start)
      nil -> 0
    end
  end

  defp text({:added, _line, text}), do: text
  defp text({:removed, text}), do: text

  defp line({:added, line, _text}), do: line
  defp line({:removed, _text}), do: nil
end
