defmodule Statifier.Machine.Content.SendRegisteredTypeTest do
  use ExUnit.Case, async: true

  # ADR-0069 decisions 1-3 at the pure core: `reject_reason/4` answers
  # through `Statifier.Send.Types.classify/2` against the stamped
  # `send_types`. Nothing here drives a `Statifier.Session`.

  alias Statifier.{Effect, Evaluator, ExecutableContent, Machine, MachineState}
  alias Statifier.ExecutableContent.Context
  alias Statifier.Interpreter.{Content, Datamodel}
  alias Statifier.Send.{Routes, Types}

  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="sink">
      <datamodel>
          <data id="x" expr="0"/>
          <data id="impression_id" expr="'imp-1'"/>
      </datamodel>
      <state id="sink">
          <onentry>
              <send type="myapp:sink" target="joined_records" event="impression.joined">
                  <param name="impression_id" expr="impression_id"/>
              </send>
          </onentry>
      </state>
      <state id="session_shaped">
          <onentry>
              <send type="myapp:execution" target="#_scxml_click_attribution" event="click.recorded"/>
          </onentry>
      </state>
      <state id="delayed">
          <onentry>
              <send type="myapp:sink" target="joined_records" event="late" delay="1s"/>
          </onentry>
      </state>
      <state id="undeclared">
          <onentry>
              <send type="myapp:other" target="joined_records" event="e"/>
              <assign location="x" expr="1"/>
          </onentry>
      </state>
  </scxml>
  """

  @send_types %{"myapp:sink" => SinkProcessor, "myapp:execution" => ExecutionProcessor}

  defp machine do
    {:ok, machine} = Statifier.compile(@document)
    machine
  end

  defp idx(machine, name), do: machine |> Machine.index(name) |> elem(1)

  defp first_node(machine, name) do
    [block] = Machine.at(machine, idx(machine, name)).onentry
    [c_index | _rest] = block.content
    Machine.content(machine, c_index)
  end

  defp machine_state(m, opts) do
    {ms, _effects} = m |> MachineState.new(opts) |> Datamodel.initialize()
    ms
  end

  defp context(ms),
    do: %Context{
      machine_state: ms,
      owner: {:onentry, 0, 0},
      datamodel_context: Evaluator.context(ms)
    }

  describe "a registered type dispatches with its target unread" do
    # sabotage: `reject_reason/4`'s `class == :registered -> nil` clause is
    # deleted, so a registered type falls through to the built-in arms ->
    # `Target.parse("joined_records")` is `{:invalid, _}`, the send rejects
    # as `{:invalid_target, "joined_records"}`, and this match reddens.
    # Confirmed red and reverted.
    test "a target C.1 would call invalid is carried verbatim, never parsed" do
      m = machine()
      ms = machine_state(m, send_types: Types.from_send_types(@send_types))

      assert {:ok, _ctx,
              [
                {:send,
                 %Effect.Send{
                   type: "myapp:sink",
                   target: "joined_records",
                   event: "impression.joined",
                   data: %{"impression_id" => "imp-1"}
                 }}
              ]} = ExecutableContent.execute(first_node(m, "sink"), context(ms))
    end

    # sabotage: same mutation as above (the `class == :registered -> nil`
    # clause deleted) -> the session-shaped target parses to
    # `{:session, "click_attribution"}`, the snapshot below does not name
    # it, and the send rejects as `{:communication, {:unreachable_target,
    # _}}`, reddening this match. Confirmed red and reverted.
    test "the ADR-0048 route snapshot is not consulted for a registered type" do
      m = machine()

      ms =
        machine_state(m,
          send_types: Types.from_send_types(@send_types),
          routes: Routes.new(sessions: ["someone_else"])
        )

      assert {:ok, _ctx,
              [
                {:send,
                 %Effect.Send{type: "myapp:execution", target: "#_scxml_click_attribution"}}
              ]} =
               ExecutableContent.execute(first_node(m, "session_shaped"), context(ms))
    end

    # sabotage: same mutation as above (the `class == :registered -> nil`
    # clause deleted) -> the delayed send's target is parsed and rejected as
    # `{:invalid_target, "joined_records"}`, and this match reddens.
    # Confirmed red and reverted.
    test "a delayed send of a registered type builds its Effect.SendDelayed" do
      m = machine()
      ms = machine_state(m, send_types: Types.from_send_types(@send_types))

      assert {:ok, _ctx,
              [
                {:send_delayed,
                 %Effect.SendDelayed{type: "myapp:sink", target: "joined_records", delay_ms: 1000}}
              ]} = ExecutableContent.execute(first_node(m, "delayed"), context(ms))
    end

    # sabotage: `reject_reason/4` reads `nil` in place of the stamped
    # `send_types` (`Types.classify(nil, type)`) -> the registered type is
    # `:unsupported` and rejects, reddening this match. Confirmed red and
    # reverted.
    test "the stamped set is what the core judges against" do
      m = machine()
      ms = machine_state(m, send_types: Types.from_send_types(%{"myapp:sink" => SinkProcessor}))

      assert {:ok, _ctx, [{:send, %Effect.Send{type: "myapp:sink"}}]} =
               ExecutableContent.execute(first_node(m, "sink"), context(ms))
    end

    # sabotage: `Statifier.Send.Types`'s `declared?(nil, _type)` clause is
    # changed to return `true` -> with no declaration every host type is
    # `:registered`, the send dispatches, and the rejection match reddens.
    # Confirmed red and reverted.
    test "with no declaration a host type is still refused, as before" do
      m = machine()
      ms = machine_state(m, [])

      assert ms.send_types == nil

      assert {:error, _ctx,
              {:send_rejected, _send_id, :execution, {:unsupported_type, "myapp:sink"}}} =
               ExecutableContent.execute(first_node(m, "sink"), context(ms))
    end
  end

  describe "an undeclared type against a declared set" do
    # 4.9's block abort for 6.2.5's unsupported type, through the real block
    # runner: the <send> is the first node of a block whose second node is
    # an <assign>, which must never run.
    #
    # sabotage: `reject_reason/4`'s `class == :unsupported ->` clause is
    # changed to `class == :never ->` (never firing) -> the undeclared type
    # falls through to the built-in arms, `Target.parse("joined_records")` is
    # `{:invalid, _}`, and the event's data becomes `{:invalid_target,
    # "joined_records"}`, reddening the `error_event.data` assertion.
    # Confirmed red and reverted.
    test "raises error.execution, aborts the block, and produces no effect" do
      m = machine()
      undeclared = idx(m, "undeclared")
      [block] = Machine.at(m, undeclared).onentry
      [send_c, _assign_c] = block.content
      owner = {:onentry, undeclared, 0}

      ms = machine_state(m, send_types: Types.from_send_types(@send_types))

      {result, effects} = Content.execute_block(ms, owner, block.content)

      assert result.datamodel["x"] == 0
      assert [error_event] = MachineState.internal_events(result)
      assert error_event.name == "error.execution"
      assert error_event.cause.origin == {:content, send_c, owner}
      assert error_event.data == {:unsupported_type, "myapp:other"}
      assert error_event.sendid != nil

      refute Enum.any?(effects, &match?({:send, _}, &1))
      refute Enum.any?(effects, &match?({:send_delayed, _}, &1))
    end
  end
end
