defmodule Statifier.Session.InvokeObserverInheritanceTest do
  use ExUnit.Case, async: false

  # `Statifier.start_session/2` (via `perform_instruction({:start_child, ...})`)
  # lands children on `Statifier.SessionSupervisor`, a fixed, module-qualified
  # singleton `test/test_helper.exs` places once for the whole run
  # (`test/statifier/session_runtime_test.exs`'s own comment explains why
  # cycling one of its children down for a single test is safe under
  # `async: false`). Every test below starts a real child (some, a real
  # grandchild too), so this module is `async: false` the same way
  # `invoke_start_child_test.exs` is.

  alias Statifier.{Compiler, Effect, Lowering, Parser, Session, StreamOrder, Validator}
  alias Statifier.Session.Invocations

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp content_body(xml), do: "<content><![CDATA[#{xml}]]></content>"

  defp parent_doc(invoke_body, opts \\ []) do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
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

  # A child with two states and one transition, so a "go" event sent after
  # it has already quiesced at "run" produces a fresh `Trace.EntrySet` -
  # distinct from the entry burst `initialize/2` already emitted at start.
  @simple_child_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0"><state id="run"><transition event="go" target="done"/></state><state id="done"/></scxml>)

  @grandchild_xml ~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="run" version="1.0"><state id="run"/></scxml>)

  # A child whose own initial state invokes a grandchild - the nesting
  # technique from `invoke_start_child_test.exs`'s "nests: a child whose own
  # initial state invokes a grandchild" test, reused verbatim (the CDATA
  # already inside this child, from the grandchild's own `<content>`, is
  # split with the standard `]]]]><![CDATA[>` escape by whoever embeds this
  # string in an outer `<content>`).
  @child_with_grandchild_xml """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <invoke type="scxml">
              <content><![CDATA[#{@grandchild_xml}]]></content>
          </invoke>
      </state>
  </scxml>
  """

  defp escape_cdata(xml), do: String.replace(xml, "]]>", "]]]]><![CDATA[>")

  defp one_invocation(state), do: Invocations.count(state.invocations) == 1

  # sabotage: `inherited_observer_opts/1`'s `%State{inherit_observers:
  # false}` clause is deleted, leaving only the `true`-shaped clause -> a
  # parent that never opted in still hands the child `trace` and its
  # subscriber pids, so the child's `Trace.EntrySet` lands in `self()`'s
  # mailbox under the child's own session id and the `== []` assertion
  # below reddens. Reverted and confirmed green.
  test "default off: the child's effects never reach the parent's subscribers" do
    machine = compile!(parent_doc(content_body(@simple_child_xml)))
    {:ok, parent} = Session.start_link(machine, trace: true, subscribers: [self()])

    wait_until(fn -> one_invocation(:sys.get_state(parent)) end)
    [%{session_id: child_session_id}] = Session.invocations(parent)

    assert StreamOrder.drain(child_session_id) == []
  end

  # sabotage: `inherited_observer_opts/1`'s `true`-shaped clause is replaced
  # with `defp inherited_observer_opts(_state), do: []` (collapsing both
  # clauses) -> the child never receives `trace`/`subscribers` regardless of
  # `inherit_observers`, so no `Trace.EntrySet` ever lands under the child's
  # session id and the `Enum.any?/2` assertion below reddens. Reverted and
  # confirmed green.
  test "on, one level: inherit_observers: true forwards the child's own trace stream" do
    machine = compile!(parent_doc(content_body(@simple_child_xml)))

    {:ok, parent} =
      Session.start_link(machine, trace: true, subscribers: [self()], inherit_observers: true)

    wait_until(fn -> one_invocation(:sys.get_state(parent)) end)
    [%{session_id: child_session_id}] = Session.invocations(parent)

    stream = StreamOrder.drain(child_session_id)
    assert Enum.any?(stream, &match?({:effect, {:trace, %Effect.Trace.EntrySet{}}}, &1))
    StreamOrder.assert_monotone(stream)
  end

  @tag timeout: 10_000
  # sabotage: `inherited_observer_opts/1`'s `true`-shaped clause drops
  # `inherit_observers: true` from the returned keyword list (keeping only
  # `trace`/`subscribers`) -> the grandchild's own parent (the child) starts
  # with `inherit_observers` defaulting back to `false`, so the grandchild's
  # `Trace.EntrySet` never reaches the parent's subscriber and the
  # `Enum.any?/2` assertion below reddens. Reverted and confirmed green.
  test "transitive: a grandchild's trace effects reach the root's subscribers" do
    parent_xml = parent_doc(content_body(escape_cdata(@child_with_grandchild_xml)))
    machine = compile!(parent_xml)

    {:ok, parent} =
      Session.start_link(machine, trace: true, subscribers: [self()], inherit_observers: true)

    wait_until(fn -> one_invocation(:sys.get_state(parent)) end)
    [%{pid: child_pid}] = Session.invocations(parent)

    wait_until(fn -> one_invocation(:sys.get_state(child_pid)) end)
    [%{session_id: grandchild_session_id}] = Session.invocations(child_pid)

    stream = StreamOrder.drain(grandchild_session_id)
    assert Enum.any?(stream, &match?({:effect, {:trace, %Effect.Trace.EntrySet{}}}, &1))
  end

  # sabotage: `inherited_observer_opts/1`'s `trace: state.machine_state.trace`
  # line is replaced with `trace: false` -> the child starts with tracing
  # off even though `inherit_observers: true` was set, so the `"go"` event
  # handled below produces no `Trace.EntrySet` and the `Enum.any?/2`
  # assertion reddens. Reverted and confirmed green.
  test "trace descends independently of the (empty) subscriber list" do
    machine = compile!(parent_doc(content_body(@simple_child_xml)))

    {:ok, parent} =
      Session.start_link(machine, trace: true, subscribers: [], inherit_observers: true)

    wait_until(fn -> one_invocation(:sys.get_state(parent)) end)
    [%{pid: child_pid, session_id: child_session_id}] = Session.invocations(parent)

    :ok = Session.subscribe(child_pid, self())
    Session.send_event(child_pid, "go")

    stream = StreamOrder.drain(child_session_id)
    assert Enum.any?(stream, &match?({:effect, {:trace, %Effect.Trace.EntrySet{}}}, &1))
  end

  # sabotage: `handle_call({:subscribe, pid}, _from, state)` is changed to
  # also subscribe `pid` to every pid already in `state.invocations` (a
  # simulated "live link" bug: `Invocations.entries(state.invocations) |>
  # Map.values() |> Enum.each(&Session.subscribe(&1.pid, pid))`, appended
  # ahead of the existing `{:reply, :ok, ...}`) -> `self()` now observes the
  # child's later effects too, reddening the `== []` assertion below.
  # Reverted and confirmed green.
  test "snapshot, not a live link: subscribing to the parent after the child starts misses it" do
    machine = compile!(parent_doc(content_body(@simple_child_xml)))

    {:ok, parent} =
      Session.start_link(machine, trace: true, subscribers: [], inherit_observers: true)

    wait_until(fn -> one_invocation(:sys.get_state(parent)) end)
    [%{pid: child_pid, session_id: child_session_id}] = Session.invocations(parent)

    :ok = Session.subscribe(parent, self())
    Session.send_event(child_pid, "go")

    assert StreamOrder.drain(child_session_id) == []
  end
end
