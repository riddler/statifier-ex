defmodule Statifier.Session.SendCancelTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Session
  alias Statifier.Validator

  # Phase 6: the core-to-session seam proven on real `<send>`/`<cancel>`
  # documents, migrated off the hand-built `Session.interpret/2` effects
  # `test/statifier/session_test.exs`'s own delayed-send/cancel suites still
  # use for their own (still-valid, ADR-0029) purpose - this suite is the
  # migration ADR-0029's Consequences anticipated: "The tests that today
  # reach timers only through it may migrate to real `<send delay>`
  # documents; the function stays, because its warrant is the embedder seam,
  # not the test gap it also happens to fill."

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # The same polling helper `test/statifier/session_test.exs` and
  # `test/statifier/replay_round_trip_test.exs` use: a timer firing arrives
  # asynchronously with no single message this helper can `assert_receive`
  # on, so quiescence is confirmed by polling `status/1` rather than by a
  # fixed sleep sized to the delay under test.
  defp wait_for_status(session, pred, attempts \\ 50)

  defp wait_for_status(_session, _pred, 0), do: flunk("status/1 never satisfied the predicate")

  defp wait_for_status(session, pred, attempts) do
    status = Session.status(session)

    if pred.(status) do
      status
    else
      Process.sleep(5)
      wait_for_status(session, pred, attempts - 1)
    end
  end

  # -- a targetless <send> lands on the external queue ------------------

  describe "a targetless <send> lands on this session's own external queue" do
    # sabotage: `Statifier.Session.Effects`'s `plan_one({:send, %Send{target:
    # nil} = send} = effect)` clause has its `{:enqueue_event, ...}`
    # instruction dropped, leaving only `[{:notify, effect}]` -> the "pong"
    # event this document's own onentry sends is never enqueued, so the
    # session never drains the transition to "b" and the
    # `wait_for_status/2` poll below flunks on timeout. Reverted and
    # confirmed green.
    test "the sent event self-delivers and drives a transition with no external input" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
            <state id="a">
                <onentry><send event="pong"/></onentry>
                <transition event="pong" target="b"/>
            </state>
            <state id="b"/>
        </scxml>
        """)

      {:ok, session} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(session)

      assert_receive {:statifier, ^session_id, {:effect, {:send, %Effect.Send{event: "pong"}}}}

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])
    end
  end

  # -- a delayed <send> schedules a timer and delivers ---------------------

  describe "a <send delay> schedules a timer and delivers" do
    # sabotage: `Statifier.Session.Effects`'s `plan_one({:send_delayed,
    # %SendDelayed{target: nil} = send} = effect)` clause is changed to emit
    # `{:notify, effect}` alone, dropping the `{:schedule, ...}` instruction
    # -> no BEAM timer is ever started, so `pending_timers` never reaches 1
    # and the transition to "b" never happens, flunking the
    # `wait_for_status/2` poll below. Reverted and confirmed green.
    test "the timer fires after the delay and the delivered event drives a transition" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
            <state id="a">
                <onentry><send event="ping" delay="50ms"/></onentry>
                <transition event="ping" target="b"/>
            </state>
            <state id="b"/>
        </scxml>
        """)

      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      status = wait_for_status(session, fn s -> s.pending_timers == 1 end)
      assert status.configuration == MapSet.new(["a"])

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.pending_timers == 0
    end
  end

  # -- a <cancel> naming the idlocation-captured id prevents delivery ------

  describe "a <cancel> naming a <send>'s idlocation-captured id" do
    # sabotage: `Statifier.Machine.Content.Send`'s `maybe_write_idlocation/4`
    # clause is changed to write `send_id <> "_x"` into the datamodel
    # instead of the bare `send_id` the timer is actually scheduled and
    # cancelled under -> `<cancel sendidexpr="loc"/>` reads back a mismatched
    # id and cancels nothing, so the timer still fires and the session
    # reaches "b" - reddening this test's `pending_timers == 0` assertion
    # (observed as `left: 1, right: 0`). Reverted and confirmed green.
    test "the send is cancelled before its delay elapses; the event never arrives" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
            <datamodel>
                <data id="loc"/>
            </datamodel>
            <state id="a">
                <onentry>
                    <send event="ping" delay="50ms" idlocation="loc"/>
                    <cancel sendidexpr="loc"/>
                </onentry>
                <transition event="ping" target="b"/>
            </state>
            <state id="b"/>
        </scxml>
        """)

      {:ok, session} = Session.start_link(machine)

      # Both `<send>` and `<cancel>` run synchronously inside the same
      # `<onentry>` block during `init/1`, well before the 50ms delay
      # elapses, so `pending_timers` is already back to 0 by the time
      # `start_link/2` returns - no poll needed for the cancellation itself.
      assert Session.status(session).pending_timers == 0

      # Sleeping past the original delay window (mirroring
      # `test/statifier/session_test.exs`'s own
      # "a matching Effect.Cancel before the delay elapses" case) confirms
      # the cancelled timer never fires - a poll has nothing to wait for
      # here, since the assertion is that nothing changes.
      Process.sleep(80)
      assert Session.status(session).configuration == MapSet.new(["a"])
    end
  end

  # -- a <cancel> for an id that never existed is a no-op ------------------

  describe "a <cancel> for an id that never existed" do
    # sabotage: n/a - this exercises `lib/statifier/session.ex:550`'s
    # already sabotage-tested unmatched-id no-op
    # (`test/statifier/session_test.exs`'s "a cancel for an unknown or
    # already-fired send_id is a no-op") through the document-driven path
    # for the first time; the pure no-op behavior itself carries its
    # sabotage note there, and `Statifier.Machine.Content.Cancel`'s own
    # "an unmatched send_id is emitted anyway" carries its sabotage note in
    # `test/statifier/machine/content/cancel_test.exs`. This test's own job
    # is only to confirm the two compose with no crash and no blocked
    # transition.
    test "the cancel is a no-op and the state chart proceeds normally" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
            <state id="a">
                <onentry><cancel sendid="never_sent"/></onentry>
                <transition event="go" target="b"/>
            </state>
            <state id="b"/>
        </scxml>
        """)

      {:ok, session} = Session.start_link(machine)

      assert Session.status(session).pending_timers == 0

      Session.send_event(session, "go")
      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])
    end
  end

  # -- a targeted <send> with an unparseable target ------------------------

  describe "a <send target=\"...\"> naming no recognized special target" do
    # The target vocabulary has a router: an unparseable target
    # (`Statifier.Send.Target.parse/1` returns `{:invalid, _}`) is 6.2.4's
    # "not supported or invalid" -> `error.execution` on the sender's own
    # internal queue, never `{:unroutable, _}` (that vocabulary member
    # survives only for `:invoke`/`:cancel_invoke`/`:autoforward`, later,
    # separate work).
    #
    # sabotage: `Statifier.Session.Effects.plan_send/3`'s `{:invalid,
    # _target} -> [execution_error(send)]` clause is changed to `[]`,
    # dropping the raise entirely -> no `error.execution` ever reaches the
    # transition, so the configuration stays at `a` instead of advancing to
    # `caught`, reddening the assertion below. Reverted and confirmed green.
    test "an unparseable target raises error.execution on the internal queue" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
            <state id="a">
                <onentry><send event="e" target="whatever"/></onentry>
                <transition event="error.execution" target="caught"/>
            </state>
            <state id="caught"/>
        </scxml>
        """)

      {:ok, session} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(session)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:send, %Effect.Send{event: "e", target: "whatever"}}}}

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["caught"]) end)
      assert status.configuration == MapSet.new(["caught"])
    end
  end
end
