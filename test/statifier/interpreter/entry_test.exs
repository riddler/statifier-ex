defmodule Statifier.Interpreter.EntryTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Event
  alias Statifier.Interpreter
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Machine.Transition
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp trace_effects(effects), do: Enum.filter(effects, &Effect.trace?/1)

  # Every `{:trace, payload}` and `{:done, payload}` member's own
  # `microstep` field, plus the `microstep` field of any `Event.Cause`
  # riding along on an `EventDequeued` trace's dequeued event - the surface
  # Decision 5's invariant ("no effect and no cause is ever stamped
  # `microstep: 0`") covers.
  #
  # `EventDequeued` and `TransitionsSelected` are deliberately excluded from
  # their *own* `microstep` field here: Decision 5's own text stamps both
  # *before* `begin_microstep/1`, "the number of microsteps completed in
  # this macrostep so far" - which is legitimately `0` for the very first
  # selection round of any macrostep (`handle_event/2`'s own `dequeued`, in
  # particular). The invariant is about step-*body* effects (the ones a
  # microstep's own exit/execute/enter round produces) and about a raised
  # event's own `cause` (always stamped from inside a step body) - not
  # about the pre-round selection trace's own stamp.
  #
  # `FinalizeAutoforward` joins them for the identical reason: it is
  # stamped in `apply_invoke_passes/2`, which `handle_event/2` runs right
  # after `begin_macrostep/1` and before any transition selection - "no
  # microstep has run yet this macrostep" is its normal case, not an
  # exception. `InvokePass` joins them too: `run_invoke_pass/1` is stamped
  # after that macrostep's fold, and a fold whose eventless probe finds
  # nothing to select and whose internal queue is already empty reaches
  # quiescence in zero microsteps (`internal_round/1`'s own `:empty`
  # branch) - the invoke pass still runs (`main_event_loop/3` gates it on
  # `running`, not on any microstep having happened), still legitimately
  # reporting zero.
  defp microsteps_on(effects) do
    Enum.flat_map(effects, fn
      {:trace, %Effect.Trace.EventDequeued{event: event}} ->
        cause_microsteps(event)

      {:trace, %Effect.Trace.TransitionsSelected{}} ->
        []

      {:trace, %Effect.Trace.FinalizeAutoforward{}} ->
        []

      {:trace, %Effect.Trace.InvokePass{}} ->
        []

      {:trace, payload} ->
        [payload.microstep]

      {:done, payload} ->
        [payload.microstep]

      _other ->
        []
    end)
  end

  defp cause_microsteps(%Event{cause: %Event.Cause{microstep: microstep}}), do: [microstep]
  defp cause_microsteps(%Event{cause: nil}), do: []

  # Hand-drawn from `@chain_document`, depth-first, document order.
  #
  #  0 scxml (root; initial="a")
  #  1   a          -- compound; transition event="go" -> b
  #  2     a1
  #  3   b
  @chain_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b"/>
          <state id="a1"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  @chain_indexes %{a: 1, a1: 2, b: 3}

  defp chain_machine, do: compile!(@chain_document)
  defp chain_idx(name), do: Map.fetch!(@chain_indexes, name)

  # Hand-drawn from `@drain_document`, depth-first, document order.
  #
  #  0 scxml (root; initial="p1")
  #  1   p1   -- eventless transition -> p2
  #  2   p2
  @drain_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p1">
      <state id="p1">
          <transition target="p2"/>
      </state>
      <state id="p2"/>
  </scxml>
  """

  @drain_indexes %{p1: 1, p2: 2}

  defp drain_machine, do: compile!(@drain_document)
  defp drain_idx(name), do: Map.fetch!(@drain_indexes, name)

  # A root whose sole state is a top-level <final> - initialize/2 should
  # terminate before any external event is ever handed to handle_event/2.
  @done_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="done">
      <final id="done"/>
  </scxml>
  """

  defp done_machine, do: compile!(@done_document)

  # Three documents whose root initial resolves through a different one of
  # the three producers `initial_transition/1` (Decision 3) reads, all
  # reaching the same configuration - root plus state "a".
  #
  #  0 scxml
  #  1   a
  #  2   b
  @initial_attribute_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a"/>
      <state id="b"/>
  </scxml>
  """

  @first_child_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
      <state id="a"/>
      <state id="b"/>
  </scxml>
  """

  # `initial="b"` so that, unplanted, this document's own default entry
  # would reach "b" - proving that a planted `initial_transition` (the
  # shape `Machine.at(machine, 0).initial_transition` would carry had the
  # document model let `<initial>` appear under `<scxml>`, which it does
  # not yet - `lib/statifier/compiler.ex`'s `resolve_root_initial/3`
  # comment) drives entry instead of the attribute.
  @compiled_transition_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="b">
      <state id="a"/>
      <state id="b"/>
  </scxml>
  """

  # A root `initial` naming a descendant nested under a wrapper state - st-ynu:
  # spec 3.11's "additional requirement" restricting an `initial` target to
  # descendants of the *containing* state is written for a <state>'s own
  # `initial`/<initial> only, never for <scxml>'s, so this is a legal state
  # specification (spec 3.2.1, 3.11) even though "nested" is not a top-level
  # child of the root. `enterStates` (Appendix D) must add "wrapper" as an
  # ancestor even though the root's `initial` never names it.
  #
  #  0 scxml (root; initial="nested")
  #  1   wrapper
  #  2     nested
  @root_initial_descendant_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="nested">
      <state id="wrapper">
          <state id="nested"/>
      </state>
  </scxml>
  """

  defp root_initial_descendant_indexes, do: %{wrapper: 1, nested: 2}

  defp root_initial_descendant_machine, do: compile!(@root_initial_descendant_document)

  defp shapes_indexes, do: %{a: 1, b: 2}

  defp plant_root_initial_transition(machine, target_index) do
    root = Machine.at(machine, 0)
    t_index = tuple_size(machine.transitions)

    transition = %Transition{
      t_index: t_index,
      source: 0,
      targets: [target_index],
      events: [],
      type: :external,
      content: [],
      location: root.location
    }

    %{
      machine
      | states: put_elem(machine.states, 0, %{root | initial_transition: t_index}),
        transitions: Tuple.insert_at(machine.transitions, t_index, transition)
    }
  end

  describe "initialize/2 - entering the initial descendant chain" do
    # sabotage: `initialize/2`'s `ExitEntry.enter_states(machine_state,
    # [initial_transition(machine)])` call is changed to
    # `ExitEntry.enter_states(machine_state, [])` -> nothing enters, so the
    # configuration stays empty instead of naming the root and its initial
    # descendant chain, reddening the configuration assertion.
    test "enters the full initial descendant chain, root included, and leaves macrostep: 1" do
      m = chain_machine()

      {result, _effects} = Interpreter.initialize(m)

      assert result.configuration == MapSet.new([0, chain_idx(:a), chain_idx(:a1)])
      assert result.macrostep == 1
      assert result.running
    end
  end

  describe "initialize/2 - a root initial naming a descendant, not a top-level child" do
    # sabotage: `add_ancestor_states_to_enter/4`'s
    # `Enum.take_while(&(&1 != ancestor))` changed to
    # `Enum.take_while(fn _ -> false end)` -> no ancestor is ever added for
    # any transition's target, so "wrapper" (and the root itself, and every
    # other ancestor-carrying test in this file) drops out of the
    # configuration, reddening this assertion
    test "enters the descendant and every ancestor between it and the root" do
      m = root_initial_descendant_machine()

      {result, _effects} = Interpreter.initialize(m)

      indexes = root_initial_descendant_indexes()

      assert result.configuration ==
               MapSet.new([0, indexes.wrapper, indexes.nested])
    end
  end

  describe "initialize/2 - the three producers of the root's initial transition" do
    # sabotage: `initial_transition/1`'s `case Machine.at(machine,
    # 0).initial_transition do` clauses are collapsed to always take the
    # `nil` branch (`Machine.initial(machine)`), ignoring a real `t_index`
    # -> the planted-transition variant below reaches {0, b} (the
    # attribute's own target) instead of {0, a} (the planted transition's
    # target), reddening the equality with the other two variants.
    test "the attribute, compiled-transition, and first-child forms all reach the same configuration" do
      attribute_machine = compile!(@initial_attribute_document)
      first_child_machine = compile!(@first_child_document)

      compiled_transition_machine =
        @compiled_transition_document
        |> compile!()
        |> plant_root_initial_transition(shapes_indexes().a)

      {attribute_result, _effects} = Interpreter.initialize(attribute_machine)
      {first_child_result, _effects} = Interpreter.initialize(first_child_machine)
      {compiled_result, _effects} = Interpreter.initialize(compiled_transition_machine)

      expected = MapSet.new([0, shapes_indexes().a])

      assert attribute_result.configuration == expected
      assert first_child_result.configuration == expected
      assert compiled_result.configuration == expected
    end
  end

  describe "initialize/2 - runs the initialization macrostep to quiescence" do
    # sabotage: `initialize/2`'s `{machine_state, loop_effects} =
    # main_event_loop(machine_state)` call and its use are deleted, so
    # `initialize/2` returns right after entering the initial state -> the
    # configuration stays at p1 instead of draining to p2, reddening the
    # configuration assertion.
    test "an eventless initial transition's target is the final position, not the initial state" do
      m = drain_machine()

      {result, _effects} = Interpreter.initialize(m)

      assert result.configuration == MapSet.new([0, drain_idx(:p2)])
      refute drain_idx(:p1) in result.configuration
    end
  end

  describe "initialize/2 - a top-level <final> as the initial state" do
    # sabotage: `main_event_loop/1`'s `if machine_state.running do ... else
    # exit_interpreter(machine_state) end` guard is inverted to `if not
    # machine_state.running`, so a machine that terminated mid-initialize
    # now skips `exit_interpreter/1` -> `status` stays `:running` instead of
    # `:done`, reddening the status assertion.
    test "terminates during initialize/2 itself: status :done, one {:done, _}, no external event needed" do
      m = done_machine()

      {result, effects} = Interpreter.initialize(m)

      refute result.running
      assert result.status == :done

      done_effects = for {:done, _payload} = effect <- effects, do: effect
      assert [{:done, _payload}] = done_effects
    end
  end

  describe "handle_event/2 - a fresh, running machine" do
    # sabotage: `initialize/2`'s `MachineState.begin_macrostep()` call in
    # its pipeline is dropped -> `initialize/2` leaves `macrostep: 0`
    # instead of `1`, so the first `handle_event/2` call lands on
    # `macrostep: 1` instead of `2`, reddening the counter assertion.
    test "begins the next macrostep and moves the configuration" do
      m = chain_machine()
      {fresh, _effects} = Interpreter.initialize(m)

      assert {:ok, result, _effects} = Interpreter.handle_event(fresh, Event.external("go"))

      assert result.macrostep == 2
      assert result.configuration == MapSet.new([0, chain_idx(:b)])
    end
  end

  describe "handle_event/2 - a terminated machine" do
    # sabotage: the `def handle_event(%MachineState{running: false}, %Event{}),
    # do: {:error, :not_running}` guard clause is deleted, falling through
    # to the general clause -> `handle_event/2` on a done machine now
    # returns `{:ok, _, _}` instead of `{:error, :not_running}`, reddening
    # the assertion below (and would otherwise begin a macrostep on a
    # machine with nothing left to run).
    test "returns {:error, :not_running} and does not raise" do
      m = done_machine()
      {done, _effects} = Interpreter.initialize(m)
      refute done.running

      assert {:error, :not_running} = Interpreter.handle_event(done, Event.external("go"))
    end
  end

  describe "handle_event/2 - an event that matches nothing" do
    # sabotage: `handle_event/2`'s `machine_state =
    # MachineState.begin_macrostep(machine_state)` call is moved to after
    # selection and gated on `transitions != []` (skipping it when nothing
    # was selected) -> a non-enabling event no longer advances `macrostep`,
    # reddening the counter assertion below even though the event was
    # accepted.
    test "returns {:ok, _, _} with the configuration unchanged and the macrostep counter advanced" do
      m = chain_machine()
      {fresh, _effects} = Interpreter.initialize(m)

      assert {:ok, result, _effects} =
               Interpreter.handle_event(fresh, Event.external("no-such-event"))

      assert result.macrostep == fresh.macrostep + 1
      assert result.configuration == fresh.configuration
    end
  end

  describe "Decision 5's invariant - no effect or cause is ever stamped microstep: 0" do
    # sabotage: `initialize/2`'s `|> MachineState.begin_microstep()` step is
    # dropped from the pipeline -> the initial entry runs at microstep 0
    # instead of 1, reddening this assertion over the very first effects
    # `initialize/2` produces.
    test "holds across a full initialize/2 + handle_event/2 run" do
      m = chain_machine()
      {fresh, init_effects} = Interpreter.initialize(m, trace: true)

      {:ok, _result, event_effects} = Interpreter.handle_event(fresh, Event.external("go"))

      refute 0 in microsteps_on(init_effects)
      refute 0 in microsteps_on(event_effects)
    end
  end

  describe "trace: false" do
    # sabotage: `handle_event/2`'s `Effect.trace(machine_state,
    # Effect.Trace.EventDequeued, event: event, from: :external)` call is
    # replaced with an unconditional bare list literal
    # `[{:trace, Effect.Trace.EventDequeued.new(machine_state, event: event,
    # from: :external)}]` -> a `trace: false` run now carries a trace
    # effect, reddening the zero-trace assertion below.
    test "yields zero trace members across initialize/2 and handle_event/2" do
      m = chain_machine()
      {fresh, init_effects} = Interpreter.initialize(m, trace: false)

      {:ok, _result, event_effects} = Interpreter.handle_event(fresh, Event.external("go"))

      assert trace_effects(init_effects) == []
      assert trace_effects(event_effects) == []
    end
  end
end
