defmodule Statifier.Session.InvokeSendTargetTest do
  use ExUnit.Case, async: false

  # Every test here either places `Statifier.Supervisor` to start a real
  # child (`Statifier.start_session/2`) or shares the module with tests that
  # do, so this module is `async: false` for the same reason
  # `invoke_start_child_test.exs` gives itself the same tag.

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Event
  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Session
  alias Statifier.Session.Invocations
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
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

  # A child that transitions on "ping" - the observable proof that a
  # `<send target="#_child1">` reached its external queue.
  defp pingable_child_xml,
    do:
      ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0"><state id="run"><transition event="ping" target="pinged"/></state><state id="pinged"/></scxml>)

  defp content_body(xml), do: "<content><![CDATA[#{xml}]]></content>"

  # -- #_invokeid, a live invocation ------------------------------------

  describe "<send target=\"#_invokeid\"> naming a live invocation" do
    # sabotage: `Statifier.Session`'s `deliver({:invoke, invoke_id}, event,
    # effect, state, override)` clause's `{:ok, %{pid: pid}} -> send_event(pid,
    # event)` branch is replaced with `{:ok, %{pid: _pid}} ->
    # communication_error(event, effect, state, override)` -> the event never
    # reaches the child, so `run` never transitions to `pinged` and the wait
    # below flunks. Reverted and confirmed green.
    test "adds the event to that session's external queue" do
      # "go" is a self-transition with no `target` - it stays inside "a", so
      # the invoking state is never exited and "child1" stays live for the
      # `<send>` to reach. A transition that left "a" would cancel "child1"
      # (6.4.3: an `<invoke>` is cancelled when its invoking state is
      # exited) before the send ever ran, which would make this test prove
      # the cancelled case below instead of the live one.
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <invoke id="child1" type="scxml">
                  #{content_body(pingable_child_xml())}
              </invoke>
              <transition event="go">
                  <send target="#_child1" event="ping"/>
              </transition>
          </state>
      </scxml>
      """

      machine = compile!(xml)
      {:ok, parent} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: "child1"}}}}

      %{invocations: invocations} = :sys.get_state(parent)
      assert {:ok, %{pid: child_pid}} = Invocations.fetch(invocations, "child1")

      Session.send_event(parent, Event.external("go"))

      child_status =
        wait_for_status(child_pid, fn s -> s.configuration == MapSet.new(["pinged"]) end)

      assert child_status.configuration == MapSet.new(["pinged"])

      # "child1" is still live - the invoking state was never exited.
      assert Invocations.live?(:sys.get_state(parent).invocations, "child1")
    end
  end

  # -- #_invokeid naming no live invocation -----------------------------

  describe "<send target=\"#_invokeid\"> naming an invokeid that was never invoked" do
    # sabotage (ADR-0048): "#_nonexistent" was never a live invocation from
    # this session's very first stamped snapshot, so
    # `Statifier.Machine.Content.Send`'s reachability arm catches it before
    # `deliver/5`'s `{:invoke, _}` clause ever runs - sabotaging that clause
    # (the pre-bead mutation here) now leaves this test green, since the
    # residual path is simply unreached. The mutation that actually reddens
    # it lives one layer up: `reject_reason/4`'s reachability `cond` arm in
    # `lib/statifier/machine/content/send.ex` is changed from
    # `{:communication, {:unreachable_target, target}}` to
    # `{:execution, {:unreachable_target, target}}` -> the core raises
    # `error.execution` instead of `error.communication`, so the
    # `<transition event="error.communication">` below never fires and the
    # wait flunks. Reverted and confirmed green.
    test "raises error.communication on the sending session" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send target="#_nonexistent" event="ping"/>
              </onentry>
              <transition event="error.communication" target="failed"/>
          </state>
          <state id="failed"/>
      </scxml>
      """

      {:ok, parent} = Session.start_link(compile!(xml))

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])
    end
  end

  # -- #_invokeid naming a cancelled invocation --------------------------

  describe "<send target=\"#_invokeid\"> naming an invocation that has since been cancelled" do
    # sabotage: the same `:error -> communication_error(event, effect, state,
    # override)` branch as the previous describe block is replaced with
    # `:error -> state` -> the parent never leaves "b", flunking the wait
    # below. Reverted and confirmed green (run together with the previous
    # test's sabotage, since both exercise the same branch).
    test "raises error.communication, the same as an invokeid that never existed" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <invoke id="child1" type="scxml">
                  #{content_body(pingable_child_xml())}
              </invoke>
              <transition event="leave" target="b"/>
          </state>
          <state id="b">
              <onentry>
                  <send target="#_child1" event="ping"/>
              </onentry>
              <transition event="error.communication" target="failed"/>
          </state>
          <state id="failed"/>
      </scxml>
      """

      machine = compile!(xml)
      {:ok, parent} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: "child1"}}}}

      # Exiting "a" cancels "child1" (`{:stop_child, "child1"}` pops the
      # table entry synchronously, before "b"'s own `<onentry>` send runs -
      # `Statifier.Session.InvokeCancelTest`'s "exiting the invoking state"
      # proves the pop side of this ordering already).
      Session.send_event(parent, Event.external("leave"))

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])
    end
  end
end
