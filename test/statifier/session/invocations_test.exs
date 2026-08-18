defmodule Statifier.Session.InvocationsTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Lowering, Parser, Validator}
  alias Statifier.Session.Invocations

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp entry(pid, overrides \\ %{}) do
    Map.merge(
      %{session_id: "sess_child", pid: pid, monitor_ref: make_ref(), autoforward: false},
      overrides
    )
  end

  describe "new/0" do
    # sabotage: n/a - asserts only the empty table's shape, not any
    # decision-bearing lib/ behavior beyond the two functions below already
    # cover
    test "is an empty table" do
      invocations = Invocations.new()

      assert Invocations.count(invocations) == 0
      assert Invocations.invoke_ids(invocations) == []
      assert Invocations.entries(invocations) == %{}
    end
  end

  describe "put/3 and fetch/2" do
    # sabotage: `put/3` is changed to skip writing the `by_pid` reverse
    # index (`by_pid: by_pid` instead of `by_pid: Map.put(by_pid, pid,
    # invoke_id)`) -> the `pop_by_pid/2` assertion in the sibling describe
    # block below reddens; `fetch/2` alone cannot tell the two maps apart,
    # which is exactly why the reverse-index invariant needs its own test.
    test "put/3 records an entry fetch/2 can read back" do
      pid = self()
      invocations = Invocations.put(Invocations.new(), "i1", entry(pid))

      assert {:ok, %{pid: ^pid, session_id: "sess_child", autoforward: false}} =
               Invocations.fetch(invocations, "i1")
    end

    # sabotage: `fetch/2` is changed to `Map.fetch(entries, invoke_id) |>
    # then(fn _ -> {:ok, %{}} end)` (always hits) -> the `:error` assertion
    # below reddens
    test "fetch/2 on an unknown id is :error" do
      assert Invocations.fetch(Invocations.new(), "unknown") == :error
    end
  end

  describe "pop/2" do
    # sabotage: `pop/2`'s hit clause is changed to leave `by_pid` untouched
    # (`by_pid: by_pid` instead of `Map.delete(by_pid, pid)`) -> the
    # reverse-index assertion below (via `pop_by_pid/2` finding nothing)
    # reddens
    test "removes the entry from both the forward and reverse index" do
      pid = self()
      invocations = Invocations.put(Invocations.new(), "i1", entry(pid))

      assert {%{pid: ^pid}, invocations} = Invocations.pop(invocations, "i1")
      assert Invocations.fetch(invocations, "i1") == :error
      assert {nil, ^invocations} = Invocations.pop_by_pid(invocations, pid)
    end

    # sabotage: `pop/2`'s miss clause (`{nil, ^entries} -> {nil,
    # invocations}`) is changed to `{nil, %__MODULE__{entries: entries,
    # by_pid: %{}}}`, silently clearing `by_pid` on a miss -> a subsequent
    # `pop_by_pid/2` on a pid that was live before the miss now finds
    # nothing, reddening the assertion below
    test "popping an unknown id is a no-op" do
      pid = self()
      invocations = Invocations.put(Invocations.new(), "i1", entry(pid))

      assert {nil, unchanged} = Invocations.pop(invocations, "unknown")
      assert {{"i1", _entry}, _rest} = Invocations.pop_by_pid(unchanged, pid)
    end
  end

  describe "pop_by_pid/2" do
    # sabotage: `pop_by_pid/2`'s hit clause pops `by_pid` but reads the
    # entry back with `Map.pop(invocations.by_pid, invoke_id)` instead of
    # `Map.pop(invocations.entries, invoke_id)` (wrong map) -> raises
    # `FunctionClauseError`/`KeyError` instead of returning the entry,
    # reddening this test
    test "removes and returns the entry a pid names, by the reverse index" do
      pid = self()
      invocations = Invocations.put(Invocations.new(), "i1", entry(pid, %{autoforward: true}))

      assert {{"i1", %{pid: ^pid, autoforward: true}}, invocations} =
               Invocations.pop_by_pid(invocations, pid)

      assert Invocations.fetch(invocations, "i1") == :error
      assert Invocations.count(invocations) == 0
    end

    # sabotage: `pop_by_pid/2`'s miss clause is changed to `{nil, {nil,
    # by_pid}}` (a nested tuple) -> the pattern match in this test's own
    # assertion fails to match the actual return shape, reddening it
    test "a pid naming no live invocation is a no-op" do
      assert {nil, unchanged} = Invocations.pop_by_pid(Invocations.new(), self())
      assert Invocations.count(unchanged) == 0
    end
  end

  describe "live?/2, invoke_ids/1, entries/1, count/1" do
    # sabotage: `live?/2` is changed from `Map.has_key?(entries, invoke_id)`
    # to `not Map.has_key?(entries, invoke_id)` (inverted) -> both
    # assertions below reddens
    test "reflect the table's current membership" do
      pid = self()
      invocations = Invocations.put(Invocations.new(), "i1", entry(pid))

      assert Invocations.live?(invocations, "i1")
      refute Invocations.live?(invocations, "i2")
      assert Invocations.invoke_ids(invocations) == ["i1"]
      assert Invocations.count(invocations) == 1
      assert %{"i1" => %{pid: ^pid}} = Invocations.entries(invocations)
    end
  end

  describe "put/3 overwriting an existing invoke id" do
    # sabotage: `put/3`'s `Map.put(entries, invoke_id, entry)` is changed to
    # `Map.put_new(entries, invoke_id, entry)` (never overwrites) -> the
    # second `fetch/2` below reads back the *first* pid's entry instead of
    # the re-entered invocation's, reddening the assertion
    test "a second put/3 under the same invoke id replaces the first entry in both maps" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = self()

      invocations =
        Invocations.new()
        |> Invocations.put("i1", entry(pid1))
        |> Invocations.put("i1", entry(pid2))

      assert {:ok, %{pid: ^pid2}} = Invocations.fetch(invocations, "i1")
      assert {{"i1", _entry}, _rest} = Invocations.pop_by_pid(invocations, pid2)

      Process.exit(pid1, :kill)
    end
  end

  describe "list/1" do
    # sabotage: n/a - asserts only the empty-table shape, which the
    # decision-bearing cases below (key shape, sort order) already cover
    test "an empty table returns []" do
      assert Invocations.list(Invocations.new()) == []
    end

    # sabotage: `list/1`'s `Enum.map/2` projection is changed to also
    # include `monitor_ref` and `autoforward` in the returned map (spread
    # the raw `entry` instead of building `%{invoke_id:, session_id:,
    # pid:}`) -> the refute below on `Map.keys/1` reddens
    test "each entry carries exactly invoke_id, session_id, and pid" do
      pid = self()

      invocations =
        Invocations.put(Invocations.new(), "i1", entry(pid, %{autoforward: true}))

      assert [projected] = Invocations.list(invocations)
      assert Map.keys(projected) |> Enum.sort() == [:invoke_id, :pid, :session_id]
      assert projected == %{invoke_id: "i1", session_id: "sess_child", pid: pid}
    end

    # sabotage: `list/1`'s `Enum.sort_by(& &1.invoke_id)` is changed to
    # `Enum.sort_by(& &1.invoke_id, :desc)` -> this test's ascending-order
    # assertion reddens (removing the sort entirely does not redden it:
    # Erlang's small flat maps already iterate in key-sorted order, so the
    # sort direction is the only mutation that actually exercises this line)
    test "results are sorted by invoke_id regardless of insertion order" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)
      pid3 = self()

      invocations =
        Invocations.new()
        |> Invocations.put("i3", entry(pid3, %{session_id: "sess_c"}))
        |> Invocations.put("i1", entry(pid1, %{session_id: "sess_a"}))
        |> Invocations.put("i2", entry(pid2, %{session_id: "sess_b"}))

      assert Invocations.list(invocations) |> Enum.map(& &1.invoke_id) == ["i1", "i2", "i3"]

      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
    end
  end

  describe "seed_datamodel/2" do
    @child_xml """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="s1" version="1.0" datamodel="predicator">
        <datamodel>
            <data id="x"/>
            <data id="y" expr="1"/>
        </datamodel>
        <final id="s1" />
    </scxml>
    """

    # sabotage: `seed_datamodel/2`'s `MapSet.member?(data_ids, name)` guard
    # is inverted to `not MapSet.member?(data_ids, name)` -> a matching
    # `<param>` name is dropped instead of kept, reddening the assertion
    # that "x" survives
    test "keeps only params whose name matches a top-level <data> id" do
      machine = compile!(@child_xml)
      params = %{"x" => 1, "unmatched" => 2}

      assert Invocations.seed_datamodel(params, machine) == %{"x" => 1}
    end

    # sabotage: same guard inversion as above, from the other direction -
    # with it inverted, a non-matching name would survive instead of being
    # dropped, reddening this test's refute
    test "drops a name with no matching top-level <data> id" do
      machine = compile!(@child_xml)
      params = %{"unmatched" => 2}

      refute Map.has_key?(Invocations.seed_datamodel(params, machine), "unmatched")
    end

    # sabotage: `seed_datamodel/2`'s `:undefined` clause is removed, falling
    # through to the `is_map(params)` clause with `:undefined` -> raises
    # `FunctionClauseError` instead of returning `%{}`, reddening this test.
    # `:undefined` is what `EventData.coerce({:params, []})` actually
    # produces for an invocation with no <param>/namelist (ADR-0037); `nil`
    # is accepted for the same outcome and pinned alongside it.
    test "absent params (no <param>/namelist at all) seed nothing" do
      machine = compile!(@child_xml)

      assert Invocations.seed_datamodel(:undefined, machine) == %{}
      assert Invocations.seed_datamodel(nil, machine) == %{}
    end
  end
end
