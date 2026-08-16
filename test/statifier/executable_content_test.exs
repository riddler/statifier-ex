defmodule Statifier.ExecutableContentTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Evaluator
  alias Statifier.ExecutableContent
  alias Statifier.ExecutableContent.Context
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Machine.Content.Log
  alias Statifier.Machine.Content.Raise
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Parser.Location
  alias Statifier.TestContent
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Two <raise>s, then a label-only <log>, then a <log expr=...>, all in one
  # onentry block so a single compile gives every node under test its own
  # c_index. A `<log expr=...>` always compiles through
  # `Statifier.Compiler.Expressions.compile/3` to a `{:compiled, ...}` expr
  # (there is no XML shape that produces `{:static, _}` for `<log>` -
  # `{:static, _}` is reserved for a literal `<donedata><content>` text
  # body), so the static-value case below builds a `%Log{}` by hand instead
  # of through this document.
  #
  #  c0  first raise ("one")
  #  c1  second raise ("two")
  #  c2  log label="x"
  #  c3  log expr="1 + 1" (compiled)
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <onentry>
              <raise event="one"/>
              <raise event="two"/>
              <log label="x"/>
              <log expr="1 + 1"/>
          </onentry>
      </state>
  </scxml>
  """

  defp machine, do: compile!(@document)

  defp location, do: Location.at_offset("", 0)

  defp state_a_content(machine) do
    {:ok, a_index} = Machine.index(machine, "a")
    a = Machine.at(machine, a_index)
    [onentry_block] = a.onentry
    onentry_block.content
  end

  defp context(machine_state, owner) do
    %Context{
      machine_state: machine_state,
      owner: owner,
      datamodel_context: Evaluator.context(machine_state)
    }
  end

  @owner {:onentry, 0, 0}

  describe "<raise>" do
    # sabotage: the <raise> impl passes `{:content, c_index}` without the
    # owner (dropping `context.owner` from the tuple) -> the cause-origin
    # pattern match below reddens.
    test "enqueues one internal event, FIFO after an event already queued, with the right cause" do
      m = machine()
      [raise0_c, raise1_c, _log_x, _log_compiled] = state_a_content(m)
      raise0 = Machine.content(m, raise0_c)
      raise1 = Machine.content(m, raise1_c)

      ms =
        m
        |> MachineState.new()
        |> MachineState.begin_macrostep()
        |> MachineState.begin_microstep()
        |> MachineState.enqueue_internal(Statifier.Event.external("already-queued"))

      ctx = context(ms, @owner)

      assert {:ok, ctx1, []} = ExecutableContent.execute(raise0, ctx)
      assert {:ok, ctx2, []} = ExecutableContent.execute(raise1, ctx1)

      assert [
               %Statifier.Event{name: "already-queued", type: :external, cause: nil},
               %Statifier.Event{name: "one", type: :internal, cause: cause0},
               %Statifier.Event{name: "two", type: :internal, cause: cause1}
             ] = MachineState.internal_events(ctx2.machine_state)

      assert cause0.origin == {:content, raise0_c, @owner}
      assert cause1.origin == {:content, raise1_c, @owner}
      assert cause0.macrostep == 1
      assert cause0.microstep == 1
      assert cause0.macrostep == cause1.macrostep
      assert cause0.microstep == cause1.microstep
    end

    # sabotage: the <raise> impl returns an effect alongside the enqueue
    # (e.g. `{:ok, ctx, [{:log, %Statifier.Effect.Log{...}}]}`) -> this
    # assertion reddens.
    test "returns an empty effect list" do
      m = machine()
      [raise0_c, _raise1_c, _log_x, _log_compiled] = state_a_content(m)
      raise0 = Machine.content(m, raise0_c)
      ms = MachineState.new(m)

      assert {:ok, _ctx, []} = ExecutableContent.execute(raise0, context(ms, @owner))
    end
  end

  describe "<log>" do
    # sabotage: the <log> impl hardcodes `owner: nil` instead of `owner:
    # owner` (dropping the context's owner) -> this assertion reddens.
    test "label-only <log> returns one :log effect with the label, nil value, its c_index, owner, and counters" do
      m = machine()
      [_raise0_c, _raise1_c, log_x_c, _log_compiled_c] = state_a_content(m)
      log_x = Machine.content(m, log_x_c)

      ms =
        m
        |> MachineState.new()
        |> MachineState.begin_macrostep()
        |> MachineState.begin_microstep()

      assert {:ok, ctx, [{:log, effect}]} =
               ExecutableContent.execute(log_x, context(ms, @owner))

      assert %Statifier.Effect.Log{
               label: "x",
               value: nil,
               c_index: ^log_x_c,
               owner: @owner,
               macrostep: 1,
               microstep: 1
             } = effect

      assert ctx.machine_state == ms
    end

    # sabotage: the <log> impl emits the label as the value (`value:
    # node.label` instead of `value: value(node)`) -> this assertion
    # reddens, since a `{:static, 2}` expr carries the static integer, not
    # the string label.
    test "static expr <log> carries the static value" do
      log_static = %Log{c_index: 99, location: location(), label: nil, expr: {:static, 2}}
      ms = MachineState.new(machine())

      assert {:ok, _ctx, [{:log, %Statifier.Effect.Log{value: 2, label: nil}}]} =
               ExecutableContent.execute(log_static, context(ms, @owner))
    end

    # sabotage: `value/2`'s general clause returns `{:ok, nil}`
    # unconditionally instead of delegating to `Evaluator.evaluate/2` ->
    # this assertion reddens, since "1 + 1" evaluates to `2`, not `nil`.
    # (verified: also reddens "static expr <log> carries the static value"
    # above and the failing-expr test below, since all three share this
    # clause.)
    test "compiled expr <log> carries the evaluated value" do
      m = machine()
      [_raise0_c, _raise1_c, _log_x_c, log_compiled_c] = state_a_content(m)
      log_compiled = Machine.content(m, log_compiled_c)

      assert %Log{expr: {:compiled, %Predicator.Compiled{}, "1 + 1"}} = log_compiled

      ms = MachineState.new(m)

      assert {:ok, _ctx, [{:log, %Statifier.Effect.Log{value: 2}}]} =
               ExecutableContent.execute(log_compiled, context(ms, @owner))
    end

    # sabotage: `value/2`'s general clause returns `{:ok, nil}`
    # unconditionally instead of delegating to `Evaluator.evaluate/2` ->
    # this assertion reddens, since `execute/2` would then see `{:ok, nil}`
    # and build a `%Effect.Log{}` instead of short-circuiting to
    # `{:error, reason}`.
    test "a failing compiled expr <log> returns {:error, _} with no :log effect" do
      {:ok, compiled} = Predicator.compile_with_spans("undeclared_identifier")

      log_failing = %Log{
        c_index: 42,
        location: location(),
        label: nil,
        expr: {:compiled, compiled, "undeclared_identifier"}
      }

      ms = MachineState.new(machine())

      assert {:error, _reason} = ExecutableContent.execute(log_failing, context(ms, @owner))
    end

    # sabotage: the <log> impl returns `{:ok, %{context | machine_state:
    # MachineState.begin_microstep(context.machine_state)}, effects}` (some
    # incidental mutation) instead of the untouched context -> this equality
    # reddens.
    test "returns the given machine_state unchanged" do
      m = machine()
      [_raise0_c, _raise1_c, log_x_c, _log_compiled_c] = state_a_content(m)
      log_x = Machine.content(m, log_x_c)
      ms = MachineState.new(m)

      assert {:ok, %Context{machine_state: ^ms}, _effects} =
               ExecutableContent.execute(log_x, context(ms, @owner))
    end
  end

  describe "the test-only node (open extension)" do
    # sabotage: n/a - this test proves a struct defined outside lib/
    # implements the protocol; it asserts no lib/ behavior of its own (the
    # protocol dispatch mechanism itself is what would break, and no
    # plausible single-line lib/ mutation targets this test specifically).
    test "dispatches through the protocol and returns its marker effect" do
      ms = MachineState.new(machine())
      node = %TestContent{c_index: 0, label: "probe"}

      assert {:ok, %Context{}, [{:log, %Statifier.Effect.Log{label: "probe"}}]} =
               ExecutableContent.execute(node, context(ms, @owner))
    end

    # sabotage: n/a - this exercises TestContent's own `fail: true` branch
    # (test/support/test_content.ex, exempt harness plumbing), not any
    # lib/ behavior; there is no runner in this phase to convert the error.
    test "in failing mode returns {:error, _} and changes nothing" do
      ms = MachineState.new(machine())
      node = %TestContent{c_index: 0, label: "probe", fail: true}

      assert {:error, {:test_content, "probe"}} =
               ExecutableContent.execute(node, context(ms, @owner))
    end
  end

  describe "Context.t()'s pending_errors default" do
    # sabotage: `@enforce_keys` on `Statifier.ExecutableContent.Context` is
    # widened to include `:pending_errors` -> every `%Context{...}` literal
    # in this suite (and every other test file) that omits it fails to
    # compile, reddening the whole file rather than just this test.
    test "a hand-built %Context{} omitting pending_errors defaults it to []" do
      ms = MachineState.new(machine())
      ctx = context(ms, @owner)

      assert %Context{pending_errors: []} = ctx
    end
  end

  describe "Protocol.assert_impl!/2" do
    # sabotage: the `defimpl Statifier.ExecutableContent` block is commented
    # out of raise.ex -> `Protocol.assert_impl!/2` raises `ArgumentError`
    # instead of returning, reddening this test.
    test "Content.Raise implements ExecutableContent" do
      assert Protocol.assert_impl!(ExecutableContent, Raise)
    end

    # sabotage: the `defimpl Statifier.ExecutableContent` block is commented
    # out of log.ex -> `Protocol.assert_impl!/2` raises `ArgumentError`
    # instead of returning, reddening this test.
    test "Content.Log implements ExecutableContent" do
      assert Protocol.assert_impl!(ExecutableContent, Log)
    end
  end
end
