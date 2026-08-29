defmodule Statifier.Session.ParallelFirstLaneCancelTest do
  use ExUnit.Case, async: false

  # `async: false` for the same reason `invoke_start_child_test.exs` and
  # `invoke_handler_test.exs` are: every test here starts a real `type="scxml"`
  # child on `Statifier.SessionSupervisor`, the fixed module-qualified
  # singleton `test/test_helper.exs` places once for the whole run, and
  # registers a named listener process for the handler-backed lane.

  alias Statifier.{Compiler, Effect, Event, Lowering, Parser, Session, StreamOrder, Validator}
  alias Statifier.Effect.Invoke
  alias Statifier.Session.Invocations

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp wait_for_status(session, pred, attempts \\ 100)
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

  # The handler-backed lane's probe. Modelled on
  # `invoke_handler_test.exs`'s `LifecycleHandler`: `cancel/2` splices an
  # observable `{:handler, __MODULE__, _}` marker in *alongside* the
  # `{:stop_child, invoke_id}` that actually pops the table entry, so a test
  # can tell "this handler's own `cancel/2` was planned" apart from "the
  # built-in scxml handler happened to plan the identical instruction".
  # That distinction is the whole point of the mirror case below.
  defmodule ProbeHandler do
    @moduledoc false
    @behaviour Statifier.Invoke.Handler

    @impl Statifier.Invoke.Handler
    def start(%Invoke{invoke_id: invoke_id}, _ctx) do
      {:ok, [{:handler, __MODULE__, {:start, invoke_id}}]}
    end

    @impl Statifier.Invoke.Handler
    def cancel(invoke_id, _ctx) do
      {:ok, [{:handler, __MODULE__, {:cancel, invoke_id}}, {:stop_child, invoke_id}]}
    end

    @impl Statifier.Invoke.Handler
    def forward(invoke_id, event, _ctx) do
      {:ok, [{:handler, __MODULE__, {:forward, invoke_id, event}}]}
    end

    @impl Statifier.Invoke.Handler
    def perform(message, _ctx) do
      send(:parallel_first_lane_test_listener, message)
      :ok
    end
  end

  # The `type="scxml"` lane's child. Its one non-final state carries an
  # `<onexit>` whose `<assign>` is readable back through `snapshot/1` even
  # after the session halts, which is how the losing-lane case proves the
  # child ran its *own* exit walk rather than merely being stopped. The
  # `finish` transition is what the winning-lane case uses to complete the
  # child on demand, so both cases share one child document.
  @child_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0" datamodel="predicator"><datamodel><data id="onexited" expr="false"/></datamodel><state id="run"><onexit><assign location="onexited" expr="true"/></onexit><transition event="finish" target="over"/></state><final id="over"/></scxml>)

  # The first-lane-wins ruling's Arm A shape (2026-08-29), by hand as a
  # blocks compiler would emit it: one transition per lane on the
  # `<parallel>` element itself, taken on that lane's own completion event
  # (`done.state.<lane>`) and targeting the block's done `<final>`. Neither
  # lane is a `<final>`-on-all-lanes join, so nothing here relies on the
  # native all-lanes `done.state.lanes`.
  #
  # `block`'s own `done.invoke.*` transition is the no-done.invoke probe:
  # it sits on the compound state that stays in the configuration after the
  # parallel is exited, so any `done.invoke` that reaches the core - from
  # the cancelled child, or from a late report for it - moves the chart to
  # `saw_done`. A lane's own `done.invoke.<id>` transition is a descendant
  # of it and preempts it (Appendix D `removeConflictingTransitions`), so
  # the probe never swallows a lane's legitimate completion.
  defp block_xml do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="block">
        <state id="block" initial="lanes">
            <transition event="done.invoke.*" target="saw_done"/>
            <parallel id="lanes">
                <transition event="done.state.child_lane" target="block_done"/>
                <transition event="done.state.probe_lane" target="block_done"/>
                <state id="child_lane" initial="child_work">
                    <state id="child_work">
                        <invoke id="inv_child" type="scxml">
                            <content><![CDATA[#{@child_xml}]]></content>
                        </invoke>
                        <onexit>
                            <log label="child-lane-exit"/>
                        </onexit>
                        <transition event="done.invoke.inv_child" target="child_ready"/>
                    </state>
                    <final id="child_ready"/>
                </state>
                <state id="probe_lane" initial="probe_work">
                    <state id="probe_work">
                        <invoke id="inv_probe" type="test:probe"/>
                        <onexit>
                            <log label="probe-lane-exit"/>
                        </onexit>
                        <transition event="done.invoke.inv_probe" target="probe_ready"/>
                    </state>
                    <final id="probe_ready"/>
                </state>
            </parallel>
            <final id="block_done"/>
        </state>
        <state id="saw_done"/>
    </scxml>
    """
  end

  # Starts the block, waits for both lanes' invocations to be live, and
  # answers the pieces both cases need.
  defp start_block do
    Process.register(self(), :parallel_first_lane_test_listener)

    {:ok, parent} =
      Session.start_link(compile!(block_xml()),
        subscribers: [self()],
        invoke_handlers: %{"test:probe" => ProbeHandler}
      )

    session_id = Session.session_id(parent)

    assert_receive {:statifier, ^session_id,
                    {:effect, {:invoke, %Effect.Invoke{invoke_id: "inv_child"}}}},
                   1_000

    assert_receive {:statifier, ^session_id,
                    {:effect, {:invoke, %Effect.Invoke{invoke_id: "inv_probe"}}}},
                   1_000

    assert_receive {:start, "inv_probe"}, 1_000

    %{invocations: invocations} = :sys.get_state(parent)
    assert {:ok, %{pid: child_pid}} = Invocations.fetch(invocations, "inv_child")

    %{parent: parent, session_id: session_id, child_pid: child_pid}
  end

  defp index_of(stream, fun), do: Enum.find_index(stream, fun)

  defp log_index(stream, label) do
    index_of(stream, &match?({:effect, {:log, %Effect.Log{label: ^label}}}, &1))
  end

  defp cancel_index(stream, invoke_id) do
    index_of(
      stream,
      &match?({:effect, {:cancel_invoke, %Effect.CancelInvoke{invoke_id: ^invoke_id}}}, &1)
    )
  end

  defp in_block_done?(status) do
    MapSet.member?(status.configuration, "block_done")
  end

  describe "the handler-backed lane completes first" do
    # sabotage: `Statifier.Interpreter.ExitEntry.depart/2`'s final
    # `{machine_state, onexit_effects ++ cancel_effects}` is changed to
    # `cancel_effects ++ onexit_effects` -> every lane's `CancelInvoke` now
    # precedes its own `<onexit>` log in the drained stream, reddening this
    # test's `assert child_exit_log < child_cancel` (observed 4 < 3) and
    # the mirror's `assert probe_exit_log < probe_cancel` alike; the
    # `:cancelled` child and the discard assertions stay green, which is
    # what makes the ordering assertion the load-bearing one here rather
    # than a restatement of `cancel_invoke_test.exs`'s single-lane pin.
    # Confirmed red and reverted.
    #
    # sabotage 2: `Statifier.Session`'s `{:stop_child, invoke_id}` clause's
    # `cancel(pid)` call is replaced with `GenServer.stop(pid, :normal)` ->
    # the scxml child dies without running `Interpreter.cancel/1`'s exit
    # walk, so `wait_for_status(child_pid, ...)` below exits on a
    # `GenServer.call` to a dead process instead of ever seeing
    # `:cancelled`, and the `onexited` assign it would have run never
    # happens; the ordering half stays green. Confirmed red and reverted.
    test "the scxml lane runs its onexit before its CancelInvoke, halts :cancelled, and sends no done.invoke" do
      %{parent: parent, session_id: session_id, child_pid: child_pid} = start_block()

      # The winning lane: the host reports the handler-backed invocation
      # complete through ADR-0051 decision 5's own door. `probe_work`'s
      # `done.invoke.inv_probe` transition takes `probe_lane` to its
      # `<final>`, raising `done.state.probe_lane`, which the `<parallel>`'s
      # own transition takes to the block's done `<final>`.
      Session.done_invocation(parent, "inv_probe", nil)

      status = wait_for_status(parent, &in_block_done?/1)
      assert in_block_done?(status)
      refute MapSet.member?(status.configuration, "saw_done")

      stream = StreamOrder.drain(session_id)

      # Appendix D exit semantics on the losing lane, in the ruled order:
      # `<onexit>` first, then one `CancelInvoke` per live invocation.
      child_exit_log = log_index(stream, "child-lane-exit")
      child_cancel = cancel_index(stream, "inv_child")

      assert is_integer(child_exit_log)
      assert is_integer(child_cancel)
      assert child_exit_log < child_cancel

      # The winning lane is exited by the same transition, so it runs its
      # own `<onexit>` too - and it still draws a `CancelInvoke` for the
      # invocation that just completed. That is not a second losing lane:
      # `done_invocation/3` pops the *session*'s `Invocations` table, while
      # the pure core's `active_invocations` record is removed in exactly
      # one place, `ExitEntry.cancel_one_invocation/4`, on exit. The core
      # has no completion signal to clear it earlier, so the winner's
      # already-finished invocation is cancelled on the way out, in the same
      # onexit-then-cancel order. Spec 6.4.3 makes that harmless (a cancel
      # for an invocation that is already over), and the built-in scxml
      # handler's own `{:stop_child, _}` is a no-op on a popped entry - but
      # a handler author reading `Statifier.Invoke.Handler`'s idempotency
      # contract should know `cancel/2` can be planned for an invocation
      # they have already reported done through `done_invocation/3`.
      probe_exit_log = log_index(stream, "probe-lane-exit")
      probe_cancel = cancel_index(stream, "inv_probe")

      assert is_integer(probe_exit_log)
      assert is_integer(probe_cancel)
      assert probe_exit_log < probe_cancel

      # 6.4.3: the child halts `:cancelled` having run its *own* `<onexit>`.
      child_status = wait_for_status(child_pid, fn s -> s.status == :cancelled end)
      assert child_status.status == :cancelled
      assert Session.snapshot(child_pid).datamodel["onexited"] == true

      # No `done.invoke` from the cancelled child reached the parent: the
      # `done.invoke.*` probe on `block` is still armed and untaken.
      assert Session.invocations(parent) == []
      refute MapSet.member?(Session.status(parent).configuration, "saw_done")

      # ADR-0068 decision 4's drain-time discard: a completion reported for
      # the cancelled invocation after the fact is dropped, not delivered.
      Session.done_invocation(parent, "inv_child", %{"late" => true})

      status = wait_for_status(parent, &in_block_done?/1)
      assert in_block_done?(status)
      refute MapSet.member?(status.configuration, "saw_done")
    end
  end

  describe "the scxml lane completes first" do
    # sabotage: `Statifier.Session.Effects.plan_one/2`'s `:cancel_invoke`
    # arm is changed back to its pre-ADR-0051 shape, `[{:notify, effect},
    # {:stop_child, invoke_id}]` (bypassing `handler_for/2` entirely) ->
    # `ProbeHandler.cancel/2` is never called, so the `{:cancel,
    # "inv_probe"}` marker never reaches the listener and the
    # `assert_receive` below times out. The whole of the sibling test above
    # stays green under this mutation, and this test's own ordering
    # assertion never runs (the timeout comes first) - which is what makes
    # the handler-dispatch assertion the load-bearing one in this mirror.
    # Confirmed red and reverted.
    test "the probe handler's cancel/2 is planned for the losing lane, after its onexit" do
      %{parent: parent, session_id: session_id, child_pid: child_pid} = start_block()

      # The winning lane, the other kind: the scxml child reaches its own
      # `<final>`, which returns `done.invoke.inv_child` to the parent
      # (`return_done_event/2`). `child_work`'s transition takes
      # `child_lane` to its `<final>`, raising `done.state.child_lane`.
      Session.send_event(child_pid, Event.external("finish"))

      status = wait_for_status(parent, &in_block_done?/1)
      assert in_block_done?(status)

      # The winning lane's `done.invoke.inv_child` was taken by
      # `child_work`'s own descendant transition, never by `block`'s
      # `done.invoke.*` probe.
      refute MapSet.member?(status.configuration, "saw_done")

      # ADR-0051 decision 6: the losing lane's cancel is planned through
      # the registered handler's own `cancel/2`, not through the built-in
      # scxml handler.
      assert_receive {:cancel, "inv_probe"}, 1_000

      stream = StreamOrder.drain(session_id)

      probe_exit_log = log_index(stream, "probe-lane-exit")
      probe_cancel = cancel_index(stream, "inv_probe")

      assert is_integer(probe_exit_log)
      assert is_integer(probe_cancel)
      assert probe_exit_log < probe_cancel

      # The winning lane draws a `CancelInvoke` of its own, for the same
      # reason the mirror case above records at length: the core clears
      # `active_invocations` only on exit, so the child that already
      # returned `done.invoke.inv_child` is cancelled on the way out too.
      # It is already halted `:done` by then, so nothing about its own exit
      # walk changes.
      assert is_integer(cancel_index(stream, "inv_child"))
      assert Session.status(child_pid).status == :done

      assert Session.invocations(parent) == []
    end
  end
end
