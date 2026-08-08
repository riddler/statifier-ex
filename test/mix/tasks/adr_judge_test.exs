defmodule Mix.Tasks.Adr.JudgeTest do
  # async: false - "execute/1 falls back to the real cli_available and git
  # checks" below chdirs the whole OS process into a scratch git repo so the
  # default `opts \\ []` clause's real `git` shell-out (its `git/1` runner
  # takes no `:cd`, so there is no way to point it elsewhere) sees that repo
  # instead of this checkout. `File.cd!/2` changes the OS process's working
  # directory for every process in the VM, not just the test's own, so no
  # other test anywhere may run concurrently while it is in effect - the same
  # reason Statifier.TmpDirTest gives for its own async: false.
  use ExUnit.Case, async: false

  alias Mix.Statifier.AdrJudge
  alias Mix.Tasks.Adr.Judge
  alias Statifier.TmpDir

  @no_scoped_changes_summary "no files in this diff are in a judged ADR scope " <>
                               "(lib/statifier/, .claude/skills/**/SKILL.md)"

  # The task's only side effects are a `git` shell-out and a model call, so
  # every test drives it with a stub runner and/or a stub caller - never the
  # real network. `rev-parse` is keyed by the ref it is asked to resolve,
  # since that call decides the base.
  defp runner(responses) do
    fn [subcommand | rest] ->
      key = if subcommand == "rev-parse", do: List.last(rest), else: subcommand
      Map.get(Map.new(responses), key, {"", 1})
    end
  end

  defp resolving(diff) do
    runner([
      {"origin/main", {"origin/main\n", 0}},
      {"merge-base", {"abc123\n", 0}},
      {"diff", {diff, 0}}
    ])
  end

  defp core_diff do
    """
    diff --git a/lib/statifier/interpreter.ex b/lib/statifier/interpreter.ex
    --- a/lib/statifier/interpreter.ex
    +++ b/lib/statifier/interpreter.ex
    @@ -10,1 +10,0 @@
    -    trace(:exit_set, state)
    """
  end

  defp docs_only_diff do
    """
    diff --git a/docs/adr/0013-something.md b/docs/adr/0013-something.md
    --- a/docs/adr/0013-something.md
    +++ b/docs/adr/0013-something.md
    @@ -1,0 +1,1 @@
    +Some prose.
    """
  end

  # Deliberately not `Statifier.TmpDir.path_for/2` (the usual
  # `@tag :isolated_tmp_dir` path): that name is deterministic per
  # module+test, so the Tests stage's and Regression ratchet's `mix test`
  # processes - which both run this file - would resolve it identically. That
  # used to matter here: `TmpDir.root()` did not carry a per-process
  # discriminator, so `Statifier.TmpDirTest`'s process-global
  # `STATIFIER_TMP_ROOT` mutations (see its own `async: false` comment) could
  # briefly make two concurrent `mix test` processes agree on the same root,
  # and `TmpDir.setup_tmp_dir/1`'s `rm_rf!` on that shared path then raced the
  # git repo this test was actively using in the other process - reproduced
  # while writing this test, once as directory corruption, once as "unable to
  # read current working directory" mid-`git init`. `TmpDir.root/0` now ends
  # in a `System.pid()` segment unconditionally (st-iao), so this directory is
  # unique to this OS process without an extra suffix - kept anyway, spelled
  # via `TmpDir.process_id/0`, as a second discriminator that costs nothing
  # and needs no reasoning about `TmpDir.root/0`'s internals to trust.
  defp scratch_repo_dir do
    Path.join([TmpDir.root(), "adr-judge-test-git-repo", TmpDir.process_id()])
  end

  # A minimal real git repo for "execute/1 falls back to the real
  # cli_available and git checks": one committed file outside lib/statifier/,
  # nothing else, so HEAD's own diff is structurally guaranteed empty.
  # `commit.gpgsign false` keeps a developer's global signing config from
  # hanging this on a passphrase prompt for a throwaway commit.
  defp seed_git_repo(dir) do
    git!(dir, ["init", "--quiet"])
    git!(dir, ["config", "user.email", "adr-judge-test@example.invalid"])
    git!(dir, ["config", "user.name", "ADR Judge Test"])
    git!(dir, ["config", "commit.gpgsign", "false"])

    File.write!(Path.join(dir, "README.md"), "scratch repo for adr_judge_test.exs\n")

    git!(dir, ["add", "README.md"])
    git!(dir, ["commit", "--quiet", "--message", "seed commit"])
  end

  defp git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} exited #{status}: #{output}")
    end
  end

  # The registry now has two entries sharing lib/statifier/ (ADR-0012 and
  # ADR-0014, added in the same phase that added this filter) - `core_diff/0`
  # is in scope for both, so an unfiltered stub would answer the propose
  # prompt for each one identically and double every finding count this file
  # asserts. Scoping the propose response to ADR-0012's own prompt (and
  # answering every other judged ADR's propose pass with "no candidates")
  # keeps this file's single-ADR assertions accurate without needing every
  # test rewritten to expect two ADRs' worth of candidates. Matching on the
  # full "reviewing a code change against <label>" line rather than just the
  # bare "ADR-0012" substring matters here: ADR-0014's own real file text
  # (read from disk, since these tests pass no `opts[:adr_texts]`) mentions
  # "ADR-0012" repeatedly while explaining how it extends it, so a bare
  # substring check would also match ADR-0014's propose prompt.
  @adr_0012_propose_marker "reviewing a code change against ADR-0012 (debuggability"

  defp stub_caller(propose_response, refute_response) do
    fn prompt ->
      cond do
        String.contains?(prompt, "PROPOSE PASS") and
            String.contains?(prompt, @adr_0012_propose_marker) ->
          propose_response

        String.contains?(prompt, "PROPOSE PASS") ->
          {:ok, "[]"}

        true ->
          refute_response
      end
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

  defp two_candidates_json do
    JSON.encode!([
      %{
        "file" => "lib/statifier/interpreter.ex",
        "line" => 10,
        "claim" => "drops a trace effect"
      },
      %{
        "file" => "lib/statifier/interpreter.ex",
        "line" => 20,
        "claim" => "loses a source location"
      }
    ])
  end

  # sabotage: match `System.find_executable("claude")` directly in execute/2
  #           instead of routing through AdrJudge.collect/1's
  #           `Keyword.get_lazy(opts, :cli_available, ...)`, so the injected
  #           false is never honored -> red
  test "no claude CLI is a skip that names it missing, not a failure" do
    assert {:skip, json} =
             Judge.execute(["--format", "json"],
               cli_available: false,
               runner: resolving(core_diff())
             )

    assert {:ok, %{"summary" => "claude CLI not on PATH", "findings" => []}} =
             JSON.decode(json)
  end

  # sabotage: swap the :no_base_ref and :no_cli clauses in execute/2's
  #           case, so a missing base with an available CLI reports the
  #           CLI-missing reason instead -> red
  test "no base ref is a skip that names the missing base, not a failure" do
    assert {:skip, json} =
             Judge.execute(["--format", "json"], cli_available: true, runner: runner([]))

    assert {:ok, %{"summary" => "no base ref: neither origin/main nor main resolves"}} =
             JSON.decode(json)
  end

  # sabotage: scope AdrJudge.collect/1's registered scope check to `lib/`
  #           instead of `lib/statifier/`, so a docs/-only diff no longer
  #           skips -> red
  test "a diff touching no lib/statifier/ files is a skip that says so" do
    assert {:skip, json} =
             Judge.execute(["--format", "json"],
               cli_available: true,
               runner: resolving(docs_only_diff())
             )

    assert {:ok, %{"summary" => @no_scoped_changes_summary}} = JSON.decode(json)
  end

  # sabotage: have scope_descriptions/0 (AdrJudge) return [] instead of
  #           mapping the registry, so the skip reason names no scope at
  #           all -> red
  test "the no-scoped-changes skip reason names every registered scope" do
    assert {:skip, json} =
             Judge.execute(["--format", "json"],
               cli_available: true,
               runner: resolving(docs_only_diff())
             )

    assert {:ok, %{"summary" => summary}} = JSON.decode(json)

    for description <- AdrJudge.scope_descriptions() do
      assert summary =~ description
    end
  end

  # sabotage: have respond/2 report a non-empty findings list as {:ok, _}
  #           instead of {:error, _} -> red
  test "a surviving finding is an error carrying the ExQuality finding contract" do
    assert {:error, json} =
             Judge.execute(["--format", "json"],
               cli_available: true,
               runner: resolving(core_diff()),
               caller: stub_caller({:ok, candidate_json()}, {:ok, ~s({"violation": true})})
             )

    assert {:ok, document} = JSON.decode(json)

    assert %{
             "summary" => "1 likely ADR violation",
             "stats" => %{"finding_count" => 1},
             "findings" => [finding]
           } = document

    assert %{
             "file" => "lib/statifier/interpreter.ex",
             "line" => 10,
             "severity" => "error",
             "check" => "adr-0012-debuggability"
           } = finding

    assert finding["message"] =~ "trace effect"
  end

  # sabotage: have respond/2 report an empty findings list as {:error, _}
  #           instead of {:ok, _} -> red
  test "a candidate overturned by the refute pass is a clean pass, not a finding" do
    assert {:ok, json} =
             Judge.execute(["--format", "json"],
               cli_available: true,
               runner: resolving(core_diff()),
               caller: stub_caller({:ok, candidate_json()}, {:ok, ~s({"violation": false})})
             )

    assert {:ok, %{"summary" => "No likely ADR violations", "findings" => []}} =
             JSON.decode(json)
  end

  # sabotage: drop the plural clause from violations/1 -> red
  test "the summary counts the findings it reports" do
    assert {:error, json} =
             Judge.execute(["--format", "json"],
               cli_available: true,
               runner: resolving(core_diff()),
               caller: stub_caller({:ok, two_candidates_json()}, {:ok, ~s({"violation": true})})
             )

    assert {:ok, %{"summary" => "2 likely ADR violations"}} = JSON.decode(json)
  end

  # sabotage: report a failing git command as {:skip, _} instead of
  #           {:error, _} -> red
  test "a failing git command fails the stage rather than skipping it" do
    responses = [{"origin/main", {"origin/main\n", 0}}, {"merge-base", {"fatal: bad\n", 128}}]

    assert {:error, json} =
             Judge.execute(["--format", "json"], cli_available: true, runner: runner(responses))

    assert {:ok, %{"summary" => "ADR judge could not read git", "findings" => [finding]}} =
             JSON.decode(json)

    assert finding["message"] =~ "exited 128"
  end

  # sabotage: drop the `--base` clause from collect_opts/2 -> red
  test "--base is preferred over the default refs" do
    responses = [
      {"upstream/trunk", {"upstream/trunk\n", 0}},
      {"merge-base", {"abc123\n", 0}},
      {"diff", {core_diff(), 0}}
    ]

    assert {:error, json} =
             Judge.execute(["--base", "upstream/trunk", "--format", "json"],
               cli_available: true,
               runner: runner(responses),
               caller: stub_caller({:ok, candidate_json()}, {:ok, ~s({"violation": true})})
             )

    assert {:ok, %{"stats" => %{"finding_count" => 1}}} = JSON.decode(json)
  end

  # Exercises the real `git` shell-out and real `System.find_executable/1`
  # rather than injected stubs, so the default `opts \\ []` clause of
  # execute/2 is asserted too - every other test in this file injects both
  # explicitly, which never reaches that default. Asserting that with this
  # checkout's own working tree used to be safe on the premise that it never
  # touches lib/statifier/ (only test/ files) - st-l5k.3 made that premise
  # permanently false, and once any lib/statifier/ file is dirty the real
  # `git diff` finds a real core change and this test shells out to the real
  # `claude` CLI (st-c8c). So instead this builds a throwaway git repo under
  # a scratch dir - one committed file outside lib/statifier/, nothing else -
  # and chdirs the OS process into it for the call: `--base HEAD`
  # always resolves there, and `git diff` against HEAD is structurally empty
  # (nothing has changed since the seed commit, and nothing is untracked), so
  # `collect/1` always reaches the no-scoped-changes skip before ever calling
  # a `caller` - this can never shell out to the real `claude` CLI,
  # regardless of what this worktree's own lib/statifier/ looks like.
  #
  # The registry now also carries ADR-0015's `.claude/skills/**/SKILL.md`
  # scope (st-laz), so the premise widens to cover it too: the seeded repo has
  # one `README.md` and no `.claude/` tree at all, so it is out of scope for
  # every registered ADR, not just the lib/statifier/ ones - the skip still
  # fires the same way.
  #
  # This still assumes the `claude` CLI is on PATH in the environment running
  # this suite (true of every developer/CI environment this task is built
  # for - it is the tool `mix adr.judge` itself shells out to). If that
  # assumption ever stops holding here, this test needs `cli_available: true`
  # added back like every other test in the file - at the cost of no longer
  # covering the default clause.
  #
  # See `scratch_repo_dir/0` for why the repo's path is not the usual
  # `@tag :isolated_tmp_dir` one.
  # sabotage: change execute/2's default opts from `[]` to
  #           `[cli_available: false]` -> red: the unsabotaged default reaches
  #           git and finds no in-scope diff against the scratch repo's HEAD
  #           for either registered scope, while the sabotaged default never
  #           gets past the CLI check, so the skip reason changes from "no
  #           files in this diff are in a judged ADR scope (lib/statifier/,
  #           .claude/skills/**/SKILL.md)" to "claude CLI not on PATH"
  test "execute/1 falls back to the real cli_available and git checks" do
    repo_dir = scratch_repo_dir()
    File.rm_rf!(repo_dir)
    File.mkdir_p!(repo_dir)
    on_exit(fn -> File.rm_rf!(repo_dir) end)

    seed_git_repo(repo_dir)

    assert {:skip, json} =
             File.cd!(repo_dir, fn -> Judge.execute(["--base", "HEAD", "--format", "json"]) end)

    assert {:ok, %{"summary" => @no_scoped_changes_summary}} = JSON.decode(json)
  end

  describe "without --format json" do
    # sabotage: print the JSON document when no format is given -> red
    test "a finding is reported as prose naming the file, check and next step" do
      assert {:error, output} =
               Judge.execute([],
                 cli_available: true,
                 runner: resolving(core_diff()),
                 caller: stub_caller({:ok, candidate_json()}, {:ok, ~s({"violation": true})})
               )

      text = IO.iodata_to_binary(output)

      assert text =~ "1 likely ADR violation"
      assert text =~ "lib/statifier/interpreter.ex:10"
      assert text =~ "(adr-0012-debuggability)"
      assert text =~ "docs/adr/"
      refute text =~ "\"findings\""
    end

    # sabotage: emit the advice block on a clean run too -> red
    test "a clean run says so and nothing else" do
      assert {:ok, output} =
               Judge.execute([],
                 cli_available: true,
                 runner: resolving(core_diff()),
                 caller: stub_caller({:ok, candidate_json()}, {:ok, ~s({"violation": false})})
               )

      assert IO.iodata_to_binary(output) == "No likely ADR violations"
    end

    # sabotage: have skipped/2 return the JSON document in prose mode -> red
    test "a skip states its reason as prose" do
      assert {:skip, output} =
               Judge.execute([], cli_available: false, runner: resolving(core_diff()))

      assert output == "claude CLI not on PATH"
    end

    # sabotage: have failed/2 drop the git reason from the prose message -> red
    test "a git failure states what git said" do
      responses = [{"origin/main", {"origin/main\n", 0}}, {"merge-base", {"fatal: bad\n", 128}}]

      assert {:error, output} = Judge.execute([], cli_available: true, runner: runner(responses))

      text = IO.iodata_to_binary(output)

      assert text =~ "ADR judge could not read git"
      assert text =~ "exited 128"
    end
  end
end
