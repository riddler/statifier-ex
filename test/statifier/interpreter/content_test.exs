defmodule Statifier.Interpreter.ContentTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.ContextRecorder
  alias Statifier.Effect
  alias Statifier.Evaluator
  alias Statifier.Interpreter.Content
  alias Statifier.Interpreter.ExitEntry
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Machine.Content.Assign
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Parser.Location
  alias Statifier.TestContent
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Hand-drawn c_index assignment, document order across the whole machine:
  #
  #  c0  <raise event="one"/>        - a's first onentry block
  #  c1  <log label="mid"/>          - a's first onentry block
  #  c2  <raise event="two"/>        - a's first onentry block
  #  c3  <log label="second-block"/> - a's second onentry block
  #  c4  <log label="t-content"/>    - the "go" transition's own content
  #  c5  <log label="b1"/>           - b's onentry block
  #  c6  <log label="b2"/>           - b's onentry block
  #
  # `a`'s <onexit/> is written empty on purpose - the empty-block test's
  # fixture.
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <onentry>
              <raise event="one"/>
              <log label="mid"/>
              <raise event="two"/>
          </onentry>
          <onentry>
              <log label="second-block"/>
          </onentry>
          <onexit/>
          <transition event="go" target="b">
              <log label="t-content"/>
          </transition>
      </state>
      <state id="b">
          <onentry>
              <log label="b1"/>
              <log label="b2"/>
          </onentry>
      </state>
  </scxml>
  """

  defp machine, do: compile!(@document)
  defp a_index(machine), do: machine |> Machine.index("a") |> elem(1)
  defp b_index(machine), do: machine |> Machine.index("b") |> elem(1)
  defp a_onentry_blocks(machine), do: Machine.at(machine, a_index(machine)).onentry
  defp b_onentry_blocks(machine), do: Machine.at(machine, b_index(machine)).onentry
  defp machine_state(machine, opts \\ [trace: true]), do: MachineState.new(machine, opts)

  # `MachineState.new/2` has no `:configuration` option (same gap
  # `evaluator_test.exs` works around), so a configuration with `id` active
  # is set directly on the built machine_state.
  defp machine_state_with_active(machine, id) do
    ms = machine_state(machine)
    %{ms | configuration: MapSet.new([Machine.index(machine, id) |> elem(1)])}
  end

  defp compiled_expr(source) do
    {:ok, compiled} = Predicator.compile_with_spans(source)
    {:compiled, compiled, source}
  end

  # Substitutes one compiled cell with `node` - the fixture-preserving
  # technique used throughout this file: a `Machine` built by the compiler
  # with one cell replaced, never a `%Machine{}` literal.
  defp machine_with_node(machine, c_index, node) do
    %{machine | contents: put_elem(machine.contents, c_index, node)}
  end

  @owner {:onentry, 1, 0}

  # sabotage: `run_nodes/2`'s `Enum.reduce_while/3` is replaced with a call
  # that iterates `Enum.reverse(c_indexes)` before folding -> the internal
  # queue would hold "two" before "one", reddening the ordered-match
  # assertion below.
  test "nodes run in document order: the queue holds both raises FIFO with the log's effect between them" do
    m = machine()
    ms = machine_state(m)
    [block1, _block2] = a_onentry_blocks(m)

    {result, effects} = Content.execute_block(ms, @owner, block1.content)

    assert [%{name: "one"}, %{name: "two"}] = MachineState.internal_events(result)

    assert [{:log, %Effect.Log{label: "mid"}}, {:trace, %Effect.Trace.ContentExecuted{}}] =
             effects
  end

  # sabotage: `execute_block/3` prepends new effects instead of appending
  # (`node_effects ++ effects` instead of `effects ++ node_effects`) -> the
  # two logs would come back reversed, reddening this assertion.
  test "effect order is preserved: two <log>s in one block return two :log effects in document order" do
    m = machine()
    ms = machine_state(m)
    [block] = b_onentry_blocks(m)

    {_result, effects} = Content.execute_block(ms, {:onentry, b_index(m), 0}, block.content)

    assert [
             {:log, %Effect.Log{label: "b1"}},
             {:log, %Effect.Log{label: "b2"}},
             {:trace, %Effect.Trace.ContentExecuted{c_indexes: [5, 6]}}
           ] = effects
  end

  # sabotage: `execute_block/3`'s `[]` clause is reverted to the old early
  # return (`def execute_block(machine_state, _owner, []), do: {machine_state,
  # []}`) -> no trace effect would be emitted even with trace: true,
  # reddening this assertion.
  test "an empty block still emits ContentExecuted with c_indexes: [] when tracing is on" do
    m = machine()
    ms = machine_state(m, trace: true)
    owner = {:onexit, a_index(m), 0}
    [onexit_block] = Machine.at(m, a_index(m)).onexit
    assert onexit_block.content == []

    assert {^ms, effects} = Content.execute_block(ms, owner, onexit_block.content)

    assert [{:trace, %Effect.Trace.ContentExecuted{owner: ^owner, c_indexes: []}}] = effects
  end

  # sabotage: the `[]` clause's `Effect.trace/3` call is replaced with a
  # hand-built `[{:trace, %ContentExecuted{}}]` that never consults the
  # `machine_state.trace` gate -> the effect would appear even with
  # `trace: false`, reddening this equality.
  test "an empty block emits nothing when tracing is off" do
    m = machine()
    ms = machine_state(m, trace: false)
    [onexit_block] = Machine.at(m, a_index(m)).onexit
    assert onexit_block.content == []

    assert {^ms, []} = Content.execute_block(ms, {:onexit, a_index(m), 0}, onexit_block.content)
  end

  describe "stop-on-error, via a test-only failing node substituted for c1" do
    # sabotage: `run_nodes/2`'s `Enum.reduce_while/3` is replaced with a plain
    # `Enum.reduce/3` that ignores the `{:error, reason}` tuple and keeps
    # folding -> "two" would still reach the internal queue after the
    # failure, reddening this refutation.
    test "the remainder of the block does not run: the first raise's event is queued, the third's never is" do
      m = machine() |> machine_with_node(1, %TestContent{c_index: 1, label: "boom", fail: true})
      ms = machine_state(m)
      [block1, _block2] = a_onentry_blocks(m)

      {result, _effects} = Content.execute_block(ms, @owner, block1.content)

      names = result |> MachineState.internal_events() |> Enum.map(& &1.name)
      assert "one" in names
      refute "two" in names
    end

    # sabotage: `raise_execution_error/4` calls `MachineState.raise_internal/4`
    # instead of `raise_platform/4` -> the raised event's `type` would come
    # back `:internal` instead of `:platform`, reddening this assertion.
    test "error.execution is raised as a platform event with the content cause and the node's reason" do
      m = machine() |> machine_with_node(1, %TestContent{c_index: 1, label: "boom", fail: true})
      ms = machine_state(m)
      [block1, _block2] = a_onentry_blocks(m)

      {result, _effects} = Content.execute_block(ms, @owner, block1.content)

      assert [_one, error_event] = MachineState.internal_events(result)
      assert error_event.name == "error.execution"
      assert error_event.type == :platform
      assert error_event.cause.origin == {:content, 1, @owner}
      assert error_event.data == {:test_content, "boom"}
    end

    # sabotage: `execute_block/3` emits `ContentExecuted` with the block's
    # full declared `c_indexes` (`c_indexes: c_indexes`, the function's
    # argument) instead of the ones the fold actually executed -> the trace
    # would wrongly carry `[0, 1, 2]` instead of the `[0, 1]` prefix,
    # reddening this assertion.
    test "ContentExecuted on error is a prefix of the block ending at (and including) the failing node" do
      m = machine() |> machine_with_node(1, %TestContent{c_index: 1, label: "boom", fail: true})
      ms = machine_state(m)
      [block1, _block2] = a_onentry_blocks(m)

      {_result, effects} = Content.execute_block(ms, @owner, block1.content)

      assert [{:trace, %Effect.Trace.ContentExecuted{owner: @owner, c_indexes: [0, 1]}}] = effects
    end
  end

  # sabotage: `ExitEntry`'s seam is reverted to the no-op stub
  # (`defp execute_block(machine_state, _owner, _c_indexes), do: {machine_state, []}`)
  # -> the second onentry block's own `:log` effect would never appear,
  # reddening this assertion.
  test "a second onentry block on the same state still runs after the first one errored" do
    doc = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="trigger">
        <state id="trigger">
            <transition event="go" target="a"/>
        </state>
        <state id="a">
            <onentry>
                <raise event="one"/>
                <log label="mid"/>
            </onentry>
            <onentry>
                <log label="second-block"/>
            </onentry>
        </state>
    </scxml>
    """

    m = compile!(doc)
    a_idx = m |> Machine.index("a") |> elem(1)
    [block1, block2] = Machine.at(m, a_idx).onentry
    [_raise_c, log_c] = block1.content
    m = machine_with_node(m, log_c, %TestContent{c_index: log_c, label: "boom", fail: true})

    transition = m.transitions |> Tuple.to_list() |> Enum.find(&(&1.events == [["go"]]))
    ms = MachineState.new(m)

    {result, effects} = ExitEntry.enter_states(ms, [transition])

    names = result |> MachineState.internal_events() |> Enum.map(& &1.name)
    assert "one" in names
    assert "error.execution" in names
    assert block2.content != []
    assert Enum.any?(effects, &match?({:log, %Effect.Log{label: "second-block"}}, &1))
  end

  # sabotage: `run_nodes/2`'s fold calls `MachineState.begin_microstep/1`
  # before dispatching each node instead of threading one unchanged counter
  # pair -> `cause0` and `cause1` would carry different `microstep` values,
  # reddening this equality.
  test "two <raise> nodes in the same block produce causes with identical counters" do
    m = machine()

    ms =
      m
      |> MachineState.new()
      |> MachineState.begin_macrostep()
      |> MachineState.begin_microstep()

    [block1, _block2] = a_onentry_blocks(m)

    {result, _effects} = Content.execute_block(ms, @owner, block1.content)

    assert [%{cause: cause0}, %{cause: cause1}] = MachineState.internal_events(result)
    assert cause0.macrostep == cause1.macrostep
    assert cause0.microstep == cause1.microstep
  end

  # sabotage: `Effect.trace/3`'s call site in `execute_block/3` is replaced
  # with a bare list literal (bypassing the `machine_state.trace` gate) -> a
  # `ContentExecuted` effect would appear even with `trace: false`, reddening
  # this refutation.
  test "trace: false yields no trace effects while the block's own effects remain" do
    m = machine()
    ms = machine_state(m, trace: false)
    [block1, _block2] = a_onentry_blocks(m)

    {_result, effects} = Content.execute_block(ms, @owner, block1.content)

    refute Enum.any?(effects, &Effect.trace?/1)
    assert [{:log, %Effect.Log{label: "mid"}}] = effects
  end

  # sabotage: `execute_one/2` is changed to call `Machine.content/2` on a
  # hardcoded `0` instead of the fold's own `c_index` -> the substituted
  # `TestContent` at c1 would never run, so its marker effect would be
  # missing, reddening this assertion.
  test "a test-only node defined outside lib/ runs through the block runner unmodified" do
    m = machine() |> machine_with_node(1, %TestContent{c_index: 1, label: "probe"})
    ms = machine_state(m)
    [block1, _block2] = a_onentry_blocks(m)

    {result, effects} = Content.execute_block(ms, @owner, block1.content)

    assert [{:log, %Effect.Log{label: "probe"}}, {:trace, %Effect.Trace.ContentExecuted{}}] =
             effects

    assert [%{name: "one"}, %{name: "two"}] = MachineState.internal_events(result)
  end

  describe "datamodel_context" do
    # sabotage: `execute_block/3` builds `datamodel_context` from
    # `%{machine_state | configuration: MapSet.new()}` instead of
    # `machine_state` itself -> `In("a")` would come back `false` even
    # though `a` is active, reddening the first assertion.
    test "the context reaching a node evaluates In(...) correctly for the configuration the block ran at" do
      m = machine() |> machine_with_node(1, %ContextRecorder{c_index: 1, label: "ctx"})
      ms = machine_state_with_active(m, "a")
      [block1, _block2] = a_onentry_blocks(m)

      {_result, effects} = Content.execute_block(ms, @owner, block1.content)

      assert [{:log, %Effect.Log{label: "ctx", value: datamodel_context}} | _rest] = effects

      assert Evaluator.evaluate(datamodel_context, compiled_expr("In('a')")) == {:ok, true}
      assert Evaluator.evaluate(datamodel_context, compiled_expr("In('b')")) == {:ok, false}
    end

    # sabotage: `run_nodes/2`'s fold is changed to rebuild `datamodel_context`
    # from the fold's current `context.machine_state` before dispatching each
    # node, instead of reusing the one `execute_block/3` built once -> the
    # second node's recorded context would pick up the first node's datamodel
    # mutation (`x` becomes bound), reddening the second assertion below,
    # and the two recorded contexts would stop being the same value,
    # reddening the equality.
    test "every node in a two-node block receives the same context value, unaffected by an earlier node's datamodel write" do
      m =
        machine()
        |> machine_with_node(5, %ContextRecorder{c_index: 5, label: "r1", put: %{"x" => 1}})
        |> machine_with_node(6, %ContextRecorder{c_index: 6, label: "r2"})

      ms = machine_state(m)
      [block] = b_onentry_blocks(m)

      {_result, effects} = Content.execute_block(ms, {:onentry, b_index(m), 0}, block.content)

      assert [
               {:log, %Effect.Log{label: "r1", value: ctx1}},
               {:log, %Effect.Log{label: "r2", value: ctx2}} | _rest
             ] = effects

      assert ctx1 == ctx2
      assert {:error, _reason} = Evaluator.evaluate(ctx2, compiled_expr("x"))
    end

    # sabotage: `execute_block/3`'s `%Context{}` literal drops the
    # `datamodel_context:` field's value and passes `nil` instead of
    # `Evaluator.context(machine_state)` -> `@enforce_keys` would still let
    # a caller-supplied `nil` through since it only checks presence, not
    # value, so instead of a compile error this reddens by returning `nil`
    # where a `%Predicator.Context{}` is expected.
    test "a transition-owned block and an onentry-owned block both get a context" do
      m = machine() |> machine_with_node(4, %ContextRecorder{c_index: 4, label: "t-ctx"})
      ms = machine_state_with_active(m, "a")
      transition = m.transitions |> Tuple.to_list() |> Enum.find(&(&1.events == [["go"]]))

      {_result, transition_effects} =
        Content.execute_block(ms, {:transition, transition.t_index}, transition.content)

      assert [
               {:log, %Effect.Log{label: "t-ctx", value: %Predicator.Context{} = t_context}}
               | _rest
             ] = transition_effects

      assert Evaluator.evaluate(t_context, compiled_expr("In('a')")) == {:ok, true}

      onentry_m = machine() |> machine_with_node(1, %ContextRecorder{c_index: 1, label: "e-ctx"})
      onentry_ms = machine_state_with_active(onentry_m, "a")
      [onentry_block, _block2] = a_onentry_blocks(onentry_m)

      {_result, onentry_effects} =
        Content.execute_block(onentry_ms, @owner, onentry_block.content)

      assert [{:log, %Effect.Log{label: "e-ctx", value: %Predicator.Context{}}} | _rest] =
               onentry_effects
    end
  end

  describe "<assign>, through the real block runner" do
    defp assign_node(c_index, location, expr_source) do
      {:ok, compiled} = Predicator.compile_with_spans(expr_source)

      %Assign{
        c_index: c_index,
        location: location,
        node_location: Location.at_offset("", 0),
        value: {:compiled, compiled, expr_source}
      }
    end

    # sabotage: `Statifier.Machine.Content.Assign`'s `execute/2` returns the
    # unchanged `context` instead of rebuilding `datamodel_context` (Decision
    # 3's seam) -> the `ContextRecorder` running right after it in the same
    # block would still evaluate against the pre-write snapshot, reddening
    # the second assertion below.
    test "a real <assign> earlier in a block is visible to a ContextRecorder later in the same block" do
      m =
        machine()
        |> machine_with_node(5, assign_node(5, "x", "1 + 1"))
        |> machine_with_node(6, %ContextRecorder{c_index: 6, label: "r2"})

      ms = machine_state(m)
      ms = %{ms | datamodel: Map.put(ms.datamodel, "x", nil)}
      [block] = b_onentry_blocks(m)

      {_result, effects} = Content.execute_block(ms, {:onentry, b_index(m), 0}, block.content)

      assert [{:log, %Effect.Log{label: "r2", value: datamodel_context}} | _rest] = effects
      assert Evaluator.evaluate(datamodel_context, compiled_expr("x")) == {:ok, 2}
    end

    # sabotage: `Statifier.Interpreter.Content.raise_execution_error/4` calls
    # `MachineState.raise_internal/4` instead of `raise_platform/4` -> the
    # raised event's `type` would come back `:internal` instead of
    # `:platform`, reddening the type assertion below.
    test "an <assign> failure raises exactly one error.execution and halts the block" do
      m = machine() |> machine_with_node(1, assign_node(1, "undeclared_root", "1"))
      ms = machine_state(m)
      [block1, _block2] = a_onentry_blocks(m)

      {result, _effects} = Content.execute_block(ms, @owner, block1.content)

      assert [%{name: "one"}, error_event] = MachineState.internal_events(result)
      assert error_event.name == "error.execution"
      assert error_event.type == :platform
      assert error_event.cause.origin == {:content, 1, @owner}
      assert error_event.data == {:unbound_location, "undeclared_root"}
    end

    # sabotage: `Statifier.Machine.Content.Assign`'s `check_system_variable/1`
    # (spec 5.10) returns `:ok` unconditionally instead of
    # `{:error, {:system_variable, root}}` -> no `error.execution` would be
    # raised and the block would run to completion instead of halting,
    # reddening the assertions below.
    test "a system-variable <assign> in a block raises error.execution and halts the block" do
      m = machine() |> machine_with_node(1, assign_node(1, "_sessionid", "1"))
      ms = machine_state(m)
      [block1, _block2] = a_onentry_blocks(m)

      {result, _effects} = Content.execute_block(ms, @owner, block1.content)

      assert [%{name: "one"}, error_event] = MachineState.internal_events(result)
      assert error_event.name == "error.execution"
      assert error_event.type == :platform
      assert error_event.cause.origin == {:content, 1, @owner}
      assert error_event.data == {:system_variable, "_sessionid"}
    end
  end

  describe "execute_block/3 - non-fatal errors" do
    # sabotage: `drain_pending/2` drops the `pending_errors: []` reset
    # (`%{context | machine_state: machine_state}` instead of also clearing
    # `pending_errors`) -> the two-pending-reasons test below sees the first
    # reason queued twice, reddening the ordered-match assertion.
    test "a node's pending_errors produce one error.execution each, and the block keeps running" do
      m =
        machine()
        |> machine_with_node(1, %TestContent{c_index: 1, label: "mid", pending: [:boom]})

      ms = machine_state(m)
      [block1, _block2] = a_onentry_blocks(m)

      {result, effects} = Content.execute_block(ms, @owner, block1.content)

      assert [
               %{name: "one"},
               %{name: "error.execution", cause: cause, data: :boom},
               %{name: "two"}
             ] = MachineState.internal_events(result)

      assert cause.origin == {:content, 1, @owner}
      assert Enum.any?(effects, &match?({:log, %Effect.Log{label: "mid"}}, &1))
    end

    # sabotage: `drain_pending/2` drops the `pending_errors: []` reset ->
    # the first pending reason would be redrained on the next node's call and
    # queued twice, reddening the ordered-match assertion below.
    test "two pending reasons on one node produce two error.execution events in order" do
      m =
        machine()
        |> machine_with_node(1, %TestContent{c_index: 1, label: "mid", pending: [:a, :b]})

      ms = machine_state(m)
      [block1, _block2] = a_onentry_blocks(m)

      {result, _effects} = Content.execute_block(ms, @owner, block1.content)

      assert [
               %{name: "one"},
               %{name: "error.execution", data: :a},
               %{name: "error.execution", data: :b},
               %{name: "two"}
             ] = MachineState.internal_events(result)
    end

    # sabotage: `run_nodes/2`'s `{:error, new_context, reason}` arm halts
    # with `context` instead of `new_context` -> the pending error recorded
    # before the failure vanishes, reddening the assertion that the pending
    # reason's error.execution is present.
    test "a fail_with_context node's pending errors are queued before its own fatal error.execution" do
      m =
        machine()
        |> machine_with_node(1, %TestContent{
          c_index: 1,
          label: "mid",
          pending: [:cond_error],
          fail_with_context: true
        })

      ms = machine_state(m)
      [block1, _block2] = a_onentry_blocks(m)

      {result, _effects} = Content.execute_block(ms, @owner, block1.content)

      names_and_data =
        result
        |> MachineState.internal_events()
        |> Enum.map(&{&1.name, &1.data})

      assert [
               {"one", nil},
               {"error.execution", :cond_error},
               {"error.execution", {:test_content, "mid"}}
             ] = names_and_data
    end

    # sabotage: `run_nodes/2`'s `{:error, reason}` (two-element) arm is
    # changed to also call `drain_pending/2` -> since `context.pending_errors`
    # is `[]` on this path this is a no-op today, so instead sabotage the
    # halt itself: change it to `{:cont, ...}` -> the block would not stop,
    # reddening the refutation that the third node's event never queues.
    test "the plain two-element {:error, reason} form still halts the block as before" do
      m = machine() |> machine_with_node(1, %TestContent{c_index: 1, label: "boom", fail: true})
      ms = machine_state(m)
      [block1, _block2] = a_onentry_blocks(m)

      {result, _effects} = Content.execute_block(ms, @owner, block1.content)

      names = result |> MachineState.internal_events() |> Enum.map(& &1.name)
      assert "one" in names
      assert "error.execution" in names
      refute "two" in names
    end
  end

  describe "<if>, through the real block runner" do
    @if_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <if cond="true">
                    <assign location="x" expr="1 + 1"/>
                </if>
                <log label="r2"/>
            </onentry>
        </state>
    </scxml>
    """

    # sabotage: `Statifier.Machine.Content.If`'s `defimpl`'s `run_partition/2`
    # is changed to fold with the enclosing block's *own* pre-call `context`
    # on every step instead of threading `new_context` forward (discarding
    # the partition's own `<assign>` rebuild) -> the `ContextRecorder`
    # running after the `</if>` in the same block would still evaluate `x`
    # against the pre-write snapshot, reddening this test's assertion -
    # this is Decision 1's mechanical reason (reason 1), pinned end to end.
    test "an <assign> inside an <if> partition is visible to a later node in the same enclosing block" do
      m =
        @if_document
        |> compile!()
        |> machine_with_node(2, %ContextRecorder{c_index: 2, label: "r2"})

      ms = machine_state(m)
      ms = %{ms | datamodel: Map.put(ms.datamodel, "x", nil)}
      [block] = a_onentry_blocks(m)

      {_result, effects} = Content.execute_block(ms, @owner, block.content)

      assert [{:log, %Effect.Log{label: "r2", value: datamodel_context}} | _rest] = effects
      assert Evaluator.evaluate(datamodel_context, compiled_expr("x")) == {:ok, 2}
    end

    @failing_if_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <if cond="true">
                    <log label="before"/>
                </if>
                <log label="never"/>
            </onentry>
        </state>
    </scxml>
    """

    # sabotage: `Statifier.Interpreter.Content.run_nodes/2`'s `{:error,
    # new_context, reason}` arm is changed to halt with `{c_index, {:some,
    # reason}}` (double-wrapping) instead of passing `reason` through as
    # `Statifier.Machine.Content.If`'s own `{:nested_content, _, _}` value
    # unwrapped -> the `data ==` pattern match below reddens.
    test "a failing partition node halts the enclosing block, raising exactly one error.execution whose data names the inner node" do
      m =
        @failing_if_document
        |> compile!()
        |> machine_with_node(1, %TestContent{c_index: 1, label: "boom", fail: true})

      ms = machine_state(m)
      [block] = a_onentry_blocks(m)

      {result, _effects} = Content.execute_block(ms, @owner, block.content)

      assert [error_event] = MachineState.internal_events(result)
      assert error_event.name == "error.execution"
      assert error_event.type == :platform
      assert error_event.cause.origin == {:content, 0, @owner}
      assert error_event.data == {:nested_content, 1, {:test_content, "boom"}}
    end

    @erroring_cond_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <if cond="undefined_var">
                    <log label="unreachable"/>
                    <elseif cond="true"/>
                    <log label="reached"/>
                </if>
            </onentry>
        </state>
    </scxml>
    """

    # sabotage: `Statifier.Machine.Content.If`'s `defimpl`'s `select/3`
    # collapses the `{:error, %Evaluator.Error{}}` arm into `{:ok, false}`
    # with no reason recorded -> `pending_errors` would come back `[]`, so
    # `Statifier.Interpreter.Content.drain_pending/2` would never raise, and
    # this test's error-event assertion reddens.
    test "an erroring cond raises error.execution and the block continues to the next branch" do
      m = compile!(@erroring_cond_document)
      ms = machine_state(m)
      [block] = a_onentry_blocks(m)

      {result, effects} = Content.execute_block(ms, @owner, block.content)

      assert [error_event] = MachineState.internal_events(result)
      assert error_event.name == "error.execution"
      assert error_event.type == :platform
      assert error_event.cause.origin == {:content, 0, @owner}

      assert Enum.any?(effects, &match?({:log, %Effect.Log{label: "reached"}}, &1))
      refute Enum.any?(effects, &match?({:log, %Effect.Log{label: "unreachable"}}, &1))
    end
  end
end
