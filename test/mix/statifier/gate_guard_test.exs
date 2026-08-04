defmodule Mix.Statifier.GateGuardTest do
  use ExUnit.Case, async: true

  alias Mix.Statifier.GateGuard

  # Every test drives the analyzer with a hand-written unified diff, so nothing
  # here needs a fixture repository or a real git history.
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

  defp source(diff, opts \\ []) do
    %{
      diff: diff,
      base_registry: opts[:base_registry],
      head_registry: opts[:head_registry]
    }
  end

  defp registry(patterns) do
    JSON.encode!(%{"description" => "ratchet", "internal_tests" => patterns})
  end

  defp ledger_diff(lines) do
    file_diff(GateGuard.ledger_path(), lines, 20)
  end

  # The path list is spelled out rather than read from `guarded_paths/0`, so
  # dropping a path from the module does not silently shrink the test with it.
  # sabotage: drop `.credo.exs` from @guarded_paths -> red on that path
  test "every guarded gate-config path fires on any hunk" do
    paths = [".quality.exs", ".credo.exs", "coveralls.json", ".sobelow-conf"]
    assert GateGuard.guarded_paths() == paths

    for path <- paths do
      assert [finding] = GateGuard.analyze(source(file_diff(path, ["  strict: false"])))

      assert %{file: ^path, line: nil, check: "gate-config", severity: "error"} = finding
      assert finding.message =~ "no entry in docs/quality-gate-changes.md"
    end
  end

  # sabotage: match mix.exs by path instead of by line content -> red
  test "an unrelated mix.exs dep bump is not a gate change" do
    diff = file_diff("mix.exs", [~s|      {:predicator, "~> 3.6"},|])

    assert GateGuard.analyze(source(diff)) == []
  end

  # sabotage: drop `warnings_as_errors` from @mix_exs_pattern -> red on that line
  test "a gate-relevant mix.exs line fires and carries its line number" do
    for line <- [
          "      test_coverage: [tool: ExCoveralls],",
          "      dialyzer: [plt_add_apps: [:mix]],",
          "      elixirc_options: [warnings_as_errors: false],",
          "      aliases: aliases(),",
          ~s|      {:ex_quality, "~> 0.5", only: [:dev, :test]},|,
          ~s|      {:credo, "~> 1.7", only: [:dev, :test]},|,
          ~s|      {:excoveralls, "~> 0.18", only: :test},|,
          ~s|      {:dialyxir, "~> 1.4", only: [:dev]},|
        ] do
      assert [%{file: "mix.exs", line: 10, check: "gate-config"}] =
               GateGuard.analyze(source(file_diff("mix.exs", [line])))
    end
  end

  # sabotage: filter mix_exs_findings/1 to added lines only -> red
  test "removing a gate-relevant mix.exs line fires, with no line to point at" do
    diff = """
    diff --git a/mix.exs b/mix.exs
    --- a/mix.exs
    +++ b/mix.exs
    @@ -20,1 +20,0 @@
    -      test_coverage: [tool: ExCoveralls],
    """

    assert [%{file: "mix.exs", line: nil, check: "gate-config"}] = GateGuard.analyze(source(diff))
  end

  # sabotage: drop the `@moduletag` alternative from @skip_tag_pattern -> red
  test "every skip-tag form fires with the line it was added on" do
    for tag <- [
          "  @tag :skip",
          "  @tag :pending",
          "  @moduletag :skip",
          "  @moduletag :pending",
          "  @tag skip: true",
          "  @tag pending: \"waiting on st2-xyz\""
        ] do
      diff = file_diff("test/statifier/document_test.exs", [tag], 42)

      assert [%{file: "test/statifier/document_test.exs", line: 42, check: "skip-tag"}] =
               GateGuard.analyze(source(diff))
    end
  end

  # sabotage: match the skip pattern without \b, so `:skip_ahead` fires too -> red
  test "a tag that merely starts with skip is not a skip tag" do
    diff = file_diff("test/statifier/document_test.exs", ["  @tag :skipped_reason"])

    assert GateGuard.analyze(source(diff)) == []
  end

  # sabotage: restrict the skip-tag scan to files outside test/scion_tests -> red
  test "a skip tag in a generated corpus file fires like any other" do
    diff = file_diff("test/scion_tests/basic/basic0_test.exs", ["  @tag :skip"], 7)

    assert [%{check: "skip-tag", line: 7}] = GateGuard.analyze(source(diff))
  end

  # sabotage: skip the `String.starts_with?(path, "test/")` filter -> red
  test "a skip tag outside test/ is not this check's business" do
    diff = file_diff("lib/statifier/interpreter.ex", ["  # @tag :skip means nothing here"])

    assert GateGuard.analyze(source(diff)) == []
  end

  # A tag the line does not start with is a quotation, not a skipped test: a
  # comment, a string literal, a heredoc in a test about skip tags. This file is
  # full of them, and an unanchored pattern reports every one.
  # sabotage: drop the ^\s* anchor from @skip_tag_pattern -> red
  test "a skip tag that does not start its line is a quotation, not a skip" do
    for quoted <- ["  # @tag :skip", ~s|    "  @tag :skip",|, "    +  @tag :skip"] do
      diff = file_diff("test/statifier/document_test.exs", [quoted])

      assert GateGuard.analyze(source(diff)) == []
    end
  end

  # sabotage: compare head against base instead of base against head -> red
  test "a pattern removed from the ratchet registry fires" do
    assert [finding] =
             GateGuard.analyze(
               source("",
                 base_registry:
                   registry(["test/statifier/**/*_test.exs", "test/mix/**/*_test.exs"]),
                 head_registry: registry(["test/statifier/**/*_test.exs"])
               )
             )

    assert %{file: "test/passing_tests.json", check: "ratchet-shrink"} = finding
    assert finding.message =~ "test/mix/**/*_test.exs"
  end

  # sabotage: compare the raw registry strings instead of parsed pattern sets -> red
  test "reformatting the registry without losing a pattern does not fire" do
    patterns = ["test/statifier/**/*_test.exs"]

    reformatted = """
    {
      "description": "ratchet",
      "internal_tests": [
        "test/statifier/**/*_test.exs"
      ]
    }
    """

    assert GateGuard.analyze(
             source("", base_registry: registry(patterns), head_registry: reformatted)
           ) == []
  end

  # sabotage: return [] instead of :error from decode/1 on a nil head registry -> red
  test "an unreadable registry snapshot is not read as an empty one" do
    assert GateGuard.analyze(
             source("", base_registry: registry(["test/statifier/**/*_test.exs"]))
           ) == []
  end

  # sabotage: return {:ok, %{}} instead of :error for undecodable JSON -> red
  test "an unparseable registry snapshot is not read as an empty one either" do
    assert GateGuard.analyze(
             source("",
               base_registry: registry(["test/statifier/**/*_test.exs"]),
               head_registry: "{oops"
             )
           ) == []
  end

  # sabotage: drop the Approved-by check from cleared_paths/1 -> red
  test "a ledger entry naming the path and approved by a human clears the finding" do
    diff =
      file_diff(".quality.exs", ["  strict: false"]) <>
        ledger_diff([
          "## 2026-08-04 - st2-h6p",
          "",
          "Approved-by: JohnnyT",
          "",
          "- .quality.exs: registers the gate_guard custom stage"
        ])

    assert GateGuard.analyze(source(diff)) == []
  end

  # sabotage: treat any ledger hunk as clearance regardless of Approved-by -> red
  test "a ledger entry with no Approved-by line clears nothing" do
    diff =
      file_diff(".quality.exs", ["  strict: false"]) <>
        ledger_diff(["## 2026-08-04 - st2-h6p", "", "- .quality.exs: loosened credo"])

    assert [%{file: ".quality.exs"}] = GateGuard.analyze(source(diff))
  end

  # sabotage: clear every finding once any approved ledger line exists -> red
  test "a ledger entry naming a different path does not clear this one" do
    diff =
      file_diff(".quality.exs", ["  strict: false"]) <>
        ledger_diff(["Approved-by: JohnnyT", "", "- coveralls.json: raised the minimum"])

    assert [%{file: ".quality.exs"}] = GateGuard.analyze(source(diff))
  end

  # sabotage: have parse_line/2 count removed lines toward the new line number -> red
  test "line numbers survive a hunk that also removes lines" do
    diff = """
    diff --git a/test/statifier/document_test.exs b/test/statifier/document_test.exs
    --- a/test/statifier/document_test.exs
    +++ b/test/statifier/document_test.exs
    @@ -5,2 +5,3 @@
    -  old line
    -  another old line
     context line
    +  @tag :skip
    """

    assert [%{line: 6, check: "skip-tag"}] = GateGuard.analyze(source(diff))
  end

  # sabotage: drop the `--- a/` clause from parse_line/2, so a deleted file has
  #           no path to attribute its hunk to -> red
  test "deleting a guarded file outright is a gate change" do
    diff = """
    diff --git a/.credo.exs b/.credo.exs
    deleted file mode 100644
    --- a/.credo.exs
    +++ /dev/null
    @@ -1,2 +0,0 @@
    -[
    -]
    """

    assert [%{file: ".credo.exs", check: "gate-config"}] = GateGuard.analyze(source(diff))
  end

  # sabotage: have hunk_start/1 raise on an unparseable header instead of
  #           falling back to 0 -> red
  test "an unparseable hunk header still attributes its file" do
    diff = """
    diff --git a/.quality.exs b/.quality.exs
    --- a/.quality.exs
    +++ b/.quality.exs
    @@ garbled @@
    +  strict: false
    """

    assert [%{file: ".quality.exs", check: "gate-config"}] = GateGuard.analyze(source(diff))
  end

  # sabotage: have the `+++ b/` clause leave the path alone, so an added file's
  #           hunk lands on the file before it in the diff -> red
  test "an added file is attributed to its new path, not the previous one" do
    diff =
      file_diff(".quality.exs", ["  strict: false"]) <>
        """
        diff --git a/test/statifier/new_test.exs b/test/statifier/new_test.exs
        new file mode 100644
        --- /dev/null
        +++ b/test/statifier/new_test.exs
        @@ -0,0 +1,1 @@
        +  @tag :skip
        """

    assert [%{file: ".quality.exs"}, %{file: "test/statifier/new_test.exs", line: 1}] =
             Enum.sort_by(GateGuard.analyze(source(diff)), & &1.file)
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
      assert GateGuard.collect(runner: runner([])) == :no_base_ref
    end

    # sabotage: drop `opts[:base]` from the candidate list -> red
    test "prefers an explicit base over origin/main" do
      responses = [
        {"upstream/trunk", {"upstream/trunk\n", 0}},
        {"merge-base", {"abc123\n", 0}},
        {"diff", {file_diff(".quality.exs", ["  strict: false"]), 0}}
      ]

      assert {:ok, sourced} = GateGuard.collect(base: "upstream/trunk", runner: runner(responses))
      assert [%{file: ".quality.exs"}] = GateGuard.analyze(sourced)
    end

    # sabotage: diff against the base ref instead of the merge base -> red
    test "diffs the working tree against the merge base" do
      parent = self()

      responses = [
        {"origin/main", {"origin/main\n", 0}},
        {"merge-base", {"abc123\n", 0}},
        {"diff", {"", 0}},
        {"show", {registry(["test/statifier/**/*_test.exs"]), 0}}
      ]

      spy = fn args ->
        send(parent, {:git, args})
        runner(responses).(args)
      end

      assert {:ok, %{diff: "", base_registry: base}} = GateGuard.collect(runner: spy)

      assert base =~ "internal_tests"
      assert_received {:git, ["rev-parse", "--verify", "--quiet", "origin/main"]}
      assert_received {:git, ["merge-base", "origin/main", "HEAD"]}

      assert_received {:git,
                       ["diff", "abc123", "--unified=0", "--src-prefix=a/", "--dst-prefix=b/"]}

      assert_received {:git, ["show", "abc123:test/passing_tests.json"]}
    end

    # A file git has never seen is absent from `git diff` entirely, so a new
    # `.credo.exs`, a new skip-tagged test, or the ledger entry meant to clear
    # one would all be invisible without this.
    # sabotage: drop untracked_diff/1 from collect_from/3 -> red
    # sabotage: drop the interesting?/1 filter, so scratch.exs is diffed too -> red
    test "an untracked file is diffed, if a check could fire on it" do
      parent = self()

      untracked = fn
        ["rev-parse" | _rest] = args ->
          if List.last(args) == "origin/main", do: {"origin/main\n", 0}, else: {"", 1}

        ["merge-base" | _rest] ->
          {"abc123\n", 0}

        ["ls-files" | _rest] ->
          {"test/statifier/new_test.exs\nscratch.exs\n", 0}

        ["diff", "--no-index" | _rest] = args ->
          send(parent, {:diffed, List.last(args)})
          {file_diff(List.last(args), ["  @tag :skip"], 1), 1}

        ["diff" | _rest] ->
          {"", 0}

        _other ->
          {"", 1}
      end

      assert {:ok, sourced} = GateGuard.collect(runner: untracked)

      assert [%{file: "test/statifier/new_test.exs", check: "skip-tag", line: 1}] =
               GateGuard.analyze(sourced)

      assert_received {:diffed, "test/statifier/new_test.exs"}
      refute_received {:diffed, "scratch.exs"}
    end

    # sabotage: raise instead of returning {:error, _} when git fails -> red
    test "a failing git command is reported, not raised" do
      responses = [{"origin/main", {"origin/main\n", 0}}, {"merge-base", {"fatal: bad\n", 128}}]

      assert {:error, message} = GateGuard.collect(runner: runner(responses))
      assert message =~ "exited 128"
    end

    # sabotage: return "" instead of nil when the registry is absent at base -> red
    test "a registry absent at the base ref is nil, not empty" do
      responses = [
        {"origin/main", {"origin/main\n", 0}},
        {"merge-base", {"abc123\n", 0}},
        {"diff", {"", 0}}
      ]

      assert {:ok, %{base_registry: nil}} = GateGuard.collect(runner: runner(responses))
    end

    # sabotage: have read/1 return "" instead of nil for a missing file -> red
    test "a registry missing from the working tree is nil, not empty" do
      responses = [
        {"origin/main", {"origin/main\n", 0}},
        {"merge-base", {"abc123\n", 0}},
        {"diff", {"", 0}},
        {"show", {registry([]), 0}}
      ]

      assert {:ok, %{head_registry: nil}} =
               GateGuard.collect(runner: runner(responses), registry_path: "no/such.json")
    end

    # Exercises the real `git` shell-out rather than an injected runner. `HEAD`
    # is used as the base because it resolves in any clone, so this asserts the
    # wiring without depending on which branches exist.
    # sabotage: point git/1 at a nonexistent binary -> red
    test "runs against the repository's real git" do
      assert {:ok, %{diff: diff}} = GateGuard.collect(base: "HEAD")
      assert is_binary(diff)
    end
  end
end
