defmodule Mix.Statifier.AdrGuard do
  @moduledoc """
  Flags likely violations of the mechanically-checkable ADRs in `docs/adr/`.

  Covers ADR-0002 (Appendix D naming), ADR-0003 (pure core with effects),
  ADR-0004 (predicator as the datamodel, so no `Code.eval_*`), ADR-0008
  (generated identifier formats), ADR-0018 (process artifacts are not code
  comments), and ADR-0058 (ADR number collisions). Each of the first five
  checks is a name or call-site pattern over the lines a diff adds -
  deliberately not an AST pass - so a false positive is cleared the way this
  project already clears an Appendix D deviation: an inline comment on or
  above the flagged line naming an ADR or the word "deviation".

  ADR-0058's tree-local checks, `adr-0058-duplicate-number` and
  `adr-0058-readme-index`, are different in kind from all five: they are
  invariants over the working tree's `docs/adr/` listing and its README table,
  not patterns over added diff lines. A finding from either carries `line:
  nil` - there is no line in a diff to point at, because the defect is a
  filename or a missing table row, not a line of code - and **neither clears
  on the `ADR-0\\d{3}|deviation` escape hatch**. There is no such thing as a
  justified duplicate ADR number, and an ADR citation is not a filename: the
  fix is a renumber and a README row move, never a suppression comment.

  ADR-0058 adds a third check, `adr-0058-base-number`: a branch-added
  `docs/adr/NNNN-*.md` whose number already exists on the base ref under a
  different filename. It differs from the two tree-local checks in a way
  ADR-0058 decision 2 states directly: "a finding from this half is always
  real (a collision it can see is a collision), but a pass from it promises
  nothing when `origin/main` is stale." The guarantee against a collision
  lives in the tree-local checks above, which run at the post-fetch,
  post-rebase gate `wurk:mr` performs. Because the base listing is taken at
  the merge-base, not the ref tip, a fetch alone never lets this check see a
  record that landed on main after the branch diverged - it fires once the
  rebase has put that record on the branch's base, by which point the
  tree-local checks fire too. What it alone catches is a branch that renames
  or renumbers an on-main record: one file per number in the tree keeps the
  duplicate check silent, while the merge-base still holds the number under
  the old filename (ADR-0058 decision 2 as amended 2026-08-19). **No
  document, skill, or report may cite a bare-gate ADR guard pass as evidence
  that no collision exists on the remote.**

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
  line inside a `\"""` doc heredoc. A doc heredoc's extent is read from the
  file's post-image text carried on `source` (populated by `collect/1`), not
  only from the diff hunk itself, so a body line added below an unchanged
  opening delimiter is still classified as doc text.

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

  `analyze/1` is pure - it takes a diff and returns findings. For the ADR-0018
  check, the file text a heredoc's extent is read from also arrives as plain
  data on `source`, rather than being fetched by `analyze/1` itself.
  `collect/1` is the part that talks to git and the filesystem, and takes
  `opts[:runner]` and `opts[:reader]` so tests never need a fixture
  repository.
  """

  @type finding :: %{
          file: String.t(),
          line: pos_integer() | nil,
          severity: String.t(),
          check: String.t(),
          message: String.t()
        }

  @type adr_index :: %{
          :files => [String.t()],
          :readme => String.t() | nil,
          optional(:base_files) => [String.t()]
        }

  @type source :: %{
          :diff => String.t(),
          optional(:files) => %{String.t() => String.t()},
          optional(:adr) => adr_index()
        }

  @lib_prefix "lib/"
  @core_prefix "lib/statifier/"
  @test_prefix "test/"

  # ADR-0003 names `Statifier.Session` as *the* production effect interpreter,
  # so it is the one core module allowed to do I/O. ADR-0027 adds
  # `Statifier.Supervisor`, the session runtime's registry-and-DynamicSupervisor
  # holder: it is the same design statement as `Statifier.Session` itself, not
  # a second one, since registration, lookup, monitor and start_child calls
  # all still happen inside `session.ex`. Excluding both is the design, not a
  # hole in the check.
  # `lib/statifier/session/telemetry.ex` (ADR-0040) joins the same list for the
  # same reason: it is not a second effect interpreter, it is the emission half
  # of the one ADR-0003 names, split out of session.ex only because
  # `.doctor.exs`'s 100% Doctor bar puts the event contract in a @moduledoc.
  # It holds no state, drives no core function, and is called from nowhere but
  # session.ex. ADR-0027's "argued, not defaulted" bar for a new exempt path is
  # answered here rather than by an ADR-0003 escape comment on every
  # :telemetry.execute/3 call site, which would be the same exemption spelled
  # ~10 times with no record.
  @effect_interpreter_paths [
    "lib/statifier/session.ex",
    "lib/statifier/supervisor.ex",
    "lib/statifier/session/telemetry.ex"
  ]

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
    :timer\. | :telemetry\. | Logger\.\w+\( | IO\.(puts|write|inspect)\( |
    File\.\w+!?\( | System\.cmd\( | Node\.\w+\( | :ets\. | Agent\.\w+!?\( |
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
    texts = Map.get(source, :files, %{})
    index = Map.get(source, :adr)

    naming_findings(files) ++
      effects_findings(files) ++
      eval_findings(files) ++
      uxid_findings(files) ++
      bead_id_findings(files, texts) ++
      duplicate_number_findings(index) ++
      readme_index_findings(index) ++
      base_number_findings(index)
  end

  @doc """
  Reads the diff the guard needs out of git.

  Base ref resolution is `opts[:base]`, then `origin/main`, then `main`. When
  none of them resolves there is nothing to diff against, so this returns
  `{:no_base_ref, source}` rather than guessing a base - the source still
  carries the tree-local `:adr` index (an empty `:diff`), because that half
  needs no base ref and the task runs it regardless; the diff-based and
  base-ref halves are what the task turns into a skipped stage.

  `opts[:runner]` replaces the `git` shell-out with a function of an argument
  list returning `{output, status}`, mirroring `Mix.Statifier.GateGuard`.
  `opts[:reader]` replaces the `File.read/1` call used to populate `:files`
  with a function of a path returning `{:ok, content} | {:error, reason}`,
  the same shape as `File.read/1` itself. `opts[:lister]` replaces the
  `File.ls/1` call used to gather `source.adr` - the `docs/adr/` numbering
  invariant's directory listing - with the same `{:ok, entries} | {:error,
  reason}` shape. Unlike the diff and the file reads, the `:adr` index is
  gathered unconditionally, even when no base ref resolves: it is a
  filesystem read, not a git one, so it costs nothing to compute up front and
  it is what lets the tree-local numbering checks run without a base ref.
  """
  @adr_dir "docs/adr"
  @adr_readme "docs/adr/README.md"
  @adr_filename_pattern ~r/^\d{4}-.+\.md$/

  @spec collect(opts :: keyword()) ::
          {:ok, source()} | {:no_base_ref, source()} | {:error, String.t()}
  def collect(opts) do
    runner = Keyword.get(opts, :runner, &git/1)
    reader = Keyword.get(opts, :reader, &File.read/1)
    lister = Keyword.get(opts, :lister, &File.ls/1)
    index = adr_index(lister, reader)
    candidates = Enum.reject([opts[:base], "origin/main", "main"], &is_nil/1)

    case Enum.find(candidates, &resolves?(&1, runner)) do
      nil -> {:no_base_ref, %{diff: "", adr: index}}
      ref -> collect_from(ref, runner, reader, index)
    end
  end

  defp collect_from(ref, runner, reader, index) do
    with {:ok, base} <- run(runner, ["merge-base", ref, "HEAD"]),
         base = String.trim(base),
         {:ok, diff} <- run(runner, ["diff", base | @diff_flags]) do
      full_diff = diff <> untracked_diff(runner)
      index = Map.put(index, :base_files, base_adr_files(runner, base))
      {:ok, %{diff: full_diff, files: file_texts(full_diff, reader), adr: index}}
    end
  end

  # Filenames only - the check compares numbers, and asking for anything more
  # would make the guard's data depend on blob contents it never reads.
  # Resolved against the merge base, not the ref tip: the question is "what
  # number existed at the point this branch diverged", and a merge-base
  # listing is what makes a number *added by this branch* distinguishable.
  defp base_adr_files(runner, base) do
    case run(runner, ["ls-tree", "--name-only", base, "docs/adr/"]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&Path.basename/1)
        |> Enum.filter(&Regex.match?(@adr_filename_pattern, &1))

      {:error, _reason} ->
        []
    end
  end

  # Deliberately a filesystem listing rather than a git one: the invariant is
  # about the working tree, so an untracked record that has not been committed
  # yet is still in scope.
  defp adr_index(lister, reader) do
    files =
      case lister.(@adr_dir) do
        {:ok, entries} ->
          entries |> Enum.filter(&Regex.match?(@adr_filename_pattern, &1)) |> Enum.sort()

        {:error, _reason} ->
          []
      end

    readme =
      case reader.(@adr_readme) do
        {:ok, text} -> text
        {:error, _reason} -> nil
      end

    %{files: files, readme: readme}
  end

  # Reads the post-image content of every `lib/` or `test/` path the assembled
  # diff names, so `analyze/1` can see inside a doc heredoc whose opener is
  # unchanged context. A path the reader cannot read (deleted between the diff
  # and the read, a race) is dropped rather than raised.
  defp file_texts(diff, reader) do
    diff
    |> String.split("\n")
    |> Enum.flat_map(fn
      "+++ /dev/null" -> []
      "+++ b/" <> path -> [path]
      _other -> []
    end)
    |> Enum.filter(&bead_id_in_scope?/1)
    |> Enum.reduce(%{}, fn path, acc ->
      case reader.(path) do
        {:ok, content} -> Map.put(acc, path, content)
        {:error, _reason} -> acc
      end
    end)
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
      "identifier generated ad hoc; ADR-0008 fixes the sess_/send_/inv_ id formats"
    )
  end

  # ADR-0018: a bead ID is a process artifact, not a fact about the code, so it
  # does not belong in a comment or doc string. Scoped to lib/ and test/ only -
  # docs/adr, docs/plans, docs/research, the gate ledger and changelog
  # fragments are exempt by construction, since none of them start with either
  # prefix.
  defp bead_id_findings(files, texts) do
    for {path, entries} <- files,
        bead_id_in_scope?(path),
        {entry, text} <- doc_context_texts(entries, Map.get(texts, path)),
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
  # dropped. The seed flag going into `doc_context_step/2` is an OR of two
  # halves: the hunk-local half, `in_heredoc? and entry.previous != nil`, which
  # is true only when this same diff hunk carries the opening `"""`; and the
  # file-derived half, `MapSet.member?(body_lines, entry.line)`, which is true
  # when the entry's line falls inside `doc_heredoc_body_lines/1`'s span for
  # the file's post-image text (absent when `file_text` is `nil`, e.g. a
  # hand-built source with no `:files` map). `previous` is nil exactly at the
  # first added line of each hunk (`parse_line/2` resets it on every `@@`
  # header), so it still bounds the hunk-local half: a heredoc left open by a
  # hunk whose closing `"""` was not itself added does not leak "still inside
  # a doc string" into the next, unrelated hunk. The file-derived half has no
  # such boundary to bound - it is keyed by line number in the file, not by
  # hunk.
  defp doc_context_texts(entries, file_text) do
    body_lines = doc_heredoc_body_lines(file_text)

    entries
    |> Enum.reduce({false, []}, fn entry, {in_heredoc?, acc} ->
      carried? = in_heredoc? and entry.previous != nil
      seed? = carried? or MapSet.member?(body_lines, entry.line)
      doc_context_step(entry, {seed?, acc})
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  # Empty for a source with no post-image text (the fallback path). Otherwise
  # walks the file's lines with a 1-based index, opening a heredoc-body span on
  # `@doc_heredoc_open_pattern` and closing it on a trimmed `"""`, collecting
  # every line number strictly between the delimiters. A moduledoc that never
  # closes simply runs the span to end of file, which the reduce tolerates.
  defp doc_heredoc_body_lines(nil), do: MapSet.new()

  defp doc_heredoc_body_lines(file_text) do
    file_text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({false, MapSet.new()}, fn {line, index}, {in_heredoc?, acc} ->
      trimmed = String.trim(line)

      cond do
        in_heredoc? and trimmed == "\"\"\"" -> {false, acc}
        in_heredoc? -> {true, MapSet.put(acc, index)}
        Regex.match?(@doc_heredoc_open_pattern, trimmed) -> {true, acc}
        true -> {false, acc}
      end
    end)
    |> elem(1)
  end

  # second element of the accumulator tuple: inside a doc heredoc?
  defp doc_context_step(entry, {true, acc}) do
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
      nearest_near_miss(candidates, normalized)
    end
  end

  defp nearest_near_miss(candidates, normalized) do
    near_misses =
      Enum.filter(candidates, fn {_canonical, candidate} -> near_miss?(normalized, candidate) end)

    case Enum.max_by(
           near_misses,
           fn {_canonical, candidate} -> rank(normalized, candidate) end,
           fn -> nil end
         ) do
      {canonical, _candidate} -> canonical
      nil -> nil
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

  # -- ADR-0058: the tree-local numbering invariant --------------------------

  @adr_number_pattern ~r/^(\d{4})-/

  # Scoped by link target, per ADR-0058 open question 2: only rows whose link
  # resolves to a record file in this directory are index rows. A future row
  # linking a predicator-ex ADR, a wurk ADR, or an http(s) URL is not this
  # check's business, and neither is the footer prose below the table.
  @readme_row_pattern ~r/^\|\s*\[(\d{4})\]\((\d{4}-[^)\/]+\.md)\)/m

  defp adr_number(file) do
    case Regex.run(@adr_number_pattern, file) do
      [_all, number] -> number
      nil -> nil
    end
  end

  defp duplicate_number_findings(nil), do: []

  defp duplicate_number_findings(%{files: files}) do
    groups =
      files
      |> Enum.group_by(&adr_number/1)
      |> Map.delete(nil)

    for {number, group} <- groups,
        length(group) > 1,
        file <- group do
      others = group |> List.delete(file) |> Enum.map(&Path.join(@adr_dir, &1))

      finding(
        Path.join(@adr_dir, file),
        nil,
        "adr-0058-duplicate-number",
        "ADR number #{number} is used by two records; ADR-0058 requires one file per number " <>
          "(also: #{Enum.join(others, ", ")})"
      )
    end
  end

  defp readme_index_findings(nil), do: []

  defp readme_index_findings(%{files: files, readme: nil}) when files != [] do
    [
      finding(
        @adr_readme,
        nil,
        "adr-0058-readme-index",
        "docs/adr/README.md could not be read; ADR-0058's index cannot be checked against it"
      )
    ]
  end

  defp readme_index_findings(%{readme: nil}), do: []

  defp readme_index_findings(%{files: files, readme: readme}) do
    rows = Regex.scan(@readme_row_pattern, readme, capture: :all_but_first)

    missing_row_findings(files, rows) ++
      dangling_row_findings(files, rows) ++
      duplicate_row_findings(rows)
  end

  defp missing_row_findings(files, rows) do
    linked = MapSet.new(rows, fn [_number, target] -> target end)

    for file <- files, not MapSet.member?(linked, file) do
      finding(
        Path.join(@adr_dir, file),
        nil,
        "adr-0058-readme-index",
        "#{Path.join(@adr_dir, file)} has no docs/adr/README.md table row linking it"
      )
    end
  end

  defp dangling_row_findings(files, rows) do
    listed = MapSet.new(files)

    for [_number, target] <- rows, not MapSet.member?(listed, target) do
      finding(
        @adr_readme,
        nil,
        "adr-0058-readme-index",
        "docs/adr/README.md links #{target}, which does not exist in docs/adr/"
      )
    end
  end

  defp duplicate_row_findings(rows) do
    duplicate_number_row_findings(rows) ++ duplicate_target_row_findings(rows)
  end

  defp duplicate_number_row_findings(rows) do
    rows
    |> Enum.group_by(fn [number, _target] -> number end)
    |> Enum.filter(fn {_number, group} -> length(group) > 1 end)
    |> Enum.map(fn {number, _group} ->
      finding(
        @adr_readme,
        nil,
        "adr-0058-readme-index",
        "docs/adr/README.md has more than one row for ADR number #{number}"
      )
    end)
  end

  defp duplicate_target_row_findings(rows) do
    rows
    |> Enum.group_by(fn [_number, target] -> target end)
    |> Enum.filter(fn {_target, group} -> length(group) > 1 end)
    |> Enum.map(fn {target, _group} ->
      finding(
        @adr_readme,
        nil,
        "adr-0058-readme-index",
        "docs/adr/README.md has more than one row linking #{target}"
      )
    end)
  end

  # -- ADR-0058: the base-ref early-warning half ------------------------------

  # Early warning only, per ADR-0058 decision 2: a finding is always real, but
  # a pass promises nothing when the base ref (`:base_files`) is stale - see
  # the moduledoc. Absent `:base_files` (the no-base-ref source, or any
  # hand-built source) this returns [] rather than raising, so the guard's
  # other checks stay usable without a base ref.
  defp base_number_findings(%{base_files: base_files, files: files}) do
    base_by_number = Map.new(base_files, &{adr_number(&1), &1})

    for file <- files,
        file not in base_files,
        number = adr_number(file),
        number != nil,
        base_file = Map.get(base_by_number, number),
        base_file != nil do
      finding(
        Path.join(@adr_dir, file),
        nil,
        "adr-0058-base-number",
        "ADR number #{number} already exists on the base ref as " <>
          "#{Path.join(@adr_dir, base_file)}; ADR-0058 requires renumbering before merge"
      )
    end
  end

  defp base_number_findings(_index), do: []

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
