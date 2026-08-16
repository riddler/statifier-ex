defmodule Mix.Tasks.Gate.CheckTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Gate.Check

  # The task's only side effect is a `git` shell-out, so every test drives it
  # with a stub runner over a hand-written diff. `rev-parse` is keyed by the ref
  # it is asked to resolve, since that call decides the base.
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

  defp gate_change do
    """
    diff --git a/.quality.exs b/.quality.exs
    --- a/.quality.exs
    +++ b/.quality.exs
    @@ -20,0 +20,1 @@
    +  strict: false
    """
  end

  defp ledger_entry do
    """
    diff --git a/docs/quality-gate-changes.md b/docs/quality-gate-changes.md
    --- a/docs/quality-gate-changes.md
    +++ b/docs/quality-gate-changes.md
    @@ -30,0 +30,2 @@
    +Approved-by: JohnnyT
    +- .quality.exs: registers the gate_guard custom stage
    """
  end

  # sabotage: have respond/2 return {:ok, _} for a non-empty finding list -> red
  test "an unjustified gate change is an error carrying the finding contract" do
    assert {:error, json} =
             Check.execute(["--format", "json"], runner: resolving(gate_change()))

    assert {:ok, document} = JSON.decode(json)

    assert %{
             "summary" => "1 unjustified gate change",
             "stats" => %{"finding_count" => 1},
             "findings" => [finding]
           } = document

    assert %{
             "file" => ".quality.exs",
             "line" => nil,
             "severity" => "error",
             "check" => "gate-config"
           } = finding

    assert finding["message"] =~ "docs/quality-gate-changes.md"
  end

  # sabotage: drop the plural clause from changes/1 -> red
  test "the summary counts the findings it reports" do
    diff =
      gate_change() <>
        """
        diff --git a/test/statifier/document_test.exs b/test/statifier/document_test.exs
        --- a/test/statifier/document_test.exs
        +++ b/test/statifier/document_test.exs
        @@ -42,0 +42,1 @@
        +  @tag :skip
        """

    assert {:error, json} = Check.execute(["--format", "json"], runner: resolving(diff))
    assert {:ok, %{"summary" => "2 unjustified gate changes"}} = JSON.decode(json)
  end

  # sabotage: ignore the ledger diff when clearing findings -> red
  test "a change the ledger justifies in the same diff is not a finding" do
    diff = gate_change() <> ledger_entry()

    assert {:ok, json} = Check.execute(["--format", "json"], runner: resolving(diff))

    assert {:ok, %{"summary" => "No unjustified gate changes", "findings" => []}} =
             JSON.decode(json)
  end

  # sabotage: return {:error, _} instead of {:skip, _} when no base ref resolves -> red
  test "no base ref is a skip that writes its own reason" do
    assert {:skip, json} = Check.execute(["--format", "json"], runner: runner([]))

    assert {:ok, %{"summary" => summary}} = JSON.decode(json)
    assert summary == "no base ref: neither origin/main nor main resolves"
  end

  # sabotage: report a failing git command as {:skip, _} -> red
  test "a failing git command fails the stage rather than skipping it" do
    responses = [{"origin/main", {"origin/main\n", 0}}, {"merge-base", {"fatal: bad\n", 128}}]

    assert {:error, json} = Check.execute(["--format", "json"], runner: runner(responses))

    assert {:ok, %{"summary" => "gate check could not read git", "findings" => [finding]}} =
             JSON.decode(json)

    assert finding["message"] =~ "exited 128"
  end

  # sabotage: have collect_opts/2 drop --base -> red
  test "--base is preferred over the default refs" do
    responses = [
      {"upstream/trunk", {"upstream/trunk\n", 0}},
      {"merge-base", {"abc123\n", 0}},
      {"diff", {gate_change(), 0}}
    ]

    assert {:error, json} =
             Check.execute(["--base", "upstream/trunk", "--format", "json"],
               runner: runner(responses)
             )

    assert {:ok, %{"stats" => %{"finding_count" => 1}}} = JSON.decode(json)
  end

  describe "without --format json" do
    # sabotage: print the JSON document when no format is given -> red
    test "a finding is reported as prose naming the file, check and next step" do
      assert {:error, output} = Check.execute([], runner: resolving(gate_change()))

      text = IO.iodata_to_binary(output)

      assert text =~ "1 unjustified gate change"
      assert text =~ ".quality.exs"
      assert text =~ "(gate-config)"
      assert text =~ "ADR-0011"
      refute text =~ "\"findings\""
    end

    # sabotage: emit the advice block on a clean run too -> red
    test "a clean run says so and nothing else" do
      assert {:ok, output} = Check.execute([], runner: resolving(""))
      assert IO.iodata_to_binary(output) == "No unjustified gate changes"
    end

    # sabotage: have at/1 ignore the line number -> red
    test "a skip-tag finding points at the line it was added on" do
      diff = """
      diff --git a/test/statifier/document_test.exs b/test/statifier/document_test.exs
      --- a/test/statifier/document_test.exs
      +++ b/test/statifier/document_test.exs
      @@ -42,0 +42,1 @@
      +  @tag :skip
      """

      assert {:error, output} = Check.execute([], runner: resolving(diff))
      assert IO.iodata_to_binary(output) =~ "test/statifier/document_test.exs:42"
    end

    # sabotage: have skipped/1's non-json clause return the JSON document too -> red
    test "no base ref is a skip that writes its own reason as prose" do
      assert {:skip, output} = Check.execute([], runner: runner([]))
      assert IO.iodata_to_binary(output) == "no base ref: neither origin/main nor main resolves"
    end

    # sabotage: have failed/2's non-json clause drop the reason from the message -> red
    test "a failing git command reports the reason as prose" do
      responses = [{"origin/main", {"origin/main\n", 0}}, {"merge-base", {"fatal: bad\n", 128}}]

      assert {:error, output} = Check.execute([], runner: runner(responses))
      assert IO.iodata_to_binary(output) =~ "gate check could not read git:"
      assert IO.iodata_to_binary(output) =~ "exited 128"
    end
  end

  # Exercises run/1 itself, not execute/2 - the only way to reach run/1's
  # `{:ok, output} -> report(output, 0)` clause and report/2's own status-0
  # clause, neither reachable through execute/2 alone. run/1 has no `opts`
  # parameter to inject a stub runner through, so this uses the real `git`
  # shell-out with `--base HEAD`: the diff between HEAD and itself is always
  # empty, so this reaches the clean-pass branch deterministically regardless
  # of what is dirty in this checkout. report/2's non-zero clause
  # (`System.at_exit(fn _ -> exit({:shutdown, status}) end)`) is never
  # reached on this path, so the `mix test` VM's own exit code stays
  # untouched - verified separately that `mix gate.check --base HEAD` exits 0
  # in this checkout before writing this test.
  # sabotage: have report/2's status-0 clause return :error instead of :ok -> red
  test "run/1 returns :ok for a real clean pass" do
    output = capture_io(fn -> assert :ok = Check.run(["--base", "HEAD"]) end)
    assert output =~ "No unjustified gate changes"
  end
end
