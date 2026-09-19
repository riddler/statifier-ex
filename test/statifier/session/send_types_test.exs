defmodule Statifier.Session.SendTypesTest do
  use ExUnit.Case, async: false

  # ADR-0069 decision 2 at the session: `:send_types` and
  # `:inherit_send_types` on `Statifier.Session.start_link/2`, stamped at
  # both boot arms, and the start-time refusal of a built-in spelling.
  # `async: false`: the inheritance tests start real children on
  # `Statifier.SessionSupervisor`, as `invoke_handler_inheritance_test.exs`
  # does. These tests read the core's stamp; the planner's hand-off of a
  # registered type is not part of this change.

  alias Statifier.{Position, Session}
  alias Statifier.Send.Types
  alias Statifier.Session.{Invocations, Recording}

  defmodule SinkProcessor do
    @moduledoc false
  end

  @send_types %{"myapp:sink" => SinkProcessor}

  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  @child_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle"><state id="idle"/></scxml>)

  @parent_xml """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <invoke type="scxml">
              <content><![CDATA[#{@child_xml}]]></content>
          </invoke>
      </state>
  </scxml>
  """

  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  defp wait_until(pred, attempts \\ 50)
  defp wait_until(_pred, 0), do: flunk("condition never became true")

  defp wait_until(pred, attempts) do
    if pred.() do
      :ok
    else
      Process.sleep(5)
      wait_until(pred, attempts - 1)
    end
  end

  defp start_child_of(opts) do
    {:ok, parent} = Session.start_link(compile!(@parent_xml), opts)
    wait_until(fn -> Invocations.count(:sys.get_state(parent).invocations) == 1 end)
    [%{pid: child}] = Session.invocations(parent)
    child
  end

  describe "the registration refusal" do
    # `Session.start_link/2` links the caller to the process it starts, and a
    # refusal in `init/1` exits that process with the refusal as its reason;
    # trapping exits lets the `{:error, _}` return be asserted directly.
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    # sabotage: `init_registered/3`'s `case` is replaced by a direct
    # `init_boot(machine, opts, resume)` call -> a map naming `"scxml"`
    # boots, `start_link/2` returns `{:ok, _}`, and this `{:error, _}` match
    # reddens. Confirmed red and reverted.
    test "a map naming a built-in spelling is refused before the session boots" do
      assert {:error, {:send_types, {:built_in_types, ["scxml"]}}} =
               Session.start_link(compile!(@chart),
                 send_types: Map.put(@send_types, "scxml", SinkProcessor)
               )
    end

    # sabotage: `built_in_send_types/1`'s filter is changed to
    # `&(SendTypes.classify(nil, &1) == :registered)` (never true against no
    # declaration) -> every built-in spelling is let through, the session
    # boots, and this `{:error, _}` match reddens. Confirmed red and reverted.
    test "every built-in spelling is named, sorted, in one refusal" do
      uri = "http://www.w3.org/TR/scxml/#SCXMLEventProcessor"

      send_types = %{
        "scxml" => SinkProcessor,
        nil => SinkProcessor,
        uri => SinkProcessor,
        "myapp:sink" => SinkProcessor
      }

      assert {:error, {:send_types, {:built_in_types, [nil, ^uri, "scxml"]}}} =
               Session.start_link(compile!(@chart), send_types: send_types)
    end

    # sabotage: `init_registered/3`'s `[] -> init_boot(machine, opts,
    # resume)` arm is changed to `[] -> {:stop, {:send_types,
    # {:built_in_types, []}}}` -> a map naming only host types is refused,
    # and this `{:ok, _}` match reddens. Confirmed red and reverted.
    test "a map naming only host types boots" do
      assert {:ok, _session} = Session.start_link(compile!(@chart), send_types: @send_types)
    end
  end

  describe "the stamp at both boot arms" do
    # sabotage: `boot/7`'s fresh clause drops its `Keyword.put(:send_types,
    # SendTypes.from_send_types(send_types))` line -> the core boots with
    # `send_types: nil`, and the equality reddens. Confirmed red and
    # reverted.
    test "a fresh start stamps the snapshot derived from the map" do
      {:ok, session} = Session.start_link(compile!(@chart), send_types: @send_types)

      assert Session.snapshot(session).send_types == Types.from_send_types(@send_types)
    end

    # sabotage: `boot/7`'s resumed clause drops its
    # `MachineState.put_send_types/2` call -> the decoded position's `nil`
    # survives, and the equality reddens. Confirmed red and reverted.
    test "a resume stamps the snapshot onto the persisted position" do
      machine = compile!(@chart)
      {:ok, first} = Session.start_link(machine, send_types: @send_types)
      assert {:ok, blob} = Position.to_binary(Session.snapshot(first))
      :ok = Session.stop(first)

      {:ok, resumed} = Session.start_link(machine, resume: blob, send_types: @send_types)

      assert Session.snapshot(resumed).send_types == Types.from_send_types(@send_types)
    end

    # sabotage: `Types.from_send_types/1`'s empty-map clause is deleted -> a
    # session started with no `:send_types` is stamped with an empty
    # `%Types{}`, and the `== nil` assertion reddens. Confirmed red and
    # reverted.
    test "no :send_types stamps nil and records no :send_types key" do
      {:ok, session} = Session.start_link(compile!(@chart), record: true)

      assert Session.snapshot(session).send_types == nil
      assert {:ok, recording} = Session.recording(session)
      refute Keyword.has_key?(Recording.opts(recording), :send_types)
    end

    # sabotage: `init_boot/3`'s recording line passes `machine_opts` unchanged
    # (the `Keyword.put(machine_opts, :send_types, send_types)` dropped) ->
    # the recording keeps the derived `%Types{}` snapshot instead of the
    # map, and the equality reddens. Confirmed red and reverted.
    test "a recording session records the :send_types map itself" do
      {:ok, session} =
        Session.start_link(compile!(@chart), record: true, send_types: @send_types)

      assert {:ok, recording} = Session.recording(session)
      assert Keyword.fetch(Recording.opts(recording), :send_types) == {:ok, @send_types}
    end
  end

  describe ":inherit_send_types" do
    # sabotage: `inherited_send_type_opts/1`'s
    # `%State{inherit_send_types: false}` clause is deleted -> a parent that
    # never opted in still hands its map down, the child is stamped, and the
    # `== nil` assertion reddens. Confirmed red and reverted.
    test "default off: an invoked child registers no send type" do
      child = start_child_of(send_types: @send_types)

      assert Session.snapshot(child).send_types == nil
    end

    # sabotage: `inherited_send_type_opts/1`'s `true`-shaped clause returns
    # `[]` -> the child boots with no map, and the equality reddens.
    # Confirmed red and reverted.
    test "on: an invoked child is stamped from the parent's map" do
      child = start_child_of(send_types: @send_types, inherit_send_types: true)

      assert Session.snapshot(child).send_types == Types.from_send_types(@send_types)
      assert :sys.get_state(child).inherit_send_types == true
    end
  end
end
