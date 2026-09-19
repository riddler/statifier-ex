defmodule Statifier.Session.FailedSendTest do
  use ExUnit.Case, async: false

  # ADR-0069 decision 5 and its `_ioprocessors` consequence: a host reports a
  # registered type's miss through `Statifier.Session.failed_send/3`, the
  # sender reads C.1's `error.communication` carrying the send id, a
  # finished or absent sender takes nothing, and `_ioprocessors` names each
  # registered type, fresh and after a resume. `async: false`: each session
  # registers a `:global` name for its processor to find the test by.

  alias Statifier.Effect.{Send, SendDelayed}
  alias Statifier.{Interpreter, MachineState, Position, Session}
  alias Statifier.Send.Types
  alias Statifier.Session.Recording

  @scxml_uri "http://www.w3.org/TR/scxml/#SCXMLEventProcessor"

  defmodule Sink do
    @moduledoc false
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(effect, _event, _ctx), do: {:ok, [{:handler, __MODULE__, effect}]}

    @impl Statifier.Send.Processor
    def cancel(_cancel, _ctx), do: {:ok, []}

    # The test registers itself under the session's id before the session
    # starts, so every handed send reaches the test that owns it.
    @impl Statifier.Send.Processor
    def perform(effect, %{session_id: session_id}) do
      case :global.whereis_name({__MODULE__, session_id}) do
        pid when is_pid(pid) -> send(pid, {__MODULE__, effect})
        :undefined -> :ok
      end

      :ok
    end

    @impl Statifier.Send.Processor
    def ioprocessors_entry(type), do: %{"location" => type <> "/joined_records"}
  end

  defmodule Bare do
    @moduledoc false
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(_effect, _event, _ctx), do: {:ok, []}

    @impl Statifier.Send.Processor
    def cancel(_cancel, _ctx), do: {:ok, []}
  end

  @send_types %{"myapp:sink" => Sink}

  # The named send's miss moves the chart to `missed` and keeps the event's
  # `sendid`; the unnamed send's miss does the same through `unnamed`.
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="waiting">
      <datamodel>
          <data id="missed_sendid"/>
      </datamodel>
      <state id="waiting">
          <transition event="join" target="joining"/>
          <transition event="join_unnamed" target="joining_unnamed"/>
      </state>
      <state id="joining">
          <onentry>
              <send type="myapp:sink" target="joined_records" event="impression.joined" id="joined"/>
          </onentry>
          <transition event="error.communication" target="missed">
              <assign location="missed_sendid" expr="_event.sendid"/>
          </transition>
      </state>
      <state id="joining_unnamed">
          <onentry>
              <send type="myapp:sink" target="joined_records" event="impression.joined"/>
          </onentry>
          <transition event="error.communication" target="missed">
              <assign location="missed_sendid" expr="_event.sendid"/>
          </transition>
      </state>
      <state id="missed"/>
      <final id="done"/>
  </scxml>
  """

  @final_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="joining">
      <state id="joining">
          <onentry>
              <send type="myapp:sink" target="joined_records" event="impression.joined" id="joined"/>
          </onentry>
          <transition event="finish" target="done"/>
          <transition event="error.communication" target="missed"/>
      </state>
      <state id="missed"/>
      <final id="done"/>
  </scxml>
  """

  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  # Starts a session registering `@send_types`, with the test registered
  # under its id so `Sink.perform/2` reaches this process.
  defp start!(xml, opts \\ []) do
    session_id = MachineState.generate_session_id()
    :yes = :global.register_name({Sink, session_id}, self())
    on_exit(fn -> :global.unregister_name({Sink, session_id}) end)

    {:ok, session} =
      Session.start_link(
        compile!(xml),
        Keyword.merge([session_id: session_id, send_types: @send_types], opts)
      )

    session
  end

  defp handed! do
    assert_receive {Sink, effect}, 1_000
    effect
  end

  defp active(session), do: Statifier.active_leaf_states(Session.snapshot(session))

  describe "failed_send/3 with a live sender" do
    # sabotage: the ordinary `{:failed_send, _, _}` clause returns
    # `{:noreply, state}` without calling `deliver_internal/6` -> no
    # `error.communication` reaches the chart, it stays in `joining`, and
    # the configuration assertion reddens. Confirmed red and reverted.
    test "the sender reads error.communication carrying the send's sendid" do
      session = start!(@chart)
      :ok = Session.send_event(session, "join")
      %Send{send_id: "joined"} = send = handed!()

      assert Session.failed_send(session, send, reason: "no_route") == :ok

      assert active(session) == MapSet.new(["missed"])
      assert Session.snapshot(session).datamodel["missed_sendid"] == "joined"
    end

    # sabotage: the ordinary clause passes `[sendid: nil]` -> the chart's
    # `missed_sendid` reads undefined rather than the minted id, and the
    # equality reddens. A gate on `id_from_author?`, as a delivered event's
    # `sendid` has, reddens the same way. Confirmed red and reverted.
    test "an unnamed send's miss carries its minted send id" do
      session = start!(@chart)
      :ok = Session.send_event(session, "join_unnamed")
      %Send{id_from_author?: false, send_id: send_id} = send = handed!()
      assert is_binary(send_id)

      :ok = Session.failed_send(session, send)

      assert active(session) == MapSet.new(["missed"])
      assert Session.snapshot(session).datamodel["missed_sendid"] == send_id
    end

    # sabotage: the ordinary clause builds its origin as `{:content,
    # send.c_index + 1, send.owner}` -> the recorded internal entry names
    # another content index, and the origin match reddens. Confirmed red
    # and reverted.
    test "the error is written through the internal door, at the send's own position" do
      session = start!(@chart, record: true)
      :ok = Session.send_event(session, "join")
      send = handed!()

      :ok = Session.failed_send(session, send)
      assert active(session) == MapSet.new(["missed"])

      {:ok, recording} = Session.recording(session)
      origin = {:content, send.c_index, send.owner}

      assert Enum.any?(Recording.entries(recording), fn entry ->
               match?(
                 {:internal, :platform, "error.communication", ^origin, _opts, _routes},
                 entry
               )
             end)
    end
  end

  describe "the dead-letter rule: nothing is written for a finished or absent sender" do
    # sabotage: the `when state.halted in [:done, :cancelled]` clause is
    # deleted -> the ordinary clause records an internal entry for the
    # finished session, the recording grows, and the equality reddens.
    # Confirmed red and reverted.
    test "a sender that reached a final state returns :ok and writes nothing" do
      session = start!(@final_chart, record: true)
      send = handed!()
      :ok = Session.send_event(session, "finish")
      assert Session.status(session).status == :done

      {:ok, before} = Session.recording(session)
      snapshot = Session.snapshot(session)

      assert Session.failed_send(session, send, reason: "no_route") == :ok

      assert Session.recording(session) == {:ok, before}
      assert Session.snapshot(session) == snapshot
      assert Session.status(session).status == :done
    end

    # sabotage: `failed_send/3` calls `GenServer.call/2` instead of
    # `GenServer.cast/2` -> the call to a stopped process exits, and the
    # test process crashes instead of reading `:ok`. Confirmed red and
    # reverted.
    test "a sender that no longer exists returns :ok and raises nothing" do
      session = start!(@final_chart)
      send = handed!()
      :ok = Session.stop(session)
      refute Process.alive?(session)

      assert Session.failed_send(session, send) == :ok
    end
  end

  describe "a process-less host makes the same write" do
    # sabotage: `Interpreter.deliver_internal/5`'s `:platform` arm calls
    # `MachineState.raise_internal/4` instead of `raise_platform/4` -> the
    # event reads `type` "internal", and the equality on `_event.type`
    # reddens. Confirmed red and reverted.
    test "deliver_internal/5 with the documented arguments delivers the miss" do
      machine = compile!(@final_chart)
      types = Types.from_send_types(@send_types)
      {machine_state, effects} = Interpreter.initialize(machine, send_types: types)
      [send] = for {:send, %Send{} = send} <- effects, do: send

      assert {:ok, machine_state, _effects} =
               Interpreter.deliver_internal(
                 machine_state,
                 :platform,
                 "error.communication",
                 {:content, send.c_index, send.owner},
                 sendid: send.send_id
               )

      assert Statifier.active_leaf_states(machine_state) == MapSet.new(["missed"])
      assert machine_state.datamodel["_event"]["type"] == "platform"
      assert machine_state.datamodel["_event"]["sendid"] == "joined"
    end

    # sabotage: `Interpreter.deliver_internal/5`'s `running: false` clause is
    # deleted -> a finished position is written to and advances, and the
    # `{:error, :not_running}` match reddens. Confirmed red and reverted.
    test "a finished position answers {:error, :not_running}" do
      send = %SendDelayed{
        event: "impression.joined",
        type: "myapp:sink",
        target: "joined_records",
        send_id: "joined",
        delay_ms: 10,
        ordinal: 1,
        c_index: 0,
        macrostep: 0,
        microstep: 0,
        round: 0
      }

      finished = %{MachineState.new(compile!(@final_chart)) | running: false}

      assert Interpreter.deliver_internal(
               finished,
               :platform,
               "error.communication",
               {:content, send.c_index, send.owner},
               sendid: send.send_id
             ) == {:error, :not_running}
    end
  end

  describe "_ioprocessors names each registered type" do
    # sabotage: `MachineState.new/2` calls `SystemVariables.initial/2`
    # (dropping `:send_types`) -> the registered entry is missing, and the
    # equality reddens. Confirmed red and reverted.
    test "a fresh session carries the processor's entry and the SCXML entry unchanged" do
      session = start!(@chart)
      session_id = Session.session_id(session)

      assert Session.snapshot(session).datamodel["_ioprocessors"] == %{
               @scxml_uri => %{"location" => "#_scxml_" <> session_id},
               "myapp:sink" => %{"location" => "myapp:sink/joined_records"}
             }
    end

    # sabotage: `Types.from_send_types/1`'s `entry!/2` calls the callback
    # unguarded -> `Bare`, which does not export it, raises
    # `UndefinedFunctionError` in `init/1`, and the start match reddens.
    # Confirmed red and reverted.
    test "a processor without the callback gets an empty entry" do
      {:ok, session} =
        Session.start_link(compile!(@chart), send_types: %{"myapp:bare" => Bare})

      assert Session.snapshot(session).datamodel["_ioprocessors"]["myapp:bare"] == %{}
    end

    # sabotage: `registered_entries/1`'s `nil` clause returns a stray entry
    # -> a session with no `:send_types` carries more than the SCXML entry,
    # and the equality reddens. Confirmed red and reverted.
    test "with no :send_types the map is the SCXML entry alone" do
      {:ok, session} = Session.start_link(compile!(@chart))
      session_id = Session.session_id(session)

      assert Session.snapshot(session).datamodel["_ioprocessors"] == %{
               @scxml_uri => %{"location" => "#_scxml_" <> session_id}
             }
    end

    # sabotage: `Position.to_binary/1` drops `"_ioprocessors"` from the
    # datamodel it encodes -> the resumed session reads no registered entry,
    # and the equality reddens. Confirmed red and reverted.
    test "a resumed session reads the entries it started with" do
      machine = compile!(@chart)
      {:ok, first} = Session.start_link(machine, send_types: @send_types)
      started = Session.snapshot(first).datamodel["_ioprocessors"]
      assert {:ok, blob} = Position.to_binary(Session.snapshot(first))
      :ok = Session.stop(first)

      {:ok, resumed} = Session.start_link(machine, resume: blob, send_types: @send_types)

      assert Session.snapshot(resumed).datamodel["_ioprocessors"] == started
      assert started["myapp:sink"] == %{"location" => "myapp:sink/joined_records"}
    end

    # sabotage: `MachineState.put_send_types/2` also rewrites
    # `"_ioprocessors"` from the new set -> the re-stamp without the type
    # drops the entry, and the equality reddens. Confirmed red and reverted.
    test "the re-stamp on a resume does not rewrite _ioprocessors" do
      machine = compile!(@chart)
      {:ok, first} = Session.start_link(machine, send_types: @send_types)
      started = Session.snapshot(first).datamodel["_ioprocessors"]
      assert {:ok, blob} = Position.to_binary(Session.snapshot(first))
      :ok = Session.stop(first)

      {:ok, resumed} = Session.start_link(machine, resume: blob)

      assert Session.snapshot(resumed).send_types == nil
      assert Session.snapshot(resumed).datamodel["_ioprocessors"] == started
    end
  end
end
