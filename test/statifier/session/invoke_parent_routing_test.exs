defmodule Statifier.Session.InvokeParentRoutingTest do
  use ExUnit.Case, async: false

  # Every test here either places `Statifier.Supervisor` to start a real
  # child (`Statifier.start_session/2`) or shares the module with tests that
  # do, so this module is `async: false` for the same reason
  # `invoke_start_child_test.exs` gives itself the same tag.

  alias Statifier.Compiler
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Session
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

  # A child that pings its parent as soon as it starts, through `target`
  # (`"#_parent"` or `"_parent"`, per Decision 8) - single-spaced, CDATA'd
  # markup in a binary (`Statifier.Invoke.Source`'s compiled-markup path,
  # exactly like `invoke_start_child_test.exs`'s own `@child_xml`).
  defp pinging_child_xml(target) do
    ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0"><state id="run"><onentry><send target="#{target}" event="ping"/></onentry></state></scxml>)
  end

  # A child with no `<transition>` at all - a live invocation that never
  # sends anything, the sibling `finalize` must stay untouched by.
  defp quiet_child_xml,
    do:
      ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0"><state id="run"/></scxml>)

  # A child that finals immediately at startup, carrying `<donedata>`.
  defp finalizing_child_xml do
    ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="done" version="1.0"><final id="done"><donedata><param name="result" expr="'child-result'"/></donedata></final></scxml>)
  end

  defp content_body(xml), do: "<content><![CDATA[#{xml}]]></content>"

  defp invoke_with(child_xml),
    do: ~s(<invoke type="scxml">#{content_body(child_xml)}</invoke>)

  defp parent_doc(invoke_body, opts \\ []) do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        #{Keyword.get(opts, :datamodel, "")}
        <state id="a">
            #{invoke_body}
            <transition event="#{Keyword.get(opts, :on, "ping")}" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """
  end

  # -- #_parent / _parent -----------------------------------------------

  describe "a child's <send target=\"#_parent\">" do
    # sabotage: `Statifier.Session`'s `deliver(:parent, event, _effect,
    # %State{invoked_by: {parent_pid, invoke_id}}, _override)` clause stamps
    # `nil` instead of `invoke_id` (`%{event | invokeid: nil}`) -> the event
    # still arrives (the transition below still fires), but the `invokeid`
    # assertion reddens. Reverted and confirmed green.
    test "arrives at the parent as an external event carrying invokeid, origin, origintype" do
      start_supervised!(Statifier.Supervisor)

      machine = compile!(parent_doc(invoke_with(pinging_child_xml("#_parent"))))
      {:ok, parent} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Statifier.Effect.Invoke{invoke_id: invoke_id}}}}

      # `Invocations.fetch/2` is deliberately not read here: since Phase 5
      # (`{:cancel_invoke, _}` -> `{:stop_child, _}`), the very "ping" this
      # test is about pops the table entry the instant it drives the parent
      # out of "a" (the invoking state) - `:sys.get_state/1` racing that pop
      # against this test process is exactly the kind of flake Phase 5
      # introduces for a test that used to be able to read the table at
      # leisure, back when `:cancel_invoke` was still `{:unroutable, _}` and
      # left the entry untouched. Waiting for "b" first, then reading the
      # delivered `_event` and cross-checking the child's *global*
      # `Statifier.Registry` entry (which outlives the parent's own table
      # entry - a cancelled child stays registered) sidesteps the table
      # race entirely.
      wait_for_status(parent, fn s -> s.configuration == MapSet.new(["b"]) end)

      event = Session.snapshot(parent).datamodel["_event"]
      assert event["name"] == "ping"
      assert event["invokeid"] == invoke_id
      assert String.starts_with?(event["origin"], "#_scxml_")
      assert event["origintype"] == SystemVariables.scxml_event_processor()

      child_session_id = String.replace_prefix(event["origin"], "#_scxml_", "")
      assert event["origin"] == SystemVariables.scxml_location(child_session_id)

      assert [{child_pid, _value}] = Registry.lookup(Statifier.Registry, child_session_id)
      assert Session.session_id(child_pid) == child_session_id
    end
  end

  describe "a child's <send target=\"_parent\"> (no #, 6.4.4's own spelling)" do
    # sabotage: `Statifier.Session.Target.parse/1`'s `def parse("_parent"),
    # do: :parent` clause is deleted, falling through to the catch-all
    # `{:invalid, other}` clause -> the child's own `<send>` raises
    # `error.execution` on itself instead of routing to `:parent`, so no
    # `ping` ever reaches the parent and the wait below flunks. Reverted and
    # confirmed green.
    test "behaves identically to #_parent" do
      start_supervised!(Statifier.Supervisor)

      machine = compile!(parent_doc(invoke_with(pinging_child_xml("_parent"))))
      {:ok, parent} = Session.start_link(machine)

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])
    end
  end

  describe "an uninvoked session" do
    # sabotage: `Statifier.Session`'s `deliver(:parent, event, effect, state,
    # override)` fallback clause (`invoked_by: nil`) is changed from
    # `communication_error(event, effect, state, override)` to `state` (a
    # silent drop) -> this session never leaves "a", flunking the wait below
    # with neither a crash nor a hang elsewhere to explain why. Reverted and
    # confirmed green.
    test "#_parent still raises error.communication" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <onentry>
                  <send target="#_parent" event="ping"/>
              </onentry>
              <transition event="error.communication" target="failed"/>
          </state>
          <state id="failed"/>
      </scxml>
      """

      {:ok, session} = Session.start_link(compile!(xml))

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])
    end
  end

  # -- done.invoke.<invoke_id> --------------------------------------------

  describe "a child reaching a top-level final" do
    # sabotage: `Statifier.Session`'s `return_done_event/2` clause builds the
    # event name from `"done.invoke"` alone, dropping `<> invoke_id` -> the
    # parent's `done.invoke.child1` transition never matches the delivered
    # `"done.invoke"` event, so the parent never leaves "a" and the wait
    # below flunks. Reverted and confirmed green.
    test "delivers done.invoke.<invoke_id> to the parent, carrying the child's donedata" do
      start_supervised!(Statifier.Supervisor)

      invoke_body =
        ~s(<invoke id="child1" type="scxml">#{content_body(finalizing_child_xml())}</invoke>)

      machine = compile!(parent_doc(invoke_body, on: "done.invoke.child1"))
      {:ok, parent} = Session.start_link(machine)

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])

      event = Session.snapshot(parent).datamodel["_event"]
      assert event["invokeid"] == "child1"
      assert event["data"] == %{"result" => "child-result"}
    end
  end

  # -- finalize is fed the right invokeid -----------------------------------

  describe "two live invocations in one state" do
    # sabotage: the same `deliver(:parent, event, _effect, %State{invoked_by:
    # {parent_pid, invoke_id}}, _override)` clause's `invoke_id` stamp is
    # replaced with `nil` (mirroring the first test's sabotage) -> the
    # delivered event's `invokeid` no longer names either live invocation, so
    # neither `<finalize>` runs (the core's own `inv.invokeid ==
    # event.invokeid` match, already sabotage-verified at the pure-core level
    # by `test/statifier/interpreter/finalize_test.exs`) -> `a_ran` stays
    # `false` where the assertion below expects `true`. Reverted and
    # confirmed green. This test's own job is proving the session-side
    # invokeid feed, not re-testing the core's matching rule.
    test "only the pinging invocation's <finalize> runs, and not its sibling's" do
      start_supervised!(Statifier.Supervisor)

      invoke_body = """
      <invoke id="inv-a" type="scxml">
          <finalize><assign location="a_ran" expr="true"/></finalize>
          #{content_body(pinging_child_xml("#_parent"))}
      </invoke>
      <invoke id="inv-b" type="scxml">
          <finalize><assign location="b_ran" expr="true"/></finalize>
          #{content_body(quiet_child_xml())}
      </invoke>
      """

      machine =
        compile!(
          parent_doc(invoke_body,
            datamodel: """
            <datamodel>
                <data id="a_ran" expr="false"/>
                <data id="b_ran" expr="false"/>
            </datamodel>
            """
          )
        )

      {:ok, parent} = Session.start_link(machine)

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])

      datamodel = Session.snapshot(parent).datamodel
      assert datamodel["a_ran"] == true
      assert datamodel["b_ran"] == false
    end
  end
end
