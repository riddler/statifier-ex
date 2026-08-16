defmodule Statifier.Session.InvokeAutoforwardTest do
  use ExUnit.Case, async: false

  # Same reason as `invoke_start_child_test.exs`: every test here places
  # `Statifier.Supervisor` (a fixed, module-qualified singleton), so this
  # module is `async: false`.

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
    {:ok, document} = Lowering.lower(root)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # A child that, the moment it sees "e", copies every 5.10.1 field of the
  # matched event into its own datamodel via `_event` and moves off its
  # initial state - both are `Session.snapshot/1`-observable proof a
  # forwarded event actually arrived, and arrived unmodified. One line so the
  # CDATA-wrapped markup survives `<invoke>`'s own text coercion unchanged
  # (`invoke_start_child_test.exs`'s own comment explains why).
  @child_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0" datamodel="predicator"><datamodel><data id="ev_data"/><data id="ev_sendid"/><data id="ev_origin"/><data id="ev_origintype"/><data id="ev_invokeid"/></datamodel><state id="run"><transition event="e" target="reached"><assign location="ev_data" expr="_event.data"/><assign location="ev_sendid" expr="_event.sendid"/><assign location="ev_origin" expr="_event.origin"/><assign location="ev_origintype" expr="_event.origintype"/><assign location="ev_invokeid" expr="_event.invokeid"/></transition></state><state id="reached"/></scxml>)

  defp content_body, do: "<content><![CDATA[#{@child_xml}]]></content>"

  defp parent_xml do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <invoke type="scxml" autoforward="true">
                #{content_body()}
            </invoke>
            <invoke type="scxml">
                #{content_body()}
            </invoke>
            <transition event="ping" target="a"/>
            <transition event="error.*" target="errored"/>
        </state>
        <state id="errored"/>
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

  # Starts the parent, waits for both `<invoke>` effects, and sorts the two
  # invocations by their `autoforward` field - document order is not relied
  # on, since `Statifier.Session.Effects.plan/2` only guarantees the two
  # `{:notify, {:invoke, _}}` instructions arrive in *some* order matching
  # the core's own `states_to_invoke` walk, not which one is which.
  defp start_parent_with_two_invocations! do
    start_supervised!(Statifier.Supervisor)

    machine = compile!(parent_xml())
    {:ok, parent} = Session.start_link(machine, subscribers: [self()])
    session_id = Session.session_id(parent)

    assert_receive {:statifier, ^session_id,
                    {:effect, {:invoke, %Effect.Invoke{invoke_id: id1, autoforward: af1}}}}

    assert_receive {:statifier, ^session_id,
                    {:effect, {:invoke, %Effect.Invoke{invoke_id: id2, autoforward: _af2}}}}

    {fwd_id, silent_id} = if af1, do: {id1, id2}, else: {id2, id1}

    %{invocations: invocations} = :sys.get_state(parent)
    assert {:ok, %{pid: fwd_pid}} = Invocations.fetch(invocations, fwd_id)
    assert {:ok, %{pid: silent_pid}} = Invocations.fetch(invocations, silent_id)

    {parent, session_id, fwd_pid, silent_pid}
  end

  describe "an external event with an autoforward=\"true\" invocation active" do
    # sabotage: two mutations, both reverted and confirmed green:
    # 1. `Statifier.Session.Effects.plan_one/2`'s `{:autoforward, _}` clause
    #    is reverted to `[{:notify, effect}, {:unroutable, effect}]` ->
    #    `Statifier.Session` never receives a `{:forward, ...}` instruction,
    #    so the forwarding child never sees "e" and `wait_for_status` below
    #    times out.
    # 2. `Statifier.Session`'s `{:forward, ...}` clause's `send_event(pid,
    #    event)` is changed to `send_event(pid, %{event | sendid: "mutated"})`
    #    -> the `ev_sendid` assertion below reddens on "mutated" instead of
    #    "sid1", proving the verbatim-copy assertion is load-bearing and not
    #    just a presence check.
    test "reaches the autoforwarding child verbatim; a non-autoforwarding sibling receives nothing" do
      {parent, _session_id, fwd_pid, silent_pid} = start_parent_with_two_invocations!()

      event =
        Event.external("e",
          data: "payload-1",
          sendid: "sid1",
          origin: "http://example.test/origin",
          origintype: "http://example.test/type"
        )

      Session.send_event(parent, event)

      status = wait_for_status(fwd_pid, fn s -> s.configuration == MapSet.new(["reached"]) end)
      assert status.configuration == MapSet.new(["reached"])

      # Verbatim per 6.4.2: every 5.10.1 field the parent's copy carried
      # survives unchanged in the child's own read of `_event`, not rebuilt
      # through `Effect.Send`. `invokeid` is `nil` on both sides - forwarding
      # never stamps it (only `#_parent` delivery does, spec 5.10.1).
      datamodel = Session.snapshot(fwd_pid).datamodel
      assert datamodel["ev_data"] == "payload-1"
      assert datamodel["ev_sendid"] == "sid1"
      assert datamodel["ev_origin"] == "http://example.test/origin"
      assert datamodel["ev_origintype"] == "http://example.test/type"
      assert datamodel["ev_invokeid"] == :undefined

      # The sibling invocation was never marked `autoforward`, so nothing
      # was ever sent to it - its configuration never moves off "run".
      assert Session.status(silent_pid).configuration == MapSet.new(["run"])
    end
  end

  describe "forwarding to a dead invocation" do
    # sabotage: `Statifier.Session`'s `{:forward, invoke_id, event}` clause's
    # `:error -> :ok` branch is changed to raise (`:error -> raise "boom"`)
    # -> the parent process crashes handling the second `ping` below, so
    # `wait_for_status` on the parent's own configuration never sees it
    # return to "a" (the crash also kills the linked test process unless
    # trapped, which is exactly the signal this sabotage is meant to
    # surface). Reverted and confirmed green.
    test "is a silent no-op that raises no error.communication on the parent" do
      Process.flag(:trap_exit, true)

      {parent, _session_id, fwd_pid, _silent_pid} = start_parent_with_two_invocations!()

      Process.exit(fwd_pid, :kill)

      wait_until(fn -> Invocations.count(:sys.get_state(parent).invocations) == 1 end)

      # The core's own `states_to_invoke`/active-invocation bookkeeping still
      # names the (now-dead) invocation, so `apply_invoke_passes/2` still
      # emits `{:autoforward, _}` for it - `Statifier.Session`'s
      # `Invocations.fetch/2` misses, and the miss must be silent.
      Session.send_event(parent, Event.external("e"))

      # Proof the parent kept running normally and never took the
      # `error.*` transition: an unrelated event still round-trips through
      # its own self-transition.
      Session.send_event(parent, Event.external("ping"))
      status = wait_for_status(parent, fn s -> s.status == :running end)
      assert status.configuration == MapSet.new(["a"])
      assert Process.alive?(parent)
    end
  end
end
