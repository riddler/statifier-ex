defmodule Statifier.Session.InvokeHandlerInheritanceTest do
  use ExUnit.Case, async: false

  # Every test here starts a real child session (one, a real grandchild too)
  # on `Statifier.SessionSupervisor`, the module-qualified singleton
  # `test/test_helper.exs` places once for the whole run, and registers a
  # named listener process. `async: false` for the same reasons
  # `invoke_observer_inheritance_test.exs` and `invoke_handler_test.exs` are.

  alias Statifier.{Compiler, Effect, Lowering, Parser, Session, StreamOrder, Validator}
  alias Statifier.Effect.Invoke
  alias Statifier.Session.Invocations

  # A handler for `"test:probe"` whose `perform/2` is the observable event:
  # it reports the *performing session's own id* alongside the invoke id, so
  # a test can tell a child's invocation from a grandchild's when both carry
  # the same document-authored `<invoke id>`.
  defmodule ProbeHandler do
    @moduledoc false
    @behaviour Statifier.Invoke.Handler

    @impl Statifier.Invoke.Handler
    def start(%Invoke{invoke_id: invoke_id}, _ctx) do
      {:ok, [{:handler, __MODULE__, invoke_id}]}
    end

    @impl Statifier.Invoke.Handler
    def cancel(invoke_id, _ctx), do: {:ok, [{:stop_child, invoke_id}]}

    @impl Statifier.Invoke.Handler
    def forward(invoke_id, event, _ctx), do: {:ok, [{:forward, invoke_id, event}]}

    @impl Statifier.Invoke.Handler
    def perform(invoke_id, ctx) do
      send(:invoke_handler_inheritance_listener, {:performed, ctx.session_id, invoke_id})
      :ok
    end
  end

  @handlers %{"test:probe" => ProbeHandler}

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
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

  defp one_invocation(state), do: Invocations.count(state.invocations) == 1

  defp escape_cdata(xml), do: String.replace(xml, "]]>", "]]]]><![CDATA[>")

  # The chart under test at every depth: it invokes a type only a registered
  # handler can serve, and catches its own `error.execution` in a named state.
  # An unregistered type therefore shows up as a *configuration*, not as an
  # absence - the bead's "starts and parks at its first step" symptom read
  # off a state id rather than off a timeout.
  @probing_child_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0"><state id="run"><invoke id="cinv" type="test:probe"/><transition event="error.execution" target="unresolved"/></state><state id="unresolved"/></scxml>)

  # A chart whose own initial state invokes the probing chart above, for the
  # grandchild depth (the nesting technique is
  # `invoke_start_child_test.exs`'s).
  @relaying_child_xml """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <invoke type="scxml">
              <content><![CDATA[#{@probing_child_xml}]]></content>
          </invoke>
      </state>
  </scxml>
  """

  defp parent_doc(child_xml) do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <invoke type="scxml">
                <content><![CDATA[#{child_xml}]]></content>
            </invoke>
        </state>
    </scxml>
    """
  end

  defp start_parent(child_xml, opts) do
    Process.register(self(), :invoke_handler_inheritance_listener)
    machine = compile!(parent_doc(child_xml))
    {:ok, parent} = Session.start_link(machine, [invoke_handlers: @handlers] ++ opts)

    wait_until(fn -> one_invocation(:sys.get_state(parent)) end)
    [%{pid: child_pid}] = Session.invocations(parent)

    {parent, child_pid}
  end

  # A session runs `Interpreter.initialize/2` to quiescence inside its own
  # `init/1`, so by the time `Session.invocations/1` can name a child's pid
  # that child has already settled - this needs no polling of its own.
  defp configuration(pid), do: Session.status(pid).configuration

  # sabotage: `inherited_invoke_handler_opts/1`'s
  # `%State{inherit_invoke_handlers: false}` clause is deleted, leaving only
  # the `true`-shaped clause -> a parent that never opted in still hands its
  # handler map down, so the child resolves `"test:probe"`, never raises
  # `error.execution`, and stays in `"run"` - the configuration assertion
  # below reddens. Reverted and confirmed green.
  test "default off: the child cannot resolve a type the parent registered" do
    {_parent, child_pid} = start_parent(@probing_child_xml, [])

    assert configuration(child_pid) == MapSet.new(["unresolved"])
    refute_receive {:performed, _session_id, "cinv"}, 200
  end

  # sabotage: `inherited_invoke_handler_opts/1`'s `true`-shaped clause is
  # replaced with `defp inherited_invoke_handler_opts(_state), do: []`
  # (collapsing both clauses) -> the child boots with an empty registry
  # regardless of the flag, raises `error.execution`, and lands in
  # `"unresolved"`, so the `assert_receive` below times out. Reverted and
  # confirmed green.
  test "on, one level: the child resolves the parent's registered handler" do
    {_parent, child_pid} = start_parent(@probing_child_xml, inherit_invoke_handlers: true)

    child_session_id = Session.session_id(child_pid)

    assert_receive {:performed, ^child_session_id, "cinv"}, 1_000
    assert configuration(child_pid) == MapSet.new(["run"])
  end

  # sabotage: `inherited_invoke_handler_opts/1`'s `invoke_handlers:
  # state.invoke_handlers` line is changed to `invoke_handlers: %{}` -> the
  # flag descends but the palette does not, so the child raises
  # `error.execution`, nothing is ever performed, and the `assert_receive`
  # below times out. Reverted and confirmed green.
  test "on: the child's own active_invocations records the resolved invocation" do
    {_parent, child_pid} = start_parent(@probing_child_xml, inherit_invoke_handlers: true)

    child_session_id = Session.session_id(child_pid)
    assert_receive {:performed, ^child_session_id, "cinv"}, 1_000

    snapshot = Session.snapshot(child_pid)
    assert Map.values(snapshot.active_invocations) == ["cinv"]
  end

  @tag timeout: 10_000
  # sabotage: `inherited_invoke_handler_opts/1`'s `true`-shaped clause drops
  # `inherit_invoke_handlers: true` from the returned keyword list (keeping
  # only `invoke_handlers`) -> the child starts with the flag defaulting back
  # to `false`, so the grandchild boots with an empty registry, raises
  # `error.execution`, and the `assert_receive` below times out. Reverted and
  # confirmed green.
  test "transitive: a grandchild resolves the root's registered handler" do
    {_parent, child_pid} =
      start_parent(escape_cdata(@relaying_child_xml), inherit_invoke_handlers: true)

    wait_until(fn -> one_invocation(:sys.get_state(child_pid)) end)
    [%{pid: grandchild_pid}] = Session.invocations(child_pid)

    grandchild_session_id = Session.session_id(grandchild_pid)

    assert_receive {:performed, ^grandchild_session_id, "cinv"}, 1_000
    assert configuration(grandchild_pid) == MapSet.new(["run"])
  end

  # sabotage: `inherited_invoke_handler_opts/1`'s `true`-shaped clause gains
  # `trace: true, subscribers: Map.keys(state.subscribers)` (collapsing the
  # handler knob into the ADR-0050 observation knob) -> the child's
  # `Trace.EntrySet` lands under its own session id and the `== []` assertion
  # below reddens. Reverted and confirmed green.
  test "independent of :inherit_observers: handlers descend, observation does not" do
    {_parent, child_pid} =
      start_parent(@probing_child_xml,
        trace: true,
        subscribers: [self()],
        inherit_invoke_handlers: true
      )

    child_session_id = Session.session_id(child_pid)
    assert_receive {:performed, ^child_session_id, "cinv"}, 1_000

    stream = StreamOrder.drain(child_session_id)
    refute Enum.any?(stream, &match?({:effect, {:trace, %Effect.Trace.EntrySet{}}}, &1))
  end
end
