defmodule Statifier.SessionRuntimeTest do
  use ExUnit.Case, async: false

  # `Statifier.start_session/2` lands sessions on `Statifier.SessionSupervisor`
  # under `Statifier.Supervisor`, a fixed, module-qualified singleton
  # (ADR-0027's "one instance, no `:name` option"). Two of these tests
  # running at once would collide starting it, so `async: false` serializes
  # this module against itself and against every other module that places
  # the same supervisor. Each test starts `Statifier.Supervisor` itself,
  # at whatever point in the test its own scenario needs it, rather than a
  # blanket `setup` - the "stays unregistered" test below specifically needs
  # it *not* running yet when its bare session starts.

  alias Statifier.Compiler
  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Session
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
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
      start_supervised!(Statifier.Supervisor)

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
    test "a send to an id that never existed raises error.communication" do
      start_supervised!(Statifier.Supervisor)

      {:ok, sender} =
        Statifier.start_session(compile!(sender_doc("#_scxml_totally-unknown-session")),
          session_id: "sess_a-unknown-test"
        )

      status = wait_for_status(sender, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])
      assert Session.snapshot(sender).datamodel["_event"]["sendid"] == "send1"
    end

    test "a send to a session that has since died raises error.communication, not a crash" do
      start_supervised!(Statifier.Supervisor)

      {:ok, receiver} =
        Statifier.start_session(compile!(receiver_doc()), session_id: "sess_b-dead-test")

      Session.stop(receiver)

      # `Registry` drops a dead process's entry on its own `:DOWN`, which is
      # not guaranteed to have run by the moment `Session.stop/2` returns -
      # so this waits for the registry itself to reflect the death rather
      # than assuming it already has, keeping the test from racing the
      # very thing it means to exercise.
      wait_until(fn -> Registry.lookup(Statifier.Registry, "sess_b-dead-test") == [] end)

      {:ok, sender} =
        Statifier.start_session(compile!(sender_doc("#_scxml_sess_b-dead-test")),
          session_id: "sess_a-dead-test"
        )

      status = wait_for_status(sender, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])
    end
  end

  describe "a bare Session.start_link/2 session stays unregistered" do
    # sabotage: `register_session/1`'s `rescue _ -> :ok` / `catch :exit, _ ->
    # :ok` clauses are deleted, leaving a bare `Registry.register/3` call ->
    # this bare session's own `start_link/2` call below (issued before
    # `Statifier.Supervisor` exists, so `Statifier.Registry` is not running
    # yet) crashes instead of starting, and the `{:ok, _bare_receiver} =`
    # match on the very next line flunks with a `MatchError` before the rest
    # of the test can even run. Reverted and confirmed green - this is also
    # the sabotage that would redden every *other* bare-`start_link/2` test
    # in `session_test.exs`, since none of them place `Statifier.Supervisor`
    # either.
    test "a session that started before the registry existed stays unreachable even after the registry later starts" do
      {:ok, _bare_receiver} =
        Session.start_link(compile!(receiver_doc()), session_id: "sess_bare-test")

      start_supervised!(Statifier.Supervisor)

      {:ok, sender} =
        Statifier.start_session(compile!(sender_doc("#_scxml_sess_bare-test")),
          session_id: "sess_a-bare-test"
        )

      status = wait_for_status(sender, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])
    end
  end
end
