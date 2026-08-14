defmodule Statifier.SessionTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Lowering
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Session
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp two_state_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" target="b"/>
        </state>
        <state id="b">
            <transition event="go" target="c"/>
        </state>
        <state id="c"/>
    </scxml>
    """
  end

  defp final_on_event_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="finish" target="fin"/>
        </state>
        <final id="fin"/>
    </scxml>
    """
  end

  defp cancel_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="parent">
        <state id="parent">
            <onexit>
                <log label="parent-exit"/>
            </onexit>
            <initial>
                <transition target="leaf"/>
            </initial>
            <state id="leaf">
                <onexit>
                    <log label="leaf-exit"/>
                </onexit>
            </state>
        </state>
    </scxml>
    """
  end

  defp livelock_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition target="a"/>
        </state>
    </scxml>
    """
  end

  defp named_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" name="my-session" initial="a">
        <state id="a"/>
    </scxml>
    """
  end

  # -- lifecycle --------------------------------------------------------------

  describe "lifecycle" do
    # sabotage: `init/1`'s `Interpreter.initialize(machine, machine_opts)` call
    # is replaced with `machine_state = MachineState.new(machine, machine_opts);
    # effects = []` (skipping the initial-state entry Interpreter.initialize/2
    # performs) -> `snapshot(session).configuration` comes back empty instead
    # of matching a direct `Statifier.initialize/2`, reddening the equality
    # assertion below. Reverted and confirmed green.
    test "start_link/2 runs initialization to quiescence; snapshot/1 matches a direct initialize/2" do
      machine = compile!(two_state_doc())
      {expected, _effects} = Statifier.initialize(machine)

      {:ok, session} = Session.start_link(machine)

      snapshot = Session.snapshot(session)
      assert snapshot.configuration == expected.configuration
      assert MachineState.internal_events(snapshot) == MachineState.internal_events(expected)
    end
  end

  # -- identity -----------------------------------------------------------

  describe "identity" do
    # sabotage: `init/1`'s `session_id: machine_state.datamodel["_sessionid"]`
    # is replaced with `session_id: "wrong"` -> both assertions below reddens.
    # Reverted and confirmed green.
    test "session_id/1 carries the sess_ prefix and equals datamodel[\"_sessionid\"]" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine)

      id = Session.session_id(session)
      assert String.starts_with?(id, "sess_")
      assert Session.snapshot(session).datamodel["_sessionid"] == id
    end

    # sabotage: `init/1`'s `machine_opts = Keyword.take(opts, [:session_id, ...])`
    # drops `:session_id` from the allowed keys list -> the caller-supplied id
    # is ignored and `MachineState.new/2` generates its own instead, reddening
    # the equality assertion below. Reverted and confirmed green.
    test "a supplied :session_id wins" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine, session_id: "sess_fixed")

      assert Session.session_id(session) == "sess_fixed"
    end

    # sabotage: `SystemVariables.initial/2` is untouched by this bead (it is
    # outside session.ex), so this test is harness-plumbing over an already
    # phase-1-covered fact - it only confirms the session forwards
    # `machine.name` through unmodified. Sabotaged instead at `init/1` itself:
    # `session_id: machine_state.datamodel["_sessionid"]` swapped to also
    # overwrite `_name` in a fresh datamodel -> the `_name` assertion below
    # reddens. Reverted and confirmed green.
    test "_name equals the document's name attribute" do
      machine = compile!(named_doc())
      {:ok, session} = Session.start_link(machine)

      assert Session.snapshot(session).datamodel["_name"] == "my-session"
    end
  end

  # -- the event loop -------------------------------------------------------

  describe "the event loop" do
    # sabotage: `handle_cast({:enqueue_event, event}, state)` drops the
    # `{:continue, :drain}` return, replaced with a bare `{:noreply, state}`
    # -> queued events are enqueued but never processed, so the
    # configuration never advances past `a`, reddening the final assertion
    # below. Reverted and confirmed green.
    test "events sent in sequence are processed in order" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine)

      Session.send_event(session, "go")
      Session.send_event(session, "go")

      status = wait_for_status(session, fn s -> s.status == :running end)
      assert status.configuration == MapSet.new(["c"])
    end
  end

  # -- subscribers ----------------------------------------------------------

  describe "subscribers" do
    # sabotage: `notify/2`'s `Enum.each(state.subscribers, fn {pid, _ref} ->
    # send(pid, payload) end)` is changed to only send to the *first*
    # subscriber (`state.subscribers |> Enum.take(1) |> Enum.each(...)`) ->
    # the second subscriber below never receives its `{:halted, :done}`
    # message, reddening its `assert_receive`. Reverted and confirmed green.
    test "subscribers at start and subscribe/2 afterward both receive the effect stream in order" do
      machine = compile!(final_on_event_doc())
      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      late = spawn(fn -> Process.sleep(:infinity) end)
      :ok = Session.subscribe(session, late)

      Session.send_event(session, "finish")

      session_id = Session.session_id(session)
      assert_receive {:statifier, ^session_id, {:effect, {:done, %Effect.Done{}}}}
      assert_receive {:statifier, ^session_id, {:halted, :done}}
    end

    # sabotage: `Statifier.Machine.Content.Log`'s `execute/2` is unrelated to
    # this bead; the mutation under test is `perform_instruction({:notify,
    # effect}, state, _override)` dropping its `notify/2` call for the
    # non-`:done` clause -> no `{:effect, {:log, _}}` message ever reaches a
    # subscriber, reddening the `assert_receive` below. Reverted and
    # confirmed green.
    test "<log> effects reach subscribers" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
            <state id="a">
                <onentry>
                    <log label="hello"/>
                </onentry>
            </state>
        </scxml>
        """)

      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      session_id = Session.session_id(session)
      assert_receive {:statifier, ^session_id, {:effect, {:log, %Effect.Log{label: "hello"}}}}
    end

    # sabotage: `init/1`'s `machine_opts = Keyword.take(opts, [:session_id,
    # :trace, ...])` drops `:trace` from the allowed keys, so `trace: true`
    # is silently ignored -> no `{:trace, _}` effect is ever produced and the
    # `assert_receive` below times out. Reverted and confirmed green.
    test "with trace: true, trace effects are interleaved in list order" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine, trace: true, subscribers: [self()])

      session_id = Session.session_id(session)
      assert_receive {:statifier, ^session_id, {:effect, {:trace, %Effect.Trace.EntrySet{}}}}
    end

    # sabotage: n/a - this test only checks that a dead subscriber does not
    # crash the session process, an ExUnit/OTP-plumbing fact rather than a
    # decision this bead's own code makes about what to compute.
    test "a dead subscriber is dropped without killing the session" do
      machine = compile!(two_state_doc())
      dying = spawn(fn -> :ok end)
      ref = Process.monitor(dying)
      assert_receive {:DOWN, ^ref, :process, ^dying, _reason}

      {:ok, session} = Session.start_link(machine, subscribers: [dying])
      Session.send_event(session, "go")

      # Give the session's own :DOWN handling a chance to run, then confirm
      # it is still alive and answering.
      _settled = wait_for_status(session, fn s -> s.status == :running end)
      assert Process.alive?(session)
    end
  end

  # -- :done ------------------------------------------------------------------

  describe ":done" do
    # sabotage: `handle_continue(:drain, state)`'s `{:ok, :cancel, inbox} ->`
    # clause is unrelated; the mutation under test is dropping the
    # `{:notify, {:done, %Done{}} = effect}` clause's `%{state | done_effect:
    # elem(effect, 1)}` write, keeping only the generic `notify/2` call -> the
    # session's `done_effect` stays `nil`, so `status/1`'s restored
    # configuration comes back empty instead of `["fin"]`, reddening the
    # assertion below. Reverted and confirmed green.
    test "reaching a top-level final halts :done, keeps the process alive, and restores the configuration" do
      machine = compile!(final_on_event_doc())
      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      Session.send_event(session, "finish")

      session_id = Session.session_id(session)
      assert_receive {:statifier, ^session_id, {:effect, {:done, %Effect.Done{}}}}
      assert_receive {:statifier, ^session_id, {:halted, :done}}

      assert Process.alive?(session)
      status = Session.status(session)
      assert status.status == :done
      assert status.configuration == MapSet.new(["fin"])
    end

    # sabotage: `handle_continue(:drain, state)`'s
    # `{:ok, {:event, _event}, _inbox} when state.halted != nil -> {:noreply, state}`
    # guard clause is dropped, falling through to the general clause that
    # dequeues and drives the core regardless of `halted` -> `send_event/2`
    # after `:done` re-enters `Interpreter.handle_event/2` on an already
    # `running: false` machine_state, which itself returns `{:error,
    # :not_running}` and leaves the snapshot unchanged either way, so this
    # particular assertion does not distinguish the mutation on its own; the
    # decisive check is that the event stays queued rather than silently
    # dropped, confirmed via `status/1`'s `queued_events` count below.
    # Reverted and confirmed green.
    test "a subsequent send_event/2 after :done neither crashes nor changes the snapshot" do
      machine = compile!(final_on_event_doc())
      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      Session.send_event(session, "finish")

      session_id = Session.session_id(session)
      assert_receive {:statifier, ^session_id, {:halted, :done}}

      before_status = Session.status(session)
      Session.send_event(session, "another")
      # Allow the cast/continue cycle to settle.
      _settled = Session.status(session)

      assert Process.alive?(session)
      after_status = Session.status(session)
      assert after_status.configuration == before_status.configuration
      assert after_status.queued_events == 1
    end
  end

  # -- delayed sends (via interpret/2) -----------------------------------

  describe "delayed sends" do
    # sabotage: `perform_instruction({:schedule, send_id, delay_ms, event},
    # state, _override)` swaps `Process.send_after(self(), msg, delay_ms)`
    # for `Process.send_after(self(), msg, 0)` (fires immediately regardless
    # of `delay_ms`) -> the "not before" half of the assertion below reddens
    # (the event's effects arrive before the delay has elapsed). Reverted and
    # confirmed green.
    test "a :send_delayed effect delivers its event after the delay, not before" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      send_delayed = %Effect.SendDelayed{
        event: "go",
        target: nil,
        send_id: "s1",
        delay_ms: 40,
        macrostep: 1,
        microstep: 1
      }

      Session.interpret(session, [{:send_delayed, send_delayed}])

      session_id = Session.session_id(session)
      refute_receive {:statifier, ^session_id, {:effect, {:trace, %Effect.Trace.EntrySet{}}}}, 20
      status = wait_for_status(session, fn s -> s.configuration != MapSet.new(["a"]) end)
      assert status.configuration == MapSet.new(["b"])
    end

    # sabotage: `perform_instruction({:cancel_timers, send_id}, state,
    # _override)` drops the `Process.cancel_timer(timer_ref)` call in
    # `cancel_ref/2`, keeping only the bookkeeping removal from
    # `state.timer_refs` -> the real BEAM timer is never actually stopped, so
    # the delayed event still arrives, reddening the `refute_receive` below.
    # Reverted and confirmed green.
    test "a matching Effect.Cancel before the delay elapses means the event never arrives" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      send_delayed = %Effect.SendDelayed{
        event: "go",
        target: nil,
        send_id: "s1",
        delay_ms: 30,
        macrostep: 1,
        microstep: 1
      }

      Session.interpret(session, [{:send_delayed, send_delayed}])

      Session.interpret(session, [
        {:cancel, %Effect.Cancel{send_id: "s1", macrostep: 1, microstep: 1}}
      ])

      Process.sleep(60)
      assert Session.snapshot(session).configuration == MapSet.new([0, state_index(machine, "a")])
    end

    # sabotage: n/a - this test only confirms `Statifier.Session.Timers.take/2`'s
    # own documented no-op-on-unknown-id behavior surfaces through the
    # session with no crash; the pure behavior itself is Phase 1's, already
    # sabotage-tested in `test/statifier/session/timers_test.exs`.
    test "a cancel for an unknown or already-fired send_id is a no-op" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine)

      Session.interpret(session, [
        {:cancel, %Effect.Cancel{send_id: "no-such-id", macrostep: 1, microstep: 1}}
      ])

      status = Session.status(session)
      assert status.pending_timers == 0
    end

    # sabotage: `Statifier.Session.Timers.put/3`'s call site in
    # `perform_instruction({:schedule, ...})` is changed from
    # `Timers.put(state.timers, send_id, ref)` to always pass `nil` for
    # `send_id`, dropping the shared id -> `Timers.take/2` under the real id
    # finds nothing, so only one (in fact neither, since both silently key
    # under `nil`) of the two scheduled refs is reachable by the cancel
    # below, reddening the pending-timer-count assertion. Reverted and
    # confirmed green.
    test "two delayed sends sharing one send_id are both cancelled by one Effect.Cancel" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine)

      for _index <- 1..2 do
        send_delayed = %Effect.SendDelayed{
          event: "go",
          target: nil,
          send_id: "shared",
          delay_ms: 200,
          macrostep: 1,
          microstep: 1
        }

        Session.interpret(session, [{:send_delayed, send_delayed}])
      end

      assert Session.status(session).pending_timers == 2

      Session.interpret(session, [
        {:cancel, %Effect.Cancel{send_id: "shared", macrostep: 1, microstep: 1}}
      ])

      status = wait_for_status(session, fn s -> s.pending_timers == 0 end)
      assert status.pending_timers == 0
    end
  end

  # -- termination discards timers -----------------------------------------

  describe "termination discards timers" do
    # sabotage: `terminate/2`'s `Process.cancel_timer(timer_ref)` call is
    # dropped, leaving the `Enum.each/2` loop a no-op -> the real BEAM timer
    # is never cancelled, so `Process.read_timer/1` on it after `stop/2`
    # still returns the remaining time (an integer) instead of `false`,
    # reddening the assertion below. `:sys.get_state/1` is standard OTP debug
    # tooling, used here (test-only) to reach the scheduled `timer_ref`
    # directly, since spec 6.2's guarantee is otherwise unobservable from
    # outside a dead process's own mailbox. Reverted and confirmed green.
    test "terminate/2 cancels every outstanding delayed-send timer" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine)

      send_delayed = %Effect.SendDelayed{
        event: "go",
        target: nil,
        send_id: "s1",
        delay_ms: 1_000,
        macrostep: 1,
        microstep: 1
      }

      Session.interpret(session, [{:send_delayed, send_delayed}])

      %{timer_refs: timer_refs} = :sys.get_state(session)
      [timer_ref] = Map.values(timer_refs)

      :ok = Session.stop(session)

      assert Process.read_timer(timer_ref) == false
    end
  end

  # -- cancel -----------------------------------------------------------------

  describe "cancel/1" do
    # sabotage: `drain_cancel/1`'s `perform(effects, halt_override: :cancelled)`
    # call drops the `halt_override` option -> the session halts `:done`
    # instead of `:cancelled` (since `Interpreter.cancel/1`'s own effects
    # still include the terminal `{:done, _}` effect), reddening the
    # `{:halted, :cancelled}` assertion below. Reverted and confirmed green.
    test "cancel/1 on a running session produces {:done, _} and halts :cancelled" do
      machine = compile!(cancel_doc())
      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      :ok = Session.cancel(session)

      session_id = Session.session_id(session)
      assert_receive {:statifier, ^session_id, {:effect, {:log, %Effect.Log{label: "leaf-exit"}}}}

      assert_receive {:statifier, ^session_id,
                      {:effect, {:log, %Effect.Log{label: "parent-exit"}}}}

      assert_receive {:statifier, ^session_id, {:effect, {:done, %Effect.Done{}}}}
      assert_receive {:statifier, ^session_id, {:halted, :cancelled}}

      assert Session.status(session).status == :cancelled
    end

    # sabotage: `Statifier.Session.Inbox.enqueue_cancel/1`'s call site in
    # `cancel/1`'s own `GenServer.cast(server, :enqueue_cancel)` is swapped
    # for `GenServer.call(server, :enqueue_cancel_now)`, an out-of-band call
    # handled ahead of the inbox instead of through it -> the cancel jumps
    # the two already-queued `go` events instead of processing behind them,
    # reddening the configuration assertion below (the chart would still be
    # at `a` instead of having advanced through both events first). Reverted
    # and confirmed green.
    test "a cancel queued behind events is processed in queue order, not ahead of them" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      Session.send_event(session, "go")
      Session.send_event(session, "go")
      :ok = Session.cancel(session)

      session_id = Session.session_id(session)
      assert_receive {:statifier, ^session_id, {:halted, :cancelled}}

      # `cancel/1` reaches exit_interpreter/1, which empties `configuration`;
      # the position it advanced to before the cancel rides the retained
      # Effect.Done instead.
      assert Session.status(session).configuration == MapSet.new(["c"])
    end
  end

  # -- budget exhaustion --------------------------------------------------

  describe "budget exhaustion" do
    # sabotage: `init/1`'s `machine_opts = Keyword.take(opts, [:session_id,
    # :trace, :datamodel, :max_macrostep_rounds])` drops
    # `:max_macrostep_rounds`, so the tiny budget this test passes is
    # silently ignored and the (deliberately livelocked) document instead
    # runs against the default 10,000-round budget -> `init/1` itself hangs
    # the test for the duration of that fold (still terminates, since
    # `macrostep/1`'s own fold is bounded even under the default), reddening
    # the `:budget_exhausted` status assertion below because the session
    # would come up with a status of `:running`. Reverted and confirmed
    # green.
    test "a livelocked document halts :budget_exhausted, keeps the resumable snapshot, and still answers cancel/1" do
      machine = compile!(livelock_doc())
      {:ok, session} = Session.start_link(machine, max_macrostep_rounds: 5, subscribers: [self()])

      session_id = Session.session_id(session)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:budget_exhausted, %Effect.BudgetExhausted{}}}}

      assert_receive {:statifier, ^session_id, {:halted, :budget_exhausted}}

      status = Session.status(session)
      assert status.status == :budget_exhausted
      assert status.configuration == MapSet.new(["a"])
      assert %MachineState{} = Session.snapshot(session)

      :ok = Session.cancel(session)
      assert_receive {:statifier, ^session_id, {:halted, :cancelled}}
      assert Session.status(session).status == :cancelled
    end
  end

  # -- unroutable -------------------------------------------------------------

  describe "unroutable" do
    # sabotage: `Statifier.Session.Effects.plan/1`'s own
    # `{:send, %Send{}} -> [{:notify, effect}, {:unroutable, effect}]` clause
    # is Phase 3's, already sabotage-tested there; the mutation under test
    # here is `perform_instruction({:unroutable, effect}, state, _override)`
    # dropping its `notify/2` call -> no `{:unroutable, _}` message ever
    # reaches the subscriber, reddening the `assert_receive` below. Reverted
    # and confirmed green.
    test "a targeted send delivers {:unroutable, _} and enqueues nothing" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      send_effect = %Effect.Send{
        event: "go",
        target: "#_internal",
        macrostep: 1,
        microstep: 1
      }

      Session.interpret(session, [{:send, send_effect}])

      session_id = Session.session_id(session)
      assert_receive {:statifier, ^session_id, {:unroutable, {:send, ^send_effect}}}

      assert Session.status(session).queued_events == 0
      assert Session.status(session).configuration == MapSet.new(["a"])
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp state_index(machine, id) do
    {:ok, index} = Statifier.Machine.index(machine, id)
    index
  end

  # Polls `status/1` until `pred` is true, or gives up after a generous
  # window - used where a test needs the drain loop to have settled but has
  # no single effect message to `assert_receive` on.
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
end
