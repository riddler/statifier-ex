defmodule Mix.Tasks.Adr.JudgeTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Adr.Judge

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

  # sabotage: scope AdrJudge.collect/1's core-changes check to `lib/` instead
  #           of `lib/statifier/`, so a docs/-only diff no longer skips -> red
  test "a diff touching no lib/statifier/ files is a skip that says so" do
    assert {:skip, json} =
             Judge.execute(["--format", "json"],
               cli_available: true,
               runner: resolving(docs_only_diff())
             )

    assert {:ok, %{"summary" => "no lib/statifier/ files in this diff"}} = JSON.decode(json)
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
             "summary" => "1 likely ADR-0012 violation",
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

    assert {:ok, %{"summary" => "No likely ADR-0012 violations", "findings" => []}} =
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

    assert {:ok, %{"summary" => "2 likely ADR-0012 violations"}} = JSON.decode(json)
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

      assert text =~ "1 likely ADR-0012 violation"
      assert text =~ "lib/statifier/interpreter.ex:10"
      assert text =~ "(adr-0012-debuggability)"
      assert text =~ "ADR-0012"
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

      assert IO.iodata_to_binary(output) == "No likely ADR-0012 violations"
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
