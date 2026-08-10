defmodule Statifier.Interpreter.ExitEntryExitTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Interpreter.ExitEntry
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Hand-drawn from `@document`, depth-first, document order:
  #
  #  0 scxml (root)
  #  1   region             (compound - the transition domain below; `c`
  #  |                        sits outside it, at the top level, on purpose)
  #  2     a                  (compound; onexit; leave_all transition)
  #  3       aa               (compound; onexit)
  #  4         a1
  #  5       a2
  #  6       hs                (history, shallow, default -> a2)
  #  7       hd                (history, deep, default -> a2)
  #  8   c                  (compound; untouched by leave_all's domain)
  #  9     c1
  # 10     hc                (history, shallow, default -> c1)
  #
  # `leave_all` is an `:external` transition sourced at `a`, targeting its
  # sibling `a2`; its domain is `region` (the nearest compound ancestor of
  # both `a` and `a2`), so its exit set is every active descendant of
  # `region`, `region` itself excluded (proper) - `a`, `aa`, `a1`, `a2` at
  # most, and never `c`, which is outside `region` entirely. Each test
  # picks its scope through `configuration`, never through a second
  # transition.
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="region">
      <state id="region">
          <state id="a">
              <transition event="leave_all" target="a2"/>
              <onexit>
                  <log label="a-exit"/>
              </onexit>
              <state id="aa">
                  <onexit>
                      <log label="aa-exit"/>
                  </onexit>
                  <state id="a1"/>
              </state>
              <state id="a2"/>
              <history id="hs" type="shallow">
                  <transition target="a2"/>
              </history>
              <history id="hd" type="deep">
                  <transition target="a2"/>
              </history>
          </state>
      </state>
      <state id="c">
          <state id="c1"/>
          <history id="hc" type="shallow">
              <transition target="c1"/>
          </history>
      </state>
  </scxml>
  """

  @indexes %{
    region: 1,
    a: 2,
    aa: 3,
    a1: 4,
    a2: 5,
    hs: 6,
    hd: 7,
    c: 8,
    c1: 9,
    hc: 10
  }

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp machine_state(machine, configuration, opts \\ [trace: true]) do
    %{
      Statifier.MachineState.new(machine, opts)
      | configuration: MapSet.new(configuration)
    }
  end

  defp leave_all(machine) do
    machine.transitions
    |> Tuple.to_list()
    |> Enum.find(&(&1.events == [["leave_all"]]))
  end

  # AC: "Exit order reverse document order ... asserted by tests"
  #
  # sabotage: `exit_states/2` sorts `states_to_exit` with
  # `Machine.document_order/2` instead of `Machine.exit_order/2` -> exit
  # order becomes ascending instead of descending, reddening this
  # assertion.
  test "exit order is strictly descending index" do
    m = machine()
    ms = machine_state(m, [idx(:a), idx(:aa), idx(:a1), idx(:a2)])

    {result, effects} = ExitEntry.exit_states(ms, [leave_all(m)])

    assert [{:trace, %Effect.Trace.ExitSet{indexes: indexes}}] = effects
    assert indexes == [idx(:a2), idx(:a1), idx(:aa), idx(:a)]
    refute MapSet.member?(result.configuration, idx(:a))
  end

  # AC: "the exit set is intersected with the configuration"
  #
  # sabotage: `Selection.compute_exit_set/2`'s `descendants_in_configuration/2`
  # helper is changed to ignore `configuration` and return every descendant
  # of the domain regardless of activity -> `aa`/`a1`, never active here,
  # would wrongly appear in the exit set, reddening this assertion.
  test "a state not in the configuration is never exited" do
    m = machine()
    ms = machine_state(m, [idx(:a2)])

    {result, effects} = ExitEntry.exit_states(ms, [leave_all(m)])

    assert [{:trace, %Effect.Trace.ExitSet{indexes: [idx_a2]}}] = effects
    assert idx_a2 == idx(:a2)
    assert result.configuration == MapSet.new()
  end

  describe "history recording" do
    # sabotage: `recorded_value/3` uses the deep predicate
    # (`atomic? and descendant?`) for a `:shallow` history instead of the
    # `parent == state_index` filter -> `hs` would record `a1` (an atomic
    # descendant two levels down) instead of `aa` (the immediate child),
    # reddening this assertion.
    test "shallow history records the exiting state's active immediate children only" do
      m = machine()
      ms = machine_state(m, [idx(:a), idx(:aa), idx(:a1)])

      {result, _effects} = ExitEntry.exit_states(ms, [leave_all(m)])

      assert Map.fetch!(result.history_values, idx(:hs)) == MapSet.new([idx(:aa)])
    end

    # sabotage: `recorded_value/3` uses the shallow predicate
    # (`parent == state_index`) for a `:deep` history instead of the
    # `atomic? and descendant?` pair -> `hd` would record `aa` (an
    # intermediate compound, not atomic) instead of `a1`, reddening this
    # assertion.
    test "deep history records active atomic descendants only, not intermediate compounds" do
      m = machine()
      ms = machine_state(m, [idx(:a), idx(:aa), idx(:a1)])

      {result, _effects} = ExitEntry.exit_states(ms, [leave_all(m)])

      assert Map.fetch!(result.history_values, idx(:hd)) == MapSet.new([idx(:a1)])
    end

    # sabotage: `record_history_values/2` is changed to record the same
    # value for every history child of a state (copies `hs`'s value onto
    # `hd` too) -> `hs` and `hd` would come back equal even though they
    # cover different depths, reddening this refutation.
    test "shallow and deep on the same exiting state record different values in one pass" do
      m = machine()
      ms = machine_state(m, [idx(:a), idx(:aa), idx(:a1)])

      {result, _effects} = ExitEntry.exit_states(ms, [leave_all(m)])

      refute Map.fetch!(result.history_values, idx(:hs)) ==
               Map.fetch!(result.history_values, idx(:hd))
    end

    # sabotage: `record_one_history_value/3` merges into the previous entry
    # (`Map.update(history_values, history_index, value, &MapSet.union(&1,
    # value))`) instead of overwriting it -> the stale member `a2` would
    # still be present in the result, reddening this refutation.
    test "recording overwrites a previously recorded value on revisit" do
      m = machine()

      ms =
        %{
          machine_state(m, [idx(:a), idx(:aa), idx(:a1)])
          | history_values: %{idx(:hs) => MapSet.new([idx(:a2)])}
        }

      {result, _effects} = ExitEntry.exit_states(ms, [leave_all(m)])

      assert Map.fetch!(result.history_values, idx(:hs)) == MapSet.new([idx(:aa)])
      refute MapSet.member?(Map.fetch!(result.history_values, idx(:hs)), idx(:a2))
    end

    # sabotage: `record_history_values/2` iterates every state in
    # `machine.states` instead of only `states_to_exit` -> `hc` (a history
    # child of `c`, which never exits here) would gain an entry, reddening
    # this refutation.
    test "a history child of a state that is not exiting records nothing" do
      m = machine()
      ms = machine_state(m, [idx(:a), idx(:aa), idx(:a1), idx(:c), idx(:c1)])

      {result, effects} = ExitEntry.exit_states(ms, [leave_all(m)])

      assert [{:trace, %Effect.Trace.ExitSet{indexes: exited}}] = effects
      refute idx(:c) in exited
      refute Map.has_key?(result.history_values, idx(:hc))
    end

    # AC: "History recorded from the pre-exit configuration before any
    # onexit content of the step runs"
    #
    # sabotage: `exit_states/2` calls `record_history_values/2` *after* the
    # `depart/2` reduction instead of before it -> `aa` and `a1` are
    # already gone from `configuration` by the time `a`'s deep history is
    # recorded, so `hd` would come back empty instead of `[a1]`,
    # reddening this assertion. `aa` (whose `onexit` runs before `a`'s
    # departure, since `aa` exits first in descending order) is the state
    # whose removal this pins against.
    test "recording reads the pre-exit configuration, before onexit runs on an earlier-exiting state" do
      m = machine()
      ms = machine_state(m, [idx(:a), idx(:aa), idx(:a1)])

      {result, _effects} = ExitEntry.exit_states(ms, [leave_all(m)])

      assert Map.fetch!(result.history_values, idx(:hd)) == MapSet.new([idx(:a1)])
    end
  end

  # sabotage: `depart/2` removes the state from `configuration` before
  # calling `run_onexit_blocks/2` instead of after -> harmless to observe
  # directly (the stub content seam has no side effect either way), so this
  # pins the *net* configuration instead: `MapSet.delete/2` is swapped for
  # a no-op in `depart/2` -> the exited states would remain in
  # `result.configuration`, reddening this assertion.
  test "the configuration after exit_states/2 is the original minus exactly the exit set" do
    m = machine()
    original = MapSet.new([idx(:a), idx(:aa), idx(:a1), idx(:c), idx(:c1)])
    ms = machine_state(m, original)

    {result, _effects} = ExitEntry.exit_states(ms, [leave_all(m)])

    assert result.configuration == MapSet.new([idx(:c), idx(:c1)])
  end

  describe "the ExitSet trace" do
    # sabotage: `exit_states/2`'s `Effect.trace/3` call passes
    # `indexes: Machine.document_order(machine, states_to_exit)` instead of
    # the already-ordered `states_to_exit` -> the trace payload's indexes
    # come back ascending instead of descending, reddening this assertion.
    test "is emitted with indexes in exit order when trace: true" do
      m = machine()
      ms = machine_state(m, [idx(:a), idx(:aa), idx(:a1)], trace: true)

      {_result, effects} = ExitEntry.exit_states(ms, [leave_all(m)])

      assert [{:trace, %Effect.Trace.ExitSet{indexes: indexes}}] = effects
      assert indexes == Machine.exit_order(m, [idx(:a), idx(:aa), idx(:a1)])
    end

    # sabotage: `Effect.trace/3`'s call site in `exit_states/2` is replaced
    # with a bare list literal `[{:trace, Effect.Trace.ExitSet.new(...)}]`
    # (bypassing the `machine_state.trace` gate) -> a trace effect is
    # emitted even with `trace: false`, reddening this refutation.
    test "no trace effect at all when trace: false" do
      m = machine()
      ms = machine_state(m, [idx(:a), idx(:aa), idx(:a1)], trace: false)

      {_result, effects} = ExitEntry.exit_states(ms, [leave_all(m)])

      refute Enum.any?(effects, &Effect.trace?/1)
    end
  end

  # sabotage: `exit_states/2`'s `Selection.compute_exit_set/2` call is
  # changed to ignore an empty `enabled_transitions` and fall back to
  # exiting the whole configuration -> this reddens because the
  # configuration would come back changed.
  test "an empty transition list exits nothing and returns the machine_state unchanged apart from the trace" do
    m = machine()
    ms = machine_state(m, [idx(:a), idx(:aa), idx(:a1)], trace: true)

    {result, effects} = ExitEntry.exit_states(ms, [])

    assert [{:trace, %Effect.Trace.ExitSet{indexes: []}}] = effects
    assert result.configuration == ms.configuration
    assert result.history_values == ms.history_values
  end
end
