defmodule Mix.Statifier.AdrJudgeTest do
  use ExUnit.Case, async: true

  alias Mix.Statifier.AdrJudge

  # The registry's two entries today - ADR-0012 (debuggability) and ADR-0014
  # (expression spans), both scoped to lib/statifier/. Fetched once so tests
  # reference their real scope/adr_path instead of a path string re-typed at
  # each call site (and so a growing registry cannot silently make `hd/1`
  # here pick the wrong ADR).
  @adr_0012 Enum.find(AdrJudge.judged(), &(&1.key == "adr-0012-debuggability"))
  @adr_0014 Enum.find(AdrJudge.judged(), &(&1.key == "adr-0014-expression-spans"))

  # Every test drives analyze/2 with a hand-written diff and a stub caller, so
  # nothing here needs a fixture repository, the real `claude` CLI, or a real
  # network call - the one seam this module exists to keep pure.
  defp source(diff, adr_text \\ "ADR-0012 placeholder text for tests.") do
    %{
      diff: diff,
      adrs: [
        %{
          key: @adr_0012.key,
          label: @adr_0012.label,
          focus: @adr_0012.focus,
          adr_text: adr_text,
          chunks: AdrJudge.scoped_chunks(diff, @adr_0012.scope)
        }
      ]
    }
  end

  defp core_diff(path \\ "lib/statifier/interpreter.ex") do
    """
    diff --git a/#{path} b/#{path}
    --- a/#{path}
    +++ b/#{path}
    @@ -10,1 +10,0 @@
    -    trace(:exit_set, state)
    """
  end

  defp stub_caller(propose_response, refute_response) do
    fn prompt ->
      if String.contains?(prompt, "PROPOSE PASS"), do: propose_response, else: refute_response
    end
  end

  defp candidate_json do
    JSON.encode!([
      %{
        "file" => "lib/statifier/interpreter.ex",
        "line" => 10,
        "claim" => "drops a trace effect at the exit-set boundary"
      }
    ])
  end

  # sabotage: drop the Enum.filter(&survives_refute?/3) call from analyze/2,
  #           reporting every proposed candidate regardless of the refute
  #           pass -> red on "produces zero findings" below
  test "a candidate the refute pass fails to overturn becomes exactly one finding" do
    caller = stub_caller({:ok, candidate_json()}, {:ok, ~s({"violation": true})})

    assert [finding] = AdrJudge.analyze(source(core_diff()), caller: caller)

    assert %{
             file: "lib/statifier/interpreter.ex",
             line: 10,
             severity: "error",
             check: "adr-0012-debuggability"
           } = finding

    assert finding.message =~ "trace effect"
  end

  # sabotage: have parse_refute/1 default to true instead of false on an
  #           explicit {"violation": false} verdict -> red
  test "a candidate overturned by the refute pass produces zero findings" do
    caller = stub_caller({:ok, candidate_json()}, {:ok, ~s({"violation": false})})

    assert AdrJudge.analyze(source(core_diff()), caller: caller) == []
  end

  # sabotage: have parse_propose/1 fall back to a one-item placeholder list
  #           instead of [] when the propose pass returns "[]" -> red
  test "the propose pass finding nothing produces zero findings" do
    caller = stub_caller({:ok, "[]"}, {:ok, ~s({"violation": true})})

    assert AdrJudge.analyze(source(core_diff()), caller: caller) == []
  end

  # An ambiguous or unparseable refute response is not silently promoted into
  # a finding: refute wins the tie by suppressing it, per the adversarial
  # design the moduledoc documents.
  # sabotage: default parse_refute/1 to true instead of false on unparseable
  #           JSON -> red
  test "an unparseable refute response overturns the candidate, not survives it" do
    caller = stub_caller({:ok, candidate_json()}, {:ok, "not json"})

    assert AdrJudge.analyze(source(core_diff()), caller: caller) == []
  end

  # sabotage: have parse_propose/1 return a one-item placeholder list instead
  #           of [] on unparseable JSON -> red
  test "an unparseable propose response produces zero findings, not a spurious one" do
    caller = stub_caller({:ok, "not json"}, {:ok, ~s({"violation": true})})

    assert AdrJudge.analyze(source(core_diff()), caller: caller) == []
  end

  # sabotage: have propose/3 raise a MatchError on a caller {:error, _} by
  #           pattern-matching `{:ok, text} = caller.(...)` instead of
  #           case-ing over both outcomes -> red (the test crashes)
  test "a caller error on the propose pass produces zero findings rather than raising" do
    caller = stub_caller({:error, :timeout}, {:ok, ~s({"violation": true})})

    assert AdrJudge.analyze(source(core_diff()), caller: caller) == []
  end

  # sabotage: have survives_refute?/3 return true unconditionally on a
  #           caller {:error, _} instead of false -> red
  test "a caller error on the refute pass overturns the candidate rather than raising" do
    caller = stub_caller({:ok, candidate_json()}, {:error, :timeout})

    assert AdrJudge.analyze(source(core_diff()), caller: caller) == []
  end

  # sabotage: have in_scope?/2 ignore scope.prefix (match any path), so a
  #           docs/-only hunk reaches the propose prompt too -> red
  test "only diff hunks under lib/statifier/ reach the propose prompt" do
    parent = self()

    diff =
      """
      diff --git a/docs/adr/0013-something.md b/docs/adr/0013-something.md
      --- a/docs/adr/0013-something.md
      +++ b/docs/adr/0013-something.md
      @@ -1,0 +1,1 @@
      +Some prose.
      """ <> core_diff()

    spy = fn prompt ->
      send(parent, {:prompt, prompt})
      if String.contains?(prompt, "PROPOSE PASS"), do: {:ok, "[]"}, else: {:ok, "{}"}
    end

    AdrJudge.analyze(source(diff), caller: spy)

    assert_received {:prompt, propose_prompt}
    assert propose_prompt =~ "lib/statifier/interpreter.ex"
    refute propose_prompt =~ "0013-something"
  end

  # sabotage: have propose_prompt/1 omit the ADR text argument -> red
  test "the full ADR-0012 text reaches the propose prompt" do
    parent = self()

    spy = fn prompt ->
      send(parent, {:prompt, prompt})
      if String.contains?(prompt, "PROPOSE PASS"), do: {:ok, "[]"}, else: {:ok, "{}"}
    end

    AdrJudge.analyze(source(core_diff(), "unique-adr-marker-xyz"), caller: spy)

    assert_received {:prompt, propose_prompt}
    assert propose_prompt =~ "unique-adr-marker-xyz"
  end

  # A candidate is proposed and refuted by two separate model calls, so its
  # own ADR text has to travel with it from the propose pass through to the
  # refute pass rather than the refute prompt re-deriving it some other way -
  # the only per-candidate handle available to refute_prompt/1 is the
  # candidate itself.
  # sabotage: have judged_identity/1 drop :adr_text from the map merged onto
  #           each candidate, so the refute prompt renders the atom `nil`
  #           where the ADR text belongs -> red
  test "a candidate's refute prompt carries that candidate's own ADR text" do
    parent = self()

    spy = fn prompt ->
      if String.contains?(prompt, "PROPOSE PASS") do
        {:ok, candidate_json()}
      else
        send(parent, {:refute_prompt, prompt})
        {:ok, ~s({"violation": false})}
      end
    end

    AdrJudge.analyze(source(core_diff(), "unique-adr-marker-xyz"), caller: spy)

    assert_received {:refute_prompt, refute_prompt}
    assert refute_prompt =~ "unique-adr-marker-xyz"
  end

  # Two registry entries (ADR-0012 and ADR-0014) sharing the exact same
  # lib/statifier/ scope means a single in-scope diff fans out into one
  # propose call per judged ADR, each carrying that ADR's own text - not one
  # call sharing/merging the two, and not just the first entry answered.
  # sabotage: have analyze/2 take only the first entry of source.adrs -> red
  #           (only one propose prompt would be sent, not two)
  test "a lib/statifier/ diff produces one propose prompt per judged ADR, each with its own ADR text" do
    parent = self()

    diff = core_diff()

    source = %{
      diff: diff,
      adrs: [
        %{
          key: @adr_0012.key,
          label: @adr_0012.label,
          focus: @adr_0012.focus,
          adr_text: "unique-0012-marker",
          chunks: AdrJudge.scoped_chunks(diff, @adr_0012.scope)
        },
        %{
          key: @adr_0014.key,
          label: @adr_0014.label,
          focus: @adr_0014.focus,
          adr_text: "unique-0014-marker",
          chunks: AdrJudge.scoped_chunks(diff, @adr_0014.scope)
        }
      ]
    }

    spy = fn prompt ->
      if String.contains?(prompt, "PROPOSE PASS"), do: send(parent, {:propose_prompt, prompt})
      {:ok, "[]"}
    end

    AdrJudge.analyze(source, caller: spy)

    assert_received {:propose_prompt, prompt_a}
    assert_received {:propose_prompt, prompt_b}
    refute_received {:propose_prompt, _third}

    prompts = [prompt_a, prompt_b]
    assert Enum.any?(prompts, &(&1 =~ "unique-0012-marker"))
    assert Enum.any?(prompts, &(&1 =~ "unique-0014-marker"))
  end

  # sabotage: have to_finding/1 hardcode check: "adr-0012-debuggability"
  #           instead of reading candidate.key -> red
  test "a candidate proposed under ADR-0014 becomes a finding with check: adr-0014-expression-spans" do
    diff = core_diff()

    source = %{
      diff: diff,
      adrs: [
        %{
          key: @adr_0014.key,
          label: @adr_0014.label,
          focus: @adr_0014.focus,
          adr_text: "ADR-0014 placeholder text for tests.",
          chunks: AdrJudge.scoped_chunks(diff, @adr_0014.scope)
        }
      ]
    }

    caller = stub_caller({:ok, candidate_json()}, {:ok, ~s({"violation": true})})

    assert [finding] = AdrJudge.analyze(source, caller: caller)
    assert finding.check == "adr-0014-expression-spans"
  end

  # sabotage: have normalize_candidate/1 accept any map, dropping the
  #           `is_binary(file) and is_binary(claim)` guard -> red
  test "a malformed candidate alongside a well-formed one is dropped, not both kept" do
    propose =
      JSON.encode!([
        %{
          "file" => "lib/statifier/interpreter.ex",
          "line" => 10,
          "claim" => "drops a trace effect"
        },
        %{"line" => 5, "claim" => "missing its file key"},
        %{"file" => "lib/statifier/interpreter.ex", "line" => 6}
      ])

    caller = stub_caller({:ok, propose}, {:ok, ~s({"violation": true})})

    assert [finding] = AdrJudge.analyze(source(core_diff()), caller: caller)
    assert finding.line == 10
  end

  # sabotage: have normalize_line/1 accept a non-integer line instead of
  #           falling back to nil -> red (the finding would carry the raw
  #           string "ten" as its line instead of nil)
  test "a non-integer line normalizes to nil rather than passing through" do
    propose =
      JSON.encode!([
        %{"file" => "lib/statifier/interpreter.ex", "line" => "ten", "claim" => "drops a trace"}
      ])

    caller = stub_caller({:ok, propose}, {:ok, ~s({"violation": true})})

    assert [%{line: nil}] = AdrJudge.analyze(source(core_diff()), caller: caller)
  end

  # sabotage: have propose/3 match on `{status, text}` for any status
  #           instead of only `{:ok, text}`, so a bare non-tuple response
  #           crashes the FunctionClauseError case into a raise -> red
  test "a caller response that is neither {:ok, _} nor {:error, _} produces zero findings" do
    caller = fn prompt ->
      if String.contains?(prompt, "PROPOSE PASS"),
        do: :unexpected,
        else: {:ok, ~s({"violation": true})}
    end

    assert AdrJudge.analyze(source(core_diff()), caller: caller) == []
  end

  # sabotage: have survives_refute?/3 read a bare non-tuple refute response
  #           as a survival instead of falling through to false -> red
  test "a refute response that is neither {:ok, _} nor {:error, _} overturns the candidate" do
    caller = stub_caller({:ok, candidate_json()}, :unexpected)

    assert AdrJudge.analyze(source(core_diff()), caller: caller) == []
  end

  # The `claude` CLI routinely answers "respond with JSON only" by wrapping
  # the JSON in a markdown code fence anyway - discovered by actually running
  # `mix adr.judge` against the real CLI, where it silently zeroed every
  # finding before this was handled.
  # sabotage: have extract_json/1 return the input unchanged instead of
  #           stripping a fenced block -> red (JSON.decode/1 fails on the
  #           fence markers, so this candidate would vanish)
  test "a propose response wrapped in a markdown code fence still parses" do
    fenced = "```json\n#{candidate_json()}\n```"
    caller = stub_caller({:ok, fenced}, {:ok, ~s({"violation": true})})

    assert [finding] = AdrJudge.analyze(source(core_diff()), caller: caller)
    assert finding.file == "lib/statifier/interpreter.ex"
  end

  # A CLI response answering with a prose preamble - the model narrating an
  # analysis, sometimes several unrelated fenced shell commands - before its
  # actual fenced verdict is common enough (also discovered against the real
  # CLI) that a fence strip anchored to the start of the response never fires
  # on it, and the leftover prose fails JSON.decode/1 the same way an
  # unparseable response does. That failure mode is safe for refute (it
  # defaults to "not a violation" either way) but would be a silent false
  # negative for propose: a genuine candidate named only in prose is dropped
  # rather than reaching the refute pass at all.
  # sabotage: have extract_json/1 take the *first* fenced block via
  #           Regex.run/2 instead of the *last* via Regex.scan/2, so a
  #           preamble's own fenced shell command is read as the answer
  #           instead of the trailing verdict -> red
  test "a propose response with a prose preamble before its fenced answer still parses" do
    prefaced =
      "Let me check the file first.\n```\ncat foo.ex\n```\n\n```json\n#{candidate_json()}\n```"

    caller = stub_caller({:ok, prefaced}, {:ok, ~s({"violation": true})})

    assert [finding] = AdrJudge.analyze(source(core_diff()), caller: caller)
    assert finding.file == "lib/statifier/interpreter.ex"
  end

  # sabotage: have extract_json/1 take the *first* fenced block instead of
  #           the *last*, so a rambling refute response's own hallucinated
  #           shell-command fence is read as the verdict instead of the
  #           trailing `{"violation": true}` -> red (the real verdict, a
  #           survival, would be overturned by the earlier, unrelated fence
  #           failing to parse as `%{"violation" => true}`)
  test "a refute response with a prose preamble before its fenced verdict still survives" do
    prefaced =
      "I'll examine the file.\n```\ngrep -n trace lib/statifier/interpreter.ex\n```\n\n" <>
        ~s(```json\n{"violation": true}\n```)

    caller = stub_caller({:ok, candidate_json()}, {:ok, prefaced})

    assert [finding] = AdrJudge.analyze(source(core_diff()), caller: caller)
    assert finding.file == "lib/statifier/interpreter.ex"
  end

  # st-c8c: in a :test build, analyze/2's default caller is
  # AdrJudge.refuse_real_call/1, not the real `call_claude_cli/1` - so a test
  # that forgets to inject opts[:caller] fails loudly and instantly instead of
  # quietly shelling out to the real `claude` CLI and spending real money.
  # sabotage: make @default_caller unconditionally &call_claude_cli/1 -> red
  #           (the test would shell out instead of raising). Must be reverted
  #           before any gate run - the sabotaged build is exactly the one
  #           that spends real money.
  test "analyze/2 with no opts[:caller] raises rather than calling the real CLI" do
    assert_raise RuntimeError, ~r/opts\[:caller\]/, fn ->
      AdrJudge.analyze(source(core_diff()))
    end
  end

  describe "scoped_chunks/2" do
    # sabotage: match "+++ b/" only, so a deleted core file (which has no
    #           "+++ b/" line) is dropped from scope -> red
    test "a deleted core file is attributed by its old path" do
      diff = """
      diff --git a/lib/statifier/interpreter.ex b/lib/statifier/interpreter.ex
      deleted file mode 100644
      --- a/lib/statifier/interpreter.ex
      +++ /dev/null
      @@ -1,1 +0,0 @@
      -defmodule Statifier.Interpreter do
      """

      assert [{"lib/statifier/interpreter.ex", _chunk}] =
               AdrJudge.scoped_chunks(diff, @adr_0012.scope)
    end

    # sabotage: drop the String.starts_with?/2 filter, so every file in the
    #           diff reads as a core chunk -> red
    test "a file outside lib/statifier/ is not a core chunk" do
      diff = """
      diff --git a/lib/mix/statifier/adr_guard.ex b/lib/mix/statifier/adr_guard.ex
      --- a/lib/mix/statifier/adr_guard.ex
      +++ b/lib/mix/statifier/adr_guard.ex
      @@ -1,0 +1,1 @@
      +  # unrelated
      """

      assert AdrJudge.scoped_chunks(diff, @adr_0012.scope) == []
    end

    # sabotage: have chunk_path/1 return the empty string instead of nil when
    #           neither header line is present, so a headerless chunk is
    #           attributed to path "" instead of dropped -> red
    test "a diff chunk with neither header line is attributed to nothing" do
      diff = """
      diff --git a/lib/statifier/blob.dat b/lib/statifier/blob.dat
      Binary files a/lib/statifier/blob.dat and b/lib/statifier/blob.dat differ
      """

      assert AdrJudge.scoped_chunks(diff, @adr_0012.scope) == []
    end

    # sabotage: have in_scope?/2 ignore scope.suffix entirely (prefix match
    #           only) -> red (a path with the prefix but the wrong suffix
    #           would wrongly stay in scope)
    test "a non-nil suffix narrows the prefix match" do
      scope = %{prefix: "lib/statifier/", suffix: ".ex", describe: "lib/statifier/*.ex"}

      diff = """
      diff --git a/lib/statifier/notes.txt b/lib/statifier/notes.txt
      --- a/lib/statifier/notes.txt
      +++ b/lib/statifier/notes.txt
      @@ -1,0 +1,1 @@
      +not an .ex file
      """

      assert AdrJudge.scoped_chunks(diff, scope) == []

      assert [{"lib/statifier/interpreter.ex", _chunk}] =
               AdrJudge.scoped_chunks(core_diff(), scope)
    end
  end

  # The task's skip reason for "nothing to judge" is built by joining these,
  # so every registered scope has to actually show up here - a registry
  # entry a maintainer adds without a scope.describe would otherwise vanish
  # from that message silently instead of failing loudly. ADR-0012 and
  # ADR-0014 share the exact same scope today, so this also pins the dedupe:
  # the skip reason must still name `lib/statifier/` once, not twice.
  # sabotage: have scope_descriptions/0 return [] unconditionally instead of
  #           mapping @judged -> red (both assertions fail)
  # sabotage: drop Enum.uniq() from scope_descriptions/0 -> red (the shared
  #           lib/statifier/ scope would be listed twice)
  test "scope_descriptions/0 names every registered scope once, even when two entries share it" do
    descriptions = AdrJudge.scope_descriptions()

    assert descriptions == Enum.uniq(descriptions)
    assert Enum.count(descriptions, &(&1 == "lib/statifier/")) == 1
  end

  describe "parse_cli_response/1 (the pure half of call_claude_cli/1)" do
    defp cli_events(extra) do
      JSON.encode!([%{"type" => "system", "subtype" => "init"} | extra])
    end

    # sabotage: match any "result" event as success instead of requiring
    #           "is_error" => false -> red
    test "a successful result event returns its text" do
      output = cli_events([%{"type" => "result", "is_error" => false, "result" => "hello"}])

      assert AdrJudge.parse_cli_response(output) == {:ok, "hello"}
    end

    # sabotage: drop the `is_error` guard from the success match, so an
    #           errored result event still returns its "result" text -> red
    test "an errored result event is an error, not the text it carries" do
      output =
        cli_events([%{"type" => "result", "is_error" => true, "result" => "rate limited"}])

      assert {:error, message} = AdrJudge.parse_cli_response(output)
      assert message =~ "rate limited"
    end

    # sabotage: default find_result/1 to the first event instead of the one
    #           with type "result", so a missing result event silently reads
    #           the init event -> red
    test "no result event in the stream is an error naming the raw output" do
      output = cli_events([])

      assert {:error, message} = AdrJudge.parse_cli_response(output)
      assert message =~ "unparseable or error result"
      assert message =~ "system"
    end

    # sabotage: drop the `JSON.decode/1` guard, so unparseable stdout raises
    #           instead of returning {:error, _} -> red
    test "unparseable stdout is an error rather than a raise" do
      assert {:error, message} = AdrJudge.parse_cli_response("not json")
      assert message =~ "not json"
    end

    # `JSON.decode/1` can succeed on valid JSON that is not a list at all (an
    # object, here), which find_result/1 must not crash on.
    # sabotage: have find_result/1 wrap a non-list in `[other]` instead of
    #           falling back to `%{}` -> red (a top-level object with its own
    #           "type" key could then masquerade as the result event)
    test "a non-list decoded response is an error rather than crashing" do
      assert {:error, message} = AdrJudge.parse_cli_response(~s({"unexpected": "shape"}))
      assert message =~ "unparseable or error result"
    end
  end

  describe "collect/1" do
    defp runner(responses) do
      fn [subcommand | rest] ->
        key = if subcommand == "rev-parse", do: List.last(rest), else: subcommand
        Map.get(Map.new(responses), key, {"", 1})
      end
    end

    # sabotage: check `System.find_executable/1` directly instead of
    #           `Keyword.get_lazy(opts, :cli_available, ...)`, so the injected
    #           false is never honored -> red
    test "the claude CLI missing is reported before any git call runs" do
      assert AdrJudge.collect(cli_available: false, runner: runner([])) == :no_cli
    end

    # sabotage: check base-ref resolution before CLI availability -> red (this
    #           test would still pass on that ordering, so it is paired with
    #           the no-CLI test above to pin the order that matters: an
    #           unavailable CLI must never depend on git resolving anything)
    test "reports no base ref rather than guessing one, once the CLI is available" do
      assert AdrJudge.collect(cli_available: true, runner: runner([])) == :no_base_ref
    end

    # sabotage: scope the registry's one entry to "lib/" instead of
    #           "lib/statifier/", so a docs/-only diff still reads as a
    #           scoped change -> red
    test "a diff touching no registered scope is reported, not silently passed" do
      responses = [
        {"origin/main", {"origin/main\n", 0}},
        {"merge-base", {"abc123\n", 0}},
        {"diff",
         {"""
          diff --git a/docs/adr/0013-something.md b/docs/adr/0013-something.md
          --- a/docs/adr/0013-something.md
          +++ b/docs/adr/0013-something.md
          @@ -1,0 +1,1 @@
          +Some prose.
          """, 0}}
      ]

      assert AdrJudge.collect(cli_available: true, runner: runner(responses)) ==
               :no_scoped_changes
    end

    # sabotage: drop `opts[:base]` from the candidate list -> red
    # sabotage: have read_adr_source/1 return {:error, :sabotage} for
    #           "adr-0012-debuggability" -> red on the adr_text assertion
    #           below (falls back to the "(unable to read ...)" placeholder)
    # sabotage: have read_adr_source/1 return {:error, :sabotage} for
    #           "adr-0014-expression-spans" -> red on the adr_0014.adr_text
    #           assertion below (falls back to the "(unable to read ...)"
    #           placeholder instead of the real ADR-0014 file content)
    test "prefers an explicit base over origin/main" do
      responses = [
        {"upstream/trunk", {"upstream/trunk\n", 0}},
        {"merge-base", {"abc123\n", 0}},
        {"diff", {core_diff(), 0}}
      ]

      assert {:ok, sourced} =
               AdrJudge.collect(
                 cli_available: true,
                 base: "upstream/trunk",
                 runner: runner(responses)
               )

      assert sourced.diff =~ "lib/statifier/interpreter.ex"
      assert [adr_0012, adr_0014] = sourced.adrs
      assert adr_0012.key == "adr-0012-debuggability"
      assert adr_0012.adr_text =~ "Debuggability"
      assert adr_0014.key == "adr-0014-expression-spans"
      # Matches the real file's own heading rather than a bare "span"
      # substring, which the file's *path* already contains
      # ("...spans-in-cond-diagnostics.md") and would pass even against the
      # "(unable to read ...)" fallback placeholder.
      assert adr_0014.adr_text =~ "Expression-level spans are part of the retained-location"
    end

    # sabotage: raise instead of returning {:error, _} when git fails -> red
    test "a failing git command is reported, not raised" do
      responses = [{"origin/main", {"origin/main\n", 0}}, {"merge-base", {"fatal: bad\n", 128}}]

      assert {:error, message} = AdrJudge.collect(cli_available: true, runner: runner(responses))
      assert message =~ "exited 128"
    end

    # A file git has never seen is absent from `git diff` entirely, so a
    # brand-new interpreter module would be invisible to this check.
    # sabotage: drop untracked_diff/1 from collect_from/3 -> red
    # sabotage: drop the any_scope_match?/1 filter, so scratch.exs is diffed
    #           too -> red
    test "an untracked file under lib/statifier/ is diffed" do
      parent = self()

      untracked = fn
        ["rev-parse" | _rest] = args ->
          if List.last(args) == "origin/main", do: {"origin/main\n", 0}, else: {"", 1}

        ["merge-base" | _rest] ->
          {"abc123\n", 0}

        ["ls-files" | _rest] ->
          {"lib/statifier/new.ex\nscratch.exs\n", 0}

        ["diff", "--no-index" | _rest] = args ->
          send(parent, {:diffed, List.last(args)})
          {core_diff(List.last(args)), 1}

        ["diff" | _rest] ->
          {"", 0}

        _other ->
          {"", 1}
      end

      assert {:ok, sourced} = AdrJudge.collect(cli_available: true, runner: untracked)
      assert [adr_0012, adr_0014] = sourced.adrs
      assert [{"lib/statifier/new.ex", _chunk}] = adr_0012.chunks
      assert [{"lib/statifier/new.ex", _chunk}] = adr_0014.chunks

      assert_received {:diffed, "lib/statifier/new.ex"}
      refute_received {:diffed, "scratch.exs"}
    end

    # `git diff --no-index` normally exits 0 or 1; any other status means the
    # comparison itself failed, and the untracked file is dropped rather than
    # reported with a garbled diff.
    # sabotage: widen `status in [0, 1]` to `is_integer(status)`, so a status
    #           2 also reads as a diffable output -> red
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

      assert AdrJudge.collect(cli_available: true, runner: untracked) == :no_scoped_changes
    end

    # Exercises the real `git` shell-out rather than an injected runner, so
    # the default `opts[:runner]` wiring is asserted too - not just the
    # injected path every other test in this module uses. The outcome is
    # environment-dependent (this branch may or may not touch
    # lib/statifier/), so every legitimate collect/1 outcome is accepted;
    # what matters is that the real `git` subprocess runs without raising.
    # sabotage: point git/1 at a nonexistent binary -> red (raises ErlangError)
    test "the default runner talks to the repository's real git" do
      result = AdrJudge.collect(cli_available: true)

      assert result in [:no_base_ref, :no_scoped_changes] or
               match?({:ok, _sourced}, result) or
               match?({:error, _reason}, result)
    end
  end
end
