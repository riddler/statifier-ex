defmodule Mix.Statifier.AdrGuardTest do
  use ExUnit.Case, async: true

  alias Mix.Statifier.AdrGuard

  # Every test drives the analyzer with a hand-written unified diff, so nothing
  # here needs a fixture repository, a real git history, or interpreter code
  # that does not exist yet.
  defp file_diff(path, added, start \\ 10) do
    body = Enum.map_join(added, "\n", &("+" <> &1))

    """
    diff --git a/#{path} b/#{path}
    index 1111111..2222222 100644
    --- a/#{path}
    +++ b/#{path}
    @@ -#{start},0 +#{start},#{length(added)} @@
    #{body}
    """
  end

  defp analyze(path, added, start \\ 10) do
    AdrGuard.analyze(%{diff: file_diff(path, added, start)})
  end

  describe "ADR-0002 - Appendix D naming" do
    # sabotage: drop the exact-match rejection from nearest_canonical/1, so a
    #           compliant spec name is reported as a near miss -> red
    test "an exactly spelled Appendix D name is compliant" do
      for name <- AdrGuard.appendix_d_names() do
        assert analyze("lib/statifier/interpreter.ex", ["  defp #{name}(state) do"]) == []
      end
    end

    # The shape ADR-0002 is about: the spec function re-derived under a name the
    # author reached for instead of the one the spec uses.
    # sabotage: raise @naming_similarity_threshold to 0.9 and drop the substring
    #           clause from near_miss?/2 -> red on exitset
    test "a name close to a spec name but not it is a near miss" do
      for {name, canonical} <- [
            {"exitset", "compute_exit_set"},
            {"enter_state", "enter_states"},
            {"microsteps", "microstep"},
            {"transition_domain", "get_transition_domain"},
            {"in_final?", "is_in_final_state"}
          ] do
        assert [finding] = analyze("lib/statifier/interpreter.ex", ["  defp #{name}(state) do"])

        assert %{check: "adr-0002-naming", severity: "error", line: 10} = finding
        assert finding.message =~ canonical
      end
    end

    # sabotage: drop the @min_name_length guard, so `state` matches inside
    #           `enter_states` -> red
    test "an unrelated helper is none of this check's business" do
      for name <- ~w(state build new parse_attributes resolve_target apply_effect) do
        assert analyze("lib/statifier/interpreter.ex", ["  defp #{name}(state) do"]) == []
      end
    end

    # sabotage: scope naming_findings/1 to @core_prefix instead of
    #           @interpreter_pattern -> red
    test "a near miss outside the interpreter files is not a naming finding" do
      assert analyze("lib/statifier/document.ex", ["  defp exitset(state) do"]) == []
    end

    # sabotage: drop the `defp?\s+` requirement from @def_pattern, so the first
    #           name on any line reads as a definition -> red
    test "a call to a near-miss name is not a definition of one" do
      assert analyze("lib/statifier/interpreter.ex", ["    exitset(state)"]) == []
      assert analyze("lib/statifier/interpreter.ex", ["    config = exitset(state)"]) == []
    end
  end

  describe "ADR-0003 - pure core with effects" do
    # sabotage: drop the Logger alternative from @effect_call_pattern -> red
    test "an effect performed in the core fires" do
      for line <- [
            "    GenServer.call(pid, :step)",
            "  use GenServer",
            "    Process.send_after(self(), :tick, 100)",
            "    :timer.sleep(10)",
            "    Logger.debug(\"stepping\")",
            "    IO.puts(\"stepping\")",
            "    File.read!(path)",
            "    System.cmd(\"echo\", [])",
            "    :ets.insert(table, entry)",
            "    Task.async(fn -> run() end)",
            "    spawn(fn -> run() end)",
            "    receive do"
          ] do
        assert [%{check: "adr-0003-effects", line: 10}] =
                 analyze("lib/statifier/interpreter.ex", [line])
      end
    end

    # ADR-0003 names Statifier.Session as *the* production effect interpreter,
    # so I/O there is the design rather than a violation of it.
    # sabotage: drop @effect_interpreter_paths from the scope predicate -> red
    test "the effect interpreter itself is allowed to perform effects" do
      assert analyze("lib/statifier/session.ex", ["    GenServer.call(pid, :step)"]) == []
    end

    # sabotage: scope effects_findings/1 to @lib_prefix instead of
    #           @core_prefix -> red
    test "the mix-task machinery is not the pure core" do
      assert analyze("lib/mix/statifier/gate_guard.ex", ["    System.cmd(\"git\", args)"]) == []
    end

    # ADR-0040: the pure core never calls :telemetry directly - the trace
    # effects are the instrumentation stream, and Statifier.Session.Telemetry
    # is the one interpreter of them.
    # sabotage: drop the :telemetry\. alternative from @effect_call_pattern -> red
    test "a :telemetry call in the core fires" do
      assert [%{check: "adr-0003-effects", line: 10}] =
               analyze("lib/statifier/interpreter.ex", [
                 "    :telemetry.execute([:statifier, :session, :effect], measurements, metadata)"
               ])
    end

    # The pre-existing exemption: session.ex is the effect interpreter ADR-0003
    # names, so a :telemetry call there is the design, not a violation.
    # sabotage: drop "lib/statifier/session.ex" from @effect_interpreter_paths -> red
    test "a :telemetry call in session.ex is exempt" do
      assert analyze("lib/statifier/session.ex", [
               "    :telemetry.execute([:statifier, :session, :effect], measurements, metadata)"
             ]) == []
    end

    # ADR-0040's new exemption: the :telemetry.execute/3 call sites live in
    # session/telemetry.ex, the emission half of the same effect interpreter,
    # split out only because .doctor.exs's 100% bar puts the event contract in
    # a @moduledoc. This is what makes the exemption load-bearing rather than
    # an unverified assertion.
    # sabotage: drop "lib/statifier/session/telemetry.ex" from
    #           @effect_interpreter_paths -> red
    test "a :telemetry call in session/telemetry.ex is exempt" do
      assert analyze("lib/statifier/session/telemetry.ex", [
               "    :telemetry.execute([:statifier, :session, :effect], measurements, metadata)"
             ]) == []
    end

    # The general inline-citation escape hatch also clears a :telemetry
    # finding in a non-exempt path, same as any other @effect_call_pattern hit.
    # sabotage: drop the entry.previous clause from cited?/1 -> red
    test "a :telemetry call with an ADR-0003 citation above it is not a finding" do
      assert analyze("lib/statifier/interpreter.ex", [
               "    # ADR-0003: deviation, trace sink reads a counter for a bug report",
               "    :telemetry.execute([:statifier, :session, :effect], measurements, metadata)"
             ]) == []
    end
  end

  describe "ADR-0004 - predicator as the datamodel" do
    # sabotage: drop the eval_quoted alternative from @eval_call_pattern -> red
    test "evaluating an expression as Elixir fires anywhere under lib/" do
      for path <- ["lib/statifier/interpreter.ex", "lib/statifier.ex"] do
        assert [%{check: "adr-0004-eval"}] =
                 analyze(path, ["    Code.eval_string(expression)"])

        assert [%{check: "adr-0004-eval"}] = analyze(path, ["    Code.eval_quoted(ast)"])
      end
    end
  end

  describe "ADR-0008 - generated identifier formats" do
    # sabotage: drop the unique_integer alternatives from
    #           @uxid_adhoc_pattern -> red
    test "an ad-hoc generated identifier fires" do
      for line <- [
            "    id = :crypto.strong_rand_bytes(16)",
            "    id = UUID.uuid4()",
            "    id = Ecto.UUID.generate()",
            "    id = System.unique_integer([:positive])",
            "    id = :erlang.unique_integer()"
          ] do
        assert [%{check: "adr-0008-uxid"}] = analyze("lib/statifier/session.ex", [line])
      end
    end

    # Unlike the effects check, session.ex is in scope here: it is exactly where
    # session IDs are generated, so it is where an ad-hoc one would appear.
    # sabotage: exclude @effect_interpreter_paths from uxid_findings/1 too -> red
    test "the session is where an ad-hoc identifier matters most" do
      assert [%{file: "lib/statifier/session.ex", check: "adr-0008-uxid"}] =
               analyze("lib/statifier/session.ex", ["    id = UUID.uuid4()"])
    end
  end

  describe "the inline-citation escape hatch" do
    # sabotage: drop the entry.text clause from cited?/1 -> red
    test "a citation on the line itself clears the finding" do
      assert analyze("lib/statifier/interpreter.ex", [
               "    Logger.debug(\"x\") # ADR-0003: trace effect, see docs/observability.md"
             ]) == []
    end

    # sabotage: drop the entry.previous clause from cited?/1 -> red
    test "a citation on the line above clears the finding" do
      assert analyze("lib/statifier/interpreter.ex", [
               "    # deviation: mechanical, the trace sink is injected here",
               "    Logger.debug(\"x\")"
             ]) == []
    end

    # sabotage: loosen @escape_pattern to any `#` comment -> red
    test "a comment that cites nothing clears nothing" do
      assert [%{check: "adr-0003-effects"}] =
               analyze("lib/statifier/interpreter.ex", ["    Logger.debug(\"x\") # noisy"])
    end

    # sabotage: have parse_line/2 carry `previous` across the hunk header -> red
    test "a citation in an earlier hunk does not reach into a later one" do
      diff = """
      diff --git a/lib/statifier/interpreter.ex b/lib/statifier/interpreter.ex
      --- a/lib/statifier/interpreter.ex
      +++ b/lib/statifier/interpreter.ex
      @@ -5,0 +5,1 @@
      +  # ADR-0003: effects are returned, not performed
      @@ -40,0 +40,1 @@
      +    Logger.debug("x")
      """

      assert [%{line: 40, check: "adr-0003-effects"}] = AdrGuard.analyze(%{diff: diff})
    end
  end

  # sabotage: have parse_line/2 count removed lines toward the new line
  #           number -> red
  test "line numbers survive a hunk that also removes lines" do
    diff = """
    diff --git a/lib/statifier/interpreter.ex b/lib/statifier/interpreter.ex
    --- a/lib/statifier/interpreter.ex
    +++ b/lib/statifier/interpreter.ex
    @@ -5,2 +5,3 @@
    -  old line
    -  another old line
     context line
    +    Logger.debug("x")
    """

    assert [%{line: 6, check: "adr-0003-effects"}] = AdrGuard.analyze(%{diff: diff})
  end

  # sabotage: have parse_line/2 treat removed lines as added ones -> red
  test "a removed effect call is not a finding" do
    diff = """
    diff --git a/lib/statifier/interpreter.ex b/lib/statifier/interpreter.ex
    --- a/lib/statifier/interpreter.ex
    +++ b/lib/statifier/interpreter.ex
    @@ -5,1 +5,0 @@
    -    Logger.debug("x")
    """

    assert AdrGuard.analyze(%{diff: diff}) == []
  end

  # sabotage: have the `+++ b/` clause leave the path alone, so an added file's
  #           hunk lands on the file before it in the diff -> red
  test "an added file is attributed to its new path, not the previous one" do
    diff =
      file_diff("lib/statifier/document.ex", ["    Logger.debug(\"x\")"]) <>
        """
        diff --git a/lib/statifier/interpreter.ex b/lib/statifier/interpreter.ex
        new file mode 100644
        --- /dev/null
        +++ b/lib/statifier/interpreter.ex
        @@ -0,0 +1,1 @@
        +  defp exitset(state) do
        """

    assert [
             %{file: "lib/statifier/document.ex", check: "adr-0003-effects"},
             %{file: "lib/statifier/interpreter.ex", check: "adr-0002-naming", line: 1}
           ] = Enum.sort_by(AdrGuard.analyze(%{diff: diff}), & &1.file)
  end

  # The eval check is the widest-scoped of the four; even it stops at lib/.
  # sabotage: widen eval_findings/1's scope predicate to every path -> red
  test "a diff that touches nothing under lib/ has nothing to report" do
    diff = file_diff("docs/adr/0013-something.md", ["    Code.eval_string(expression)"])

    assert AdrGuard.analyze(%{diff: diff}) == []
  end

  describe "ADR-0018 - process artifacts are not code comments" do
    # sabotage: drop the `#` clause from doc_context_step/2 -> red
    test "a bead ID in a line comment fires" do
      for id <- ["st-af3", "st-wju.4", "st-l5k.5"] do
        assert [%{check: "adr-0018-bead-id", line: 10}] =
                 analyze("lib/statifier/document.ex", [
                   "    # #{id} replaces this function's body"
                 ])
      end
    end

    # A dotted child is optional, not required: making the dot mandatory would
    # break a bare parent id, the shape the loop above already covers.
    # sabotage: change @bead_id_pattern's `(?:\.[a-z0-9]+)*` to
    #           `(?:\.[a-z0-9]+)` (mandatory instead of optional) -> red on the
    #           un-dotted id
    test "a bead ID's dotted child is optional" do
      assert [%{check: "adr-0018-bead-id"}] =
               analyze("lib/statifier/document.ex", ["    # see st-af3 for context"])
    end

    # sabotage: replace @doc_single_line_pattern's capture with the literal
    #           attribute keyword only, so no doc content is ever checked -> red
    test "a bead ID in a single-line moduledoc, doc or typedoc fires" do
      for attr <- ~w(moduledoc doc typedoc) do
        assert [%{check: "adr-0018-bead-id"}] =
                 analyze("lib/statifier/document.ex", [~s(  @#{attr} "st-af3 explains this")])
      end
    end

    # sabotage: drop the test-description clause from doc_context_step/2 -> red
    test "a bead ID in a test description fires" do
      assert [%{check: "adr-0018-bead-id"}] =
               analyze("test/statifier/document_test.exs", [
                 ~s(  test "st-af3 handles the empty document" do)
               ])
    end

    # sabotage: drop the heredoc-open clause from doc_context_step/2, so a doc
    #           heredoc body is never treated as comment text -> red
    test "a bead ID inside a doc heredoc added in the same hunk fires" do
      diff = """
      diff --git a/lib/statifier/document.ex b/lib/statifier/document.ex
      --- a/lib/statifier/document.ex
      +++ b/lib/statifier/document.ex
      @@ -10,0 +10,3 @@
      +  @moduledoc \"\"\"
      +  st-af3 explains why this module exists.
      +  \"\"\"
      """

      assert [%{check: "adr-0018-bead-id", line: 11}] = AdrGuard.analyze(%{diff: diff})
    end

    # A bead ID added mid-body into a heredoc whose opening `\"\"\"` is unchanged
    # context is invisible to the diff hunk alone - this is the case the
    # file-derived heredoc-body set closes: the post-image text on `:files`
    # carries the moduledoc's extent even though its opener never appears
    # above.
    # sabotage: have doc_context_texts/2 ignore the file-derived body-line set -> red
    test "a bead ID added into a heredoc whose opener is not in the diff is still caught" do
      diff = """
      diff --git a/lib/statifier/document.ex b/lib/statifier/document.ex
      --- a/lib/statifier/document.ex
      +++ b/lib/statifier/document.ex
      @@ -11,0 +11,1 @@
      +  st-af3 explains why this module exists.
      """

      file_text = """
      defmodule Statifier.Document do
        @moduledoc \"\"\"
        Line 3.
        Line 4.
        Line 5.
        Line 6.
        Line 7.
        Line 8.
        Line 9.
        Line 10.
        st-af3 explains why this module exists.
        Line 12.
        \"\"\"
      end
      """

      assert [%{check: "adr-0018-bead-id", line: 11}] =
               AdrGuard.analyze(%{diff: diff, files: %{"lib/statifier/document.ex" => file_text}})
    end

    # Documents the degradation when a source carries no post-image text
    # rather than leaving it implicit: with no `:files` key, the file-derived
    # half of the seed flag contributes nothing, and the hunk-local fallback
    # (no opener in this hunk) reports no finding.
    # sabotage: have doc_heredoc_body_lines/1 raise on nil instead of returning an empty set -> red
    test "a bead ID added into a heredoc whose opener is not in the diff, with no file text supplied, is not caught" do
      diff = """
      diff --git a/lib/statifier/document.ex b/lib/statifier/document.ex
      --- a/lib/statifier/document.ex
      +++ b/lib/statifier/document.ex
      @@ -11,0 +11,1 @@
      +  st-af3 explains why this module exists.
      """

      assert AdrGuard.analyze(%{diff: diff}) == []
    end

    # sabotage: have doc_context_texts/1 carry in_heredoc? across a hunk
    #           boundary instead of resetting on entry.previous == nil -> red
    #           (fires a second time on the unrelated later hunk's plain code)
    test "an unclosed heredoc in one hunk does not swallow a later, unrelated hunk" do
      diff = """
      diff --git a/lib/statifier/document.ex b/lib/statifier/document.ex
      --- a/lib/statifier/document.ex
      +++ b/lib/statifier/document.ex
      @@ -10,0 +10,1 @@
      +  @moduledoc \"\"\"
      @@ -40,0 +41,1 @@
      +    id = "st-af3"
      """

      assert AdrGuard.analyze(%{diff: diff}) == []
    end

    # The check is about comment/doc text, not code: a bead-ID-shaped string
    # literal used as ordinary data is none of this check's business.
    # sabotage: check entry.text instead of the doc_context_texts/1 pairing in
    #           bead_id_findings/1, so every added line is checked regardless
    #           of context -> red
    test "a bead ID inside ordinary code is not a comment or doc string" do
      assert analyze("lib/statifier/document.ex", ["    id = \"st-af3\""]) == []
    end

    # sabotage: drop the lookbehind/lookahead pair from @bead_id_pattern -> red
    #           (fires on "cost-effective" and "21st-century")
    test "a hyphenated word that merely contains st- is not a bead ID" do
      assert analyze("lib/statifier/document.ex", [
               "    # the cost-effective, 21st-century approach"
             ]) == []
    end

    # sabotage: have bead_id_in_scope?/1 return true unconditionally, so
    #           docs/adr/ is in scope too -> red
    test "a bead ID outside lib/ and test/ is not flagged" do
      assert analyze("docs/adr/0013-something.md", ["# st-af3 is discussed here"]) == []
    end

    # sabotage: drop @bead_escape_pattern's entry.text clause from
    #           bead_cited?/1 -> red
    test "the ADR-0018-exempt marker on the line itself clears the finding" do
      assert analyze("lib/statifier/document.ex", [
               "    # st-af3 named for git blame, ADR-0018-exempt"
             ]) == []
    end

    # sabotage: drop @bead_escape_pattern's entry.previous clause from
    #           bead_cited?/1 -> red
    test "the ADR-0018-exempt marker on the line above clears the finding" do
      assert analyze("lib/statifier/document.ex", [
               "    # ADR-0018-exempt: named for git blame",
               "    # st-af3 replaces this function's body"
             ]) == []
    end

    # This is the exact accident ADR-0018's Consequences document at e2524fc:
    # a correct, unrelated ADR citation must not clear a bead-ID finding.
    # sabotage: have bead_cited?/1 call the shared cited?/1 (@escape_pattern)
    #           instead of its own @bead_escape_pattern -> red (this becomes
    #           [] instead of a finding)
    test "an ordinary ADR citation does not clear the finding" do
      assert [%{check: "adr-0018-bead-id"}] =
               analyze("lib/statifier/document.ex", [
                 "    # see ADR-0012 item 3, added under st-af3"
               ])
    end

    # sabotage: have bead_cited?/1 call the shared cited?/1 (@escape_pattern)
    #           instead of its own @bead_escape_pattern -> red (this is the
    #           same mutation as the test above; it also happens to be the
    #           one that lets the bare word "deviation" clear this check too)
    test "the word deviation does not clear the finding either" do
      assert [%{check: "adr-0018-bead-id"}] =
               analyze("lib/statifier/document.ex", [
                 "    # deviation from the plan, tracked as st-af3"
               ])
    end
  end

  describe "ADR-0058 - numbering invariant" do
    defp analyze_adr(index) do
      AdrGuard.analyze(%{diff: "", adr: index})
    end

    # sabotage: drop missing_row_findings/2's `not` (see two tests below),
    #           so a consistent tree's linked files are wrongly flagged -> red
    test "a consistent directory and table produce no findings" do
      readme = """
      | # | Decision | Status |
      |---|---|---|
      | [0001](0001-first.md) | First | accepted |
      | [0002](0002-second.md) | Second | accepted |
      """

      assert analyze_adr(%{files: ["0001-first.md", "0002-second.md"], readme: readme}) == []
    end

    # sabotage: change `file <- group` to `file <- Enum.take(group, 1)`, so
    #           only one finding is emitted per collision instead of one per
    #           file -> red
    test "two files sharing a number produce two findings, each naming the other" do
      readme = """
      | # | Decision | Status |
      |---|---|---|
      | [0052](0052-a.md) | A | accepted |
      | [0052](0052-b.md) | B | accepted |
      """

      findings =
        analyze_adr(%{files: ["0052-a.md", "0052-b.md"], readme: readme})
        |> Enum.filter(&(&1.check == "adr-0058-duplicate-number"))

      assert length(findings) == 2

      assert Enum.any?(findings, fn f ->
               f.file == "docs/adr/0052-a.md" and f.line == nil and f.message =~ "0052-b.md"
             end)

      assert Enum.any?(findings, fn f ->
               f.file == "docs/adr/0052-b.md" and f.message =~ "0052-a.md"
             end)
    end

    # sabotage: drop missing_row_findings/2's negation - `MapSet.member?(linked,
    #           file)` instead of `not MapSet.member?(...)` -> red
    test "a record with no row produces a missing-row finding naming the record" do
      readme = """
      | # | Decision | Status |
      |---|---|---|
      | [0001](0001-first.md) | First | accepted |
      """

      assert [%{check: "adr-0058-readme-index", file: "docs/adr/0002-second.md", line: nil}] =
               analyze_adr(%{files: ["0001-first.md", "0002-second.md"], readme: readme})
    end

    # sabotage: drop dangling_row_findings/2's negation - `MapSet.member?(listed,
    #           target)` instead of `not MapSet.member?(...)` -> red
    test "a row whose link target does not exist produces a dangling-row finding" do
      readme = """
      | # | Decision | Status |
      |---|---|---|
      | [0001](0001-first.md) | First | accepted |
      | [0002](0002-ghost.md) | Ghost | accepted |
      """

      assert [%{check: "adr-0058-readme-index", file: "docs/adr/README.md", message: message}] =
               analyze_adr(%{files: ["0001-first.md"], readme: readme})

      assert message =~ "0002-ghost.md"
    end

    # sabotage: have duplicate_number_row_findings/1 group by `target` (the
    #           same grouping duplicate_target_row_findings/1 uses) instead of
    #           `number`, so a number reused under two distinct targets goes
    #           undetected -> red
    test "two rows for the same number produce a duplicate-row finding" do
      readme = """
      | # | Decision | Status |
      |---|---|---|
      | [0001](0001-first.md) | First | accepted |
      | [0001](0002-second.md) | Mislabeled | accepted |
      """

      assert [%{check: "adr-0058-readme-index", file: "docs/adr/README.md", message: message}] =
               analyze_adr(%{files: ["0001-first.md", "0002-second.md"], readme: readme})

      assert message =~ "0001"
    end

    # Without this finding, a deleted README would make the bijection
    # vacuously true - the silent-pass shape ADR-0058 exists to avoid.
    # sabotage: have the `files != []` clause return `[]` instead of the
    #           unreadable-README finding -> red
    test "a nil readme with a non-empty listing produces the unreadable finding" do
      assert [%{check: "adr-0058-readme-index", file: "docs/adr/README.md"}] =
               analyze_adr(%{files: ["0001-first.md"], readme: nil})
    end

    # sabotage: drop the `files != []` guard from the unreadable-README clause
    #           entirely, so it also matches the empty-checkout case -> red
    test "an empty listing with a nil readme produces nothing" do
      assert analyze_adr(%{files: [], readme: nil}) == []
    end

    # sabotage: drop the `^\|\s*` anchor from @readme_row_pattern, so a
    #           row-shaped reference in footer prose (not a table row) is read
    #           as a row too -> red
    test "footer prose with a parenthesized .md reference produces no dangling finding" do
      readme = """
      | # | Decision | Status |
      |---|---|---|
      | [0001](0001-first.md) | First | accepted |

      New ADRs: see [0037](0037-unbound.md) for the historical precedent, but
      that is prose, not a table row.
      """

      assert analyze_adr(%{files: ["0001-first.md"], readme: readme}) == []
    end

    # sabotage: widen the link-target capture from `(\d{4}-[^)\/]+\.md)` to
    #           `([^)]+\.md)`, so a slash-bearing or non-numeric target
    #           matches too -> red
    test "a row linking outside docs/adr/ is ignored by both halves" do
      readme = """
      | # | Decision | Status |
      |---|---|---|
      | [0001](0001-first.md) | First | accepted |
      | [0002](../../other/docs/adr/0002-elsewhere.md) | Elsewhere | accepted |
      | [0003](https://example.com/0003-remote.md) | Remote | accepted |
      """

      assert analyze_adr(%{files: ["0001-first.md"], readme: readme}) == []
    end

    # sabotage: drop the `defp duplicate_number_findings(nil), do: []` head, so
    #           a source with no :adr key raises FunctionClauseError instead of
    #           being tolerated -> red
    test "analyze/1 with no :adr key returns only diff-line findings" do
      diff = """
      diff --git a/lib/statifier/interpreter.ex b/lib/statifier/interpreter.ex
      --- a/lib/statifier/interpreter.ex
      +++ b/lib/statifier/interpreter.ex
      @@ -40,0 +40,1 @@
      +    Logger.debug("x")
      """

      assert [%{check: "adr-0003-effects"}] = AdrGuard.analyze(%{diff: diff})
    end
  end

  describe "ADR-0058 - the base-ref early-warning half" do
    # sabotage: drop the `not` from `file not in base_files`, so a branch file
    #           absent from the base tree under a different filename fails the
    #           membership filter and no finding is emitted -> red
    test "a branch file whose number exists on the base under a different name is a finding" do
      readme = """
      | # | Decision | Status |
      |---|---|---|
      | [0052](0052-b.md) | B | accepted |
      """

      index = %{
        files: ["0052-b.md"],
        readme: readme,
        base_files: ["0052-a.md"]
      }

      assert [
               %{
                 file: "docs/adr/0052-b.md",
                 line: nil,
                 check: "adr-0058-base-number",
                 message: message
               }
             ] = AdrGuard.analyze(%{diff: "", adr: index})

      assert message =~ "0052-a.md"
      assert message =~ "0052"
    end

    # An edit to an existing record - the branch's file is the same filename
    # the base ref already has under that number - is not a new collision.
    # sabotage: drop the `file not in base_files` filter entirely, so a file
    #           present under its own name on the base also self-matches -> red
    test "the same number under the same filename is not a finding" do
      index = %{
        files: ["0052-a.md"],
        readme: nil,
        base_files: ["0052-a.md"]
      }

      assert AdrGuard.analyze(%{diff: "", adr: index})
             |> Enum.filter(&(&1.check == "adr-0058-base-number")) == []
    end

    # sabotage: change the base-file lookup from `Map.get(base_by_number,
    #           number)` to `List.first(base_files)`, so a branch file's
    #           number matches whatever base file happens to be first,
    #           regardless of whether that number actually exists there -> red
    test "a number absent from the base is not a finding" do
      index = %{
        files: ["0057-new.md"],
        readme: nil,
        base_files: ["0052-a.md"]
      }

      assert AdrGuard.analyze(%{diff: "", adr: index})
             |> Enum.filter(&(&1.check == "adr-0058-base-number")) == []
    end

    # Covers both Phase 2's no-base-ref source and any hand-built source that
    # never populates :base_files.
    # sabotage: drop `defp base_number_findings(_index), do: []`, so an index
    #           with no :base_files key raises FunctionClauseError -> red
    test "an absent :base_files key produces no findings" do
      index = %{files: ["0052-a.md"], readme: nil}

      assert AdrGuard.analyze(%{diff: "", adr: index})
             |> Enum.filter(&(&1.check == "adr-0058-base-number")) == []
    end
  end

  # Keyed by git subcommand, except `rev-parse`, which is keyed by the ref it is
  # asked to resolve - that is the call whose answer decides the base.
  defp runner(responses) do
    fn [subcommand | rest] ->
      key = if subcommand == "rev-parse", do: List.last(rest), else: subcommand
      Map.get(Map.new(responses), key, {"", 1})
    end
  end

  describe "collect/1" do
    # sabotage: fall back to HEAD instead of returning {:no_base_ref, _} -> red
    test "reports no base ref rather than guessing one" do
      lister = fn "docs/adr" -> {:ok, ["0001-first.md"]} end
      reader = fn "docs/adr/README.md" -> {:ok, "readme text"} end

      assert {:no_base_ref, source} =
               AdrGuard.collect(runner: runner([]), lister: lister, reader: reader)

      assert %{diff: "", adr: %{files: ["0001-first.md"], readme: "readme text"}} = source
    end

    # sabotage: drop `opts[:base]` from the candidate list -> red
    test "prefers an explicit base over origin/main" do
      responses = [
        {"upstream/trunk", {"upstream/trunk\n", 0}},
        {"merge-base", {"abc123\n", 0}},
        {"diff", {file_diff("lib/statifier/interpreter.ex", ["  defp exitset(s) do"]), 0}}
      ]

      assert {:ok, sourced} = AdrGuard.collect(base: "upstream/trunk", runner: runner(responses))
      assert [%{check: "adr-0002-naming"}] = AdrGuard.analyze(sourced)
    end

    # sabotage: diff against the base ref instead of the merge base -> red
    test "diffs the working tree against the merge base" do
      parent = self()

      responses = [
        {"origin/main", {"origin/main\n", 0}},
        {"merge-base", {"abc123\n", 0}},
        {"diff", {"", 0}}
      ]

      spy = fn args ->
        send(parent, {:git, args})
        runner(responses).(args)
      end

      assert {:ok, %{diff: ""}} = AdrGuard.collect(runner: spy)
      assert_received {:git, ["rev-parse", "--verify", "--quiet", "origin/main"]}
      assert_received {:git, ["merge-base", "origin/main", "HEAD"]}

      assert_received {:git,
                       ["diff", "abc123", "--unified=0", "--src-prefix=a/", "--dst-prefix=b/"]}
    end

    # A file git has never seen is absent from `git diff` entirely, so a
    # brand-new interpreter module would be invisible to every check here.
    # sabotage: drop untracked_diff/1 from collect_from/2 -> red
    # sabotage: drop the @lib_prefix filter, so scratch.exs is diffed too -> red
    test "an untracked file under lib/ is diffed" do
      parent = self()

      untracked = fn
        ["rev-parse" | _rest] = args ->
          if List.last(args) == "origin/main", do: {"origin/main\n", 0}, else: {"", 1}

        ["merge-base" | _rest] ->
          {"abc123\n", 0}

        ["ls-files" | _rest] ->
          {"lib/statifier/interpreter.ex\nscratch.exs\n", 0}

        ["diff", "--no-index" | _rest] = args ->
          send(parent, {:diffed, List.last(args)})
          {file_diff(List.last(args), ["  defp exitset(s) do"], 1), 1}

        ["diff" | _rest] ->
          {"", 0}

        _other ->
          {"", 1}
      end

      assert {:ok, sourced} = AdrGuard.collect(runner: untracked)

      assert [%{file: "lib/statifier/interpreter.ex", check: "adr-0002-naming", line: 1}] =
               AdrGuard.analyze(sourced)

      assert_received {:diffed, "lib/statifier/interpreter.ex"}
      refute_received {:diffed, "scratch.exs"}
    end

    # `collect/1`'s `:files` seam: only the lib/ and test/ paths the diff
    # names get their post-image text read, which is what lets `analyze/1` see
    # inside a doc heredoc whose opener sits outside the diff hunk.
    # sabotage: drop the lib/ + test/ filter from file_texts/2, so every diffed path is read -> red
    test "collect/1 reads post-image text for the diffed lib/ and test/ paths only" do
      parent = self()

      diff =
        file_diff("lib/statifier/document.ex", ["  defp exitset(s) do"]) <>
          file_diff("test/statifier/document_test.exs", ["  test \"x\" do"]) <>
          file_diff("docs/adr/0013-something.md", ["  something"])

      responses = [
        {"origin/main", {"origin/main\n", 0}},
        {"merge-base", {"abc123\n", 0}},
        {"diff", {diff, 0}}
      ]

      reader = fn path ->
        send(parent, {:read, path})
        {:ok, "content of #{path}"}
      end

      assert {:ok, sourced} = AdrGuard.collect(runner: runner(responses), reader: reader)

      assert Map.keys(sourced.files) |> Enum.sort() == [
               "lib/statifier/document.ex",
               "test/statifier/document_test.exs"
             ]

      assert_received {:read, "lib/statifier/document.ex"}
      assert_received {:read, "test/statifier/document_test.exs"}
      refute_received {:read, "docs/adr/0013-something.md"}
    end

    # sabotage: drop the @adr_filename_pattern filter from adr_index/2, so
    #           README.md, .DS_Store, and draft.md all count as records -> red
    test "collect/1 populates :adr from the injected lister and reader, filtering non-records" do
      lister = fn "docs/adr" ->
        {:ok, ["0001-first.md", "0002-second.md", "README.md", ".DS_Store", "draft.md"]}
      end

      reader = fn
        "docs/adr/README.md" -> {:ok, "the readme text"}
        other -> {:error, "unexpected read: #{other}"}
      end

      responses = [
        {"origin/main", {"origin/main\n", 0}},
        {"merge-base", {"abc123\n", 0}},
        {"diff", {"", 0}}
      ]

      assert {:ok, %{adr: index}} =
               AdrGuard.collect(runner: runner(responses), lister: lister, reader: reader)

      assert index.files == ["0001-first.md", "0002-second.md"]
      assert index.readme == "the readme text"
    end

    # sabotage: drop the @adr_filename_pattern filter from base_adr_files/2,
    #           so README.md counts as a base record too -> red
    test "collect/1 populates :base_files from the injected runner's ls-tree response" do
      responses = [
        {"origin/main", {"origin/main\n", 0}},
        {"merge-base", {"abc123\n", 0}},
        {"diff", {"", 0}},
        {"ls-tree",
         {"docs/adr/0001-first.md\ndocs/adr/0002-second.md\ndocs/adr/README.md\n" <>
            "docs/adr/nested/0003-nested.md\n", 0}}
      ]

      assert {:ok, %{adr: index}} = AdrGuard.collect(runner: runner(responses))

      assert Enum.sort(index.base_files) == ["0001-first.md", "0002-second.md", "0003-nested.md"]
    end

    # sabotage: raise instead of returning {:error, _} when git fails -> red
    test "a failing git command is reported, not raised" do
      responses = [{"origin/main", {"origin/main\n", 0}}, {"merge-base", {"fatal: bad\n", 128}}]

      assert {:error, message} = AdrGuard.collect(runner: runner(responses))
      assert message =~ "exited 128"
    end

    # Exercises the real `git` shell-out rather than an injected runner. `HEAD`
    # is used as the base because it resolves in any clone, so this asserts the
    # wiring without depending on which branches exist.
    # sabotage: point git/1 at a nonexistent binary -> red
    test "runs against the repository's real git" do
      assert {:ok, %{diff: diff}} = AdrGuard.collect(base: "HEAD")
      assert is_binary(diff)
    end

    # `git diff --no-index` normally exits 0 or 1; any other status means the
    # comparison itself failed, and the untracked file is dropped rather than
    # reported with a garbled diff. Mirrors the same guard in
    # Mix.Statifier.AdrJudge.
    # sabotage: widen `status in [0, 1]` to `is_integer(status)`, so a status
    #           2 also reads as a diffable output -> red (the "fatal:
    #           unreadable file" text leaks into the diff instead of being
    #           dropped)
    test "an untracked file git cannot diff contributes nothing rather than garbage" do
      untracked = fn
        ["rev-parse" | _rest] = args ->
          if List.last(args) == "origin/main", do: {"origin/main\n", 0}, else: {"", 1}

        ["merge-base" | _rest] ->
          {"abc123\n", 0}

        ["ls-files" | _rest] ->
          {"lib/statifier/broken.ex\n", 0}

        ["diff", "--no-index" | _rest] ->
          {"fatal: unreadable file\n", 2}

        ["diff" | _rest] ->
          {"", 0}

        _other ->
          {"", 1}
      end

      assert {:ok, %{diff: diff}} = AdrGuard.collect(runner: untracked)
      assert diff == ""
    end
  end

  # `@@` headers with no `-<n> +<n>` shape are not something a real diff
  # emits, but the parser falls back to line 0 rather than crashing on one.
  # sabotage: have hunk_start/1 fall back to 1 instead of 0 on an
  #           unparseable header -> red
  test "an unparseable hunk header falls back to line 0 rather than crashing" do
    diff = """
    diff --git a/lib/statifier/interpreter.ex b/lib/statifier/interpreter.ex
    --- a/lib/statifier/interpreter.ex
    +++ b/lib/statifier/interpreter.ex
    @@ garbled hunk header @@
    +    Logger.debug("x")
    """

    assert [%{line: 0, check: "adr-0003-effects"}] = AdrGuard.analyze(%{diff: diff})
  end
end
