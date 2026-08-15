defmodule Statifier.Session.InvokeStartChildTest do
  use ExUnit.Case, async: false

  # `Statifier.start_session/2` (via `perform_instruction({:start_child, ...})`)
  # lands children on `Statifier.SessionSupervisor`, a fixed, module-qualified
  # singleton (`test/statifier/session_runtime_test.exs`'s own comment). Every
  # test in this module either places `Statifier.Supervisor` itself or
  # specifically needs it *not* running yet, so this module is `async: false`
  # the same way that one is.

  alias Statifier.Compiler
  alias Statifier.Effect
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

  # A markup `<content>` binary, wrapped in CDATA so the outer parser sees it
  # purely as text (Decision 1: element children of `<content>` are still
  # `{:misplaced_element, _, "content"}`, but a CDATA-wrapped document string
  # is exactly the "content is markup in a binary" path `Statifier.Invoke.Source`
  # compiles). One line, single-spaced throughout: `<invoke>`'s own coercion
  # (`Statifier.EventData.coerce({:text, _})`) trims and, on a failed
  # predicator-literal parse, space-normalizes the text, and a document with
  # no internal whitespace runs survives that unchanged.
  @child_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0" datamodel="predicator"><datamodel><data id="x" expr="'child-default'"/><data id="from_namelist"/></datamodel><state id="run"/></scxml>)

  defp parent_doc(invoke_body, opts \\ []) do
    datamodel = Keyword.get(opts, :datamodel, "")

    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        #{datamodel}
        <state id="a">
            <invoke type="scxml"#{Keyword.get(opts, :invoke_attrs, "")}>
                #{invoke_body}
            </invoke>
            <transition event="error.communication" target="failed"/>
        </state>
        <state id="failed"/>
    </scxml>
    """
  end

  defp content_body, do: "<content><![CDATA[#{@child_xml}]]></content>"

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

  # -- starting the child ---------------------------------------------------

  describe "an <invoke> with a markup <content> binary" do
    # sabotage: `Statifier.Session.Effects.plan_invoke/2`'s supported-type
    # branch is reverted from `[{:start_child, invoke, effect}]` to
    # `[{:unroutable, effect}]` -> no child is ever started, so
    # `Invocations.count/1` below stays 0 and the assertion reddens. Reverted
    # and confirmed green.
    test "starts a real child session, monitored, with one table entry" do
      start_supervised!(Statifier.Supervisor)

      machine = compile!(parent_doc(content_body(), invoke_attrs: " autoforward=\"true\""))
      {:ok, parent} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: invoke_id}}}}

      %{invocations: invocations} = :sys.get_state(parent)
      assert Invocations.count(invocations) == 1

      assert {:ok, %{pid: child_pid, autoforward: true, session_id: child_session_id}} =
               Invocations.fetch(invocations, invoke_id)

      assert is_binary(child_session_id)
      assert Session.status(child_pid).configuration == MapSet.new(["run"])
    end
  end

  # -- 6.4.3 name-matched seeding --------------------------------------------

  describe "6.4.3 name-matched <param> seeding" do
    # sabotage: `Statifier.Session.Invocations.seed_datamodel/2`'s
    # `MapSet.member?(data_ids, name)` guard is inverted to `not
    # MapSet.member?(data_ids, name)` -> the matching "x" param is dropped and
    # the non-matching "nomatch" survives, reddening both assertions below at
    # once (`assert` on "x" fails first). Reverted and confirmed green.
    test "a matching <param> wins over the child's own expr; a non-matching one is absent" do
      start_supervised!(Statifier.Supervisor)

      invoke_body = """
      <param name="x" expr="'from-parent'"/>
      <param name="nomatch" expr="1"/>
      #{content_body()}
      """

      parent_xml = parent_doc(invoke_body)

      {:ok, parent} = Session.start_link(compile!(parent_xml), subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: invoke_id}}}}

      %{invocations: invocations} = :sys.get_state(parent)
      assert {:ok, %{pid: child_pid}} = Invocations.fetch(invocations, invoke_id)

      datamodel = Session.snapshot(child_pid).datamodel
      assert datamodel["x"] == "from-parent"
      refute Map.has_key?(datamodel, "nomatch")
    end
  end

  describe "6.4.3 name-matched namelist seeding" do
    # sabotage: same guard inversion as the <param> test above -
    # `MapSet.member?(data_ids, name)` inverted to `not
    # MapSet.member?(data_ids, name)` -> the matching "from_namelist" value is
    # dropped, reddening the assertion. Namelist and `<param>` share the one
    # `seed_datamodel/2` implementation (both merged into the same coerced
    # `params` map before this module ever sees them), so this test's own job
    # is only to confirm namelist reaches that map at all - the guard itself
    # is already sabotage-verified by the `<param>` test and by
    # `invocations_test.exs`.
    test "a namelist variable matching a top-level <data> id is seeded" do
      start_supervised!(Statifier.Supervisor)

      parent_xml =
        parent_doc(content_body(),
          invoke_attrs: " namelist=\"from_namelist\"",
          datamodel: """
          <datamodel>
              <data id="from_namelist" expr="'via-namelist'"/>
          </datamodel>
          """
        )

      {:ok, parent} = Session.start_link(compile!(parent_xml), subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: invoke_id}}}}

      %{invocations: invocations} = :sys.get_state(parent)
      assert {:ok, %{pid: child_pid}} = Invocations.fetch(invocations, invoke_id)

      assert Session.snapshot(child_pid).datamodel["from_namelist"] == "via-namelist"
    end
  end

  # -- failure paths: error.communication, no table entry -------------------

  describe "a runtime that cannot start the child" do
    # sabotage: `Statifier.Session`'s `start_child/5` clause's `{:error,
    # _reason} -> invoke_error(invoke, effect, state, override)` branch (the
    # `Statifier.start_session/2`-failure arm - reached here through the
    # private `start_session/3` helper's `catch :exit, reason -> {:error,
    # reason}`, since `Statifier.SessionSupervisor` unstarted makes
    # `Statifier.start_session/2` exit rather than return `{:error, _}`) is
    # changed to `{:error, _reason} -> state` (silently dropped) -> this
    # test's `error.communication` transition never fires, so the parent
    # stays on "a" instead of reaching "failed", reddening the wait below.
    # Reverted and confirmed green.
    test "no Statifier.Supervisor placed raises error.communication and writes no table entry" do
      machine = compile!(parent_doc(content_body()))
      {:ok, parent} = Session.start_link(machine)

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])

      %{invocations: invocations} = :sys.get_state(parent)
      assert Invocations.count(invocations) == 0
    end

    # sabotage: `Statifier.Session`'s `perform_instruction({:start_child,
    # ...})` clause's `{:error, _reason} -> invoke_error(invoke, effect,
    # state, override)` branch (the `Source.resolve/2`-failure arm) is
    # changed to `{:error, _reason} -> state` -> this test's
    # `error.communication` transition never fires, reddening the wait
    # below the same way as its sibling test above. Reverted and confirmed
    # green.
    test "a non-compiling <content> binary raises error.communication and writes no table entry" do
      start_supervised!(Statifier.Supervisor)

      invoke_body = "<content><![CDATA[<not-scxml/>]]></content>"
      machine = compile!(parent_doc(invoke_body))
      {:ok, parent} = Session.start_link(machine)

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])

      %{invocations: invocations} = :sys.get_state(parent)
      assert Invocations.count(invocations) == 0
    end

    # sabotage: same `Source.resolve/2`-failure arm as the two tests above,
    # exercised here through `Statifier.Invoke.Source`'s own `:src_not_resolved`
    # branch instead of a compile failure - reddens the same way.
    test "a src with no configured resolver raises error.communication and writes no table entry" do
      start_supervised!(Statifier.Supervisor)

      machine = compile!(parent_doc("", invoke_attrs: " src=\"file:child.scxml\""))
      {:ok, parent} = Session.start_link(machine)

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])

      %{invocations: invocations} = :sys.get_state(parent)
      assert Invocations.count(invocations) == 0
    end

    # sabotage: same `Source.resolve/2`-failure arm again, this time reached
    # through an `invoke_source` resolver that itself returns `{:error, _}`
    # unchanged (`Statifier.Invoke.Source.resolve/2`'s own pass-through
    # clause) - reddens the same way.
    test "a resolver returning {:error, _} raises error.communication and writes no table entry" do
      start_supervised!(Statifier.Supervisor)

      machine = compile!(parent_doc("", invoke_attrs: " src=\"file:child.scxml\""))
      resolver = fn _src -> {:error, :nope} end
      {:ok, parent} = Session.start_link(machine, invoke_source: resolver)

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])

      %{invocations: invocations} = :sys.get_state(parent)
      assert Invocations.count(invocations) == 0
    end
  end

  # -- the two monitors -------------------------------------------------------

  describe "the parent/child monitors" do
    # sabotage: `Statifier.Session`'s `monitor_parent/1` clause
    # (`{parent_pid, _invoke_id} -> Process.monitor(parent_pid); :ok`) has
    # its `Process.monitor/1` call dropped -> the child never notices its
    # parent's death, so `Process.alive?/1` on the child pid stays `true`
    # past the poll's attempts below, flunking `wait_until/2`. Reverted and
    # confirmed green.
    test "killing a parent stops its child" do
      start_supervised!(Statifier.Supervisor)

      # `Session.start_link/2` links the calling process (this test) to the
      # session it starts, same as any `start_link`. A non-`:normal` exit
      # reason on a linked process propagates and would crash this test
      # along with `parent` unless exits are trapped first - trapping turns
      # that propagated exit into an ordinary `{:EXIT, ...}` mailbox message
      # this test never has to read, since the assertion below is about the
      # *child*, reached only through its own `Process.monitor/1` of
      # `parent` (`monitor_parent/1`), not through this link at all.
      Process.flag(:trap_exit, true)

      machine = compile!(parent_doc(content_body()))
      {:ok, parent} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: invoke_id}}}}

      %{invocations: invocations} = :sys.get_state(parent)
      assert {:ok, %{pid: child_pid}} = Invocations.fetch(invocations, invoke_id)

      Process.exit(parent, :kill)

      wait_until(fn -> not Process.alive?(child_pid) end)
    end

    # sabotage: `Statifier.Session`'s `handle_info/2` clause for a monitored
    # child's `:DOWN` (`Invocations.pop_by_pid/2` hit -> `{:noreply, %{state
    # | invocations: invocations}}`) is changed to `{:noreply, state}`
    # (the popped table is discarded) -> `Invocations.count/1` below stays 1
    # forever instead of reaching 0, flunking `wait_until/2`. Reverted and
    # confirmed green.
    test "killing a child removes its entry from the parent's table" do
      start_supervised!(Statifier.Supervisor)

      machine = compile!(parent_doc(content_body()))
      {:ok, parent} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: invoke_id}}}}

      %{invocations: invocations} = :sys.get_state(parent)
      assert {:ok, %{pid: child_pid}} = Invocations.fetch(invocations, invoke_id)

      Process.exit(child_pid, :kill)

      wait_until(fn -> Invocations.count(:sys.get_state(parent).invocations) == 0 end)
      assert Process.alive?(parent)
    end
  end
end
