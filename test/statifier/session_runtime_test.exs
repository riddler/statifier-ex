defmodule Statifier.SessionRuntimeTest do
  use ExUnit.Case, async: false

  # `Statifier.start_session/2` lands sessions on `Statifier.SessionSupervisor`
  # under `Statifier.Supervisor`, a fixed, module-qualified singleton
  # (ADR-0027's "one instance, no `:name` option") that `test/test_helper.exs`
  # places once for the whole run. `async: false` here is what makes it safe
  # for the "stays unregistered" test below to reach into that shared runtime
  # and manually cycle `Statifier.Registry` for the span its own scenario
  # needs it down - by the time any `async: false` module runs, every
  # `async: true` module has already finished (`ExUnit.Runner`'s own
  # async-then-sync scheduling), and `async: false` modules never overlap
  # each other either, so no concurrently running session can observe the
  # registry mid-cycle.

  alias Statifier.{Compiler, Lowering, Parser, Session, Validator}
  alias Statifier.Send.Routes

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp receiver_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="ping" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """
  end

  defp sender_doc(target) do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <send event="ping" target="#{target}" id="send1"/>
            </onentry>
            <transition event="error.communication" target="failed"/>
        </state>
        <state id="failed"/>
    </scxml>
    """
  end

  # ADR-0048 decision 6 exempts a delayed send from the plan-time
  # reachability check outright, so its route is always resolved at fire
  # time, on `Statifier.Session`'s own `deliver_fired/4` - regardless of
  # whether the target was ever reachable when the `<send>` itself ran. This
  # is what makes a delayed send to a target that dies later a deterministic
  # way to exercise ADR-0048 decision 5's residual path, with no dependency
  # on `Statifier.Registry`'s own deregistration timing.
  defp delayed_sender_doc(target) do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <send event="ping" target="#{target}" id="send1" delay="10ms"/>
            </onentry>
            <transition event="error.communication" target="failed"/>
        </state>
        <state id="failed"/>
    </scxml>
    """
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

  # sabotage: `Statifier.start_session/2`'s child spec is changed from
  # `restart: :temporary` to `restart: :permanent` -> this test itself stays
  # green (nothing here crashes a session), which is exactly why ADR-0027
  # decision 4 is instead exercised directly by asserting the source line
  # below rather than by a runtime assertion; grep is the mechanical check
  # here, not a sabotage of running behavior.
  test "session.ex declares restart: :temporary" do
    source = File.read!(Path.join([__DIR__, "..", "..", "lib", "statifier", "session.ex"]))
    assert source =~ "use GenServer, restart: :temporary"
  end

  describe "Statifier.start_session/2 registers, so cross-session #_scxml_<sessionid> delivers" do
    # sabotage: `deliver/5`'s new `{:session, sid}` clause (the non-self one)
    # has its `[{pid, _value}] -> send_event(pid, event); state` branch
    # deleted, leaving only the `[] -> communication_error/4` branch (no
    # catch-all) -> a hit on the sender's registry lookup no longer matches
    # any clause of the `case`, so the sender's own `init/1` crashes with a
    # `CaseClauseError` the moment it tries to deliver, and the `{:ok,
    # _sender} =` match in this test flunks with a `MatchError` before the
    # receiver is ever checked. Reverted and confirmed green.
    test "a send to another registered session's id is delivered there" do
      {:ok, receiver} =
        Statifier.start_session(compile!(receiver_doc()), session_id: "sess_b-runtime-test")

      {:ok, _sender} =
        Statifier.start_session(compile!(sender_doc("#_scxml_sess_b-runtime-test")),
          session_id: "sess_a-runtime-test"
        )

      status = wait_for_status(receiver, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])
    end
  end

  describe "an unknown or dead session id raises error.communication on the sender" do
    # sabotage (ADR-0048): "#_scxml_totally-unknown-session" was never in
    # this sender's own snapshot - dead (never live) *before* the sender's
    # very first stamp, at `init/1` - so
    # `Statifier.Machine.Content.Send`'s reachability arm catches it before
    # `deliver/5` (and `communication_error/4`) ever run; sabotaging either
    # of those, or `registry_lookup/1`'s own rescue clause, now leaves this
    # test green, since the residual path is simply unreached. The mutation
    # that actually reddens it lives one layer up: `reject_reason/4`'s
    # reachability `cond` arm in `lib/statifier/machine/content/send.ex` is
    # changed from `{:communication, {:unreachable_target, target}}` to
    # `{:execution, {:unreachable_target, target}}` -> the core raises
    # `error.execution` instead of `error.communication`, so the
    # `<transition event="error.communication">` never fires and the wait
    # below flunks. Reverted and confirmed green.
    test "a send to an id that never existed raises error.communication" do
      {:ok, sender} =
        Statifier.start_session(compile!(sender_doc("#_scxml_totally-unknown-session")),
          session_id: "sess_a-unknown-test"
        )

      status = wait_for_status(sender, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])
      assert Session.snapshot(sender).datamodel["_event"]["sendid"] == "send1"
    end

    # ADR-0048 decision 5's staleness reading, given a live witness: unlike
    # the sibling test above, this target is alive when the sender starts
    # (and stays alive long enough to confirm the timer is actually
    # scheduled), then dies *after* - a delayed send never gets a plan-time
    # reachability determination at all (decision 6), so its route is always
    # resolved this way, at fire time, on the residual `deliver_fired/4` ->
    # `deliver/5` -> `communication_error/4` path, regardless of when the
    # target died relative to any stamp.
    #
    # sabotage: `registry_lookup/1`'s `rescue ArgumentError -> []` clause is
    # deleted -> unreachable here (the registry *is* running for this test,
    # so `Registry.lookup/2` never raises), which is why the mutation that
    # actually reddens this test is `communication_error/4`'s call being
    # swapped for `Inbox.enqueue_event/2` (mirroring the sabotage on the
    # cross-session delivery test above, on the empty-lookup branch instead
    # of the hit branch) -> the sender's own inbox gets the never-delivered
    # `ping` event instead of `error.communication`, so it stays on `"a"`
    # rather than reaching `"failed"`, reddening the assertion below.
    # Reverted and confirmed green.
    test "a send to a session that has since died raises error.communication, not a crash" do
      {:ok, receiver} =
        Statifier.start_session(compile!(receiver_doc()), session_id: "sess_b-dead-test")

      {:ok, sender} =
        Statifier.start_session(compile!(delayed_sender_doc("#_scxml_sess_b-dead-test")),
          session_id: "sess_a-dead-test"
        )

      # Confirms the timer is actually armed (the target was reachable, and
      # decision 6 exempted the plan-time check either way) before the
      # target dies - the send has already been stamped and scheduled at
      # this point, so anything that happens to the target from here on is
      # strictly "after the stamping".
      wait_for_status(sender, fn s -> s.pending_timers == 1 end)

      Session.stop(receiver)

      # `Registry` drops a dead process's entry on its own `:DOWN`, which is
      # not guaranteed to have run by the moment `Session.stop/2` returns -
      # so this waits for the registry itself to reflect the death rather
      # than assuming it already has, keeping the test from racing the
      # very thing it means to exercise.
      wait_until(fn -> Registry.lookup(Statifier.Registry, "sess_b-dead-test") == [] end)

      status = wait_for_status(sender, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])
    end
  end

  describe "a bare Session.start_link/2 session stays unregistered" do
    # sabotage: `register_session/1`'s `rescue _ -> :ok` / `catch :exit, _ ->
    # :ok` clauses are deleted, leaving a bare `Registry.register/3` call ->
    # the bare session's own `start_link/2` call below (issued while
    # `Statifier.Registry` is cycled down, so it is not running yet) crashes
    # instead of starting, and the `{:ok, _bare_receiver} =` match on the
    # very next line flunks with a `MatchError` before the rest of the test
    # can even run. Reverted and confirmed green - this is also the sabotage
    # that would redden every *other* bare-`start_link/2` test in
    # `session_test.exs`, since none of them place `Statifier.Supervisor`
    # either.
    test "a session that started before the registry existed stays unreachable even after the registry later starts" do
      # `Statifier.Registry` is the shared, module-qualified runtime
      # `test/test_helper.exs` places once for the whole run - there is no
      # "before `Statifier.Supervisor` exists" moment left to catch a bare
      # session in anymore, so this cycles the registry child down for the
      # span the bare session starts in and back up before anything else
      # needs it. Restoring it in `after` keeps a failed assertion from
      # leaving the shared runtime down for the rest of the suite.
      :ok = Supervisor.terminate_child(Statifier.Supervisor, Statifier.Registry)

      try do
        {:ok, _bare_receiver} =
          Session.start_link(compile!(receiver_doc()), session_id: "sess_bare-test")
      after
        {:ok, _pid} = Supervisor.restart_child(Statifier.Supervisor, Statifier.Registry)
      end

      {:ok, sender} =
        Statifier.start_session(compile!(sender_doc("#_scxml_sess_bare-test")),
          session_id: "sess_a-bare-test"
        )

      status = wait_for_status(sender, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])
    end
  end

  describe "ADR-0048: a live registered peer is reachable through the stamped snapshot" do
    # sabotage: `Statifier.Session`'s `routes/3` is changed to always pass an
    # empty `MapSet.new()` for `:sessions` instead of
    # `MapSet.put(registry_keys(), session_id)` -> the sender's own stamped
    # snapshot names no session at all, so `Statifier.Machine.Content.Send`'s
    # reachability arm now rejects even this *live*, registered peer as
    # unreachable, raising `error.communication` instead of delivering -
    # the receiver never leaves "a" and the wait below flunks. Reverted and
    # confirmed green.
    test "a live peer's id is in the sender's own stamped snapshot, and the event is delivered with no error" do
      {:ok, receiver} =
        Statifier.start_session(compile!(receiver_doc()), session_id: "sess_b-live-test")

      {:ok, sender} =
        Statifier.start_session(compile!(sender_doc("#_scxml_sess_b-live-test")),
          session_id: "sess_a-live-test"
        )

      receiver_status =
        wait_for_status(receiver, fn s -> s.configuration == MapSet.new(["b"]) end)

      assert receiver_status.configuration == MapSet.new(["b"])

      # The sender never leaves "a" (no `error.communication` transition
      # exists there to move it, and none fired), so the only witnesses of
      # success are the receiver's own transition above and the sender's own
      # stamped snapshot below naming the receiver as reachable.
      sender_status = Session.status(sender)
      assert sender_status.configuration == MapSet.new(["a"])

      sender_snapshot = Session.snapshot(sender)
      assert %Routes{sessions: sessions} = sender_snapshot.routes
      assert MapSet.member?(sessions, "sess_b-live-test")
    end
  end
end
