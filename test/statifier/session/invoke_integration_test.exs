defmodule Statifier.Session.InvokeIntegrationTest do
  use ExUnit.Case, async: false

  # Phase 6: prove the protocol as one thing rather than five. Phases 2-5
  # each landed a unit-level proof of their own instruction
  # (`invoke_start_child_test.exs`, `invoke_parent_routing_test.exs`,
  # `invoke_autoforward_test.exs`, `invoke_cancel_test.exs`); this module
  # composes several of those obligations into one run each, plus two shapes
  # no earlier phase had a reason to build: an invoke chain three sessions
  # deep, and a combined seed/finalize/forward/done run in a single
  # `<invoke>`. Every test here places `Statifier.Supervisor`, a fixed,
  # module-qualified singleton, so this module is `async: false` for the
  # same reason every other `test/statifier/session/invoke_*_test.exs`
  # module gives itself the same tag.

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

  defp content_body(xml), do: "<content><![CDATA[#{xml}]]></content>"

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

  # -- one <invoke>, every obligation in sequence ----------------------------

  describe "seed -> #_parent -> finalize -> autoforward -> done.invoke, in one invocation" do
    # A child seeded from a matching <param> (6.4.3), that immediately pings
    # its parent through #_parent (stamping invokeid, feeding the core's
    # finalize match), waits for one forwarded event, and only then finals
    # with donedata carrying what it was seeded with - so a single child
    # configuration proves seeding, #_parent delivery, and forwarding all
    # reached the same session before it terminates.
    @child_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0" datamodel="predicator"><datamodel><data id="seed"/></datamodel><state id="run"><onentry><send target="#_parent" event="ping"/></onentry><transition event="go" target="done"/></state><final id="done"><donedata><param name="seed" expr="seed"/></donedata></final></scxml>)

    defp full_cycle_parent_xml do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <datamodel>
              <data id="finalize_ran" expr="false"/>
          </datamodel>
          <state id="a">
              <invoke id="child1" type="scxml" autoforward="true">
                  <param name="seed" expr="'from-parent'"/>
                  <finalize><assign location="finalize_ran" expr="true"/></finalize>
                  #{content_body(@child_xml)}
              </invoke>
              <transition event="done.invoke.child1" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # sabotage: `Statifier.Session.Invocations.seed_datamodel/2`'s matching
    # guard is inverted (same mutation `invoke_start_child_test.exs` already
    # sabotage-verifies at the unit level) -> the child's `seed` datamodel
    # entry stays at its own `nil` default instead of `"from-parent"`, so the
    # donedata assertion below reddens on `nil` instead of `"from-parent"`,
    # proving this integration test actually depends on seeding and is not
    # just re-checking `done.invoke` delivery on its own. Reverted and
    # confirmed green.
    test "one <invoke> composes every obligation to the same child" do
      start_supervised!(Statifier.Supervisor)

      machine = compile!(full_cycle_parent_xml())
      {:ok, parent} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(parent)

      # #_parent arrived and fed the finalize whose invokeid matches child1,
      # not left for another sibling that does not exist here.
      assert_receive {:statifier, ^session_id, {:effect, {:invoke, _}}}

      wait_for_status(parent, fn _status ->
        Session.snapshot(parent).datamodel["finalize_ran"] == true
      end)

      %{invocations: invocations} = :sys.get_state(parent)
      assert Invocations.count(invocations) == 1
      assert {:ok, %{pid: child_pid}} = Invocations.fetch(invocations, "child1")

      # Forward "go" so the child finals; it arrives at the child through
      # the autoforward path, not through a direct send to the child pid.
      Session.send_event(parent, Event.external("go"))

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])

      event = Session.snapshot(parent).datamodel["_event"]
      assert event["invokeid"] == "child1"
      assert event["data"] == %{"seed" => "from-parent"}

      # The child finaled (idling `:done`, not stopped - `Session`'s own
      # "`:done` idles the session; it does not stop it" section) rather
      # than crashing, so it is still the same live child the table named.
      assert Session.status(child_pid).status == :done
    end
  end

  # -- a nested invoke: child itself invokes a grandchild --------------------

  describe "a child that itself invokes a grandchild" do
    # The grandchild pings its own parent (the child) the instant it starts;
    # the child copies that into its own datamodel and then finals with it as
    # donedata, so the parent's own done.invoke event proves the value made
    # it all the way from the grandchild, through the child, without ever
    # touching the parent directly - the invoked_by chain composing across
    # two levels on the one flat SessionSupervisor.
    @grandchild_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0"><state id="run"><onentry><send target="#_parent" event="from_grandchild"/></onentry></state></scxml>)

    # The grandchild `<invoke>` is deliberately *not* in the child's own
    # initial state: `DynamicSupervisor.start_child/2` runs the child's
    # `start_link`/`init/1` synchronously inside the supervisor process
    # (`:proc_lib.sync_start/2`), so a grandchild invoke fired from within
    # that same init would call back into the very supervisor process that
    # is still blocked waiting for the child's init to return - a deadlock,
    # not a spec question. Entering "invoking" only after the child session
    # is already up and running (a live `Session.send_event/2` from this
    # test, standing in for whatever external stimulus a real embedder would
    # send) keeps the grandchild's own invoke on the ordinary
    # `handle_event/2` path, same as every other `<invoke>` in this suite.
    # The grandchild's own `<content>` cannot be a second nested
    # `<![CDATA[`: the first `]]>` it contains would close the *outer*
    # CDATA the parent's `content_body/1` wraps this whole child document
    # in, cutting the child off mid-document. Escaping the grandchild markup
    # as ordinary XML text keeps this string CDATA-free, so the parent's one
    # level of CDATA stays the only one in play.
    defp escape_xml(xml) do
      xml
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
    end

    defp child_with_grandchild_xml do
      ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="waiting" version="1.0" datamodel="predicator"><datamodel><data id="seen" expr="false"/></datamodel><state id="waiting"><transition event="go" target="invoking"/></state><state id="invoking"><invoke type="scxml"><content>#{escape_xml(@grandchild_xml)}</content></invoke><transition event="from_grandchild" target="done"/></state><final id="done"><donedata><param name="seen" expr="true"/></donedata></final></scxml>)
    end

    defp nested_parent_xml do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <invoke id="child1" type="scxml">
                  #{content_body(child_with_grandchild_xml())}
              </invoke>
              <transition event="done.invoke.child1" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # sabotage: `Statifier.Session`'s `start_child/5` clause's success arm
    # drops the `invoked_by: {self(), invoke.invoke_id}` option it passes to
    # `Statifier.start_session/2` -> the grandchild's own `<send
    # target="#_parent">` finds `invoked_by: nil` on the child and raises
    # `error.communication` on the child instead of reaching it, so the
    # child never leaves "invoking", the parent's done.invoke.child1
    # transition never fires, and the wait below flunks. Reverted and
    # confirmed green.
    test "the flat SessionSupervisor and invoked_by chain compose across two levels" do
      start_supervised!(Statifier.Supervisor)

      machine = compile!(nested_parent_xml())
      {:ok, parent} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: "child1"}}}}

      %{invocations: invocations} = :sys.get_state(parent)
      assert {:ok, %{pid: child_pid}} = Invocations.fetch(invocations, "child1")

      # Nudge the already-running child into "invoking", which starts the
      # grandchild - well after the child's own start_link/init returned.
      Session.send_event(child_pid, Event.external("go"))

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])

      event = Session.snapshot(parent).datamodel["_event"]
      assert event["invokeid"] == "child1"
      assert event["data"] == %{"seen" => true}

      # Both the child and the grandchild landed on the one flat
      # SessionSupervisor - no supervisor-per-parent nesting (ADR-0027).
      children = DynamicSupervisor.which_children(Statifier.SessionSupervisor)
      assert length(children) == 2
    end
  end

  # -- two invocations in one state: finalize scoping (spec 6.5) ------------

  describe "two invocations in the same invoking state" do
    # Only inv-a ever sends anything; inv-b is live but silent for the whole
    # test. 6.5's "only the finalize code in the original invoking state is
    # executed" read narrowly here: even with two invocations sharing one
    # invoking state, the event inv-a delivers must run inv-a's <finalize>
    # and never inv-b's, which a quiet sibling makes unambiguous to assert -
    # unlike two pingers racing each other, there is exactly one delivered
    # event to reason about.
    @pinger_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0"><state id="run"><onentry><send target="#_parent" event="ping"/></onentry></state></scxml>)
    @quiet_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0"><state id="run"/></scxml>)

    defp two_invocation_parent_xml do
      """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <datamodel>
              <data id="a_runs" expr="0"/>
              <data id="b_runs" expr="0"/>
          </datamodel>
          <state id="a">
              <invoke id="inv-a" type="scxml">
                  <finalize><assign location="a_runs" expr="a_runs + 1"/></finalize>
                  #{content_body(@pinger_xml)}
              </invoke>
              <invoke id="inv-b" type="scxml">
                  <finalize><assign location="b_runs" expr="b_runs + 1"/></finalize>
                  #{content_body(@quiet_xml)}
              </invoke>
              <transition event="ping" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """
    end

    # sabotage: `Statifier.Interpreter.apply_invoke_passes_for_invocation/5`'s
    # `invoke_id == event.invokeid` finalize match (`lib/statifier/interpreter.ex`)
    # is widened to `true` unconditionally -> the single "ping" delivered
    # from inv-a now also runs inv-b's <finalize>, so `b_runs` reaches 1
    # where the assertion below expects it to stay 0. Reverted and confirmed
    # green.
    test "the one delivered event runs only its own invocation's finalize" do
      start_supervised!(Statifier.Supervisor)

      machine = compile!(two_invocation_parent_xml())
      {:ok, parent} = Session.start_link(machine)

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])

      datamodel = Session.snapshot(parent).datamodel
      assert datamodel["a_runs"] == 1
      assert datamodel["b_runs"] == 0
    end
  end
end
