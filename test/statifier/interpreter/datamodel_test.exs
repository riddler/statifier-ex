defmodule Statifier.Interpreter.DatamodelTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Evaluator, Event, ExecutableContent, Interpreter}
  alias Statifier.Effect.{DatamodelChange, DatamodelInit}
  alias Statifier.ExecutableContent.Context
  alias Statifier.Interpreter.Datamodel
  alias Statifier.{Lowering, MachineState, Parser, Validator}
  alias Statifier.Machine.Content.Assign
  alias Statifier.Parser.Location

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp compiled_expr(source) do
    {:ok, compiled} = Predicator.compile_with_spans(source)
    {:compiled, compiled, source}
  end

  # sabotage: `Datamodel.seed/2` is changed to fold over `[]` instead of
  # `Tuple.to_list(machine.data_elements)` -> "Var1" never becomes a
  # datamodel key at all, reddening `Map.has_key?/2` below.
  test "a declared-unassigned <data id=\"Var1\"/> is present and bound to nil" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="Var1"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()

    assert Map.has_key?(ms.datamodel, "Var1")
    assert ms.datamodel["Var1"] == nil
  end

  # sabotage: `Evaluator.bind/3` is changed to rewrite `nil` to `:undefined`
  # before handing a value to `Predicator.Context.bind/3` (reintroducing the
  # retired shim) -> `Var1`'s genuine bound `nil` (see the
  # "declared-unassigned" test above - the value-less `<data>`'s compiled
  # `{:static, nil}` overwrites the seed) reads back as `:undefined`, and
  # `Var1 === null` reddens to `{:ok, false}`.
  test "Var1 === null evaluates {:ok, true} against a value-less <data>'s bound nil" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="Var1"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()
    context = Evaluator.context(ms)

    assert Evaluator.evaluate(context, compiled_expr("Var1 === null")) == {:ok, true}
    assert Evaluator.evaluate(context, compiled_expr("Var1 === undefined")) == {:ok, false}
  end

  # sabotage: `Datamodel.seed/2` is changed to fold over `[]` instead of
  # `Tuple.to_list(machine.data_elements)` -> "Var1" never becomes a
  # datamodel key at all, so `on_unbound: :error` turns the first assertion's
  # evaluation into an `{:error, %UndefinedVariableError{}}` instead of
  # `{:ok, true}`. Since `Evaluator.bind/3`'s own `nil` -> `:undefined`
  # rewrite was retired (Phase 3), `Statifier.Evaluator.context/1` no longer
  # bridges the two spellings, so a
  # `Datamodel.seed/2`-only mutation of `:undefined` to `nil` also reddens
  # this test directly - `Var1 === undefined` would answer `{:ok, false}`
  # instead of `{:ok, true}`. `src` is never fetched (ADR-0003), so `Var1`
  # keeps exactly the seed `initialize/1` wrote - unlike a value-less
  # `<data id="Var1"/>`, whose compiled `{:static, nil}` value evaluates and
  # overwrites the seed with a genuine `nil` (see the "declared-unassigned"
  # test above); this fixture pins what evaluating a never-bound root reads
  # once it is bound at all.
  test "a <data> whose value never binds reads undefined, not null, through Evaluator.evaluate/2" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="Var1" src="file:unfetched.txt"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()
    context = Evaluator.context(ms)

    assert Evaluator.evaluate(context, compiled_expr("Var1 === undefined")) == {:ok, true}
    assert Evaluator.evaluate(context, compiled_expr("Var1 !== null")) == {:ok, true}
  end

  # sabotage: `Datamodel.bind_value/4`'s catch-all clause is changed to
  # store `nil` instead of the evaluated `value` -> a successfully evaluated
  # `expr="1"` would still read back `nil`, reddening this assertion.
  test "expr=\"1\" binds 1" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="Var1" expr="1"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()

    assert ms.datamodel["Var1"] == 1
  end

  # sabotage: `Datamodel.bind_value/4`'s catch-all clause's `{:error,
  # reason} -> raise_binding_error(...)` branch is dropped, so an
  # `Evaluator.evaluate/2` failure is silently ignored instead of raised ->
  # no `error.execution` reaches the internal queue, reddening the
  # assertions below.
  test "expr=\"return\" leaves :undefined and enqueues one error.execution with cause {:data, 0}" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="Var1" expr="return"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()

    assert ms.datamodel["Var1"] == :undefined
    assert [event] = MachineState.internal_events(ms)
    assert event.name == "error.execution"
    assert event.type == :platform
    assert event.cause.origin == {:data, 0}
  end

  # sabotage: `Datamodel.bind_value/4`'s `{:invalid, error}` clause is
  # dropped, falling through to the catch-all clause, which calls
  # `Evaluator.evaluate/2` on a value that is not a `Machine.expr()` and
  # raises a `FunctionClauseError` instead of a clean `error.execution` ->
  # this test would crash rather than assert cleanly.
  test "an unparseable expr leaves :undefined and enqueues one error.execution with cause {:data, 0}" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="o1" expr="{p1: 'v1'"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()

    assert ms.datamodel["o1"] == :undefined
    assert [event] = MachineState.internal_events(ms)
    assert event.name == "error.execution"
    assert event.type == :platform
    assert event.cause.origin == {:data, 0}
  end

  # sabotage: `Datamodel.bind_value/4`'s `{:src, uri}` clause is dropped,
  # falling through to the catch-all clause and crashing the same way the
  # invalid-expr sabotage above does, rather than raising a clean
  # `error.execution`.
  test "src leaves :undefined and enqueues one error.execution with cause {:data, 0}" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="Var1" src="file:x.txt"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()

    assert ms.datamodel["Var1"] == :undefined
    assert [event] = MachineState.internal_events(ms)
    assert event.name == "error.execution"
    assert event.type == :platform
    assert event.cause.origin == {:data, 0}
  end

  # sabotage: `Datamodel.bind/5`'s `MapSet.member?(top_level_indexes,
  # d_index) and MapSet.member?(env_ids, data.id)` guard is replaced with a
  # bare `false` -> the environment's "Var1" would be overwritten by the
  # document's own expr="1", reddening this assertion.
  test "a :datamodel option value overrides a top-level <data expr> of the same id" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="Var1" expr="1"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    {ms, _effects} =
      machine |> MachineState.new(datamodel: %{"Var1" => "from-env"}) |> Datamodel.initialize()

    assert ms.datamodel["Var1"] == "from-env"
  end

  # sabotage: `Datamodel.bind/5`'s environment-skip guard drops the
  # `MapSet.member?(top_level_indexes, d_index)` half, checking `env_ids`
  # alone -> a state-scoped <data> whose id matches an environment key would
  # wrongly be skipped, reddening this assertion (it would stay "from-env"
  # instead of becoming the document's own bound value).
  test "a :datamodel option value does not override a state-scoped <data> of the same id" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <state id="s0">
              <datamodel>
                  <data id="Var1" expr="1"/>
              </datamodel>
          </state>
      </scxml>
      """)

    {ms, _effects} =
      machine |> MachineState.new(datamodel: %{"Var1" => "from-env"}) |> Datamodel.initialize()

    assert ms.datamodel["Var1"] == 1
  end

  # sabotage: `Datamodel.d_indexes_to_bind/2`'s `:late` clause is changed to
  # return `0..(tuple_size(machine.data_elements) - 1)//1` (the `:early`
  # body) unconditionally -> the state-scoped `<data expr="2">` would be
  # bound at initialization under late binding too, reddening the
  # `== :undefined` half of this assertion.
  test "under binding=\"late\", a top-level <data> binds at initialization while a state-scoped one stays :undefined" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" binding="late">
          <datamodel>
              <data id="Root1" expr="1"/>
          </datamodel>
          <state id="s0">
              <datamodel>
                  <data id="Local1" expr="2"/>
              </datamodel>
          </state>
      </scxml>
      """)

    {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()

    assert ms.datamodel["Root1"] == 1
    assert Map.has_key?(ms.datamodel, "Local1")
    assert ms.datamodel["Local1"] == :undefined
  end

  # sabotage: `Interpreter.Datamodel.write/4` is changed to call
  # `Predicator.ContextLocation.put(%{}, path, value)` (an empty base map)
  # instead of `Predicator.ContextLocation.put(datamodel, path, value)` -> the
  # resulting datamodel would contain only the written "Var1" key, dropping
  # the unrelated seeded-but-unbound "Other" id entirely, reddening the
  # `Map.has_key?/2` assertion below.
  test "after an <assign> to one id, an unrelated seeded-but-unbound <data> id is still nil" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="Var1"/>
              <data id="Other"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()

    node = %Assign{
      c_index: 0,
      location: "Var1",
      node_location: Location.at_offset("", 0),
      value: {:static, 1}
    }

    context = %Context{
      machine_state: ms,
      owner: {:onentry, 0, 0},
      datamodel_context: Evaluator.context(ms)
    }

    assert {:ok, new_context, [{:datamodel_change, _change}]} =
             ExecutableContent.execute(node, context)

    assert new_context.machine_state.datamodel["Var1"] == 1
    assert Map.has_key?(new_context.machine_state.datamodel, "Other")
    assert new_context.machine_state.datamodel["Other"] == nil
  end

  describe "the call site (Statifier.Interpreter.initialize/2)" do
    # sabotage: `Interpreter.initialize/2`'s `Datamodel.initialize(machine_state)`
    # call is moved to *after* the `ExitEntry.enter_states/2` call instead of
    # before it -> s0's <onentry> raise of "foo" would reach the internal
    # queue ahead of the binding failure's own error.execution, so "foo"
    # would win the race and the configuration would land on "fail" instead
    # of "pass", reddening this assertion.
    test "a binding failure's error.execution is queued ahead of the entering state's own onentry raise" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <datamodel>
                <data id="Var1" expr="return"/>
            </datamodel>
            <state id="s0">
                <onentry>
                    <raise event="foo"/>
                </onentry>
                <transition event="error.execution" target="pass"/>
                <transition event="foo" target="fail"/>
            </state>
            <state id="pass"/>
            <state id="fail"/>
        </scxml>
        """)

      {ms, _effects} = Interpreter.initialize(machine)

      assert MapSet.member?(
               MachineState.active_leaf_states(ms),
               elem(Statifier.Machine.index(machine, "pass"), 1)
             )

      refute MapSet.member?(
               MachineState.active_leaf_states(ms),
               elem(Statifier.Machine.index(machine, "fail"), 1)
             )
    end

    # sabotage: `Datamodel.seed/2` is changed to iterate
    # `[%Statifier.Machine.Data{d_index: 0, id: "phantom", value: {:static, nil}, location: nil}]`
    # unconditionally instead of `machine.data_elements` -> a document with
    # no <datamodel> at all would gain a spurious "phantom" key, reddening
    # this equality.
    test "a document with no <datamodel> produces a datamodel with exactly the four system variables" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <state id="s0"/>
        </scxml>
        """)

      {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()

      assert Map.keys(ms.datamodel) |> Enum.sort() ==
               Enum.sort(["_event", "_ioprocessors", "_name", "_sessionid"])
    end
  end

  describe "the {:datamodel_init, %Effect.DatamodelInit{}} baseline effect" do
    # sabotage: `Datamodel.initialize/1`'s `init_effect` carries `datamodel:
    # %{}` instead of `machine_state.datamodel` -> the baseline's map is
    # empty instead of holding the four system variables, reddening the
    # equality below.
    test "a document with no <datamodel> still emits exactly one baseline effect holding the four system variables" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <state id="s0"/>
        </scxml>
        """)

      {_ms, effects} = machine |> MachineState.new() |> Datamodel.initialize()

      assert [{:datamodel_init, %DatamodelInit{datamodel: datamodel}}] = effects

      assert Map.keys(datamodel) |> Enum.sort() ==
               Enum.sort(["_event", "_ioprocessors", "_name", "_sessionid"])
    end

    # sabotage: `Datamodel.initialize/1`'s `init_effect` is built after the
    # `Enum.reduce/3` binding fold instead of before it -> "Var1" would read
    # `1` (the bound expr value) instead of `:undefined` in the baseline's
    # own map, reddening the `== :undefined` assertion below - the baseline
    # is genuinely pre-binding, not merely pre-effect (decision 1).
    test "under binding=\"early\", every declared id appears as :undefined in the baseline, never the bound value" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <datamodel>
                <data id="Var1" expr="1"/>
            </datamodel>
            <state id="s0"/>
        </scxml>
        """)

      {ms, effects} = machine |> MachineState.new() |> Datamodel.initialize()

      assert [{:datamodel_init, %DatamodelInit{datamodel: datamodel}} | _binding_effects] =
               effects

      assert datamodel["Var1"] == :undefined
      # The live machine_state, by contrast, has the bound value - proving
      # the baseline is a snapshot taken before the fold, not the same map.
      assert ms.datamodel["Var1"] == 1
    end

    # sabotage: `Datamodel.initialize/1`'s `init_effect` carries `datamodel:
    # %{}` instead of `machine_state.datamodel` -> an author-supplied
    # `:datamodel` option's keys/values go missing from the baseline,
    # reddening this assertion (decision 4).
    test "an author :datamodel option's keys and values appear verbatim in the baseline" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <state id="s0"/>
        </scxml>
        """)

      {_ms, effects} =
        machine |> MachineState.new(datamodel: %{"Var1" => "from-env"}) |> Datamodel.initialize()

      assert [{:datamodel_init, %DatamodelInit{datamodel: datamodel}}] = effects
      assert datamodel["Var1"] == "from-env"
    end

    # sabotage: `Datamodel.initialize/1`'s `init_effect` stamps
    # `machine_state.macrostep`/`.microstep` with hardcoded `0`s instead of
    # reading them off `machine_state` -> this assertion reddens once
    # `Interpreter.initialize/2` has already advanced both counters to 1
    # before calling `Datamodel.initialize/1`.
    test "macrostep/microstep on the baseline are the counters initialize/2 has already advanced" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <state id="s0"/>
        </scxml>
        """)

      {_ms, effects} = Interpreter.initialize(machine)

      assert [{:datamodel_init, %DatamodelInit{macrostep: 1, microstep: 1}} | _rest] = effects
    end

    # sabotage: `Datamodel.initialize/1`'s `init_effect` stamps `round: 1`
    # (a plausible-looking hardcode, matching `macrostep`/`microstep`'s own
    # advanced-to-1 value in the test above) instead of reading
    # `machine_state.round` -> red, since `round` never advances before
    # `Datamodel.initialize/1` runs (only `begin_round/1` writes it, and
    # nothing calls it this early) - ADR-0046's "round: 0 before the fold
    # begins" case.
    test "the baseline carries round: 0, even though macrostep/microstep have already advanced" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <state id="s0"/>
        </scxml>
        """)

      {_ms, effects} = Interpreter.initialize(machine)

      assert [{:datamodel_init, %DatamodelInit{macrostep: 1, microstep: 1, round: 0}} | _rest] =
               effects
    end
  end

  describe "the {:datamodel_change, %Effect.DatamodelChange{}} binding effect" do
    # sabotage: `bind_value/4`'s success clause is changed to build the
    # effect with `d_index: nil` instead of `d_index: d_index` -> the
    # `== 0` assertion below reddens.
    test "binding=\"early\", a top-level <data expr> emits one :datamodel_change with d_index set" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <datamodel>
                <data id="x" expr="1"/>
            </datamodel>
            <state id="s0"/>
        </scxml>
        """)

      {_ms, effects} = machine |> MachineState.new() |> Datamodel.initialize()

      assert [{:datamodel_init, _init}, {:datamodel_change, change}] = effects
      assert change.d_index == 0
      assert change.c_index == nil
      assert change.owner == nil
      assert change.location_path == ["x"]
      assert change.location_source == "x"
      assert change.new_value == 1
      assert change.prior_value == :undefined
    end

    # sabotage: `Datamodel.d_indexes_to_bind/2`'s `:early` clause is changed
    # to `MapSet.to_list(top_level_indexes)` (top-level only) instead of the
    # full `d_index` range -> "Local1"'s binding effect never appears,
    # reddening the three-element match below.
    test "binding=\"early\", a state-scoped <data> is also bound at initialize/1 and also emitted" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <datamodel>
                <data id="Root1" expr="1"/>
            </datamodel>
            <state id="s0">
                <datamodel>
                    <data id="Local1" expr="2"/>
                </datamodel>
            </state>
        </scxml>
        """)

      {_ms, effects} = machine |> MachineState.new() |> Datamodel.initialize()

      assert [
               {:datamodel_init, _init},
               {:datamodel_change, root_change},
               {:datamodel_change, local_change}
             ] = effects

      assert root_change.d_index == 0
      assert root_change.location_path == ["Root1"]
      assert local_change.d_index == 1
      assert local_change.location_path == ["Local1"]
      assert local_change.new_value == 2
    end

    # sabotage: `Datamodel.d_indexes_to_bind/2`'s `:late` clause is changed
    # to the `:early` clause's own body (`0..(tuple_size(machine.data_elements)
    # - 1)//1`) -> "Local1" would also be bound and emitted at `initialize/1`,
    # reddening the two-element match below.
    test "binding=\"late\", only the top-level <data> emits from initialize/1" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" binding="late">
            <datamodel>
                <data id="Root1" expr="1"/>
            </datamodel>
            <state id="s0">
                <datamodel>
                    <data id="Local1" expr="2"/>
                </datamodel>
            </state>
        </scxml>
        """)

      {_ms, effects} = machine |> MachineState.new() |> Datamodel.initialize()

      assert [{:datamodel_init, _init}, {:datamodel_change, change}] = effects
      assert change.location_path == ["Root1"]
    end

    # sabotage: `bind/6`'s environment-skip branch is changed to call
    # `bind_value(machine_state, context, d_index, data)` unconditionally
    # instead of returning `{machine_state, []}` -> the environment's "Var1"
    # would emit a spurious :datamodel_change, reddening the one-element
    # match below.
    test "an environment-overridden top-level <data> emits no :datamodel_change" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <datamodel>
                <data id="Var1" expr="1"/>
            </datamodel>
            <state id="s0"/>
        </scxml>
        """)

      {_ms, effects} =
        machine |> MachineState.new(datamodel: %{"Var1" => "from-env"}) |> Datamodel.initialize()

      assert [{:datamodel_init, _init}] = effects
    end

    # sabotage: `bind_value/4`'s `{:invalid, error}` clause is changed to
    # return `{raise_binding_error(machine_state, d_index, error), [{:ok,
    # :sabotage}]}` instead of `{..., []}` -> a spurious element appears,
    # reddening the one-element match below.
    test "a {:invalid, _} value emits no :datamodel_change while still raising error.execution" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <datamodel>
                <data id="o1" expr="{p1: 'v1'"/>
            </datamodel>
            <state id="s0"/>
        </scxml>
        """)

      {ms, effects} = machine |> MachineState.new() |> Datamodel.initialize()

      assert [{:datamodel_init, _init}] = effects
      assert [event] = MachineState.internal_events(ms)
      assert event.name == "error.execution"
    end

    # sabotage: `bind_value/4`'s `{:src, uri}` clause is changed to return
    # `{raise_binding_error(machine_state, d_index, {:src, uri}), [{:ok,
    # :sabotage}]}` instead of `{..., []}` -> a spurious element appears,
    # reddening the one-element match below.
    test "a src value emits no :datamodel_change while still raising error.execution" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <datamodel>
                <data id="Var1" src="file:x.txt"/>
            </datamodel>
            <state id="s0"/>
        </scxml>
        """)

      {ms, effects} = machine |> MachineState.new() |> Datamodel.initialize()

      assert [{:datamodel_init, _init}] = effects
      assert [event] = MachineState.internal_events(ms)
      assert event.name == "error.execution"
    end

    # sabotage: `bind_value/4`'s catch-all clause's `{:error, reason} ->
    # {raise_binding_error(...), []}` branch is changed to `{raise_binding_error(...),
    # [{:ok, :sabotage}]}` -> a spurious element appears, reddening the
    # one-element match below.
    test "an evaluation failure emits no :datamodel_change while still raising error.execution" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <datamodel>
                <data id="Var1" expr="return"/>
            </datamodel>
            <state id="s0"/>
        </scxml>
        """)

      {ms, effects} = machine |> MachineState.new() |> Datamodel.initialize()

      assert [{:datamodel_init, _init}] = effects
      assert [event] = MachineState.internal_events(ms)
      assert event.name == "error.execution"
    end

    # sabotage: `initialize/1`'s `Enum.reduce/3` binding fold is changed to
    # `effects ++ new_effects` reversed to `new_effects ++ effects` -> the
    # accumulated order would put every later d_index's effect ahead of
    # earlier ones instead of after, reddening the ascending-order
    # assertion below.
    test "binding effects arrive in ascending d_index order, after the baseline" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <datamodel>
                <data id="a" expr="1"/>
                <data id="b" expr="2"/>
                <data id="c" expr="3"/>
            </datamodel>
            <state id="s0"/>
        </scxml>
        """)

      {_ms, effects} = machine |> MachineState.new() |> Datamodel.initialize()

      assert [{:datamodel_init, _init} | changes] = effects
      assert Enum.map(changes, fn {:datamodel_change, c} -> c.d_index end) == [0, 1, 2]
    end
  end

  describe "the binding effect through a full chart (Interpreter.initialize/2 + handle_event/2)" do
    # sabotage: `ExitEntry.arrive/3`'s final concatenation drops
    # `data_effects`, reverting to `onentry_effects ++ default_entry_effects
    # ++ completion_effects` -> "c"'s late-bound `<data id="X">` would still
    # bind (the write happens either way) but its `:datamodel_change` effect
    # would never reach the returned effect list, reddening the "exactly one"
    # assertion on first entry.
    test "a late-bound state-scoped <data> emits its :datamodel_change on first entry only" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" binding="late">
            <state id="s0">
                <transition event="go" target="c"/>
            </state>
            <state id="c">
                <datamodel>
                    <data id="X" expr="1"/>
                </datamodel>
                <transition event="back" target="s0"/>
            </state>
        </scxml>
        """)

      {ms, init_effects} = Interpreter.initialize(machine)

      refute Enum.any?(init_effects, &binding_change_for?(&1, "X"))

      {:ok, ms, go_effects} = Interpreter.handle_event(ms, Event.external("go"))
      assert Enum.count(go_effects, &binding_change_for?(&1, "X")) == 1
      assert ms.datamodel["X"] == 1

      {:ok, ms, back_effects} = Interpreter.handle_event(ms, Event.external("back"))
      refute Enum.any?(back_effects, &binding_change_for?(&1, "X"))

      {:ok, _ms, reentry_effects} = Interpreter.handle_event(ms, Event.external("go"))
      refute Enum.any?(reentry_effects, &binding_change_for?(&1, "X"))
    end

    # sabotage: `bind_value/4`'s success clause's `prior_value = Map.get(...)`
    # binding is changed to `prior_value = :undefined` unconditionally ->
    # the `== 42` assertion below reddens, since the seeded-then-assigned
    # value would be misreported as never-bound.
    test "a pre-existing <assign> makes prior_value the assigned value, not :undefined" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" binding="late">
            <state id="s0">
                <onentry>
                    <assign location="Y" expr="42"/>
                </onentry>
                <transition event="go" target="c"/>
            </state>
            <state id="c">
                <datamodel>
                    <data id="Y" expr="1"/>
                </datamodel>
            </state>
        </scxml>
        """)

      {ms, _init_effects} = Interpreter.initialize(machine)
      assert ms.datamodel["Y"] == 42

      {:ok, _ms, go_effects} = Interpreter.handle_event(ms, Event.external("go"))

      assert [change] =
               for(
                 {:datamodel_change, %DatamodelChange{location_path: ["Y"]} = c} <- go_effects,
                 do: c
               )

      assert change.prior_value == 42
      assert change.new_value == 1
    end

    defp binding_change_for?({:datamodel_change, %DatamodelChange{location_path: [id]}}, id),
      do: true

    defp binding_change_for?(_effect, _id), do: false
  end

  describe "enter_state/2 (Phase 5's per-state late-binding step)" do
    defp late_machine do
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" binding="late">
          <state id="s0">
              <datamodel>
                  <data id="Var1" expr="1"/>
              </datamodel>
          </state>
      </scxml>
      """)
    end

    # sabotage: `Datamodel.bind_state_data/4`'s `:late` clause is changed to
    # `Enum.reduce([], machine_state, ...)` instead of folding over the
    # state's real `d_indexes` -> "Var1" would stay :undefined even after
    # `enter_state/2` runs, reddening this assertion.
    test ~s(under binding="late", a state-scoped <data expr="1"> binds to 1 at enter_state/2) do
      machine = late_machine()
      s0 = elem(Statifier.Machine.index(machine, "s0"), 1)

      {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()
      assert ms.datamodel["Var1"] == :undefined

      {ms, _effects} = Datamodel.enter_state(ms, s0)
      assert ms.datamodel["Var1"] == 1
    end

    # sabotage: `Datamodel.bind_state_data/4`'s two clause heads are swapped
    # (`:early` guards the binding body, `:late` guards the no-op) -> an
    # early-binding document's state-scoped <data> would rebind at
    # enter_state/2, changing a value a prior write left there back to its
    # document default, reddening the `== "kept"` assertion below.
    test "under binding=\"early\", enter_state/2 is a no-op" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
            <state id="s0">
                <datamodel>
                    <data id="Var1" expr="1"/>
                </datamodel>
            </state>
        </scxml>
        """)

      s0 = elem(Statifier.Machine.index(machine, "s0"), 1)

      {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()
      # Var1 was already bound to 1 by initialize/1 under :early; simulate a
      # write an <assign>-equivalent left afterward.
      ms = %{ms | datamodel: Map.put(ms.datamodel, "Var1", "kept")}

      {result, effects} = Datamodel.enter_state(ms, s0)

      assert result == ms
      assert effects == []
      assert result.datamodel["Var1"] == "kept"
    end

    # sabotage: `Datamodel.bind_state_data/4`'s `:late` clause reads
    # `0..(tuple_size(machine.data_elements) - 1)` (every d_index in the
    # whole machine, the `:early` clause's own range) instead of
    # `Machine.at(machine, state_index).data` -> entering `s0`, which
    # declares no `<datamodel>` of its own, would incorrectly also bind the
    # sibling `other` state's still-unentered `<data id="Other1">`,
    # reddening the `== :undefined` assertion below.
    test "under binding=\"late\", a state with no <datamodel> touches no other state's data" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" binding="late">
            <state id="s0"/>
            <state id="other">
                <datamodel>
                    <data id="Other1" expr="7"/>
                </datamodel>
            </state>
        </scxml>
        """)

      s0 = elem(Statifier.Machine.index(machine, "s0"), 1)
      {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()

      {result, effects} = Datamodel.enter_state(ms, s0)

      assert result == ms
      assert effects == []
      assert result.datamodel["Other1"] == :undefined
    end

    # sabotage: `Datamodel.bind_state_data/4`'s `:late, 0` clause is deleted,
    # so the root falls through to the general `:late` clause -> root entry
    # rebinds the top-level <data> with no environment check and "Var1" comes
    # back 1 instead of 99, reddening both assertions below.
    test ~s(under binding="late", root entry does not overwrite an environment value) do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" binding="late">
            <datamodel>
                <data id="Var1" expr="1"/>
            </datamodel>
            <state id="s0"/>
        </scxml>
        """)

      # Spec 5.3.2: the environment's value MUST replace the one the top-level
      # <data> declares. The root is state index 0 and is entered like any
      # other state, so without the `:late, 0` no-op its own `data` list - which
      # *is* the top-level list - would be bound a second time by `arrive/3`,
      # after `initialize/1` correctly skipped it.
      {ms, _effects} = Interpreter.initialize(machine, datamodel: %{"Var1" => 99})

      assert ms.datamodel["Var1"] == 99
      assert MapSet.member?(ms.configuration, 0), "the root must really have been entered"
    end

    # sabotage: as above, the `:late, 0` clause is deleted -> `enter_state/2`
    # on the root binds the top-level <data> and returns a changed struct,
    # reddening the `== ms` identity assertion below.
    test ~s(under binding="late", enter_state/2 on the root is a no-op) do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0" binding="late">
            <datamodel>
                <data id="Var1" expr="1"/>
            </datamodel>
            <state id="s0"/>
        </scxml>
        """)

      {ms, _effects} =
        machine
        |> MachineState.new(datamodel: %{"Var1" => 99})
        |> Datamodel.initialize()

      assert Datamodel.enter_state(ms, 0) == {ms, []}
    end

    # sabotage: `bind_value/4`'s `{:datamodel_change, _}` effect stamps
    # `round: 0` unconditionally instead of reading `machine_state.round` ->
    # red, since the round bumped to 2 below (simulating entry mid-fold) no
    # longer matches the hardcoded 0.
    test "a state-entry <data> binding carries the entering round, not round: 0" do
      machine = late_machine()
      s0 = elem(Statifier.Machine.index(machine, "s0"), 1)

      {ms, _effects} = machine |> MachineState.new() |> Datamodel.initialize()
      # Simulate enter_state/2 running mid-fold, on the round that entered
      # s0 - two rounds in, not the anonymous round: 0 the baseline uses.
      ms = ms |> MachineState.begin_round() |> MachineState.begin_round()

      {_ms, effects} = Datamodel.enter_state(ms, s0)

      assert [{:datamodel_change, %DatamodelChange{round: 2}}] = effects
    end
  end

  describe "write_location/4's fourth element (the %Datamodel.Write{} report)" do
    @document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
        <state id="s0"/>
    </scxml>
    """

    defp write_context(datamodel) do
      ms = %{(compile!(@document) |> MachineState.new()) | datamodel: datamodel}
      {ms, Evaluator.context(ms)}
    end

    # sabotage: `write_location/4`'s `prior_value = read_path(...)` binding is
    # changed to `prior_value = nil` unconditionally -> a seeded-:undefined
    # id's prior_value would still read :undefined by coincidence (nil !=
    # :undefined though, so this reddens directly: the assertion expects the
    # atom :undefined, not nil).
    test "a fresh write over a seeded-:undefined id reports prior_value: :undefined" do
      {ms, ctx} = write_context(%{"Var1" => :undefined})

      assert {:ok, _ms, _ctx, write} = Datamodel.write_location(ms, ctx, "Var1", 1)
      assert write.path == ["Var1"]
      assert write.prior_value == :undefined
      assert write.new_value == 1
    end

    # sabotage: `read_path/2`'s `Map.fetch/2` clause is changed to always
    # `{:halt, :undefined}` regardless of the fetch result -> an overwrite's
    # prior_value would read :undefined instead of the old value, reddening
    # the `== "old"` assertion.
    test "an overwrite reports the old value as prior_value" do
      {ms, ctx} = write_context(%{"Var1" => "old"})

      assert {:ok, _ms, _ctx, write} = Datamodel.write_location(ms, ctx, "Var1", "new")
      assert write.path == ["Var1"]
      assert write.prior_value == "old"
      assert write.new_value == "new"
    end

    # sabotage: `write_location/4`'s `%Write{path: path, ...}` literal is
    # changed to `%Write{path: [root | _rest] = path; [root], ...}` (reporting
    # only the root segment `["a"]` instead of the full resolved path) -> the
    # `== ["a", "b", "c"]` assertion reddens.
    test "a deep path a.b.c reports the full path and the leaf's prior value" do
      {ms, ctx} = write_context(%{"a" => %{"b" => %{"c" => "old-leaf"}}})

      assert {:ok, _ms, _ctx, write} = Datamodel.write_location(ms, ctx, "a.b.c", "new-leaf")
      assert write.path == ["a", "b", "c"]
      assert write.prior_value == "old-leaf"
      assert write.new_value == "new-leaf"
    end

    # sabotage: `read_path/2`'s integer-index clause guard is changed from
    # `is_integer(segment) and is_list(container)` to
    # `is_binary(segment) and is_list(container)` (never matches an integer
    # segment) -> falls through to the catch-all, reddening prior_value from
    # 20 to :undefined.
    test "a bracket path items[1] carries an integer segment and reports the indexed prior value" do
      {ms, ctx} = write_context(%{"items" => [10, 20, 30]})

      assert {:ok, _ms, _ctx, write} = Datamodel.write_location(ms, ctx, "items[1]", 99)
      assert write.path == ["items", 1]
      assert write.prior_value == 20
      assert write.new_value == 99
    end

    # sabotage: `read_path/2`'s catch-all clause is changed to `{:halt, nil}`
    # instead of `{:halt, :undefined}` -> a vivified intermediate container's
    # prior_value would read nil instead of :undefined, reddening the
    # assertion (and not crashing, which is exactly what this test is here to
    # confirm read_path/2 does not do against a nil/non-container root).
    test "a vivified intermediate container reports prior_value: :undefined, not a crash" do
      {ms, ctx} = write_context(%{"a" => nil})

      assert {:ok, _ms, _ctx, write} = Datamodel.write_location(ms, ctx, "a.b.c", 1)
      assert write.path == ["a", "b", "c"]
      assert write.prior_value == :undefined
      assert write.new_value == 1
      assert write.__struct__ == Datamodel.Write
    end
  end
end
