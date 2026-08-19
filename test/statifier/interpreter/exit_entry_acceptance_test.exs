defmodule Statifier.Interpreter.ExitEntryAcceptanceTest do
  use ExUnit.Case, async: true

  alias Statifier.{
    Compiler,
    Effect,
    Event,
    Interpreter,
    Lowering,
    Machine,
    MachineState,
    Parser,
    Validator
  }

  alias Statifier.Interpreter.ExitEntry

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Hand-drawn from `@document`, depth-first, document order - one document
  # covering every acceptance-criteria line a test in this file can decide,
  # shaped the same way `selection_acceptance_test.exs` is (the sibling this
  # shape is borrowed from) rather than split into one fixture per rule.
  #
  #  0 scxml (root)
  #  1   region
  #  2     a                  (compound; initial="a1")
  #  3       a1                 (compound; onexit; `leave` -> a2)
  #  4         a1x
  #  5       a2
  #  6       hs                (history, shallow, default -> a1)
  #  7       hd                (history, deep, default -> a1, w/ content)
  #  |       `leave-a` (external, a -> cf_active) also sits on `a`
  #  8     cf_holder          (compound)
  #  9       cf_active
  # 10       cf_done            (final)
  # 11     par                 (parallel)
  # 12       reg1               (compound)
  # 13         reg1_active
  # 14         reg1_final         (final)
  # 15       reg2               (compound)
  # 16         reg2_active
  # 17         reg2_final         (final)
  # 18       hpar               (history, deep, default -> reg1_active reg2_active)
  # 19     trigger             (go-* transitions)
  # 20   top_final              (final, parent 0 - top-level)
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="region">
      <state id="region">
          <state id="a" initial="a1">
              <state id="a1">
                  <onexit>
                      <log label="a1-exit"/>
                  </onexit>
                  <transition event="leave" target="a2"/>
                  <state id="a1x"/>
              </state>
              <state id="a2"/>
              <history id="hs" type="shallow">
                  <transition target="a1"/>
              </history>
              <history id="hd" type="deep">
                  <transition target="a1">
                      <log label="hd-default-content"/>
                  </transition>
              </history>
              <transition event="leave-a" target="cf_active" type="external"/>
          </state>
          <state id="cf_holder">
              <state id="cf_active"/>
              <final id="cf_done"/>
          </state>
          <parallel id="par">
              <state id="reg1">
                  <state id="reg1_active"/>
                  <final id="reg1_final"/>
              </state>
              <state id="reg2">
                  <state id="reg2_active"/>
                  <final id="reg2_final"/>
              </state>
              <history id="hpar" type="deep">
                  <transition target="reg1_active reg2_active"/>
              </history>
          </parallel>
          <state id="trigger">
              <transition event="go-cf-done" target="cf_done"/>
              <transition event="go-reg1-final" target="reg1_final"/>
              <transition event="go-reg2-final" target="reg2_final"/>
              <transition event="go-hs" target="hs"/>
              <transition event="go-hd" target="hd"/>
              <transition event="go-hpar" target="hpar"/>
              <transition event="go-top" target="top_final"/>
          </state>
      </state>
      <final id="top_final"/>
  </scxml>
  """

  @indexes %{
    region: 1,
    a: 2,
    a1: 3,
    a1x: 4,
    a2: 5,
    hs: 6,
    hd: 7,
    cf_holder: 8,
    cf_active: 9,
    cf_done: 10,
    par: 11,
    reg1: 12,
    reg1_active: 13,
    reg1_final: 14,
    reg2: 15,
    reg2_active: 16,
    reg2_final: 17,
    hpar: 18,
    trigger: 19,
    top_final: 20
  }

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp machine_state(machine, configuration \\ [], opts \\ [trace: true]) do
    %{
      MachineState.new(machine, opts)
      | configuration: MapSet.new(configuration)
    }
  end

  defp transition_named(machine, event_name) do
    machine.transitions
    |> Tuple.to_list()
    |> Enum.find(&(&1.events == [[event_name]]))
  end

  defp empty_acc, do: {MapSet.new(), MapSet.new(), %{}}

  # AC: "exit_states, compute_entry_set, add_descendant_states_to_enter,
  # add_ancestor_states_to_enter, enter_states, is_in_final_state diff cleanly
  # against pseudocode" - the executable half of that criterion: every
  # spec-named function exists and is public under the spec's name, so a
  # silent rename is a failure here, not only in review.
  #
  # sabotage: `enter_states/2` in lib/statifier/interpreter/exit_entry.ex is
  # renamed to `enter_states2/2` -> `function_exported?/3` returns false for
  # it, reddening the `Enum.all?/2` assertion below.
  test "all six spec-named functions exist and are public" do
    Code.ensure_loaded!(ExitEntry)

    spec_functions = [
      {ExitEntry, :exit_states, 2},
      {ExitEntry, :compute_entry_set, 2},
      {ExitEntry, :add_descendant_states_to_enter, 3},
      {ExitEntry, :add_ancestor_states_to_enter, 4},
      {ExitEntry, :enter_states, 2},
      {ExitEntry, :in_final_state?, 2}
    ]

    assert length(spec_functions) == 6
    assert Enum.all?(spec_functions, fn {m, f, a} -> function_exported?(m, f, a) end)
  end

  # AC: "Exit order reverse document order ... asserted by tests"
  #
  # sabotage: `exit_states/2` pipes `states_to_exit` through
  # `Machine.document_order/2` instead of `Machine.exit_order/2` -> the order
  # becomes ascending instead of descending, reddening this assertion.
  test "exit order is reverse document order" do
    m = machine()
    ms = machine_state(m, [idx(:a), idx(:a1), idx(:a1x)])
    leave_a = transition_named(m, "leave-a")

    {_result, effects} = ExitEntry.exit_states(ms, [leave_a])

    assert [{:trace, %Effect.Trace.ExitSet{indexes: indexes}} | rest] = effects
    assert indexes == [idx(:a1x), idx(:a1), idx(:a)]

    # a1's own onexit block ("a1-exit") is the only one in this document's
    # exit set; a1x and a have none.
    a1_index = idx(:a1)

    assert [
             {:log, %Effect.Log{label: "a1-exit"}},
             {:trace, %Effect.Trace.ContentExecuted{owner: {:onexit, ^a1_index, 0}}}
           ] = rest
  end

  # AC: "Exit order reverse document order, entry order document order,
  # asserted by tests"
  #
  # sabotage: `enter_states/2` pipes `states_to_enter` through
  # `Machine.exit_order/2` instead of `Machine.document_order/2` -> the order
  # becomes descending instead of ascending, reddening this assertion.
  test "entry order is document order" do
    m = machine()
    ms = machine_state(m, [idx(:region), idx(:trigger)])
    cf_done = transition_named(m, "go-cf-done")

    {_result, effects} = ExitEntry.enter_states(ms, [cf_done])

    assert [{:trace, %Effect.Trace.EntrySet{indexes: indexes}}] = effects
    assert indexes == [idx(:cf_holder), idx(:cf_done)]
  end

  describe "the four history criteria" do
    # AC: "History: shallow vs deep difference ... each a named test"
    #
    # sabotage: `recorded_value/3`'s `:deep` branch is changed to use the
    # `:shallow` predicate (`parent == state_index`) too -> `hd` would record
    # `a1` (the immediate child) instead of `a1x` (the atomic descendant),
    # equal to what `hs` records, reddening the inequality assertion below.
    test "shallow history and deep history record different values on the same exit" do
      m = machine()
      ms = machine_state(m, [idx(:a), idx(:a1), idx(:a1x)])
      leave_a = transition_named(m, "leave-a")

      {result, _effects} = ExitEntry.exit_states(ms, [leave_a])

      assert Map.fetch!(result.history_values, idx(:hs)) == MapSet.new([idx(:a1)])
      assert Map.fetch!(result.history_values, idx(:hd)) == MapSet.new([idx(:a1x)])
    end

    # AC: "History: ... overwrite on revisit ... each a named test"
    #
    # sabotage: `record_one_history_value/3` is changed to
    # `Map.put_new(machine_state.history_values, history_index, value)`
    # instead of an unconditional `Map.put/3` -> the stale preset value
    # `MapSet.new([idx(:a2)])` would survive, reddening this assertion.
    test "recording overwrites a previously recorded value on revisit" do
      m = machine()

      ms = %{
        machine_state(m, [idx(:a), idx(:a1), idx(:a1x)])
        | history_values: %{idx(:hs) => MapSet.new([idx(:a2)])}
      }

      leave_a = transition_named(m, "leave-a")
      {result, _effects} = ExitEntry.exit_states(ms, [leave_a])

      assert Map.fetch!(result.history_values, idx(:hs)) == MapSet.new([idx(:a1)])
    end

    # AC: "History: ... coherent parallel restoration ... each a named test" -
    # a deep history recorded across both regions of a parallel restores both
    # recorded leaves plus the ancestors between each and the history's
    # parent, in one coherent set (not one region restored and the other
    # defaulted).
    #
    # sabotage: `enter_restored/4`'s ancestor pass is bounded by `nil` instead
    # of `parent_index` -> the walk no longer stops at `par`, pulling in
    # `region` (and the root) too, reddening the exact-set assertion below.
    test "a recorded deep history on a parallel restores both regions coherently" do
      m = machine()

      ms = %{
        machine_state(m)
        | history_values: %{idx(:hpar) => MapSet.new([idx(:reg1_final), idx(:reg2_active)])}
      }

      {states_to_enter, _default_entry, history_content} =
        ExitEntry.add_descendant_states_to_enter(ms, idx(:hpar), empty_acc())

      assert states_to_enter ==
               MapSet.new([idx(:reg1_final), idx(:reg2_active), idx(:reg1), idx(:reg2)])

      assert history_content == %{}
    end

    # AC: "History: ... default transition content only on unrecorded
    # history ... each a named test" - `default_history_content` registers
    # the default transition only when nothing was recorded; a recorded
    # history registers nothing, even though the recorded state itself
    # (`a1`) is compound and would otherwise carry its own default-entry
    # flag.
    #
    # sabotage: `enter_history_target/3`'s recorded (`{:ok, recorded}`)
    # branch is changed to also call
    # `register_default_history_content/3` -> a *recorded* history target
    # would wrongly register default history content, reddening the
    # refutation below.
    test "default history content is registered only when the history is unrecorded" do
      m = machine()
      unrecorded_ms = machine_state(m)

      {_states, _default_entry, unrecorded_content} =
        ExitEntry.add_descendant_states_to_enter(unrecorded_ms, idx(:hs), empty_acc())

      assert Map.has_key?(unrecorded_content, idx(:a))

      recorded_ms = %{
        machine_state(m)
        | history_values: %{idx(:hs) => MapSet.new([idx(:a1)])}
      }

      {_states, _default_entry, recorded_content} =
        ExitEntry.add_descendant_states_to_enter(recorded_ms, idx(:hs), empty_acc())

      assert recorded_content == %{}
    end
  end

  # AC: "History recorded from the pre-exit configuration before any onexit
  # content of the step runs" - `hd`'s deep history is a child of `a`, which
  # exits in the same step as `a1x`, its own atomic descendant. If recording
  # ran after (or interleaved with) `depart/2`'s configuration removal, `a1x`
  # would already be gone from the configuration by the time `hd` reads it.
  #
  # sabotage: `exit_states/2` calls `record_history_values/2` *after* the
  # `depart/2` reduction instead of before it -> `a1x` is already removed
  # from `configuration` by the time `hd` records, so `hd` would come back
  # empty instead of `[a1x]`, reddening this assertion.
  test "history is recorded from the configuration as it stood before any state in the step exited" do
    m = machine()
    ms = machine_state(m, [idx(:a), idx(:a1), idx(:a1x)])
    leave_a = transition_named(m, "leave-a")

    {result, _effects} = ExitEntry.exit_states(ms, [leave_a])

    assert Map.fetch!(result.history_values, idx(:hd)) == MapSet.new([idx(:a1x)])
  end

  describe "the three completion-event cases" do
    # AC: "done.state.{parent} on final entry into compound"
    #
    # sabotage: `raise_completion_events/2` is changed to check
    # `Machine.final?(machine, Machine.at(machine, state_index).parent)`
    # instead of `Machine.final?(machine, state_index)` -> `cf_holder` (not
    # itself final) never triggers `raise_parent_completion/3`, and no event
    # is raised, reddening this assertion.
    test "entering a final inside a compound raises done.state.{parent}" do
      m = machine()
      ms = machine_state(m, [idx(:region), idx(:trigger)])
      cf_done = transition_named(m, "go-cf-done")

      {result, _effects} = ExitEntry.enter_states(ms, [cf_done])

      assert [event] = MachineState.internal_events(result)
      assert event.name == "done.state.cf_holder"
    end

    # AC: "done.state.{grandparent} when a parallel completes"
    #
    # sabotage: `raise_parent_completion/3` is reordered to call
    # `maybe_raise_grandparent_completion/3` *before* raising the parent's
    # own `done.state.*` -> the internal queue would hold `done.state.par`
    # first and `done.state.reg2` second, reddening the ordered-match
    # assertion below.
    test "completing the second region of a parallel raises done.state.{grandparent} after the parent's" do
      m = machine()
      ms = machine_state(m, [idx(:region), idx(:par), idx(:reg1), idx(:reg1_final)])
      reg2_final = transition_named(m, "go-reg2-final")

      {result, _effects} = ExitEntry.enter_states(ms, [reg2_final])

      assert [reg_event, par_event] = MachineState.internal_events(result)
      assert reg_event.name == "done.state.reg2"
      assert par_event.name == "done.state.par"
    end

    # AC: "top-level final only clears running (no event) - matching the
    # pseudocode split"
    #
    # sabotage: `raise_completion_events/2`'s `parent == 0` guard is dropped
    # entirely, always falling through to `raise_parent_completion/3` -> the
    # `:scxml` root's own id is `nil`, so no event is raised either way, but
    # `running` is never set to `false`, reddening this assertion.
    test "entering a top-level final clears running and raises nothing" do
      m = machine()
      ms = machine_state(m, [idx(:region), idx(:trigger)])
      go_top = transition_named(m, "go-top")

      {result, _effects} = ExitEntry.enter_states(ms, [go_top])

      assert result.running == false
      assert MachineState.internal_events(result) == []
    end
  end

  # AC: "Raised done.state.* events carry cause metadata and counters"
  #
  # sabotage: `raise_parent_completion/3`'s `MachineState.raise_platform/4`
  # call passes `{:state, parent}` instead of `{:state, state_index}` as the
  # cause origin -> `event.cause.origin` would name `cf_holder` instead of
  # `cf_done`, reddening the origin assertion below.
  test "a raised done.state.* event carries cause metadata and the machine_state's counters" do
    m = machine()
    ms = %{machine_state(m, [idx(:region), idx(:trigger)]) | macrostep: 5, microstep: 2}
    cf_done = transition_named(m, "go-cf-done")

    {result, _effects} = ExitEntry.enter_states(ms, [cf_done])

    assert [event] = MachineState.internal_events(result)
    assert event.cause.origin == {:state, idx(:cf_done)}
    assert event.cause.macrostep == 5
    assert event.cause.microstep == 2
  end

  describe "exit-set and entry-set trace effects" do
    # AC: "Exit-set/entry-set trace effects emitted here, gated"
    #
    # sabotage: `exit_states/2`'s `Effect.trace/3` call site is replaced with
    # a bare list literal `[{:trace, Effect.Trace.ExitSet.new(...)}]`
    # (bypassing the `machine_state.trace` gate) -> a trace effect is emitted
    # even with `trace: false`, reddening this refutation.
    test "ExitSet is emitted when trace: true and gated off entirely when trace: false" do
      m = machine()
      leave_a = transition_named(m, "leave-a")

      ms_on = machine_state(m, [idx(:a), idx(:a1), idx(:a1x)], trace: true)
      {_result, effects_on} = ExitEntry.exit_states(ms_on, [leave_a])
      assert Enum.any?(effects_on, &Effect.trace?/1)

      ms_off = machine_state(m, [idx(:a), idx(:a1), idx(:a1x)], trace: false)
      {_result, effects_off} = ExitEntry.exit_states(ms_off, [leave_a])
      refute Enum.any?(effects_off, &Effect.trace?/1)
    end

    # sabotage: `enter_states/2`'s `Effect.trace/3` call site is replaced
    # with a bare list literal (bypassing the `machine_state.trace` gate) ->
    # a trace effect is emitted even with `trace: false`, reddening this
    # refutation.
    test "EntrySet is emitted when trace: true and gated off entirely when trace: false" do
      m = machine()
      cf_done = transition_named(m, "go-cf-done")

      ms_on = machine_state(m, [idx(:region), idx(:trigger)], trace: true)
      {_result, effects_on} = ExitEntry.enter_states(ms_on, [cf_done])
      assert Enum.any?(effects_on, &Effect.trace?/1)

      ms_off = machine_state(m, [idx(:region), idx(:trigger)], trace: false)
      {_result, effects_off} = ExitEntry.enter_states(ms_off, [cf_done])
      refute Enum.any?(effects_off, &Effect.trace?/1)
    end
  end

  # AC: "All functions pure, plain values in and out; callable standalone" -
  # the executable form of `docs/observability.md` constraint 5, matching the
  # same assertion `selection_acceptance_test.exs` makes for its own
  # functions: every one of the six functions is called directly here with
  # values built by hand from the compiled machine, no support code and no
  # stepping.
  #
  # sabotage: `in_final_state?/2`'s parallel branch's `Enum.all?/2` is
  # changed to `Enum.any?/2` -> a parallel with only one region final would
  # wrongly answer `true`, reddening the refutation below (this also
  # exercises `add_descendant_states_to_enter/3` and
  # `add_ancestor_states_to_enter/4` directly, which are otherwise
  # unaffected by this mutation, so the other assertions here would stay
  # green - it is this test's own `in_final_state?/2` line that catches it).
  test "all six functions are callable standalone with plain values" do
    m = machine()
    leave_a = transition_named(m, "leave-a")
    cf_done = transition_named(m, "go-cf-done")

    exit_ms = machine_state(m, [idx(:a), idx(:a1), idx(:a1x)])
    {exit_result, _effects} = ExitEntry.exit_states(exit_ms, [leave_a])
    assert exit_result.configuration == MapSet.new()

    enter_ms = machine_state(m, [idx(:region), idx(:trigger)])

    assert ExitEntry.compute_entry_set(enter_ms, [cf_done]) ==
             {MapSet.new([idx(:cf_holder), idx(:cf_done)]), MapSet.new(), %{}}

    assert ExitEntry.add_descendant_states_to_enter(enter_ms, idx(:cf_done), empty_acc()) ==
             {MapSet.new([idx(:cf_done)]), MapSet.new(), %{}}

    assert ExitEntry.add_ancestor_states_to_enter(
             enter_ms,
             idx(:cf_done),
             idx(:region),
             empty_acc()
           ) == {MapSet.new([idx(:cf_holder)]), MapSet.new(), %{}}

    {enter_result, _effects} = ExitEntry.enter_states(enter_ms, [cf_done])
    assert MapSet.member?(enter_result.configuration, idx(:cf_done))

    partial = machine_state(m, [idx(:par), idx(:reg1), idx(:reg1_final), idx(:reg2)])
    refute ExitEntry.in_final_state?(partial, idx(:par))
  end

  # This is the closest thing to a full microstep round trip these two
  # functions alone can prove: `exit_states/2` then `enter_states/2` over
  # the same transition list, from a hand-built configuration, leaves a
  # configuration that is exactly the ancestors-closed set the entry order
  # describes. `leave` (`a1` -> `a2`, domain `a`) exits `a1`/`a1x` and
  # re-enters via the same transition list, so the round trip is
  # self-contained in one call pair. What it does not reach: transition
  # selection is not exercised here, and nothing calls these two functions
  # back to back the way a real microstep will - both are asserted directly
  # against a hand-built `machine_state` instead.
  #
  # sabotage: `enter_states/2`'s `arrive/3` is changed to add each entered
  # state to a copy of `machine_state.configuration` that is discarded (the
  # reduce's accumulator is never actually updated) -> the final
  # configuration would come back missing `a2` entirely, reddening this
  # assertion.
  test "exit_states/2 then enter_states/2 over the same transitions round-trips to the ancestors-closed entry set" do
    m = machine()
    ms = machine_state(m, [idx(:region), idx(:a), idx(:a1), idx(:a1x)])
    leave = transition_named(m, "leave")

    {exited, _exit_effects} = ExitEntry.exit_states(ms, [leave])
    assert exited.configuration == MapSet.new([idx(:region), idx(:a)])

    {entered, _enter_effects} = ExitEntry.enter_states(exited, [leave])

    {states_to_enter, _default_entry, _history_content} = ExitEntry.compute_entry_set(ms, [leave])
    entry_order = Machine.document_order(m, states_to_enter)

    assert entered.configuration == MapSet.union(exited.configuration, MapSet.new(entry_order))
    assert entered.configuration == MapSet.new([idx(:region), idx(:a), idx(:a2)])
  end

  # A second, standalone document for the bead's own acceptance criterion:
  # "the carried configuration matches the configuration folded from the
  # deltas, across a parallel-region chart, including exit_interpreter".
  # Driven through the real interpreter loop
  # (`Interpreter.initialize/2` / `handle_event/2`) rather than the
  # hand-built `machine_state` values the rest of this file uses, because
  # only a real drive to termination reaches `exit_interpreter/1`'s
  # whole-configuration sweep.
  #
  #  0 scxml (root)
  #  1   par                 (parallel)
  #  2     reg1                (compound; initial="reg1a")
  #  3       reg1a               (`go` -> reg1b)
  #  4       reg1b
  #  5     reg2                (compound; initial="reg2a")
  #  6       reg2a               (`go` -> reg2b)
  #  7       reg2b
  #  |     `finish` (external, par -> done) also sits on `par`
  #  8   done                (final, parent 0 - top-level, sibling of par)
  @parallel_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="par">
      <parallel id="par">
          <state id="reg1" initial="reg1a">
              <state id="reg1a">
                  <transition event="go" target="reg1b"/>
              </state>
              <state id="reg1b"/>
          </state>
          <state id="reg2" initial="reg2a">
              <state id="reg2a">
                  <transition event="go" target="reg2b"/>
              </state>
              <state id="reg2b"/>
          </state>
          <transition event="finish" target="done"/>
      </parallel>
      <final id="done"/>
  </scxml>
  """

  @parallel_indexes %{
    par: 1,
    reg1: 2,
    reg1a: 3,
    reg1b: 4,
    reg2: 5,
    reg2a: 6,
    reg2b: 7,
    done: 8
  }

  defp pidx(name), do: Map.fetch!(@parallel_indexes, name)

  defp trace_set_payloads(effects) do
    for {:trace, %mod{} = payload} <- effects,
        mod in [Effect.Trace.EntrySet, Effect.Trace.ExitSet],
        do: payload
  end

  # sabotage: `enter_states/2` in lib/statifier/interpreter/exit_entry.ex is
  # changed to stamp `configuration:` from `pre_entry_state.configuration`
  # (the pre-arrive binding, before the reduce that adds each entered state)
  # instead of the post-`arrive/3` accumulator `machine_state.configuration`
  # -> every `EntrySet`'s `configuration` freezes one step behind, so the
  # naive fold below (which unions `indexes` into its own running total)
  # diverges from the payload's own `configuration` at the very first
  # `EntrySet`, reddening that step's equality assertion. Confirmed red
  # (left `MapSet.new([0, 1, 2, 3, 5, 6])`, right `MapSet.new([])`) and
  # reverted.
  test "carried configuration matches the naive delta fold across a parallel-region run, including exit_interpreter" do
    {:ok, root} = Parser.parse(@parallel_document)
    {:ok, document} = Lowering.lower(root, @parallel_document)
    {:ok, document, _warnings} = Validator.validate(document, @parallel_document)
    {:ok, m} = Compiler.compile(document)

    {ms0, init_effects} = Interpreter.initialize(m, trace: true)
    {:ok, ms1, go_effects} = Interpreter.handle_event(ms0, %Event{name: "go", type: :external})

    {:ok, ms2, finish_effects} =
      Interpreter.handle_event(ms1, %Event{name: "finish", type: :external})

    refute ms2.running
    assert ms2.status == :done

    payloads = trace_set_payloads(init_effects ++ go_effects ++ finish_effects)

    # Step 4: fold independently, starting from `MapSet.new()` - the naive
    # delta fold a consumer would write - and assert after each step that it
    # agrees with the payload's own `configuration`, across both the
    # within-microstep boundary and the boundary between separate
    # `handle_event/2` calls.
    {final_fold, entry_sets, exit_sets} =
      Enum.reduce(payloads, {MapSet.new(), [], []}, fn payload, {fold, entries, exits} ->
        case payload do
          %Effect.Trace.EntrySet{indexes: indexes, configuration: configuration} = entry_set ->
            fold = MapSet.union(fold, MapSet.new(indexes))
            assert fold == configuration
            {fold, [entry_set | entries], exits}

          %Effect.Trace.ExitSet{indexes: indexes, configuration: configuration} = exit_set ->
            fold = MapSet.difference(fold, MapSet.new(indexes))
            assert fold == configuration
            {fold, entries, [exit_set | exits]}
        end
      end)

    entry_sets = Enum.reverse(entry_sets)
    exit_sets = Enum.reverse(exit_sets)

    # Step 5: the terminal `ExitSet` is `exit_interpreter/1`'s whole-
    # configuration sweep, not the ordinary `exit_states/2` path - its
    # `indexes` is the entire configuration that was running (root plus
    # `done`), its `configuration` is `MapSet.new()`, and the fold agrees.
    assert %Effect.Trace.ExitSet{configuration: terminal_configuration} =
             terminal_exit = List.last(exit_sets)

    assert terminal_configuration == MapSet.new()
    assert final_fold == MapSet.new()
    assert MapSet.new(terminal_exit.indexes) == MapSet.new([0, pidx(:done)])

    # Step 6: the last `EntrySet` *before* the run heads into termination -
    # not the very last `EntrySet` in the stream, which is the trivial
    # top-level-final entry (`done` alone, part of the same terminating step
    # as the exit above) - carries every state of both parallel regions plus
    # their ancestors: the ADR-0005 full-configuration property, and the
    # part a delta-folding consumer gets wrong.
    last_entry_set = List.last(entry_sets)
    pre_termination_entry_set = Enum.at(entry_sets, -2)

    assert last_entry_set.configuration == MapSet.new([0, pidx(:done)])

    assert pre_termination_entry_set.configuration ==
             MapSet.new([0, pidx(:par), pidx(:reg1), pidx(:reg1b), pidx(:reg2), pidx(:reg2b)])
  end
end
