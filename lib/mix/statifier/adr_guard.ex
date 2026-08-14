defmodule Mix.Statifier.AdrGuard do
  @moduledoc """
  Flags likely violations of the mechanically-checkable ADRs in `docs/adr/`.

  Covers ADR-0002 (Appendix D naming), ADR-0003 (pure core with effects),
  ADR-0004 (predicator as the datamodel, so no `Code.eval_*`), ADR-0008
  (UXIDs for identifiers), and ADR-0018 (process artifacts are not code
  comments). Each check is a name or call-site pattern over the lines a diff
  adds - deliberately not an AST pass - so a false positive is cleared the way
  this project already clears an Appendix D deviation: an inline comment on or
  above the flagged line naming an ADR or the word "deviation".

  The ADR-0018 check is the exception to that escape hatch, on purpose. It
  flags a bead ID (`st-` plus the id, including a dotted child suffix) added
  in a comment, `@moduledoc`, `@doc`, `@typedoc` or test description under
  `lib/` or `test/`. It does not look for phase numbers,
  decision numbers, or plan filenames - ADR-0018 point 2 keeps the unnumbered
  word "phase" legal and a regex cannot separate a numbered process reference
  from ordinary English, so those stay a review matter. It also does not clear
  on `@escape_pattern`: an ADR-number or "deviation" citation is exactly the
  kind of line ADR-0018's Consequences show clearing itself by accident (a
  legitimate ADR citation that happens to sit beside an unrelated bead
  mention), so this check has its own marker, `ADR-0018-exempt`, and nothing
  else clears it. Being line-based rather than AST-based, it can only tell a
  comment/doc line from a code line by shape: a `#` line, a single-line
  `@moduledoc`/`@doc`/`@typedoc "..."`, a `test "..." do` description, or a
  line inside a `\"""` doc heredoc whose opening and closing delimiters are
  both in the same diff hunk. A bead ID added mid-body into a heredoc whose
  opening delimiter is unchanged context (invisible to a `--unified=0` diff)
  is a known blind spot, not a design goal.

  Deliberately not covered: ADR-0015's banned-operation list for
  `.claude/scripts/`. That rule was an absolute whole-tree ban, and this
  guard's shape (added diff lines only, a citation escape hatch, a skip when
  no base ref resolves) was wrong for it; `.claude/scripts/test/contract_test.rb`
  was its permanent enforcement site until both the tree and that test were
  removed once the kit's mechanics moved to another repo - see
  ADR-0015's Consequences for the historical detail.

  The naming check is the one with judgment in it. An exactly-spelled Appendix D
  name is compliant and an unrelated helper is none of this check's business;
  what it looks for is the shape ADR-0002's context describes, a spec function
  independently re-derived under a heuristic name - close to a canonical name
  without being it.

  `analyze/1` is pure - it takes a diff and returns findings. `collect/1` is the
  part that talks to git, and takes an `opts[:runner]` so tests never need a
  fixture repository.
  """

  @type finding :: %{
          file: String.t(),
          line: pos_integer() | nil,
          severity: String.t(),
          check: String.t(),
          message: String.t()
        }

  @type source :: %{diff: String.t()}

  @lib_prefix "lib/"
  @core_prefix "lib/statifier/"
  @test_prefix "test/"

  # ADR-0003 names `Statifier.Session` as *the* production effect interpreter,
  # so it is the one core module allowed to do I/O. Excluding it is the design,
  # not a hole in the check.
  @effect_interpreter_paths ["lib/statifier/session.ex"]

  @interpreter_pattern ~r{^lib/statifier/interpreter}

  @appendix_d_names ~w(
    main_event_loop select_transitions select_eventless_transitions
    remove_conflicting_transitions get_transition_domain compute_exit_set
    compute_entry_set add_descendant_states_to_enter
    add_ancestor_states_to_enter microstep enter_states exit_states
    exit_interpreter is_in_final_state
  )

  @def_pattern ~r/^\s*defp?\s+([a-z_][a-zA-Z0-9_]*[?!]?)/

  # Below this length a normalized name is a substring of half the canonical
  # list by accident: `state` sits inside `enter_states` and means nothing by it.
  @min_name_length 7
  @naming_similarity_threshold 0.84

  @effect_call_pattern ~r/
    use\s+GenServer\b | GenServer\. | Process\.(send|send_after|exit|monitor)\( |
    :timer\. | Logger\.\w+\( | IO\.(puts|write|inspect)\( | File\.\w+!?\( |
    System\.cmd\( | Node\.\w+\( | :ets\. | Agent\.\w+!?\( |
    Task\.(start|async)\( | \bspawn\w*\( | \breceive\s+do\b
  /x

  @eval_call_pattern ~r/\bCode\.eval_(string|quoted)\(/

  @uxid_adhoc_pattern ~r/
    :crypto\.strong_rand_bytes\( | UUID\.uuid4\( | Ecto\.UUID\.generate\( |
    System\.unique_integer\( | :erlang\.unique_integer\(
  /x

  @escape_pattern ~r/ADR-0\d{3}|deviation/i

  # `st-` plus the id, including a dotted child suffix. The lookaround pair
  # stands in for a word boundary on the hyphen side: without it, "cost-
  # effective" and "21st-century" would both read as bead IDs, since neither
  # side of a `\b` sees the hyphen as a boundary.
  @bead_id_pattern ~r/(?<![a-zA-Z0-9])st-[a-z0-9]+(?:\.[a-z0-9]+)*(?![a-zA-Z0-9])/

  # Deliberately not @escape_pattern - see the moduledoc.
  @bead_escape_pattern ~r/ADR-0018-exempt/i

  @doc_heredoc_open_pattern ~r/^@(?:moduledoc|doc|typedoc)\s+"""$/
  @doc_single_line_pattern ~r/^@(?:moduledoc|doc|typedoc)\s+"(.*)"$/
  @test_description_pattern ~r/^test\s+"(.*)"\s+do$/

  # Pinned because `diff.mnemonicPrefix` in a developer's git config would
  # otherwise rename the prefixes out from under the parser.
  @diff_flags ["--unified=0", "--src-prefix=a/", "--dst-prefix=b/"]

  @doc "The Appendix D function names ADR-0002 requires the interpreter to keep."
  @spec appendix_d_names() :: [String.t()]
  def appendix_d_names, do: @appendix_d_names

  @doc """
  Turns a diff into likely-ADR-violation findings.

  A finding is dropped when the line it fires on, or the line above it in the
  same hunk, cites an ADR number or the word "deviation" - the same inline
  justification CLAUDE.md already asks for.
  """
  @spec analyze(source :: source()) :: [finding()]
  def analyze(source) do
    files = parse_diff(source.diff)

    naming_findings(files) ++
      effects_findings(files) ++
      eval_findings(files) ++
      uxid_findings(files) ++
      bead_id_findings(files)
  end

  @doc """
  Reads the diff the guard needs out of git.

  Base ref resolution is `opts[:base]`, then `origin/main`, then `main`. When
  none of them resolves there is nothing to diff against, so this returns
  `:no_base_ref` rather than guessing a base; the task turns that into a skipped
  stage.

  `opts[:runner]` replaces the `git` shell-out with a function of an argument
  list returning `{output, status}`, mirroring `Mix.Statifier.GateGuard`.
  """
  @spec collect(opts :: keyword()) :: {:ok, source()} | {:error, String.t()} | :no_base_ref
  def collect(opts) do
    runner = Keyword.get(opts, :runner, &git/1)
    candidates = Enum.reject([opts[:base], "origin/main", "main"], &is_nil/1)

    case Enum.find(candidates, &resolves?(&1, runner)) do
      nil -> :no_base_ref
      ref -> collect_from(ref, runner)
    end
  end

  defp collect_from(ref, runner) do
    with {:ok, base} <- run(runner, ["merge-base", ref, "HEAD"]),
         base = String.trim(base),
         {:ok, diff} <- run(runner, ["diff", base | @diff_flags]) do
      {:ok, %{diff: diff <> untracked_diff(runner)}}
    end
  end

  # A file git has never seen is absent from `git diff` entirely, so a brand-new
  # interpreter module would be invisible to every check here.
  defp untracked_diff(runner) do
    case run(runner, ["ls-files", "--others", "--exclude-standard"]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, @lib_prefix))
        |> Enum.map_join(&added_file_diff(runner, &1))

      {:error, _reason} ->
        ""
    end
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

  defp run(runner, args) do
    case runner.(args) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, "git #{Enum.join(args, " ")} exited #{status}: #{output}"}
    end
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)

  # -- checks ---------------------------------------------------------------

  defp naming_findings(files) do
    for {path, entries} <- files,
        Regex.match?(@interpreter_pattern, path),
        entry <- entries,
        not cited?(entry),
        name = defined_name(entry.text),
        canonical = nearest_canonical(name) do
      finding(
        path,
        entry.line,
        "adr-0002-naming",
        "#{name} reads as a re-derived #{canonical}; ADR-0002 keeps the Appendix D name"
      )
    end
  end

  defp effects_findings(files) do
    pattern_findings(
      files,
      @effect_call_pattern,
      "adr-0003-effects",
      fn path ->
        String.starts_with?(path, @core_prefix) and path not in @effect_interpreter_paths
      end,
      "side effect in the pure core; ADR-0003 returns an effect for Statifier.Session to run"
    )
  end

  # An eval is a violation wherever it appears, not only in the core: ADR-0004
  # makes predicator the whole datamodel, with no ECMAScript escape hatch.
  defp eval_findings(files) do
    pattern_findings(
      files,
      @eval_call_pattern,
      "adr-0004-eval",
      &String.starts_with?(&1, @lib_prefix),
      "expression evaluated as Elixir; ADR-0004 makes predicator the datamodel"
    )
  end

  # `session.ex` is in scope here, unlike the effects check: it is exactly where
  # session IDs are generated, so it is where an ad-hoc ID would appear.
  defp uxid_findings(files) do
    pattern_findings(
      files,
      @uxid_adhoc_pattern,
      "adr-0008-uxid",
      &String.starts_with?(&1, @core_prefix),
      "identifier generated ad hoc; ADR-0008 makes generated IDs UXIDs"
    )
  end

  # ADR-0018: a bead ID is a process artifact, not a fact about the code, so it
  # does not belong in a comment or doc string. Scoped to lib/ and test/ only -
  # docs/adr, docs/plans, docs/research, the gate ledger and changelog
  # fragments are exempt by construction, since none of them start with either
  # prefix.
  defp bead_id_findings(files) do
    for {path, entries} <- files,
        bead_id_in_scope?(path),
        {entry, text} <- doc_context_texts(entries),
        not bead_cited?(entry),
        Regex.match?(@bead_id_pattern, text) do
      finding(
        path,
        entry.line,
        "adr-0018-bead-id",
        "bead ID in a comment or doc string; ADR-0018 routes that to the commit message, " <>
          "not the code"
      )
    end
  end

  defp bead_id_in_scope?(path) do
    String.starts_with?(path, @lib_prefix) or String.starts_with?(path, @test_prefix)
  end

  # Walks a file's added entries in line order, pairing each one that reads as
  # comment/doc text with the substring to check - the whole line for a `#`
  # comment or a heredoc body line, just the quoted content for a single-line
  # doc attribute or a test description. An entry that is plain code is
  # dropped. `in_heredoc?` only turns on when this same diff hunk carries the
  # opening `"""`, which is the line-based check's known blind spot: a body
  # line added into an already-existing heredoc is invisible to it. `previous`
  # is nil exactly at the first added line of each hunk (`parse_line/2` resets
  # it on every `@@` header), so it doubles as the hunk boundary: an heredoc
  # left open by a hunk whose closing `"""` was not itself added does not leak
  # "still inside a doc string" into the next, unrelated hunk.
  defp doc_context_texts(entries) do
    entries
    |> Enum.reduce({false, []}, fn entry, {in_heredoc?, acc} ->
      doc_context_step(entry, {in_heredoc? and entry.previous != nil, acc})
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp doc_context_step(entry, {true = _in_heredoc?, acc}) do
    trimmed = String.trim(entry.text)
    {trimmed != "\"\"\"", [{entry, entry.text} | acc]}
  end

  defp doc_context_step(entry, {false, acc}) do
    trimmed = String.trim(entry.text)

    cond do
      Regex.match?(@doc_heredoc_open_pattern, trimmed) ->
        {true, acc}

      String.starts_with?(trimmed, "#") ->
        {false, [{entry, entry.text} | acc]}

      text = quoted_doc_text(trimmed) ->
        {false, [{entry, text} | acc]}

      text = quoted_test_description(trimmed) ->
        {false, [{entry, text} | acc]}

      true ->
        {false, acc}
    end
  end

  defp quoted_doc_text(trimmed) do
    case Regex.run(@doc_single_line_pattern, trimmed) do
      [_all, text] -> text
      nil -> nil
    end
  end

  defp quoted_test_description(trimmed) do
    case Regex.run(@test_description_pattern, trimmed) do
      [_all, text] -> text
      nil -> nil
    end
  end

  defp bead_cited?(entry) do
    Regex.match?(@bead_escape_pattern, entry.text) or
      (entry.previous != nil and Regex.match?(@bead_escape_pattern, entry.previous))
  end

  defp pattern_findings(files, pattern, check, in_scope?, message) do
    for {path, entries} <- files,
        in_scope?.(path),
        entry <- entries,
        not cited?(entry),
        Regex.match?(pattern, entry.text) do
      finding(path, entry.line, check, message)
    end
  end

  defp cited?(entry) do
    Regex.match?(@escape_pattern, entry.text) or
      (entry.previous != nil and Regex.match?(@escape_pattern, entry.previous))
  end

  defp defined_name(text) do
    case Regex.run(@def_pattern, text) do
      [_all, name] -> name
      nil -> nil
    end
  end

  # An exact match is the compliant case and a distant one is an unrelated
  # helper; only the near miss in between is what ADR-0002 is about.
  defp nearest_canonical(name) do
    normalized = normalize(name)
    candidates = Enum.map(@appendix_d_names, &{&1, normalize(&1)})

    compliant? = Enum.any?(candidates, fn {_canonical, candidate} -> candidate == normalized end)

    if compliant? or String.length(normalized) < @min_name_length do
      nil
    else
      candidates
      |> Enum.filter(fn {_canonical, candidate} -> near_miss?(normalized, candidate) end)
      |> Enum.max_by(fn {_canonical, candidate} -> rank(normalized, candidate) end, fn -> nil end)
      |> case do
        {canonical, _candidate} -> canonical
        nil -> nil
      end
    end
  end

  defp near_miss?(normalized, candidate) do
    contained?(normalized, candidate) or
      String.jaro_distance(normalized, candidate) >= @naming_similarity_threshold
  end

  # Containment outranks similarity: `exitset` inside `computeexitset` is the
  # spec name with its qualifier dropped, which says more about which function
  # was meant than `exitstates` scoring a little higher on edit distance.
  defp rank(normalized, candidate) do
    {contained?(normalized, candidate), String.jaro_distance(normalized, candidate)}
  end

  defp contained?(normalized, candidate) do
    String.contains?(normalized, candidate) or String.contains?(candidate, normalized)
  end

  defp normalize(name) do
    name
    |> String.replace(["?", "!"], "")
    |> String.replace("_", "")
    |> String.downcase()
  end

  defp finding(path, line, check, message) do
    %{file: path, line: line, severity: "error", check: check, message: message}
  end

  # -- diff parsing ---------------------------------------------------------

  # Only added lines are checked: a check about what the code now does has
  # nothing to say about a line the diff removes. `previous` is the line above
  # in the same hunk, which is where an inline citation usually sits.
  defp parse_diff(diff) do
    {_path, _line, _previous, acc} =
      diff
      |> String.split("\n")
      |> Enum.reduce({nil, 0, nil, %{}}, &parse_line/2)

    Map.new(acc, fn {path, entries} -> {path, Enum.reverse(entries)} end)
  end

  defp parse_line("--- a/" <> path, {_path, _line, _previous, acc}), do: {path, 0, nil, acc}
  defp parse_line("--- " <> _rest, state), do: state
  defp parse_line("+++ /dev/null", state), do: state
  defp parse_line("+++ b/" <> path, {_path, _line, _previous, acc}), do: {path, 0, nil, acc}

  defp parse_line("@@" <> _rest = header, {path, _line, _previous, acc}),
    do: {path, hunk_start(header), nil, acc}

  defp parse_line("+" <> text, {path, line, previous, acc}) when is_binary(path) do
    entry = %{line: line, text: text, previous: previous}

    {path, line + 1, text, Map.update(acc, path, [entry], &[entry | &1])}
  end

  defp parse_line(" " <> text, {path, line, _previous, acc}), do: {path, line + 1, text, acc}
  defp parse_line(_other, state), do: state

  defp hunk_start(header) do
    case Regex.run(~r/^@@ -\S+ \+(\d+)/, header) do
      [_all, start] -> String.to_integer(start)
      nil -> 0
    end
  end
end
