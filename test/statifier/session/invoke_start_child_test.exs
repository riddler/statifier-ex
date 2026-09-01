defmodule Statifier.Session.InvokeStartChildTest do
  use ExUnit.Case, async: false

  # `Statifier.start_session/2` (via `perform_instruction({:start_child, ...})`)
  # lands children on `Statifier.SessionSupervisor`, a fixed, module-qualified
  # singleton `test/test_helper.exs` places once for the whole run
  # (`test/statifier/session_runtime_test.exs`'s own comment explains why
  # cycling one of its children down for a single test is safe under
  # `async: false`). One test below does exactly that to reach the "no
  # runtime placed" branch, so this module is `async: false` the same way
  # that one is.

  alias Statifier.{
    Compiler,
    Effect,
    Event,
    Lowering,
    Machine,
    Parser,
    Session,
    StreamOrder,
    Validator
  }

  alias Statifier.Event.Cause
  alias Statifier.Session.Invocations

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
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

  describe "Session.invocations/1" do
    # sabotage: `Statifier.Session`'s `handle_call(:invocations, ...)` clause
    # is changed to `{:reply, [], state}` (ignores the table) -> the
    # assertion below that `Session.invocations/1` reports the same
    # invoke_id/session_id/pid `:sys.get_state/1` shows reddens (expects one
    # entry, gets `[]`). Reverted and confirmed green.
    test "names the same invoke_id, session_id, and pid :sys.get_state/1 shows" do
      machine = compile!(parent_doc(content_body(), invoke_attrs: " autoforward=\"true\""))
      {:ok, parent} = Session.start_link(machine, subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: invoke_id}}}}

      %{invocations: invocations} = :sys.get_state(parent)

      assert {:ok, %{pid: child_pid, session_id: child_session_id}} =
               Invocations.fetch(invocations, invoke_id)

      assert Session.invocations(parent) == [
               %{invoke_id: invoke_id, session_id: child_session_id, pid: child_pid}
             ]
    end

    # sabotage: `perform_instruction({:stop_child, invoke_id}, state, _)`'s
    # hit clause is changed from `%{state | invocations: invocations}` to
    # `state` (drops the popped table, keeping the cancelled invocation's
    # stale entry) -> `Session.invocations/1` keeps reporting the cancelled
    # invocation instead of `[]`, reddening the assertion below. Reverted
    # and confirmed green.
    test "the entry disappears once the invocation is cancelled" do
      parent_xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <invoke type="scxml">
                  #{content_body()}
              </invoke>
              <transition event="leave" target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """

      {:ok, parent} = Session.start_link(compile!(parent_xml), subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: invoke_id}}}}

      assert [%{invoke_id: ^invoke_id}] = Session.invocations(parent)

      Session.send_event(parent, Statifier.Event.external("leave"))

      assert_receive {:statifier, ^session_id,
                      {:effect, {:cancel_invoke, %Effect.CancelInvoke{invoke_id: ^invoke_id}}}}

      wait_for_status(parent, fn s -> s.configuration == MapSet.new(["b"]) end)

      assert Session.invocations(parent) == []
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
      # `Statifier.SessionSupervisor` is the shared, module-qualified runtime
      # `test/test_helper.exs` places once for the whole run, so this cycles
      # it down for the span this one test needs it unplaced - safe under
      # `async: false` for the reason `session_runtime_test.exs`'s own
      # comment gives. Restoring it in `after` keeps a failed assertion from
      # leaving the shared runtime down for the rest of the suite.
      :ok = Supervisor.terminate_child(Statifier.Supervisor, Statifier.SessionSupervisor)

      try do
        machine = compile!(parent_doc(content_body()))
        {:ok, parent} = Session.start_link(machine)

        status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["failed"]) end)
        assert status.configuration == MapSet.new(["failed"])

        %{invocations: invocations} = :sys.get_state(parent)
        assert Invocations.count(invocations) == 0
      after
        {:ok, _pid} = Supervisor.restart_child(Statifier.Supervisor, Statifier.SessionSupervisor)
      end
    end

    # sabotage: `Statifier.Session`'s `perform_instruction({:start_child,
    # ...})` clause's `{:error, _reason} -> invoke_error(invoke, effect,
    # state, override)` branch (the `Source.resolve/2`-failure arm) is
    # changed to `{:error, _reason} -> state` -> this test's
    # `error.communication` transition never fires, reddening the wait
    # below the same way as its sibling test above. Reverted and confirmed
    # green.
    test "a non-compiling <content> binary raises error.communication and writes no table entry" do
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
      machine = compile!(parent_doc("", invoke_attrs: " src=\"file:child.scxml\""))
      resolver = fn _src -> {:error, :nope} end
      {:ok, parent} = Session.start_link(machine, invoke_source: resolver)

      status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["failed"]) end)
      assert status.configuration == MapSet.new(["failed"])

      %{invocations: invocations} = :sys.get_state(parent)
      assert Invocations.count(invocations) == 0
    end

    # sabotage: `deliver_internal/6`'s `deferred: state.deferred ++
    # [{effects, override}]` is changed back to `|> perform(effects,
    # halt_override: override)` -> the invoke re-entry's `Trace.InvokePass`/
    # `Trace.MacrostepStable` at round 3 arrive before the outer batch's
    # round 1 pair, reddening `assert_monotone/1`.
    test "the invoke-failure path delivers effects in non-decreasing (macrostep, round) order" do
      :ok = Supervisor.terminate_child(Statifier.Supervisor, Statifier.SessionSupervisor)

      try do
        machine = compile!(parent_doc(content_body()))
        {:ok, parent} = Session.start_link(machine, trace: true, subscribers: [self()])
        session_id = Session.session_id(parent)

        status = wait_for_status(parent, fn s -> s.configuration == MapSet.new(["failed"]) end)
        assert status.configuration == MapSet.new(["failed"])

        stream = StreamOrder.drain(session_id)
        StreamOrder.assert_monotone(stream)
        StreamOrder.assert_stable_unique(stream)
      after
        {:ok, _pid} = Supervisor.restart_child(Statifier.Supervisor, Statifier.SessionSupervisor)
      end
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

  # -- the deadlocking path: parent started through the runtime -------------

  describe "a parent started through the runtime (Statifier.start_session/2)" do
    # sabotage: `perform(state, effects)` and the `:initialize`
    # `Telemetry.macrostep_stop/7` call are moved back into `init/1` ahead of
    # its return (the pre-fix shape) -> the parent's `init/1` calls
    # `DynamicSupervisor.start_child/2` on the `Statifier.SessionSupervisor`
    # that is still serving its own start, and `Statifier.start_session/2`
    # below never returns, reddening this test on its 10_000ms timeout
    # instead of an assertion. Reverted and confirmed green.
    @tag timeout: 10_000
    test "starts its initial state's <invoke> without deadlocking the supervisor" do
      # parent_doc/2 already puts <invoke> in the initial state "a".
      machine = compile!(parent_doc(content_body(), invoke_attrs: " autoforward=\"true\""))
      {:ok, parent} = Statifier.start_session(machine, subscribers: [self()])
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

    # sabotage: same mutation as above (perform/3 + the `:initialize` span
    # close moved back into `init/1`) -> the *parent's* own `init/1` already
    # carries an `<invoke>` in its initial state "a" (`parent_doc/2`), so it
    # wedges `Statifier.SessionSupervisor` on its own start the same way the
    # first test's parent does, before this test ever reaches the child's or
    # grandchild's start; `Statifier.start_session/2` never returns and this
    # test times out at 10_000ms instead of asserting. Reverted and confirmed
    # green.
    @tag timeout: 10_000
    test "nests: a child whose own initial state invokes a grandchild" do
      grandchild_xml =
        ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0"><state id="run"/></scxml>)

      child_xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <invoke type="scxml">
                  <content><![CDATA[#{grandchild_xml}]]></content>
              </invoke>
          </state>
      </scxml>
      """

      # `child_xml` already contains its own `]]>` (from the grandchild's
      # CDATA-wrapped `<content>`), and CDATA sections do not nest - the
      # first `]]>` this outer section meets closes it early, truncating
      # the child document. The standard XML CDATA-splitting escape (close,
      # emit a literal `]]>`, reopen) keeps the whole string as one
      # CDATA-carried binary despite that.
      escaped_child_xml = String.replace(child_xml, "]]>", "]]]]><![CDATA[>")
      parent_xml = parent_doc("<content><![CDATA[#{escaped_child_xml}]]></content>")

      machine = compile!(parent_xml)
      {:ok, parent} = Statifier.start_session(machine, subscribers: [self()])
      session_id = Session.session_id(parent)

      assert_receive {:statifier, ^session_id,
                      {:effect, {:invoke, %Effect.Invoke{invoke_id: child_invoke_id}}}}

      %{invocations: parent_invocations} = :sys.get_state(parent)
      assert Invocations.count(parent_invocations) == 1

      assert {:ok, %{pid: child_pid}} = Invocations.fetch(parent_invocations, child_invoke_id)

      wait_until(fn ->
        Invocations.count(:sys.get_state(child_pid).invocations) == 1
      end)

      %{invocations: child_invocations} = :sys.get_state(child_pid)
      assert Invocations.count(child_invocations) == 1

      [grandchild_invoke_id] = Invocations.invoke_ids(child_invocations)

      assert {:ok, %{pid: grandchild_pid}} =
               Invocations.fetch(child_invocations, grandchild_invoke_id)

      assert Session.status(grandchild_pid).configuration == MapSet.new(["run"])
    end
  end

  # -- an unsupported <invoke type> -------------------------------------------

  describe "an <invoke> with an unsupported type" do
    # This is the end-to-end pin for the whole rejection: one document, one
    # run, every consequence asserted from the same drained stream. A
    # session always declares a registered set - `Statifier.Session` stamps
    # the core with `Statifier.Invoke.Types.from_handlers/1` over its
    # `:invoke_handlers` map, empty here - so this type is a
    # half-registration, and `Statifier.Interpreter` refuses it outright:
    # `error.execution` is raised, no `Effect.Invoke` reaches the stream at
    # all, the invocation is never recorded, `Trace.InvokePass` never names
    # it, and exiting the state emits no `Effect.CancelInvoke` for it.
    #
    # The raised event is the same one this test always asserted; what
    # changed is that the core raises it before building an effect, rather
    # than the session planner raising it against an effect the core had
    # already emitted. The index pair is therefore read off the machine -
    # there is no longer an `%Effect.Invoke{}` to read it from.
    #
    # sabotage: `Statifier.Interpreter`'s `registered_type/2` declared-set
    # clause is changed to return `:ok` unconditionally -> the invocation
    # is emitted and recorded live again, so the `refute` on the invoke
    # effect reddens, the entry-time `Trace.InvokePass` gains "bad" in its
    # `invoke_ids` (reddening the `Enum.all?` below - which is why it is
    # `all?` over every pass and not `any?`: this run emits a second, empty
    # pass after the transition, and an `any?` would be satisfied by that
    # one no matter what the first pass carried), and exiting state "a"
    # emits an `Effect.CancelInvoke{invoke_id: "bad"}` (reddening the last
    # `refute`). Reverted and confirmed green.
    test "raises error.execution, and no Effect.Invoke is emitted at all" do
      machine =
        compile!("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
            <state id="a">
                <invoke id="bad" type="http://example.com/not-scxml"/>
                <transition event="error.execution" target="b"/>
            </state>
            <state id="b"/>
        </scxml>
        """)

      {:ok, session} = Session.start_link(machine, trace: true, subscribers: [self()])
      session_id = Session.session_id(session)

      status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
      assert status.configuration == MapSet.new(["b"])

      stream = StreamOrder.drain(session_id)

      {:ok, state_index} = Machine.index(machine, "a")
      invoke_index = 0

      refute Enum.any?(stream, &match?({:effect, {:invoke, _invoke}}, &1))

      assert Enum.any?(stream, fn
               {:effect,
                {:trace,
                 %Effect.Trace.EventDequeued{
                   from: :internal,
                   event: %Event{
                     name: "error.execution",
                     cause: %Cause{origin: {:invoke, ^state_index, ^invoke_index}}
                   }
                 }}} ->
                 true

               _other_message ->
                 false
             end)

      invoke_passes =
        for {:effect, {:trace, %Effect.Trace.InvokePass{invoke_ids: invoke_ids}}} <- stream,
            do: invoke_ids

      assert invoke_passes != []
      assert Enum.all?(invoke_passes, &("bad" not in &1))

      %{invocations: invocations} = :sys.get_state(session)
      assert Invocations.count(invocations) == 0

      refute Enum.any?(stream, fn
               {:effect, {:cancel_invoke, %Effect.CancelInvoke{invoke_id: "bad"}}} -> true
               _other_message -> false
             end)
    end
  end
end
