defmodule Mix.Tasks.Adr.CheckTest do
  use ExUnit.Case, async: true

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

  # sabotage: return {:error, _} instead of {:skip, _} when no base ref
  #           resolves -> red
  test "no base ref is a skip that writes its own reason" do
    assert {:skip, json} = Check.execute(["--format", "json"], runner: runner([]))

    assert {:ok, %{"summary" => summary}} = JSON.decode(json)
    assert summary == "no base ref: neither origin/main nor main resolves"
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
      assert {:skip, output} = Check.execute([], runner: runner([]))

      assert output == "no base ref: neither origin/main nor main resolves"
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
end
