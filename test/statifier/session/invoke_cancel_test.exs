defmodule Statifier.Session.InvokeCancelTest do
  use ExUnit.Case, async: false

  # Same reason as `invoke_start_child_test.exs`: every test that starts a
  # real child places `Statifier.Supervisor` (a fixed, module-qualified
  # singleton), so this module is `async: false`.

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Event
  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Replay
  alias Statifier.Session
  alias Statifier.Session.Inbox
  alias Statifier.Session.Invocations
  alias Statifier.Session.Recording
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # A child whose `<onexit>` both proves it ran (an assignment
  # `Session.snapshot/1` can read back) and tries to talk to the parent
  # (`#_parent`, invokeid-stamped) - the send the parent must discard once
  # the invocation is cancelled, per 6.4.3's MUST-NOT-insert sentence.
  @child_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0" datamodel="predicator"><datamodel><data id="onexited" expr="false"/></datamodel><state id="run"><onexit><assign location="onexited" expr="true"/><send target="#_parent" event="onexit.child"/></onexit></state></scxml>)

  defp content_body, do: "<content><![CDATA[#{@child_xml}]]></content>"

  defp parent_xml do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <invoke type="scxml">
                #{content_body()}
            </invoke>
            <transition event="leave" target="b"/>
            <transition event="onexit.child" target="saw_onexit"/>
            <transition event="done.invoke.*" target="saw_done"/>
        </state>
        <state id="b">
            <transition event="onexit.child" target="saw_onexit"/>
            <transition event="done.invoke.*" target="saw_done"/>
        </state>
        <state id="saw_onexit"/>
        <state id="saw_done"/>
    </scxml>
    """
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

  # -- the drain-time discard, in isolation ----------------------------------

  describe "an event whose invokeid names no live invocation" do
    # sabotage: `handle_continue(:drain, state)`'s new discard branch (`if
    # id != nil and not Invocations.live?(state.invocations, id)`) is
    # inverted to `if id == nil or Invocations.live?(...)` -> the ghost event
    # is delivered to the core instead of discarded, so the parent takes the
    # "ghost" transition and lands on "ghost_reached" instead of
    # "ping_reached", reddening the assertion. Reverted and confirmed green.
    test "is dropped at drain time; the drain continues to the next entry" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
            <state id="a">
                <transition event="ghost" target="ghost_reached"/>
                <transition event="ping" target="ping_reached"/>
            </state>
            <state id="ghost_reached"/>
            <state id="ping_reached"/>
        </scxml>
        """)

      {:ok, parent} = Session.start_link(machine)

      # No `<invoke>` was ever started, so `state.invocations` is empty and
      # "inv_dead" names nothing live - the same predicate a real cancel
      # leaves behind once it pops the entry.
      ghost = Event.external("ghost", invokeid: "inv_dead")

      :sys.replace_state(parent, fn state ->
        %{state | inbox: Inbox.enqueue_event(state.inbox, ghost)}
      end)

      Session.send_event(parent, Event.external("ping"))

      status =
        wait_for_status(parent, fn s -> s.configuration == MapSet.new(["ping_reached"]) end)

      assert status.configuration == MapSet.new(["ping_reached"])
    end
  end

  # -- end to end: cancelling a real child ----------------------------------

  describe "exiting the invoking state" do
    # sabotage: three mutations, each reverted and confirmed green:
    # 1. `Statifier.Session`'s `{:stop_child, invoke_id}` clause drops its
    #    `cancel(pid)` call entirely (keeps only the pop/demonitor) -> the
    #    child never receives a cancel marker, so `wait_for_status` below
    #    times out waiting for `:cancelled`.
    # 2. That same clause's `cancel(pid)` is replaced with
    #    `GenServer.stop(pid, :normal)` -> the child's process exits without
    #    ever running `Interpreter.cancel/1`'s `exit_interpreter/1` walk, so
    #    its `<onexit>` never runs and `onexited` stays `false` in the
    #    (now-dead) child's last known datamodel, reddening the `onexited`
    #    assertion specifically (the `:cancelled` assertion above it would
    #    also fail differently, since a stopped process cannot answer
    #    `status/1` at all).
    # 3. `handle_continue(:drain, state)`'s discard branch is removed
    #    entirely (falls through to the ordinary `drain_event` clause) -> the
    #    child's `#_parent` "onexit.child" send is delivered to the core, so
    #    the parent lands on "saw_onexit" instead of staying on "b",
    #    reddening the configuration assertion.
    test "stops the child, runs its <onexit>, and discards what it sends back; no done.invoke" do
      start_supervised!(Statifier.Supervisor)

      machine = compile!(parent_xml())
      {:ok, parent} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: invoke_id}}}}

      %{invocations: invocations} = :sys.get_state(parent)
      assert {:ok, %{pid: child_pid}} = Invocations.fetch(invocations, invoke_id)

      Session.send_event(parent, Event.external("leave"))

      assert_receive {:statifier, ^session_id,
                      {:effect, {:cancel_invoke, %Effect.CancelInvoke{invoke_id: ^invoke_id}}}}

      status = wait_for_status(child_pid, fn s -> s.status == :cancelled end)
      assert status.status == :cancelled

      # The child's own `<onexit>` content ran, even though the process is
      # now halted - `snapshot/1` still answers a `:cancelled` session
      # (`Statifier.Session`'s own "`:done` idles the session" section).
      assert Session.snapshot(child_pid).datamodel["onexited"] == true

      # The table entry is gone - the parent is silent by construction.
      assert Invocations.count(:sys.get_state(parent).invocations) == 0

      # Whatever the child's onexit sent to `#_parent` (and any done.invoke,
      # had the child's exit walk produced one) was discarded: the parent
      # took only the "leave" transition, never "saw_onexit" or "saw_done".
      final_status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert final_status.configuration == MapSet.new(["b"])
    end
  end

  # -- parent termination ----------------------------------------------------

  describe "stopping the parent" do
    # sabotage: `terminate/2`'s new `Enum.each(fn {_id, %{pid: pid}} ->
    # cancel(pid) end)` walk over `Invocations.entries/1` is dropped entirely
    # -> the child is never told to cancel, so `terminate/2`'s own
    # `cancel(pid)` call never happens and the child never runs its cancel
    # walk before it dies from its own (Phase 2) parent-monitor `:DOWN` -
    # the assertion below reddens waiting for `{:halted, :cancelled}` that
    # never arrives. Reverted and confirmed green.
    #
    # This subscribes to the *child*'s own effect stream rather than
    # polling `status/1`, because the child's Phase 2 parent-monitor stops
    # its whole process the instant it sees this session's own `:DOWN`
    # (any exit reason, `monitor_parent/1`'s own comment) - by the time
    # `Session.stop/2` returns here, the child process may already be gone,
    # so `status/1`/`snapshot/1` cannot be relied on to observe it
    # afterward. `terminate/2`'s `cancel(pid)` cast is what this test proves
    # ran: it is sent before this session actually exits, so it is
    # guaranteed to reach and be processed by the child strictly before that
    # same exit's `:DOWN` message does, meaning the child's cancel walk
    # (and its `{:halted, :cancelled}` notification) always completes before
    # the child stops itself - the ordering the subscriber message below
    # captures regardless of what happens to the child process afterward.
    test "cancels every still-live child" do
      start_supervised!(Statifier.Supervisor)

      machine = compile!(parent_xml())
      {:ok, parent} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: invoke_id}}}}

      %{invocations: invocations} = :sys.get_state(parent)
      assert {:ok, %{pid: child_pid}} = Invocations.fetch(invocations, invoke_id)

      child_session_id = Session.session_id(child_pid)
      Session.subscribe(child_pid, self())

      Session.stop(parent)

      assert_receive {:statifier, ^child_session_id, {:halted, :cancelled}}
    end
  end

  # -- ADR-0034 round trip ----------------------------------------------------

  describe "a live run versus Replay over the same recording" do
    # sabotage: `Statifier.Replay`'s `perform_instruction({:stop_child,
    # invoke_id}, state, _override)` clause is changed from `MapSet.delete`
    # to a no-op (`state`) -> `live_invoke_ids` keeps the cancelled
    # invocation's id forever, so `apply_entry/2`'s `{:event, _}` clause
    # never discards the child's recorded "onexit.child" entry the way the
    # live run did - Replay instead *delivers* it to the core, taking the
    # parent's "saw_onexit" transition, so `result.machine_state.configuration`
    # reddens against `live_configuration` (which stayed on "b"). Reverted
    # and confirmed green.
    test "over a recording containing a start, a discard, and a cancel, both reach the same donedata configuration" do
      start_supervised!(Statifier.Supervisor)

      machine = compile!(parent_xml())
      {:ok, parent} = Session.start_link(machine, subscribers: [self()], record: true)
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: invoke_id}}}}

      Session.send_event(parent, Event.external("leave"))

      assert_receive {:statifier, ^session_id,
                      {:effect, {:cancel_invoke, %Effect.CancelInvoke{invoke_id: ^invoke_id}}}}

      # Give the (now-cancelled) child's asynchronous `<onexit>` send a
      # chance to actually arrive and be recorded - it always is, discarded
      # or not, since `record/2` taps the input clause ahead of the drain's
      # own decision (`Statifier.Session`'s own moduledoc, "Recording taps
      # the input clauses, never the inbox").
      wait_until(fn ->
        {:ok, recording} = Session.recording(parent)

        Enum.any?(
          Recording.entries(recording),
          &match?({:event, %Event{name: "onexit.child"}}, &1)
        )
      end)

      live_status = Session.status(parent)
      assert live_status.configuration == MapSet.new(["b"])

      # The parent itself never halts in this scenario - only the child's
      # invocation is cancelled - so `snapshot/1`'s raw, index-based
      # configuration is still live (not emptied by `exit_interpreter/1`,
      # which only ever runs for *this* session's own termination).
      live_configuration = Session.snapshot(parent).configuration

      {:ok, recording} = Session.recording(parent)
      assert {:ok, result} = Replay.run(recording)

      # The recorded stream's own `{:invoke, _}`/`{:cancel_invoke, _}`
      # effects are what re-derive `live_invoke_ids` (Decision 6) - re-check
      # they are present, so a future change that stops emitting either
      # can't silently make this test vacuous.
      assert Enum.any?(result.stream, &match?({:effect, {:invoke, _}}, &1))
      assert Enum.any?(result.stream, &match?({:effect, {:cancel_invoke, _}}, &1))
      assert result.status == :running

      assert result.machine_state.configuration == live_configuration
    end
  end
end
