defmodule Statifier.Send.EventTest do
  use ExUnit.Case, async: true

  # ADR-0069 decision 4's event carrier: `Statifier.Send.Event.build/3`, the
  # one construction site of a delivered `<send>` event.

  alias Statifier.Effect.{Send, SendDelayed}
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Send.Event, as: SendEvent
  alias Statifier.Session.Effects

  doctest Statifier.Send.Event

  @session_id "sess_builder"

  defp send(fields) do
    struct!(
      %Send{event: "impression.joined", macrostep: 1, microstep: 2, round: 0},
      fields
    )
  end

  defp delayed(fields) do
    struct!(
      %SendDelayed{
        event: "reminder",
        send_id: "send_3",
        delay_ms: 1000,
        macrostep: 1,
        microstep: 2,
        round: 0,
        ordinal: 1
      },
      fields
    )
  end

  describe "the fields it stamps" do
    # sabotage: `build/3` passes `data: nil` instead of `send.data` -> the
    # event's `data` is `nil` and this match reddens. Confirmed red and
    # reverted.
    test "name and data come from the send" do
      event = SendEvent.build(send(data: %{"impression_id" => "imp-1"}), @session_id)

      assert %Statifier.Event{
               name: "impression.joined",
               type: :external,
               data: %{"impression_id" => "imp-1"}
             } = event
    end

    # sabotage: `build/3`'s `sendid:` drops its `id_from_author?` gate
    # (`sendid: send.send_id`) -> the generated id leaks onto the event and
    # the `nil` assertion reddens. Confirmed red and reverted.
    test "sendid is the send id only when the author named the send" do
      assert SendEvent.build(send(send_id: "send_1", id_from_author?: false), @session_id).sendid ==
               nil

      assert SendEvent.build(send(send_id: "joined", id_from_author?: true), @session_id).sendid ==
               "joined"
    end

    # sabotage: `caller_context_of/1`'s `%SendDelayed{}` clause returns `nil`
    # -> the delayed send's term is dropped and the equality reddens.
    # Confirmed red and reverted.
    test "caller_context comes from a delayed send, and is nil for an immediate one" do
      assert SendEvent.build(delayed(caller_context: {:trace, "abc"}), @session_id).caller_context ==
               {:trace, "abc"}

      assert SendEvent.build(send([]), @session_id).caller_context == nil
    end
  end

  describe "origin and origintype" do
    # sabotage: `build/3`'s `:origin` default is
    # `SystemVariables.scxml_location("")` -> the sender's id is lost and
    # the equality reddens. Confirmed red and reverted.
    test "default to the sender's #_scxml_ location and the processor URI" do
      event = SendEvent.build(send([]), @session_id)

      assert event.origin == "#_scxml_sess_builder"
      assert event.origin == SystemVariables.scxml_location(@session_id)
      assert event.origintype == "http://www.w3.org/TR/scxml/#SCXMLEventProcessor"
    end

    # sabotage: `build/3` ignores `opts` (both fields take their defaults
    # unconditionally) -> the processor's own address is dropped and both
    # equalities redden. Confirmed red and reverted.
    test "a processor overrides either one" do
      event =
        SendEvent.build(send([]), @session_id,
          origin: "myapp:reply/imp-1",
          origintype: "myapp:execution"
        )

      assert {event.origin, event.origintype} == {"myapp:reply/imp-1", "myapp:execution"}

      assert SendEvent.build(send([]), @session_id, origintype: "myapp:execution").origin ==
               "#_scxml_sess_builder"
    end
  end

  describe "the session's delivered event is the builder's" do
    # sabotage: `delivered_event/2` in `Statifier.Session.Effects` builds
    # its own event with `origin: nil` instead of calling `build/2` -> the
    # enqueued event differs from the builder's and the equality reddens.
    # Confirmed red and reverted.
    test "an immediate self-send enqueues exactly what build/2 returns" do
      effect = send(target: nil, data: %{"k" => 1}, send_id: "s1", id_from_author?: true)

      assert [{:notify, _effect}, {:enqueue_event, event}] =
               Effects.plan([{:send, effect}], %{session_id: @session_id, invoke_types: nil})

      assert event == SendEvent.build(effect, @session_id)
    end

    # sabotage: as above -> the scheduled event differs and the equality
    # reddens. Confirmed red and reverted.
    test "a delayed send schedules exactly what build/2 returns" do
      effect = delayed(target: nil, caller_context: :ctx)

      assert [{:notify, _notified}, {:schedule, "send_3", 1000, :self, event, _scheduled}] =
               Effects.plan([{:send_delayed, effect}], %{
                 session_id: @session_id,
                 invoke_types: nil
               })

      assert event == SendEvent.build(effect, @session_id)
    end
  end
end
