defmodule Statifier.Interpreter.ContentTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Interpreter.Content
  alias Statifier.Interpreter.ExitEntry
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.MachineState
  alias Statifier.Parser
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

  # sabotage: `execute_block/3`'s `[]` clause is dropped, falling through to
  # the general clause -> an empty block would still build a `Context` and
  # emit a spurious `ContentExecuted` trace effect, reddening this equality.
  test "an empty block returns the machine_state unchanged and no effects, even with trace: true" do
    m = machine()
    ms = machine_state(m, trace: true)
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
end
