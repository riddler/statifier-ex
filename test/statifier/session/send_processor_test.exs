defmodule Statifier.Session.SendProcessorTest do
  use ExUnit.Case, async: false

  # ADR-0069 decision 4: a registered type's `<send>` is handed to its
  # `Statifier.Send.Processor` with the event already built, a delayed one is
  # the processor's timer, and a `<cancel>` naming it reaches the same
  # processor. The first two describes drive the pure planner; the rest
  # drive a live `Statifier.Session`. `async: false`: the session tests
  # register a `:global` name per session.

  alias Statifier.Effect.{Cancel, Send, SendDelayed}
  alias Statifier.{Replay, Session}
  alias Statifier.Send.Event, as: SendEvent
  alias Statifier.Send.Types
  alias Statifier.Session.Effects

  defmodule Recorder do
    @moduledoc false
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(effect, event, _ctx),
      do: {:ok, [{:handler, __MODULE__, {:deliver, effect, event}}]}

    @impl Statifier.Send.Processor
    def cancel(cancel, _ctx), do: {:ok, [{:handler, __MODULE__, {:cancel, cancel}}]}

    # The test process registers itself under the session's id before the
    # session starts, so every payload reaches the test that owns it.
    @impl Statifier.Send.Processor
    def perform(payload, %{session_id: session_id}) do
      case :global.whereis_name({__MODULE__, session_id}) do
        pid when is_pid(pid) -> send(pid, {__MODULE__, payload})
        :undefined -> :ok
      end

      :ok
    end
  end

  defmodule Other do
    @moduledoc false
    @behaviour Statifier.Send.Processor

    @impl Statifier.Send.Processor
    def deliver(_effect, _event, _ctx), do: {:ok, [{:handler, __MODULE__, :deliver}]}

    @impl Statifier.Send.Processor
    def cancel(_cancel, _ctx), do: {:ok, [{:handler, __MODULE__, :cancel}]}
  end

  @send_types %{"myapp:sink" => Recorder, "myapp:other" => Other}
  @session_id "sess_processor"

  defp context(extra \\ %{}) do
    Map.merge(
      %{
        session_id: @session_id,
        invoke_types: nil,
        send_types: Types.from_send_types(@send_types),
        send_processors: @send_types
      },
      extra
    )
  end

  defp immediate(fields),
    do:
      struct!(
        %Send{
          event: "impression.joined",
          type: "myapp:sink",
          target: "joined_records",
          send_id: "joined",
          id_from_author?: true,
          macrostep: 1,
          microstep: 1,
          round: 0,
          ordinal: 1
        },
        fields
      )

  defp delayed(fields),
    do:
      struct!(
        %SendDelayed{
          event: "reminder",
          type: "myapp:sink",
          target: "reminders",
          send_id: "remind",
          id_from_author?: true,
          delay_ms: 5000,
          macrostep: 1,
          microstep: 1,
          round: 0,
          ordinal: 2
        },
        fields
      )

  defp cancel(send_id),
    do: %Cancel{send_id: send_id, macrostep: 2, microstep: 1, round: 0, ordinal: 3}

  describe "the planner hands a registered type to its processor" do
    # sabotage: `plan_send/3`'s `:registered` arm plans the built-in branch
    # instead -> `Target.parse("joined_records")` is invalid, the plan is
    # `error.execution`, and this match reddens. Confirmed red and reverted.
    test "an immediate send plans the processor's instructions, with the built event" do
      effect = immediate([])

      assert Effects.plan([{:send, effect}], context()) == [
               {:notify, {:send, effect}},
               {:handler, Recorder, {:deliver, effect, SendEvent.build(effect, @session_id)}}
             ]
    end

    # sabotage: `plan_send_delayed/3`'s `:registered` arm plans the built-in
    # branch -> the plan is `error.execution` for the unparseable target and
    # the equality reddens. Confirmed red and reverted.
    test "a delayed send plans no library timer, only the processor's instructions" do
      effect = delayed(caller_context: :ctx)

      assert Effects.plan([{:send_delayed, effect}], context()) == [
               {:notify, {:send_delayed, effect}},
               {:handler, Recorder, {:deliver, effect, SendEvent.build(effect, @session_id)}}
             ]
    end

    # sabotage: `processor_for/2` answers `Recorder` for every type -> the
    # second type's send reaches the wrong module and the equality reddens.
    # Confirmed red and reverted.
    test "each registered type reaches its own module" do
      effect = immediate(type: "myapp:other")

      assert [{:notify, _effect}, {:handler, Other, :deliver}] =
               Effects.plan([{:send, effect}], context())
    end

    # sabotage: `plan_send/3`'s `:unsupported` arm hands off too (`hand_off/2`)
    # -> `processor_for/2`'s `Map.fetch!/2` raises and the test reddens.
    # Confirmed red and reverted.
    test "an unregistered type is still error.execution" do
      effect = immediate(type: "myapp:unknown")

      assert [
               {:notify, _effect},
               {:raise, :platform, "error.execution", _origin, [sendid: "joined"]}
             ] =
               Effects.plan([{:send, effect}], context())
    end

    # sabotage: `plan_send/3`'s `:built_in` arm calls `hand_off/2` ->
    # `processor_for/2` finds no module for a `nil` type and raises, and the
    # test reddens. Confirmed red and reverted.
    test "a built-in send plans as before with a registered set present" do
      effect = immediate(type: nil, target: nil, ordinal: nil)

      assert [{:notify, _effect}, {:enqueue_event, event}] =
               Effects.plan([{:send, effect}], context())

      assert event == SendEvent.build(effect, @session_id)
    end
  end

  describe "the planner routes a <cancel> to the processor holding its id" do
    # sabotage: `hold/2`'s `:send_delayed` clause returns `context`
    # unchanged -> the same-list cancel finds no hold and plans only
    # `{:cancel_timers, _}`, and this equality reddens. Confirmed red and
    # reverted.
    test "a delayed send and its cancel in one effect list" do
      send = delayed([])
      cancel = cancel("remind")

      assert [
               {:notify, {:send_delayed, ^send}},
               {:handler, Recorder, {:deliver, ^send, _event}},
               {:notify, {:cancel, ^cancel}},
               {:cancel_timers, "remind"},
               {:handler, Recorder, {:cancel, ^cancel}}
             ] = Effects.plan([{:send_delayed, send}, {:cancel, cancel}], context())
    end

    # sabotage: `plan_one/2`'s cancel arm reads `%{}` instead of
    # `held(context)` -> the cancel reaches no processor and the equality
    # reddens. Confirmed red and reverted.
    test "a cancel whose id the context holds, in type order" do
      cancel = cancel("remind")
      held = %{"remind" => ["myapp:other", "myapp:sink"]}

      assert Effects.plan([{:cancel, cancel}], context(%{held_sends: held})) == [
               {:notify, {:cancel, cancel}},
               {:cancel_timers, "remind"},
               {:handler, Other, :cancel},
               {:handler, Recorder, {:cancel, cancel}}
             ]
    end

    # sabotage: `hold/2`'s `:cancel` clause returns `context` unchanged ->
    # the second cancel of the same id reaches the processor again and the
    # equality reddens. Confirmed red and reverted.
    test "a cancel releases the id, so a second cancel reaches no processor" do
      held = %{"remind" => ["myapp:sink"]}

      assert [
               {:notify, _first_cancel},
               {:cancel_timers, "remind"},
               {:handler, Recorder, _payload},
               {:notify, _second_cancel},
               {:cancel_timers, "remind"}
             ] =
               Effects.plan(
                 [{:cancel, cancel("remind")}, {:cancel, cancel("remind")}],
                 context(%{held_sends: held})
               )
    end

    # sabotage: `hold/2`'s `:send_delayed` clause registers every delayed
    # send, built-in or not -> the built-in id is held, the cancel reaches
    # `Recorder`, and the equality reddens. Confirmed red and reverted.
    test "a built-in delayed send and its cancel plan exactly as before" do
      send = delayed(type: nil, target: nil, ordinal: 1)
      cancel = cancel("remind")

      assert [
               {:notify, {:send_delayed, ^send}},
               {:schedule, "remind", 5000, :self, _event, {:send_delayed, ^send}},
               {:notify, {:cancel, ^cancel}},
               {:cancel_timers, "remind"}
             ] = Effects.plan([{:send_delayed, send}, {:cancel, cancel}], context())
    end
  end

  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
      <state id="idle">
          <transition event="join" target="joined"/>
          <transition event="remind" target="reminding"/>
          <transition event="tick" target="ticking"/>
      </state>
      <state id="joined">
          <onentry>
              <send type="myapp:sink" target="joined_records" event="impression.joined" id="joined">
                  <param name="impression_id" expr="'imp-1'"/>
              </send>
          </onentry>
      </state>
      <state id="reminding">
          <onentry>
              <send type="myapp:sink" target="reminders" event="reminder" id="remind" delay="5s"/>
          </onentry>
          <transition event="stop" target="stopped"/>
      </state>
      <state id="stopped">
          <onentry>
              <cancel sendid="remind"/>
          </onentry>
      </state>
      <state id="ticking">
          <onentry>
              <send event="tock" id="tick" delay="5s"/>
          </onentry>
          <transition event="stop" target="untocked"/>
      </state>
      <state id="untocked">
          <onentry>
              <cancel sendid="tick"/>
          </onentry>
      </state>
  </scxml>
  """

  defp start!(opts \\ []) do
    session_id = "sess_processor_#{System.unique_integer([:positive])}"
    :yes = :global.register_name({Recorder, session_id}, self())
    on_exit(fn -> :global.unregister_name({Recorder, session_id}) end)

    {:ok, machine} = Statifier.compile(@chart)

    {:ok, session} =
      Session.start_link(
        machine,
        Keyword.merge([session_id: session_id, send_types: %{"myapp:sink" => Recorder}], opts)
      )

    {session, session_id}
  end

  defp send_and_settle(session, name) do
    :ok = Session.send_event(session, name)
    _status = Session.status(session)
    :ok
  end

  describe "a live session" do
    # sabotage: `Session.plan_context/1` omits `:send_processors` ->
    # `processor_for/2` raises, the session crashes, and no `{Recorder, _}`
    # message arrives. Confirmed red and reverted.
    test "hands a registered immediate send to its module with the built event" do
      {session, session_id} = start!()
      send_and_settle(session, "join")

      assert_receive {Recorder, {:deliver, %Send{type: "myapp:sink"} = effect, event}}
      assert event == SendEvent.build(effect, session_id)
      assert %{name: "impression.joined", data: %{"impression_id" => "imp-1"}} = event
      assert event.sendid == "joined"
      assert is_integer(effect.ordinal)
    end

    # sabotage: `plan_send_delayed/3`'s `:registered` arm returns the
    # built-in `{:schedule, ...}` instruction for a `:self` route -> the
    # session arms a timer and `pending_timers` reads 1. Confirmed red and
    # reverted.
    test "schedules no library timer for a registered delayed send" do
      {session, _session_id} = start!()
      send_and_settle(session, "remind")

      assert_receive {Recorder, {:deliver, %SendDelayed{send_id: "remind", delay_ms: 5000}, _}}
      assert Session.status(session).pending_timers == 0
    end

    # sabotage: the session's `{:notify, {:send_delayed, _}}` arm skips
    # `register_held_send/3` -> the cancel, planned in a later drive, finds
    # no hold and never reaches `Recorder`. Confirmed red and reverted.
    test "routes a later <cancel> naming it to the same module" do
      {session, _session_id} = start!()
      send_and_settle(session, "remind")
      assert_receive {Recorder, {:deliver, %SendDelayed{}, _}}

      send_and_settle(session, "stop")
      assert_receive {Recorder, {:cancel, %Cancel{send_id: "remind"}}}
      assert :sys.get_state(session).held_sends == %{}
    end

    # sabotage: the session's `{:notify, {:send_delayed, _}}` arm holds
    # every delayed send (its `classify/2` check dropped) -> the built-in
    # id is held and the `held_sends == %{}` assertion reddens. Confirmed red
    # and reverted.
    test "a built-in delayed send and its cancel behave as before" do
      {session, _session_id} = start!()
      send_and_settle(session, "tick")

      assert Session.status(session).pending_timers == 1
      assert :sys.get_state(session).held_sends == %{}

      send_and_settle(session, "stop")
      assert Session.status(session).pending_timers == 0
      refute_received {Recorder, _payload}
    end

    # sabotage: `Replay.plan_context/1` omits `:send_processors` ->
    # `processor_for/2` raises inside `Replay.run/1` and the test reddens.
    # Confirmed red and reverted.
    test "replays a recording with a registered delayed send and its cancel" do
      {session, _session_id} = start!(record: true)
      send_and_settle(session, "remind")
      send_and_settle(session, "stop")

      {:ok, recording} = Session.recording(session)
      assert {:ok, %{machine_state: machine_state, stream: stream}} = Replay.run(recording)
      assert Statifier.active_leaf_states(machine_state) == MapSet.new(["stopped"])
      assert Enum.any?(stream, &match?({:effect, {:cancel, %Cancel{send_id: "remind"}}}, &1))
    end
  end
end
