defmodule Mix.Tasks.Adr.CheckTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Adr.Check

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

  defp near_miss_name do
    """
    diff --git a/lib/statifier/interpreter.ex b/lib/statifier/interpreter.ex
    --- a/lib/statifier/interpreter.ex
    +++ b/lib/statifier/interpreter.ex
    @@ -20,0 +20,1 @@
    +  defp exitset(state) do
    """
  end

  defp core_effect do
    """
    diff --git a/lib/statifier/interpreter.ex b/lib/statifier/interpreter.ex
    --- a/lib/statifier/interpreter.ex
    +++ b/lib/statifier/interpreter.ex
    @@ -40,0 +40,1 @@
    +    GenServer.call(pid, :step)
    """
  end

  # sabotage: have respond/2 return {:ok, _} for a non-empty finding list -> red
  test "a likely violation is an error carrying the finding contract" do
    assert {:error, json} = Check.execute(["--format", "json"], runner: resolving(core_effect()))

    assert {:ok, document} = JSON.decode(json)

    assert %{
             "summary" => "1 likely ADR violation",
             "stats" => %{"finding_count" => 1},
             "findings" => [finding]
           } = document

    assert %{
             "file" => "lib/statifier/interpreter.ex",
             "line" => 40,
             "severity" => "error",
             "check" => "adr-0003-effects"
           } = finding

    assert finding["message"] =~ "ADR-0003"
  end

  # sabotage: drop the plural clause from violations/1 -> red
  test "the summary counts the findings it reports" do
    diff = near_miss_name() <> core_effect()

    assert {:error, json} = Check.execute(["--format", "json"], runner: resolving(diff))
    assert {:ok, %{"summary" => "2 likely ADR violations"}} = JSON.decode(json)
  end

  # This stage only skips when it cannot resolve a base ref. A diff with nothing
  # under lib/ was checked and found clean, which is a pass.
  # sabotage: return {:skip, _} when the finding list is empty -> red
  test "a diff with no lib/ changes passes rather than skipping" do
    diff = """
    diff --git a/docs/adr/0013-something.md b/docs/adr/0013-something.md
    --- a/docs/adr/0013-something.md
    +++ b/docs/adr/0013-something.md
    @@ -1,0 +1,1 @@
    +Some prose.
    """

    assert {:ok, json} = Check.execute(["--format", "json"], runner: resolving(diff))

    assert {:ok, %{"summary" => "No likely ADR violations", "findings" => []}} = JSON.decode(json)
  end

  # sabotage: have respond_partial/2 skip regardless of findings -> red
  test "no base ref is a skip that writes its own reason" do
    lister = fn "docs/adr" -> {:ok, []} end
    reader = fn "docs/adr/README.md" -> {:ok, ""} end

    assert {:skip, json} =
             Check.execute(["--format", "json"],
               runner: runner([]),
               lister: lister,
               reader: reader
             )

    assert {:ok, %{"summary" => summary}} = JSON.decode(json)

    assert summary ==
             "no base ref: neither origin/main nor main resolves; " <>
               "the docs/adr/ numbering invariant ran and is clean"
  end

  # sabotage: report a failing git command as {:skip, _} -> red
  test "a failing git command fails the stage rather than skipping it" do
    responses = [{"origin/main", {"origin/main\n", 0}}, {"merge-base", {"fatal: bad\n", 128}}]

    assert {:error, json} = Check.execute(["--format", "json"], runner: runner(responses))

    assert {:ok, %{"summary" => "ADR check could not read git", "findings" => [finding]}} =
             JSON.decode(json)

    assert finding["message"] =~ "exited 128"
  end

  # sabotage: have collect_opts/2 drop --base -> red
  test "--base is preferred over the default refs" do
    responses = [
      {"upstream/trunk", {"upstream/trunk\n", 0}},
      {"merge-base", {"abc123\n", 0}},
      {"diff", {near_miss_name(), 0}}
    ]

    assert {:error, json} =
             Check.execute(["--base", "upstream/trunk", "--format", "json"],
               runner: runner(responses)
             )

    assert {:ok, %{"stats" => %{"finding_count" => 1}}} = JSON.decode(json)
  end

  # Exercises the real `git` shell-out rather than an injected runner, so the
  # default `opts \\ []` clause of execute/2 is asserted too - every other
  # test in this file injects a runner explicitly, which never reaches that
  # default. `--base HEAD` is used because it always resolves, so the outcome
  # here does not depend on which branches exist in the checkout.
  # sabotage: change execute/2's default opts from `[]` to
  #           `[runner: fn _ -> {"", 1} end]` -> red (a runner that fails
  #           every git call forces `:no_base_ref`, which the real default
  #           never produces for a ref that always resolves)
  test "execute/1 falls back to the real git runner" do
    assert {tag, _output} = Check.execute(["--base", "HEAD", "--format", "json"])
    refute tag == :skip
  end

  describe "ADR-0056 - numbering findings reported by the task" do
    # sabotage: have execute/2's :ok clause reject `line: nil` findings before
    #           calling respond/2, so a numbering finding never reaches the
    #           task's response -> red
    test "a numbering finding is reported as {:error, _} with an empty line" do
      lister = fn "docs/adr" -> {:ok, ["0001-first.md", "0001-second.md"]} end

      reader = fn
        "docs/adr/README.md" ->
          {:ok,
           """
           | # | Decision | Status |
           |---|---|---|
           | [0001](0001-first.md) | First | accepted |
           | [0001](0001-second.md) | Second | accepted |
           """}
      end

      assert {:error, json} =
               Check.execute(["--format", "json"],
                 runner: resolving(""),
                 lister: lister,
                 reader: reader
               )

      assert {:ok, %{"findings" => findings}} = JSON.decode(json)
      assert Enum.any?(findings, &(&1["check"] == "adr-0056-duplicate-number"))
      assert Enum.all?(findings, &(&1["line"] in [nil]))
    end

    # sabotage: have human/1's `line: nil` clause fall through to the general
    #           clause, printing "path:" with a trailing colon -> red
    test "prose output for a line: nil finding prints the path without a trailing colon" do
      lister = fn "docs/adr" -> {:ok, ["0001-first.md", "0001-second.md"]} end
      reader = fn "docs/adr/README.md" -> {:ok, ""} end

      assert {:error, output} =
               Check.execute([], runner: resolving(""), lister: lister, reader: reader)

      text = IO.iodata_to_binary(output)

      assert text =~ "docs/adr/0001-first.md\n"
      refute text =~ "docs/adr/0001-first.md:"
    end

    # sabotage: have execute/2's {:no_base_ref, source} clause call
    #           respond/2 instead of respond_partial/2, so a colliding index
    #           reports {:ok, _} (respond/2's :ok is unconditional for a []
    #           argument, but the real behavior lost here is that a nonempty
    #           finding list under no base ref must still fail the stage) -> red
    test "no base ref with a colliding index fails the stage, not skips it" do
      lister = fn "docs/adr" -> {:ok, ["0001-first.md", "0001-second.md"]} end

      reader = fn
        "docs/adr/README.md" ->
          {:ok,
           """
           | # | Decision | Status |
           |---|---|---|
           | [0001](0001-first.md) | First | accepted |
           | [0001](0001-second.md) | Second | accepted |
           """}
      end

      assert {:error, json} =
               Check.execute(["--format", "json"],
                 runner: runner([]),
                 lister: lister,
                 reader: reader
               )

      assert {:ok, %{"findings" => findings}} = JSON.decode(json)
      assert Enum.any?(findings, &(&1["check"] == "adr-0056-duplicate-number"))
    end

    # sabotage: have respond_partial/2's [] clause return {:error, _} instead
    #           of {:skip, _} -> red
    test "no base ref with a clean index skips, naming the invariant as having run" do
      lister = fn "docs/adr" -> {:ok, ["0001-first.md"]} end

      reader = fn "docs/adr/README.md" ->
        {:ok,
         "| # | Decision | Status |\n|---|---|---|\n| [0001](0001-first.md) | First | accepted |\n"}
      end

      assert {:skip, json} =
               Check.execute(["--format", "json"],
                 runner: runner([]),
                 lister: lister,
                 reader: reader
               )

      assert {:ok, %{"summary" => summary}} = JSON.decode(json)
      assert summary =~ "the docs/adr/ numbering invariant ran and is clean"
    end
  end

  describe "without --format json" do
    # sabotage: print the JSON document when no format is given -> red
    test "a finding is reported as prose naming the file, check and next step" do
      assert {:error, output} = Check.execute([], runner: resolving(near_miss_name()))

      text = IO.iodata_to_binary(output)

      assert text =~ "1 likely ADR violation"
      assert text =~ "lib/statifier/interpreter.ex:20"
      assert text =~ "(adr-0002-naming)"
      assert text =~ "deviation"
      refute text =~ "\"findings\""
    end

    # sabotage: emit the advice block on a clean run too -> red
    test "a clean run says so and nothing else" do
      assert {:ok, output} = Check.execute([], runner: resolving(""))
      assert IO.iodata_to_binary(output) == "No likely ADR violations"
    end

    # sabotage: have skipped/1 return the JSON document in prose mode -> red
    test "a skip states its reason as prose" do
      lister = fn "docs/adr" -> {:ok, []} end
      reader = fn "docs/adr/README.md" -> {:ok, ""} end

      assert {:skip, output} =
               Check.execute([], runner: runner([]), lister: lister, reader: reader)

      assert output ==
               "no base ref: neither origin/main nor main resolves; " <>
                 "the docs/adr/ numbering invariant ran and is clean"
    end

    # sabotage: have failed/2 drop the git reason from the prose message -> red
    test "a git failure states what git said" do
      responses = [{"origin/main", {"origin/main\n", 0}}, {"merge-base", {"fatal: bad\n", 128}}]

      assert {:error, output} = Check.execute([], runner: runner(responses))

      text = IO.iodata_to_binary(output)

      assert text =~ "ADR check could not read git"
      assert text =~ "exited 128"
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
  # untouched - verified separately that `mix adr.check --base HEAD` exits 0
  # in this checkout before writing this test.
  # sabotage: have report/2's status-0 clause return :error instead of :ok -> red
  test "run/1 returns :ok for a real clean pass" do
    output = capture_io(fn -> assert :ok = Check.run(["--base", "HEAD"]) end)
    assert output =~ "No likely ADR violations"
  end
end
