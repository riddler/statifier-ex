defmodule Statifier.MachineStateAcceptanceTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect.Trace
  alias Statifier.Event
  alias Statifier.Event.Cause
  alias Statifier.Lowering
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Validator

  require Statifier.Effect, as: Effect

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # A nested compound state (a > b > c) alongside a parallel with two regions
  # (p1, p2), each with one atomic child - the "nested compound/parallel
  # configuration" the bead's acceptance criteria names by its own wording.
  #
  #  0 scxml (root, children [1,4,9])
  #  1   a                (children [2], last 3)
  #  2     b               (children [3], last 3)
  #  3       c              (atomic)
  #  4   p                (parallel, children [5,7], last 8)
  #  5     p1              (children [6], last 6)
  #  6       p1a
  #  7     p2              (children [8], last 8)
  #  8       p2a
  #  9   f                (final)
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <state id="b">
              <state id="c"/>
          </state>
      </state>
      <parallel id="p">
          <state id="p1">
              <state id="p1a"/>
          </state>
          <state id="p2">
              <state id="p2a"/>
          </state>
      </parallel>
      <final id="f"/>
  </scxml>
  """

  @indexes %{
    a: 1,
    b: 2,
    c: 3,
    p: 4,
    p1: 5,
    p1a: 6,
    p2: 7,
    p2a: 8,
    f: 9
  }

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  @expected_fields [
    :machine,
    :configuration,
    :internal_queue,
    :history_values,
    :entered_states,
    :states_to_invoke,
    :active_invocations,
    :invoke_counter,
    :datamodel,
    :running,
    :status,
    :macrostep,
    :microstep,
    :round,
    :trace,
    :max_macrostep_rounds
  ]

  # AC: "machine_state holds machine, configuration (full, MapSet of
  # indexes), FIFO internal queue, history values, first-entry tracking,
  # states awaiting the invoke pass, live invocation ids, the session-global
  # invoke platformid counter (ADR-0008 as amended 2026-08-15), datamodel
  # slot, running, status, macrostep/microstep/round counters, trace
  # option, round budget (ADR-0019) - nothing loop-local left unreified".
  # `entered_states` is the ADR-0002 substitute for Appendix D's
  # `s.isFirstEntry`, which cannot live on a compiled, immutable
  # `%Machine.State{}` in this port - see that field's own moduledoc
  # section. `states_to_invoke` is Appendix D's `statesToInvoke` global,
  # added to unconditionally by `enter_states/2` and deleted from by
  # `exit_states/2` - see that field's own moduledoc section.
  # `active_invocations` is `inv.invokeid` hoisted off compiled data
  # (Decision 7 of the plan this bead's Phase 6 implements) - see that
  # field's own moduledoc section. `round` (ADR-0020) is the third
  # counter, joining `macrostep`/`microstep`. `invoke_counter` is a fourth,
  # unrelated to that trio's per-macrostep reset - it is the pure,
  # session-global source `Statifier.Interpreter.generate_invoke_id/3`
  # reads and writes so the invoke id it mints never touches the wall clock
  # or a CSPRNG (ADR-0003) - see that field's own moduledoc section.
  #
  # sabotage: add `foo: nil` to `MachineState`'s `defstruct` in
  # lib/statifier/machine_state.ex - the struct then grows a seventeenth
  # key, and this equality assertion reddens for exactly the "someone adds
  # a field without updating the docs" failure the plan calls out.
  test "machine_state holds the sixteen fields, and the struct has no others" do
    ms = MachineState.new(machine())

    assert MapSet.new(Map.keys(Map.from_struct(ms))) == MapSet.new(@expected_fields)
  end

  # AC: "External queue explicitly NOT in core state; divergence documented
  # at the port site." The pure core takes one external event per call
  # (ADR-0003); the session that drives it owns queueing the waiting
  # external events. This is a mechanical deviation from Appendix D's
  # `main_event_loop`, which owns both queues - the semantics of processing
  # one external event are unchanged, only the storage of the waiting ones
  # moves outward.
  #
  # sabotage: add `external_queue: nil` to `MachineState`'s `defstruct` ->
  # `:external_queue` appears in the field set and this refutation reddens.
  test "the external queue is not a field" do
    ms = MachineState.new(machine())

    refute :external_queue in Map.keys(Map.from_struct(ms))
  end

  # AC: "Event struct with type (:external/:internal/:platform) and cause
  # metadata slots"
  #
  # sabotage: `Event.platform/3` stamps `type: :internal` instead of
  # `type: :platform` -> the platform-type assertion below reddens.
  test "Event carries type in the three spec values and a cause slot" do
    cause = Cause.new({:state, 0}, 1, 1, 1)

    external = Event.external("ext")
    internal = Event.internal("int", cause)
    platform = Event.platform("plat", cause)

    assert external.type == :external
    assert internal.type == :internal
    assert platform.type == :platform

    assert external.cause == nil
    assert internal.cause == cause
    assert platform.cause == cause
  end

  @core_effects [
    {:send, %Effect.Send{event: "e", macrostep: 0, microstep: 0}},
    {:send_delayed, %Effect.SendDelayed{event: "e", delay_ms: 1, macrostep: 0, microstep: 0}},
    {:cancel, %Effect.Cancel{send_id: "s", macrostep: 0, microstep: 0}},
    {:invoke, %Effect.Invoke{invoke_id: "i", state_index: 0, macrostep: 0, microstep: 0}},
    {:budget_exhausted,
     %Effect.BudgetExhausted{
       configuration: MapSet.new(),
       budget: 1,
       pending_internal_events: [],
       macrostep: 0,
       microstep: 0,
       round: 0
     }},
    {:done, %Effect.Done{configuration: MapSet.new(), macrostep: 0, microstep: 0}},
    {:log, %Effect.Log{macrostep: 0, microstep: 0}}
  ]

  @trace_effects [
    {:trace,
     %Trace.EventDequeued{
       event: Event.external("e"),
       from: :external,
       macrostep: 0,
       microstep: 0,
       round: 0
     }},
    {:trace, %Trace.TransitionsSelected{t_indexes: [], macrostep: 0, microstep: 0, round: 0}},
    {:trace, %Trace.ExitSet{indexes: [], macrostep: 0, microstep: 0, round: 0}},
    {:trace,
     %Trace.ContentExecuted{
       owner: {:transition, 0},
       c_indexes: [],
       macrostep: 0,
       microstep: 0,
       round: 0
     }},
    {:trace, %Trace.EntrySet{indexes: [], macrostep: 0, microstep: 0, round: 0}},
    {:trace,
     %Trace.MacrostepStable{configuration: MapSet.new(), macrostep: 0, microstep: 0, round: 0}},
    {:trace, %Trace.Done{configuration: MapSet.new(), macrostep: 0, microstep: 0, round: 0}}
  ]

  # AC: "One @type effect union: core effects + all seven trace effects;
  # trace effects carry counters and identities" - the core set is now
  # seven, ADR-0019's `:budget_exhausted` joining the ADR-0003 six.
  #
  # sabotage: `Effect.trace?/1`'s catch-all clause (`def trace?(_effect),
  # do: false`) becomes `do: true` -> the `refute` below (core effects are
  # not trace effects) reddens because every core effect now reads as a
  # trace effect too.
  test "the effect union covers the core seven plus all seven trace points" do
    assert length(@core_effects) == 7
    assert length(@trace_effects) == 7
    assert length(@core_effects) + length(@trace_effects) == 14

    refute Enum.any?(@core_effects, &Effect.trace?/1)
    assert Enum.all?(@trace_effects, &Effect.trace?/1)
  end

  # AC: "Trace emission gated by a single cheap boolean; trace-off allocates
  # nothing" - exercised here across all seven trace payload modules, driven
  # by the same vocabulary the previous test enumerates.
  #
  # sabotage: `Effect.trace/3`'s `if machine_state.trace do` becomes
  # `if true do` -> every one of the seven calls below returns a
  # one-element list instead of `[]`, reddening the `Enum.all?/2` assertion.
  test "trace-off emission yields [] for all seven trace payload modules" do
    ms_off = MachineState.new(machine(), trace: false)

    results = [
      Effect.trace(ms_off, Trace.EventDequeued, event: Event.external("e"), from: :external),
      Effect.trace(ms_off, Trace.TransitionsSelected, t_indexes: []),
      Effect.trace(ms_off, Trace.ExitSet, indexes: []),
      Effect.trace(ms_off, Trace.ContentExecuted, owner: {:transition, 0}, c_indexes: []),
      Effect.trace(ms_off, Trace.EntrySet, indexes: []),
      Effect.trace(ms_off, Trace.MacrostepStable, configuration: MapSet.new()),
      Effect.trace(ms_off, Trace.Done, configuration: MapSet.new())
    ]

    assert length(results) == 7
    assert Enum.all?(results, &(&1 == []))
  end

  # AC: "Counter semantics defined in @doc, with advance sites named" - the
  # zeroed-at-construction half of that contract.
  #
  # sabotage: `MachineState.new/2` sets `microstep: 1` instead of `0` ->
  # this assertion reddens; zero must mean "no macrostep has begun yet".
  # sabotage: `MachineState.new/2` sets `round: 1` instead of `0` -> the
  # round assertion reddens the same way.
  test "counter fields are present and zero on new/2" do
    ms = MachineState.new(machine())

    assert ms.macrostep == 0
    assert ms.microstep == 0
    assert ms.round == 0
  end

  # AC: "Leaf-state derived view implemented and tested against nested
  # compound/parallel configs" - driven from XML through the real compile
  # pipeline (Parser -> Lowering -> Validator -> Compiler), distinct in kind
  # from `machine_state_test.exs`'s hand-assembled configuration.
  #
  # sabotage: `MachineState.active_leaf_states/1` drops the `atomic?` filter
  # and returns the whole configuration unchanged -> the ancestors (`a`,
  # `b`, `p`) survive into the view, reddening this assertion.
  test "active_leaf_states/1 over a nested compound + parallel configuration" do
    ms = %{
      MachineState.new(machine())
      | configuration:
          MapSet.new([
            idx(:a),
            idx(:b),
            idx(:c),
            idx(:p),
            idx(:p1),
            idx(:p1a),
            idx(:p2),
            idx(:p2a)
          ])
    }

    assert MachineState.active_leaf_states(ms) ==
             MapSet.new([idx(:c), idx(:p1a), idx(:p2a)])
  end
end
