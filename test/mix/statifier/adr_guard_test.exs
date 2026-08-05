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

  describe "ADR-0008 - UXIDs for identifiers" do
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

  # Keyed by git subcommand, except `rev-parse`, which is keyed by the ref it is
  # asked to resolve - that is the call whose answer decides the base.
  defp runner(responses) do
    fn [subcommand | rest] ->
      key = if subcommand == "rev-parse", do: List.last(rest), else: subcommand
      Map.get(Map.new(responses), key, {"", 1})
    end
  end

  describe "collect/1" do
    # sabotage: fall back to HEAD instead of returning :no_base_ref -> red
    test "reports no base ref rather than guessing one" do
      assert AdrGuard.collect(runner: runner([])) == :no_base_ref
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
  end
end
