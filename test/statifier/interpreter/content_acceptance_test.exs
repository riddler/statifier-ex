defmodule Statifier.Interpreter.ContentAcceptanceTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Evaluator
  alias Statifier.ExecutableContent
  alias Statifier.ExecutableContent.Context
  alias Statifier.Interpreter.Content
  alias Statifier.Interpreter.ExitEntry
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Machine.Content.Log
  alias Statifier.Machine.Content.Raise
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

  # Hand-drawn, depth-first, document order - one document covering every
  # acceptance-criteria line a test in this file can decide, so this file is
  # organized around its own AC list rather than one fixture per rule
  # (`selection_acceptance_test.exs` is the sibling this shape is borrowed
  # from).
  #
  # c-indexes, document order across the whole machine:
  #
  #  c0  <raise event="triggered"/>  - raiser's onentry
  #  c1  <log label="hello"/>        - logger's onentry
  #  c2  <raise event="one"/>        - ordered's onentry
  #  c3  <log label="mid"/>          - ordered's onentry
  #  c4  <raise event="two"/>        - ordered's onentry
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="trigger">
      <state id="trigger">
          <transition event="go" target="raiser"/>
      </state>
      <state id="raiser">
          <onentry>
              <raise event="triggered"/>
          </onentry>
      </state>
      <state id="logger">
          <onentry>
              <log label="hello"/>
          </onentry>
      </state>
      <state id="ordered">
          <onentry>
              <raise event="one"/>
              <log label="mid"/>
              <raise event="two"/>
          </onentry>
      </state>
  </scxml>
  """

  defp machine, do: compile!(@document)
  defp idx(machine, name), do: machine |> Machine.index(name) |> elem(1)

  defp onentry_content(machine, name) do
    [block] = Machine.at(machine, idx(machine, name)).onentry
    block.content
  end

  defp machine_state(machine, opts \\ [trace: true]), do: MachineState.new(machine, opts)

  # Substitutes one compiled cell with `node` - the fixture-preserving
  # technique `content_test.exs` uses: a `Machine` built by the compiler
  # with one cell replaced, never a `%Machine{}` literal.
  defp machine_with_node(machine, c_index, node) do
    %{machine | contents: put_elem(machine.contents, c_index, node)}
  end

  # AC: "ExecutableContent protocol dispatch; test-only node proves open
  # extension" - both real node kinds carry a `defimpl`, and a struct defined
  # entirely outside `lib/` (`Statifier.TestContent`) implements the same
  # protocol and runs through the block runner untouched, with no central
  # dispatcher anywhere to update.
  #
  # sabotage: n/a - `Protocol.assert_impl!/2` only proves the `defimpl`s are
  # loaded and consolidated; the end-to-end run below is exercised (and
  # sabotaged) by AC 2's document-order test and `content_test.exs`'s own
  # "a test-only node defined outside lib/ runs through the block runner
  # unmodified" test, so re-sabotaging the same dispatch path here would not
  # learn anything new.
  test "AC1: both real node kinds and a test-only node implement the protocol, and the test-only node runs end to end" do
    assert Protocol.assert_impl!(ExecutableContent, Raise) == :ok
    assert Protocol.assert_impl!(ExecutableContent, Log) == :ok
    assert Protocol.assert_impl!(ExecutableContent, TestContent) == :ok

    m = machine() |> machine_with_node(1, %TestContent{c_index: 1, label: "probe"})
    ms = machine_state(m)
    owner = {:onentry, idx(m, "logger"), 0}

    {_result, effects} = Content.execute_block(ms, owner, onentry_content(m, "logger"))

    assert [{:log, %Effect.Log{label: "probe"}}, {:trace, %Effect.Trace.ContentExecuted{}}] =
             effects
  end

  # AC: "Block runner: document order, stop-on-error (tested via failing
  # test-only node), effect order preserved"
  #
  # sabotage: `run_nodes/2` in `lib/statifier/interpreter/content.ex` is
  # changed to fold over `Enum.reverse(c_indexes)` instead of `c_indexes`
  # -> the internal queue would hold "two" before "one", reddening the
  # ordered-match assertion below.
  test "AC2: a block runs its nodes in document order, preserving effect order" do
    m = machine()
    ms = machine_state(m)
    owner = {:onentry, idx(m, "ordered"), 0}

    {result, effects} = Content.execute_block(ms, owner, onentry_content(m, "ordered"))

    assert [%{name: "one"}, %{name: "two"}] = MachineState.internal_events(result)

    assert [{:log, %Effect.Log{label: "mid"}}, {:trace, %Effect.Trace.ContentExecuted{}}] =
             effects
  end

  # sabotage: `run_nodes/2`'s `Enum.reduce_while/3` is replaced with a plain
  # `Enum.reduce/3` that ignores the `{:error, reason}` tuple and keeps
  # folding -> "two" would still reach the internal queue after the failing
  # node, reddening the refutation below.
  test "AC2: an error stops the remainder of the block from running" do
    m = machine() |> machine_with_node(3, %TestContent{c_index: 3, label: "boom", fail: true})
    ms = machine_state(m)
    owner = {:onentry, idx(m, "ordered"), 0}

    {result, _effects} = Content.execute_block(ms, owner, onentry_content(m, "ordered"))

    names = result |> MachineState.internal_events() |> Enum.map(& &1.name)
    assert "one" in names
    refute "two" in names
  end

  # AC: "Errors-are-events conversion in the runner, not in leaf nodes; only
  # the interpreter raises error.execution" - asserted structurally as well
  # as behaviorally (the behavioral half is `content_test.exs`'s "error.execution
  # is raised as a platform event..." test): no module under
  # `lib/statifier/machine/content/` mentions `error.execution` or `Event`,
  # so a future leaf that raises its own error fails here even before it
  # reaches a behavioral test.
  #
  # sabotage: a line reading `# Event error.execution` is appended to
  # `lib/statifier/machine/content/raise.ex` -> the offenders list below
  # picks it up and the `assert offenders == []` reddens. Reverted after
  # confirming.
  test "AC3: no module under lib/statifier/machine/content/ mentions error.execution or Event" do
    files = Path.wildcard(Path.join(File.cwd!(), "lib/statifier/machine/content/*.ex"))
    assert files != []

    offenders =
      for file <- files,
          text = File.read!(file),
          String.contains?(text, "error.execution") or String.contains?(text, "Event") do
        file
      end

    assert offenders == []
  end

  # AC: "<raise> queues an internal event FIFO with {:content, c_index,
  # owner} cause and the counters, and emits no effect" - the FIFO half is
  # AC 2's document-order test (two raises land in order); this test pins
  # the cause shape and the no-effect return directly off the protocol call.
  #
  # sabotage: `Raise`'s `execute/2` in
  # `lib/statifier/machine/content/raise.ex` is changed to stamp
  # `{:content, context.owner, c_index}` (arguments swapped) -> the
  # `cause.origin` equality below reddens.
  test "AC4: <raise> stamps a content cause with c_index, owner, and the current counters, and emits no effect" do
    m = machine()

    ms =
      m
      |> MachineState.new()
      |> MachineState.begin_macrostep()
      |> MachineState.begin_microstep()

    owner = {:onentry, idx(m, "raiser"), 0}
    raise_node = Machine.content(m, 0)

    context = %Context{
      machine_state: ms,
      owner: owner,
      datamodel_context: Evaluator.context(ms)
    }

    assert {:ok, new_context, []} = ExecutableContent.execute(raise_node, context)

    assert [%{name: "triggered", cause: cause}] =
             MachineState.internal_events(new_context.machine_state)

    assert cause.origin == {:content, 0, owner}
    assert cause.macrostep == ms.macrostep
    assert cause.microstep == ms.microstep
  end

  # AC: "the :log effect carries label, c_index, owner, and counters"
  #
  # sabotage: `Log`'s `execute/2` in `lib/statifier/machine/content/log.ex`
  # builds the effect with `owner: nil` instead of `owner: owner` -> the
  # `owner: ^owner` pattern below reddens.
  test "AC5: the :log effect carries label, c_index, owner, and counters" do
    m = machine()

    ms =
      m
      |> MachineState.new()
      |> MachineState.begin_macrostep()
      |> MachineState.begin_microstep()

    owner = {:onentry, idx(m, "logger"), 0}
    log_node = Machine.content(m, 1)

    context = %Context{
      machine_state: ms,
      owner: owner,
      datamodel_context: Evaluator.context(ms)
    }

    assert {:ok, ^context, [{:log, log_effect}]} = ExecutableContent.execute(log_node, context)

    assert %Effect.Log{
             label: "hello",
             c_index: 1,
             owner: ^owner,
             macrostep: macrostep,
             microstep: microstep
           } = log_effect

    assert macrostep == ms.macrostep
    assert microstep == ms.microstep
  end

  # AC: "Content-executed trace effect wraps block execution, gated, with
  # block identity"
  #
  # sabotage: `Effect.trace/3`'s call site in `execute_block/3`
  # (`lib/statifier/interpreter/content.ex`) is replaced with a bare list
  # literal that always includes the trace payload, bypassing the
  # `machine_state.trace` gate -> the `refute` below reddens.
  test "AC6: ContentExecuted wraps the block, gated by trace, carrying block identity" do
    m = machine()
    owner = {:onentry, idx(m, "ordered"), 0}
    content = onentry_content(m, "ordered")

    ms_on = machine_state(m, trace: true)
    {_ms, effects_on} = Content.execute_block(ms_on, owner, content)

    assert [%Effect.Trace.ContentExecuted{owner: ^owner, c_indexes: [2, 3, 4]}] =
             for({:trace, payload} <- effects_on, do: payload)

    ms_off = machine_state(m, trace: false)
    {_ms, effects_off} = Content.execute_block(ms_off, owner, content)

    refute Enum.any?(effects_off, &match?({:trace, _}, &1))
  end

  # AC: "Context type decision documented with the datamodel threading in
  # view" - the executable half: constructing a `%Context{}` with
  # `machine_state`, `owner`, and `datamodel_context` (the reserved slot
  # st-af3.1 Phase 3 fills) and running both real node kinds through it pins
  # the field set now, so a later change adds a field rather than silently
  # replacing the struct.
  #
  # sabotage: a fourth field (`:extra`) is added to `Statifier.ExecutableContent.Context`'s
  # `defstruct` -> the `Map.keys/1` equality below gains a fourth entry and
  # reddens, even though construction and dispatch both still succeed.
  test "AC7: Context has exactly machine_state, owner, and datamodel_context, and both node kinds run through it" do
    m = machine()
    ms = MachineState.new(m)
    owner = {:onentry, idx(m, "ordered"), 0}

    context = %Context{
      machine_state: ms,
      owner: owner,
      datamodel_context: Evaluator.context(ms)
    }

    assert context |> Map.from_struct() |> Map.keys() |> Enum.sort() == [
             :datamodel_context,
             :machine_state,
             :owner
           ]

    raise_node = Machine.content(m, 2)
    log_node = Machine.content(m, 3)

    assert {:ok, _ctx, []} = ExecutableContent.execute(raise_node, context)
    assert {:ok, _ctx, [{:log, _log_effect}]} = ExecutableContent.execute(log_node, context)
  end

  # AC 8 (sabotage: a runner that keeps executing past an error turns the
  # stop-on-error test red) has no test of its own here - it is satisfied by
  # the sabotage lines already recorded on "AC2: an error stops the
  # remainder of the block from running" above and on
  # `content_test.exs`'s stop-on-error tests, each independently verified
  # against `run_nodes/2`'s `Enum.reduce_while/3`. Recorded here as a
  # review judgment rather than as a test that asserts about tests.

  # The round trip this test can assert without the macrostep loop, which is
  # not yet implemented: `enter_states/2` over a document whose `<onentry>`
  # raises an event leaves that event on the internal queue - the closest
  # this test gets to "a microstep worked".
  #
  # sabotage: `execute_block/3` in `lib/statifier/interpreter/exit_entry.ex`
  # is reverted to the no-op stub (`defp execute_block(machine_state,
  # _owner, _c_indexes), do: {machine_state, []}`) -> the internal queue
  # stays empty, reddening the assertion below (the same mutation
  # `exit_entry_enter_test.exs`'s "the onentry seam is live" test verifies;
  # restated here because this round trip is a documented acceptance line
  # for this module).
  test "round-trip: enter_states/2 over a document whose onentry raises an event leaves it on the internal queue" do
    m = machine()
    transition = m.transitions |> Tuple.to_list() |> Enum.find(&(&1.events == [["go"]]))
    ms = MachineState.new(m)

    {result, _effects} = ExitEntry.enter_states(ms, [transition])

    assert [%{name: "triggered", type: :internal}] = MachineState.internal_events(result)
  end
end
