defmodule Statifier.Interpreter.DatamodelTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Evaluator
  alias Statifier.ExecutableContent
  alias Statifier.ExecutableContent.Context
  alias Statifier.Interpreter
  alias Statifier.Interpreter.Datamodel
  alias Statifier.Lowering
  alias Statifier.Machine.Content.Assign
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Parser.Location
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
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

    ms = machine |> MachineState.new() |> Datamodel.initialize()

    assert Map.has_key?(ms.datamodel, "Var1")
    assert ms.datamodel["Var1"] == nil
  end

  # sabotage: `Statifier.Evaluator.context/1`'s `on_unbound: :error` option
  # is dropped -> an unbound identifier would resolve to something other
  # than the seeded nil, and predicator's own `:undefined` normalization
  # would not be exercised the same way, reddening this equality.
  test "Var1 === undefined evaluates {:ok, true} against the seeded datamodel" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="Var1"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    ms = machine |> MachineState.new() |> Datamodel.initialize()
    context = Evaluator.context(ms)

    assert Evaluator.evaluate(context, compiled_expr("Var1 === undefined")) == {:ok, true}
    assert Evaluator.evaluate(context, compiled_expr("Var1 !== undefined")) == {:ok, false}
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

    ms = machine |> MachineState.new() |> Datamodel.initialize()

    assert ms.datamodel["Var1"] == 1
  end

  # sabotage: `Datamodel.bind_value/4`'s catch-all clause's `{:error,
  # reason} -> raise_binding_error(...)` branch is dropped, so an
  # `Evaluator.evaluate/2` failure is silently ignored instead of raised ->
  # no `error.execution` reaches the internal queue, reddening the
  # assertions below.
  test "expr=\"return\" leaves nil and enqueues one error.execution with cause {:data, 0}" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="Var1" expr="return"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    ms = machine |> MachineState.new() |> Datamodel.initialize()

    assert ms.datamodel["Var1"] == nil
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
  test "an unparseable expr leaves nil and enqueues one error.execution with cause {:data, 0}" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="o1" expr="{p1: 'v1'"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    ms = machine |> MachineState.new() |> Datamodel.initialize()

    assert ms.datamodel["o1"] == nil
    assert [event] = MachineState.internal_events(ms)
    assert event.name == "error.execution"
    assert event.type == :platform
    assert event.cause.origin == {:data, 0}
  end

  # sabotage: `Datamodel.bind_value/4`'s `{:src, uri}` clause is dropped,
  # falling through to the catch-all clause and crashing the same way the
  # invalid-expr sabotage above does, rather than raising a clean
  # `error.execution`.
  test "src leaves nil and enqueues one error.execution with cause {:data, 0}" do
    machine =
      compile!("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
          <datamodel>
              <data id="Var1" src="file:x.txt"/>
          </datamodel>
          <state id="s0"/>
      </scxml>
      """)

    ms = machine |> MachineState.new() |> Datamodel.initialize()

    assert ms.datamodel["Var1"] == nil
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

    ms = machine |> MachineState.new(datamodel: %{"Var1" => "from-env"}) |> Datamodel.initialize()

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

    ms = machine |> MachineState.new(datamodel: %{"Var1" => "from-env"}) |> Datamodel.initialize()

    assert ms.datamodel["Var1"] == 1
  end

  # sabotage: `Datamodel.d_indexes_to_bind/2`'s `:late` clause is changed to
  # return `0..(tuple_size(machine.data_elements) - 1)//1` (the `:early`
  # body) unconditionally -> the state-scoped `<data expr="2">` would be
  # bound at initialization under late binding too, reddening the `== nil`
  # half of this assertion.
  test "under binding=\"late\", a top-level <data> binds at initialization while a state-scoped one stays nil" do
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

    ms = machine |> MachineState.new() |> Datamodel.initialize()

    assert ms.datamodel["Root1"] == 1
    assert Map.has_key?(ms.datamodel, "Local1")
    assert ms.datamodel["Local1"] == nil
  end

  # sabotage: `Statifier.Machine.Content.Assign`'s write step is changed to
  # write `assigned_context.data` (the normalized view read back out of
  # `Predicator.ContextLocation.put/3` applied to
  # `context.datamodel_context.data`) into `machine_state.datamodel`, instead
  # of writing through the raw `machine_state.datamodel` directly (Decision
  # 2) -> `Predicator.Context.new/2` deep-normalizes `nil` to `:undefined`, so
  # the unrelated seeded-but-unbound "Other" id would come back `:undefined`
  # instead of `nil`, reddening the `== nil` assertion below.
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

    ms = machine |> MachineState.new() |> Datamodel.initialize()

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

    assert {:ok, new_context, []} = ExecutableContent.execute(node, context)

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

      ms = machine |> MachineState.new() |> Datamodel.initialize()

      assert Map.keys(ms.datamodel) |> Enum.sort() ==
               Enum.sort(["_event", "_ioprocessors", "_name", "_sessionid"])
    end
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
    # state's real `d_indexes` -> "Var1" would stay nil even after
    # `enter_state/2` runs, reddening this assertion.
    test ~s(under binding="late", a state-scoped <data expr="1"> binds to 1 at enter_state/2) do
      machine = late_machine()
      s0 = elem(Statifier.Machine.index(machine, "s0"), 1)

      ms = machine |> MachineState.new() |> Datamodel.initialize()
      assert ms.datamodel["Var1"] == nil

      ms = Datamodel.enter_state(ms, s0)
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

      ms = machine |> MachineState.new() |> Datamodel.initialize()
      # Var1 was already bound to 1 by initialize/1 under :early; simulate a
      # write an <assign>-equivalent left afterward.
      ms = %{ms | datamodel: Map.put(ms.datamodel, "Var1", "kept")}

      result = Datamodel.enter_state(ms, s0)

      assert result == ms
      assert result.datamodel["Var1"] == "kept"
    end

    # sabotage: `Datamodel.bind_state_data/4`'s `:late` clause reads
    # `0..(tuple_size(machine.data_elements) - 1)` (every d_index in the
    # whole machine, the `:early` clause's own range) instead of
    # `Machine.at(machine, state_index).data` -> entering `s0`, which
    # declares no `<datamodel>` of its own, would incorrectly also bind the
    # sibling `other` state's still-unentered `<data id="Other1">`,
    # reddening the `== nil` assertion below.
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
      ms = machine |> MachineState.new() |> Datamodel.initialize()

      result = Datamodel.enter_state(ms, s0)

      assert result == ms
      assert result.datamodel["Other1"] == nil
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

      ms =
        machine
        |> MachineState.new(datamodel: %{"Var1" => 99})
        |> Datamodel.initialize()

      assert Datamodel.enter_state(ms, 0) == ms
    end
  end
end
