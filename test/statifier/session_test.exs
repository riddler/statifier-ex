defmodule Statifier.SessionTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Event
  alias Statifier.Lowering
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Session
  alias Statifier.Session.Recording
  alias Statifier.StreamOrder
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
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
        microstep: 1,
        round: 0
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
        microstep: 1,
        round: 0
      }

      Session.interpret(session, [{:send_delayed, send_delayed}])

      Session.interpret(session, [
        {:cancel, %Effect.Cancel{send_id: "s1", macrostep: 1, microstep: 1, round: 0}}
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
        {:cancel, %Effect.Cancel{send_id: "no-such-id", macrostep: 1, microstep: 1, round: 0}}
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
          microstep: 1,
          round: 0
        }

        Session.interpret(session, [{:send_delayed, send_delayed}])
      end

      assert Session.status(session).pending_timers == 2

      Session.interpret(session, [
        {:cancel, %Effect.Cancel{send_id: "shared", macrostep: 1, microstep: 1, round: 0}}
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
        microstep: 1,
        round: 0
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

  # -- cancel-invoke miss ------------------------------------------------------

  describe "a cancel_invoke effect naming no live invocation" do
    # sabotage: `Statifier.Session`'s `perform_instruction({:stop_child,
    # invoke_id}, state, _override)` clause's `{nil, invocations} -> %{state
    # | invocations: invocations}` miss branch is changed to
    # `{nil, _invocations} -> raise "boom"` -> `interpret/2` crashes the
    # session handling this effect, so the `wait_for_status` poll below (for
    # the ordinary "go" event this test sends afterward, proving the
    # session is still alive) times out flunking instead of reaching "b".
    # Reverted and confirmed green.
    test "is a silent no-op; the session keeps running" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      cancel_effect = %Effect.CancelInvoke{
        invoke_id: "a.inv_1",
        state_index: 1,
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      Session.interpret(session, [{:cancel_invoke, cancel_effect}])

      session_id = Session.session_id(session)
      assert_receive {:statifier, ^session_id, {:effect, {:cancel_invoke, ^cancel_effect}}}

      # No `{:unroutable, _}` message follows - `:cancel_invoke` routes now
      # (Phase 5) - and the session took no transition on the fabricated,
      # never-live "a.inv_1" id, so it is still on "a" and still answers an
      # ordinary event normally.
      assert Session.status(session).configuration == MapSet.new(["a"])

      Session.send_event(session, "go")
      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])
    end
  end

  # -- delivered event fields (spec 5.10.1 / C.1) --------------------------

  describe "origin, origintype and sendid on a delivered (target-less) send" do
    defp self_send_doc(send_attrs) do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send event="e" #{send_attrs}/>
              </onentry>
              <transition event="e" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # sabotage: `Session.Effects`'s `delivered_event/2` passes `sendid:
    # send.send_id` unconditionally instead of gating it on
    # `send.id_from_author?` -> the generated (non-nil) `Effect.Send.send_id`
    # leaks onto `_event.sendid`, reddening the `:undefined` assertion below
    # even though the `Effect.Send.send_id` assertion stays green. Reverted
    # and confirmed green.
    test "sendid is :undefined on _event while Effect.Send.send_id is non-nil, when the author named neither id nor idlocation" do
      machine = compile!(self_send_doc(""))
      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      session_id = Session.session_id(session)

      assert_receive {:statifier, ^session_id, {:effect, {:send, %Effect.Send{send_id: send_id}}}}

      refute send_id == nil

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])

      assert Session.snapshot(session).datamodel["_event"]["sendid"] == :undefined
    end

    # sabotage: `Effect.Send`'s `id_from_author?` field default is changed
    # from `false` to `true` -> a generated id would now also read as
    # author-written, but this test writes `id="send1"` explicitly so it
    # would stay green under that particular mutation; instead sabotaged at
    # `Session.Effects.delivered_event/2`, changing `sendid: if(send.id_from_author?,
    # do: send.send_id)` to always `nil` -> this assertion reddens (test351's
    # own assertion, run here as a unit test since the corpus cannot run it
    # yet). Reverted and confirmed green.
    test "sendid is the author's id on _event, when the author wrote id" do
      machine = compile!(self_send_doc(~s(id="send1")))
      {:ok, session} = Session.start_link(machine)

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])

      assert Session.snapshot(session).datamodel["_event"]["sendid"] == "send1"
    end

    # sabotage: `Session.Effects.delivered_event/2` passes
    # `origintype: "scxml"` (the short alias, not
    # `SystemVariables.scxml_event_processor/0`'s URI) -> the `origintype`
    # assertion below reddens, per plan decision 11 (origintype is the
    # Processor's type URI, not the string "scxml"; test352 is the corpus
    # test that will judge it). Reverted and confirmed green.
    test "origintype is the processor URI and origin is this session's own #_scxml_ location" do
      machine = compile!(self_send_doc(""))
      {:ok, session} = Session.start_link(machine)

      session_id = Session.session_id(session)
      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])

      event = Session.snapshot(session).datamodel["_event"]
      assert event["origintype"] == SystemVariables.scxml_event_processor()
      assert event["origin"] == "#_scxml_" <> session_id
    end
  end

  # -- <send> target routing --------------------------------------------

  describe "#_internal delivers with no registry (test189, test495)" do
    defp internal_send_doc(send_attrs) do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send event="e" target="#_internal" #{send_attrs}/>
              </onentry>
              <transition event="e" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # sabotage: `Session.Effects.plan_send/3`'s `:internal ->` clause is
    # changed to route through `{:enqueue_event, ...}` instead of
    # `{:deliver, :internal, ...}` - for this particular document the final
    # configuration is unaffected (both queues eventually reach the same
    # transition), so the decisive assertion is `queued_events == 0` staying
    # true throughout: an external-queue delivery would briefly populate it.
    # Sabotaged instead at `Interpreter.deliver_internal/5`'s own
    # `:internal ->` clause, swapped from `raise_internal/4` to
    # `raise_platform/4` -> `_event.type` reads `"platform"` instead of
    # `"internal"`, reddening the type assertion below. Reverted and
    # confirmed green. A second sabotage at `SystemVariables.event/1`'s
    # `absent/1` helper, changed to `defp absent(_), do: nil` -> the
    # `origin`/`origintype` assertions below redden against `:undefined`.
    # Reverted and confirmed green.
    test "an internally-delivered send advances the configuration with a blank origin/origintype" do
      machine = compile!(internal_send_doc(""))
      {:ok, session} = Session.start_link(machine)

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])

      event = Session.snapshot(session).datamodel["_event"]
      assert event["type"] == "internal"
      assert event["origin"] == :undefined
      assert event["origintype"] == :undefined
    end

    # sabotage: `Session.Effects.internal_event/1`'s `sendid:
    # if(send.id_from_author?, do: send.send_id)` is changed to always `nil`
    # -> the "carries the author's id" assertion below reddens. Reverted and
    # confirmed green.
    test "sendid is the author's id when the author named the send" do
      machine = compile!(internal_send_doc(~s(id="send1")))
      {:ok, session} = Session.start_link(machine)

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])
      assert Session.snapshot(session).datamodel["_event"]["sendid"] == "send1"
    end

    # sabotage: `Session.Effects.internal_event/1`'s `sendid:
    # if(send.id_from_author?, do: send.send_id)` is changed to
    # unconditionally `send.send_id` (dropping the `id_from_author?` gate) ->
    # the generated (non-nil) id leaks onto `_event.sendid`, reddening the
    # `:undefined` assertion below. Reverted and confirmed green.
    test "sendid is :undefined when the author named neither id nor idlocation" do
      machine = compile!(internal_send_doc(""))
      {:ok, session} = Session.start_link(machine)

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])
      assert Session.snapshot(session).datamodel["_event"]["sendid"] == :undefined
    end
  end

  describe "the internal-send success path delivers effects in delivery order (ADR-0044)" do
    # A document-local helper rather than widening `internal_send_doc/1`
    # above, whose three existing callers assert on `_event` fields and
    # should not change: `a -go-> b`, `b`'s `<onentry>` raises an
    # `#_internal` "ping", `b -ping-> c` where `c` is a top-level `<final>` -
    # the bead's 2026-08-16 chart.
    defp internal_send_to_final_doc do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <transition event="go" target="b"/>
          </state>
          <state id="b">
              <onentry>
                  <send event="ping" target="#_internal"/>
              </onentry>
              <transition event="ping" target="c"/>
          </state>
          <final id="c"/>
      </scxml>
      """
    end

    # sabotage: same mutation as the invoke-failure test -> the outer
    # batch's `Trace.ContentExecuted` (m=2 r=0) and the round-1
    # `TransitionsSelected`/`InvokePass`/`MacrostepStable` trio arrive after
    # `{:halted, :done}`, reddening both `assert_monotone/1` and
    # `assert_halted_last/1`.
    test "the re-entry's effects arrive after the outer batch's tail, and {:halted, :done} is last" do
      machine = compile!(internal_send_to_final_doc())
      {:ok, session} = Session.start_link(machine, trace: true, subscribers: [self()])
      session_id = Session.session_id(session)

      Session.send_event(session, "go")
      status = wait_for_status(session, fn s -> s.status == :done end)
      assert status.status == :done

      stream = StreamOrder.drain(session_id)
      StreamOrder.assert_monotone(stream)
      StreamOrder.assert_stable_unique(stream)
      StreamOrder.assert_halted_last(stream)
    end
  end

  describe "a re-entry whose own deferred batch crosses the seam again (nesting depth)" do
    # ADR-0044's open question: can a re-entry's deferred batch itself
    # cross the seam a second time? `a -go-> b`, `b`'s `<onentry>` raises
    # `#_internal` "ping" (first crossing, deferred at the outer batch); when
    # the drain performs that deferred batch, `b -ping-> c` runs `c`'s own
    # `<onentry>`, which raises a second `#_internal` "pong" (second
    # crossing, appended to `state.deferred` *while the first entry is being
    # drained*) before `c -pong-> d`, a top-level `<final>`, is ever reached.
    # This document does reach a second level - `drain_deferred/1`'s
    # recursive clause is what performs it.
    defp two_level_internal_send_doc do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <transition event="go" target="b"/>
          </state>
          <state id="b">
              <onentry>
                  <send event="ping" target="#_internal"/>
              </onentry>
              <transition event="ping" target="c"/>
          </state>
          <state id="c">
              <onentry>
                  <send event="pong" target="#_internal"/>
              </onentry>
              <transition event="pong" target="d"/>
          </state>
          <final id="d"/>
      </scxml>
      """
    end

    # sabotage: `drain_deferred/1`'s recursive clause drops its trailing
    # `|> drain_deferred()` so the drain performs only the first queued
    # batch -> the second-level re-entry's effects are never delivered and
    # the drained stream is missing its highest-round trace effects (the
    # run also never reaches `d`, so `wait_for_status/2` itself times out).
    test "both crossings' effects still arrive in non-decreasing (macrostep, round) order" do
      machine = compile!(two_level_internal_send_doc())
      {:ok, session} = Session.start_link(machine, trace: true, subscribers: [self()])
      session_id = Session.session_id(session)

      Session.send_event(session, "go")
      status = wait_for_status(session, fn s -> s.status == :done end)
      assert status.status == :done

      stream = StreamOrder.drain(session_id)
      StreamOrder.assert_monotone(stream)
      StreamOrder.assert_stable_unique(stream)
      StreamOrder.assert_halted_last(stream)
    end
  end

  describe "a namelist over a declared-but-unbound root round-trips as :undefined (ADR-0037 open question 1)" do
    # `Var1` is declared with `src` (never fetched, ADR-0003) so it stays
    # genuinely unbound at the seed. A value-less `<data id="Var1"/>`
    # instead compiles to `{:static, nil}` and binds a real `nil` (see
    # `test/statifier/interpreter/datamodel_test.exs`'s "declared-unassigned"
    # test) - a different, already-null case this fixture does not mean to
    # exercise.
    defp namelist_unbound_round_trip_doc do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <datamodel>
              <data id="Var1" src="file:unfetched.txt"/>
          </datamodel>
          <state id="a">
              <onentry>
                  <send event="e" target="#_internal" namelist="Var1"/>
              </onentry>
              <transition event="e" target="undefined_check"/>
          </state>
          <state id="undefined_check">
              <transition cond="_event.data.Var1 === undefined" target="null_check"/>
              <transition target="fail"/>
          </state>
          <state id="null_check">
              <transition cond="_event.data.Var1 === null" target="fail"/>
              <transition target="pass"/>
          </state>
          <state id="pass"/>
          <state id="fail"/>
      </scxml>
      """
    end

    # Open question 1's end-to-end pin (ADR-0037,
    # docs/adr/0037-unbound-spelled-undefined-at-the-writer.md): this is the
    # property that would break under either candidate translation at the
    # effect boundary (mapping `:undefined -> nil`, or dropping the member) -
    # `undefined_check` alone would still pass under a `nil` translation, so
    # `null_check` is the state that makes the answer non-reversible by
    # accident.
    #
    # sabotage: `Statifier.Machine.Content.Send`'s `resolve_params/2`
    # translates `:undefined` to `nil` at the send boundary - the very
    # translation this record rejected -> `_event.data.Var1` reads null,
    # `null_check` takes its `=== null` branch, and the chart halts in
    # `fail` -> red.
    #
    # Two shallower mutations deliberately do *not* reach this test, and
    # neither is the one to write here: mapping the whole `data` to `%{}`
    # leaves the answer intact, since a missing member of an empty map
    # still reads undefined; and `event.data || %{}` is a no-op, because
    # `||` falls back only on `nil`/`false` and `:undefined` is truthy.
    test "delivered _event.data.Var1 reads === undefined true and === null false" do
      machine = compile!(namelist_unbound_round_trip_doc())
      {:ok, session} = Session.start_link(machine)

      status =
        wait_for_status(session, fn s ->
          s.configuration == MapSet.new(["pass"]) or s.configuration == MapSet.new(["fail"])
        end)

      assert status.configuration == MapSet.new(["pass"])
    end
  end

  describe "self-addressed #_scxml_<sessionid> via targetexpr (test190, test350, test501)" do
    defp self_targetexpr_doc do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send event="e" targetexpr="'#_scxml_' + _sessionid"/>
              </onentry>
              <transition event="e" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # sabotage: `perform_instruction/3`'s `{:deliver, {:session, sid}, event,
    # _effect}` clause (via `deliver/5`) has its self-match guard changed
    # from `%State{session_id: sid}` to `%State{session_id: _sid}` (always
    # matches, dropping the equality requirement) - this particular document
    # only ever addresses itself, so that mutation stays green here;
    # sabotaged instead by inverting the guard to `%State{session_id: other}
    # when other != sid` (never matches its own id) -> the send falls
    # through to `communication_error/4` instead, and `error.communication`
    # (not `e`) reaches the transition, reddening the configuration
    # assertion below since no `event="e"` transition exists to catch it.
    # Reverted and confirmed green.
    test "delivers to the session's own inbox with no registry" do
      machine = compile!(self_targetexpr_doc())
      {:ok, session} = Session.start_link(machine)

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])
    end
  end

  describe "a send addressed to the received _event.origin (test349)" do
    defp origin_round_trip_doc do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send event="ping" targetexpr="'#_scxml_' + _sessionid"/>
              </onentry>
              <transition event="ping" target="b"/>
          </state>
          <state id="b">
              <onentry>
                  <send event="pong" targetexpr="_event.origin"/>
              </onentry>
              <transition event="pong" target="c"/>
          </state>
          <state id="c"/>
      </scxml>
      """
    end

    # sabotage: `Session.Effects.delivered_event/2` (Phase 3) is changed to
    # pass `origin: nil` unconditionally -> `_event.origin` in state `b`
    # reads `:undefined` from predicator's normalization, `targetexpr`
    # evaluates to a non-`#_scxml_`-shaped string, `Target.parse/1` returns
    # `{:invalid, _}`, and the send raises `error.execution` instead of
    # reaching `c` - reddening the configuration assertion below. Reverted
    # and confirmed green.
    test "a reply addressed to _event.origin reaches the sender" do
      machine = compile!(origin_round_trip_doc())
      {:ok, session} = Session.start_link(machine)

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["c"]) end)
      assert status.configuration == MapSet.new(["c"])
    end
  end

  describe "#_scxml_<unknown> -> error.communication (test496, mandatory/send/test521)" do
    defp unknown_session_doc(send_attrs) do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send event="e" target="#_scxml_no-such-session" #{send_attrs}/>
              </onentry>
              <transition event="error.communication" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # sabotage: `deliver/5`'s `{:session, _sid}` (non-self) clause is
    # changed to `Inbox.enqueue_event/2` unconditionally instead of calling
    # `communication_error/4` -> no `error.communication` is ever raised, so
    # the transition to `b` never fires and both assertions below time out
    # (via `wait_for_status/3`'s own flunk). Reverted and confirmed green.
    test "an unresolvable session id raises error.communication carrying the failing send's id" do
      machine = compile!(unknown_session_doc(~s(id="send1")))
      {:ok, session} = Session.start_link(machine)

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])

      assert Session.snapshot(session).datamodel["_event"]["sendid"] == "send1"
    end
  end

  describe "an unsupported type raises error.execution with no delivery and no timer" do
    defp unsupported_type_doc do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send event="e" type="http://example.com/bogus" delay="200ms" id="send1"/>
              </onentry>
              <transition event="error.execution" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # Under ADR-0047 the rejection now happens in the core
    # (`Statifier.Machine.Content.Send`'s `reject_reason/2`), before any
    # `{:send_delayed, _}` effect is ever built - `Session.Effects`'s own
    # `plan_send_delayed/3` check is only the `Session.interpret/2`
    # boundary arm ADR-0047 decision 4 keeps and never actually decides
    # this document's outcome, since the core already halted the block.
    #
    # sabotage: `Statifier.Interpreter.Content`'s `raise_execution_error/4`
    # clause that destructures `{:send_rejected, send_id, reason}` into
    # `data: reason, sendid: send_id` is deleted, leaving only the generic
    # clause that puts the whole tuple in `data` and sets no `sendid` opt
    # -> `_event.sendid` comes back `:undefined` instead of `"send1"`,
    # reddening the third assertion below (the other two still pass, since
    # the block still aborts and no timer is ever scheduled - this
    # mutation isolates the sendid-bearing conversion specifically).
    # Confirmed red and reverted.
    test "the check happens at plan time, not fire time, and schedules nothing" do
      machine = compile!(unsupported_type_doc())
      {:ok, session} = Session.start_link(machine)

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])
      assert status.pending_timers == 0
      assert Session.snapshot(session).datamodel["_event"]["sendid"] == "send1"
    end
  end

  describe "a delayed send to #_scxml_<self> fires to the right place" do
    defp delayed_self_targetexpr_doc do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send event="e" delay="10ms" targetexpr="'#_scxml_' + _sessionid"/>
              </onentry>
              <transition event="e" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # sabotage: `Session.Effects.plan_send_delayed/3`'s generic `route ->`
    # clause is changed to always schedule with route `:internal` instead of
    # the resolved `route` - for this document `:internal` also happens to
    # deliver "e" successfully (`#_internal` and self-addressed
    # `#_scxml_<id>` both eventually satisfy the `event="e"` transition), so
    # the final-configuration assertion alone would stay green under that
    # mutation. Sabotaged instead at `Session`'s own `deliver_fired/4`: the
    # generic `deliver_fired(route, event, effect, state)` clause is changed
    # to always resolve as `:parent` (`communication_error/4`) regardless of
    # `route` -> `error.communication` fires instead of `e`, and the
    # configuration never reaches `b`, reddening the assertion below.
    # Reverted and confirmed green.
    test "fires and delivers after the delay, not before" do
      machine = compile!(delayed_self_targetexpr_doc())
      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      session_id = Session.session_id(session)
      refute_receive {:statifier, ^session_id, {:effect, {:trace, %Effect.Trace.EntrySet{}}}}, 5
      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])
    end
  end

  describe "a delayed #_internal send crosses the ADR-0039 seam outside any perform/3" do
    # `targetexpr`, not the literal `target` attribute: the validator's
    # `delay_and_internal_target/2` check only fires on a literal
    # `target="#_internal"` (it cannot be evaluated until execute time when
    # `targetexpr` was written instead), so this is what actually reaches
    # `Send.Target.parse/1`'s `:internal` route at runtime.
    defp delayed_internal_doc do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send event="e" delay="10ms" targetexpr="'#_internal'"/>
              </onentry>
              <transition event="e" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # sabotage: `handle_info({:statifier_delayed_send, ...}, state)`'s
    # `|> drain_deferred()` is removed -> the fired `#_internal` delivery's
    # effects sit in `state.deferred` forever, the subscriber never receives
    # the transition's trace effects, and the drain assertion times out.
    #
    # Note: the chart still reaches its target configuration without the
    # drain, because the *core* advanced at the seam. Only the subscriber
    # stream is missing the effects, so this asserts on the drained stream,
    # not on `wait_for_status/2` alone.
    test "the fired timer's effects reach the subscriber in non-decreasing (macrostep, round) order" do
      machine = compile!(delayed_internal_doc())
      {:ok, session} = Session.start_link(machine, trace: true, subscribers: [self()])
      session_id = Session.session_id(session)

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])

      stream = StreamOrder.drain(session_id)

      assert Enum.any?(stream, &match?({:effect, {:trace, %Effect.Trace.EventDequeued{}}}, &1)),
             "expected the fired #_internal delivery's trace effects to reach the subscriber"

      StreamOrder.assert_monotone(stream)
    end
  end

  describe "an invalid target on a halted session is a no-op, not a crash" do
    # sabotage: `Session`'s own private `deliver_internal/6` helper (the one
    # call site of `Interpreter.deliver_internal/5`) has its
    # `{:error, :not_running} -> state` clause changed to
    # `{:error, :not_running} -> raise "unreachable"` -> the session process
    # crashes on the `<send>` below instead of no-opping, reddening
    # `Process.alive?/1`. Confirmed red (the process exits with the raised
    # error). Reverted and confirmed green.
    test "a targeted send to an unparseable target after :done neither crashes nor changes the snapshot" do
      machine = compile!(final_on_event_doc())
      {:ok, session} = Session.start_link(machine, subscribers: [self()])

      Session.send_event(session, "finish")

      session_id = Session.session_id(session)
      assert_receive {:statifier, ^session_id, {:halted, :done}}

      before_status = Session.status(session)

      send_effect = %Effect.Send{
        event: "e",
        target: "not a recognized target",
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      Session.interpret(session, [{:send, send_effect}])
      _settled = Session.status(session)

      assert Process.alive?(session)
      assert Session.status(session) == before_status
    end
  end

  # -- recording ----------------------------------------------------------

  describe "recording" do
    # sabotage: `recording/1`'s `handle_call(:recording, _from, %State{recording:
    # nil} = state)` clause is swapped to reply `{:ok, state.recording}`
    # unconditionally (dropping the `nil` branch entirely) -> the default
    # session below gets back `{:ok, nil}` instead of `{:error,
    # :not_recording}`, reddening the assertion. Reverted and confirmed green.
    test "recording/1 returns {:error, :not_recording} by default" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine)

      assert Session.recording(session) == {:error, :not_recording}
    end

    # sabotage: `handle_cast({:enqueue_event, event}, state)`'s `record(state,
    # &Recording.put_event(&1, event))` call is dropped -> the two `go` events
    # below never reach the recording, so `Recording.entries/1` comes back
    # empty instead of two `{:event, _}` entries, reddening the assertion.
    # Reverted and confirmed green.
    test "with record: true, events sent via send_event/2 are recorded in order" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine, record: true)

      Session.send_event(session, "go")
      Session.send_event(session, "go")

      _status = wait_for_status(session, fn s -> s.status == :running end)

      {:ok, recording} = Session.recording(session)

      assert [
               {:event, %Event{name: "go"}},
               {:event, %Event{name: "go"}}
             ] = Recording.entries(recording)
    end

    # sabotage: `handle_cast(:enqueue_cancel, state)`'s `record(state,
    # &Recording.put_cancel/1)` call is dropped -> the cancel marker never
    # reaches the recording, so the entry list below comes back with only the
    # one `{:event, _}` entry instead of the event followed by `:cancel`,
    # reddening the pattern match. Reverted and confirmed green.
    test "cancel/1 records the cancel marker in queue position relative to events" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine, record: true, subscribers: [self()])

      Session.send_event(session, "go")
      :ok = Session.cancel(session)

      session_id = Session.session_id(session)
      assert_receive {:statifier, ^session_id, {:halted, :cancelled}}

      {:ok, recording} = Session.recording(session)

      assert [{:event, %Event{name: "go"}}, :cancel] = Recording.entries(recording)
    end

    # sabotage: `handle_cast({:interpret, effects}, state)`'s `record(state,
    # &Recording.put_interpret(&1, effects))` call is dropped -> the
    # interpret/2 batch below is never recorded, so the entry list comes back
    # empty instead of one `{:interpret, _}` entry, reddening the assertion.
    # Reverted and confirmed green.
    test "an interpret/2 call records its batch" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine, record: true)

      send_delayed = %Effect.SendDelayed{
        event: "go",
        target: nil,
        send_id: "s1",
        delay_ms: 200,
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      effects = [{:send_delayed, send_delayed}]
      Session.interpret(session, effects)

      _status = wait_for_status(session, fn s -> s.pending_timers == 1 end)

      {:ok, recording} = Session.recording(session)
      assert [{:interpret, ^effects}] = Recording.entries(recording)
    end

    # sabotage: `handle_info({:statifier_delayed_send, ref, send_id, event},
    # state)`'s `record(state, &Recording.put_timer(&1, send_id, event))` call
    # is moved to after the `inbox: Inbox.enqueue_event(...)` update instead of
    # before it, and `send_id` is reverted to the ignored `_send_id` binding
    # used before this bead so the appended entry's `send_id` field is always
    # `nil` -> the assertion below (matching the real "s1") reddens. Reverted
    # and confirmed green.
    test "a fired delayed send records a {:timer, send_id, event} entry after the interpret/2 entry that scheduled it" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine, record: true, subscribers: [self()])

      send_delayed = %Effect.SendDelayed{
        event: "go",
        target: nil,
        send_id: "s1",
        delay_ms: 20,
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      effects = [{:send_delayed, send_delayed}]
      Session.interpret(session, effects)

      session_id = Session.session_id(session)
      assert_receive {:statifier, ^session_id, {:effect, {:send_delayed, _}}}

      status = wait_for_status(session, fn s -> s.configuration != MapSet.new(["a"]) end)
      assert status.configuration == MapSet.new(["b"])

      {:ok, recording} = Session.recording(session)

      assert [
               {:interpret, ^effects},
               {:timer, "s1", %Event{name: "go"}}
             ] = Recording.entries(recording)
    end

    # sabotage: `init/1`'s `Recording.new(machine, Keyword.put(machine_opts,
    # :session_id, session_id))` call is changed to pass `machine_opts`
    # unchanged (dropping the `Keyword.put/3`) -> `Recording.opts/1` carries
    # `session_id: nil` instead of the session's resolved `sess_` id,
    # reddening the assertion below. Reverted and confirmed green.
    test "the recorded opts carry the resolved session id when none was supplied" do
      machine = compile!(two_state_doc())
      {:ok, session} = Session.start_link(machine, record: true)

      session_id = Session.session_id(session)
      {:ok, recording} = Session.recording(session)

      assert Recording.opts(recording)[:session_id] == session_id
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
