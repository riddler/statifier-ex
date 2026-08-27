defmodule Statifier.Session.InvokeHandlerTest do
  use ExUnit.Case, async: false

  # `async: false` matches `test/statifier/session/invoke_start_child_test.exs`'s
  # own idiom - both suites drive a real `Statifier.Session` process to
  # quiescence and drain its subscriber mailbox.

  alias Statifier.{Compiler, Effect, Event, Lowering, Parser, Session, StreamOrder, Validator}
  alias Statifier.Effect.Invoke
  alias Statifier.Event.Cause

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

  defp wait_for_snapshot(session, pred, attempts \\ 50)

  defp wait_for_snapshot(_session, _pred, 0),
    do: flunk("snapshot/1 never satisfied the predicate")

  defp wait_for_snapshot(session, pred, attempts) do
    snapshot = Session.snapshot(session)

    if pred.(snapshot) do
      snapshot
    else
      Process.sleep(5)
      wait_for_snapshot(session, pred, attempts - 1)
    end
  end

  # A `Statifier.Invoke.Handler` implementation for `"test:echo"`, used end
  # to end below. `start/2` returns the one opaque instruction the
  # behaviour adds to the vocabulary, `{:handler, __MODULE__, invoke_id}`;
  # `perform/2` makes that instruction observable to the test process by
  # sending it a message under a name registered per test (the registration
  # dies with the test process itself, so nothing to clean up across runs).
  defmodule EchoHandler do
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
    def perform(invoke_id, _ctx) do
      send(:invoke_handler_test_listener, {:performed, invoke_id})
      :ok
    end
  end

  defp parent_doc(invoke_type) do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <invoke id="inv1" type="#{invoke_type}"/>
            <transition event="go" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """
  end

  # sabotage: `Statifier.Session.Effects.plan_invoke/3`'s `Map.get(context
  # |> Map.get(:invoke_handlers, %{}), invoke.type, ScxmlHandler)` lookup is
  # changed to ignore `context.invoke_handlers` entirely (hardcoded to
  # `ScxmlHandler`) -> `"test:echo"` dispatches to the built-in handler
  # instead, which returns `{:start_child, ...}` rather than `{:handler,
  # EchoHandler, _}`, so `EchoHandler.perform/2` never runs and the
  # `assert_receive` below times out. Reverted and confirmed green.
  test "a handler registered for \"test:echo\" is dispatched to, appears live, and its instruction is performed" do
    Process.register(self(), :invoke_handler_test_listener)

    machine = compile!(parent_doc("test:echo"))

    {:ok, session} =
      Session.start_link(machine,
        trace: true,
        subscribers: [self()],
        invoke_handlers: %{"test:echo" => EchoHandler}
      )

    session_id = Session.session_id(session)

    wait_for_status(session, fn s -> s.configuration == MapSet.new(["a"]) end)

    assert_receive {:performed, "inv1"}, 1_000

    stream = StreamOrder.drain(session_id)

    invoke_passes =
      for {:effect, {:trace, %Effect.Trace.InvokePass{invoke_ids: invoke_ids}}} <- stream,
          do: invoke_ids

    assert invoke_passes != []
    assert Enum.any?(invoke_passes, &("inv1" in &1))

    assert {:effect,
            {:invoke,
             %Effect.Invoke{
               invoke_id: "inv1",
               state_index: state_index,
               invoke_index: invoke_index
             }}} =
             Enum.find(stream, &match?({:effect, {:invoke, _invoke}}, &1))

    snapshot = Session.snapshot(session)

    assert Map.get(snapshot.active_invocations, {state_index, invoke_index}) == "inv1"
  end

  # sabotage: `Statifier.Invoke.Types.registered?/2`'s declared-set clause
  # is changed to return `true` unconditionally, ignoring `MapSet.member?/2`
  # entirely -> "test:missing" is (wrongly) judged registered even though
  # only "test:echo" was declared, so `plan_invoke/3` dispatches it to the
  # built-in scxml handler instead of raising `error.execution` - the
  # `Enum.any?/2` assertion below (which looks for the raised event) reddens.
  # Reverted and confirmed green.
  test "an unregistered \"test:missing\" type still raises error.execution with the real index pair" do
    machine = compile!(parent_doc("test:missing"))

    {:ok, session} =
      Session.start_link(machine,
        trace: true,
        subscribers: [self()],
        invoke_handlers: %{"test:echo" => EchoHandler}
      )

    session_id = Session.session_id(session)

    stream = StreamOrder.drain(session_id)

    assert {:effect,
            {:invoke,
             %Effect.Invoke{
               invoke_id: "inv1",
               type: "test:missing",
               state_index: state_index,
               invoke_index: invoke_index
             }}} = Enum.find(stream, &match?({:effect, {:invoke, _invoke}}, &1))

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

    snapshot = Session.snapshot(session)
    refute Map.has_key?(snapshot.active_invocations, {state_index, invoke_index})
  end

  # A second `Statifier.Invoke.Handler` for `"test:lifecycle"`, used by the
  # full-lifecycle test below. Unlike `EchoHandler` above, `cancel/2` and
  # `forward/3` do not just reuse the built-in `{:stop_child, _}`/
  # `{:forward, _, _}` instructions - they *also* splice in a `{:handler,
  # __MODULE__, _}` the test can observe through `perform/2`, so the test
  # can tell "this handler's own `cancel/2`/`forward/3` ran" apart from "the
  # built-in `scxml` handler's `cancel/2`/`forward/3` happened to produce
  # the identical instruction" - `EchoHandler`'s own cancel/forward cannot
  # be told apart from the built-in's, which is fine for Phase 3's own test
  # above (it never exercises cancel/forward) but would not prove anything
  # about ADR-0051 decision 6's dispatch here. `cancel/2` still emits
  # `{:stop_child, invoke_id}` alongside the observable marker, since that
  # is what actually pops `invoke_id`'s table entry.
  defmodule LifecycleHandler do
    @moduledoc false
    @behaviour Statifier.Invoke.Handler

    @impl Statifier.Invoke.Handler
    def start(%Invoke{invoke_id: invoke_id}, _ctx) do
      {:ok, [{:handler, __MODULE__, {:start, invoke_id}}]}
    end

    @impl Statifier.Invoke.Handler
    def cancel(invoke_id, _ctx) do
      {:ok, [{:handler, __MODULE__, {:cancel, invoke_id}}, {:stop_child, invoke_id}]}
    end

    @impl Statifier.Invoke.Handler
    def forward(invoke_id, event, _ctx) do
      {:ok, [{:handler, __MODULE__, {:forward, invoke_id, event}}]}
    end

    @impl Statifier.Invoke.Handler
    def perform(message, _ctx) do
      send(:invoke_lifecycle_test_listener, message)
      :ok
    end
  end

  defp lifecycle_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a" datamodel="predicator">
        <datamodel>
            <data id="result"/>
        </datamodel>
        <state id="a">
            <invoke id="inv1" type="test:lifecycle" autoforward="true" namelist="result">
                <finalize/>
            </invoke>
            <transition event="go" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """
  end

  # sabotage: `Statifier.Session.Effects.plan_one/2`'s `:cancel_invoke`/
  # `:autoforward` arms are changed back to their pre-Phase-4 shape
  # (`[{:notify, effect}, {:stop_child, invoke_id}]` /
  # `[{:notify, effect}, {:forward, af.invoke_id, af.event}]`, bypassing
  # `handler_for/2` entirely) -> `LifecycleHandler.cancel/2` and `forward/3`
  # never run, so neither `assert_receive {:forward, "inv1", _}` nor
  # `assert_receive {:cancel, "inv1"}` below is ever satisfied, and both
  # time out. Reverted and confirmed green.
  test "autoforward reaches the handler's forward/3, and state exit cancels through the same handler" do
    Process.register(self(), :invoke_lifecycle_test_listener)

    machine = compile!(lifecycle_doc())

    {:ok, session} =
      Session.start_link(machine,
        trace: true,
        subscribers: [self()],
        invoke_handlers: %{"test:lifecycle" => LifecycleHandler}
      )

    wait_for_status(session, fn s -> s.configuration == MapSet.new(["a"]) end)
    assert_receive {:start, "inv1"}, 1_000

    # ADR-0051 decision 6, dispatch half: autoforward reaches the handler's
    # own `forward/3`, not just the built-in's.
    Session.send_event(session, "ping")
    assert_receive {:forward, "inv1", %Event{name: "ping"}}, 1_000

    # 6.4.3's cancellation: exiting "a" cancels "inv1" through the same
    # handler, and the table entry it never had a pid for is still popped.
    Session.send_event(session, "go")
    assert_receive {:cancel, "inv1"}, 1_000

    wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
    refute Enum.any?(Session.invocations(session), &(&1.invoke_id == "inv1"))
  end

  # sabotage: `Statifier.Session`'s `build_done_event/3` is changed to drop
  # `invokeid: invoke_id` from the constructed event -> `apply_invoke_passes_
  # for_invocation/5`'s `invoke_id == event.invokeid` guard no longer
  # matches ("inv1" vs `nil`), so the empty `<finalize/>` never runs and
  # `wait_for_snapshot/2` below times out waiting for `"result"` to become
  # `42`; the `EventDequeued` trace assertion also stops matching, since it
  # asserts `invokeid: "inv1"` on the same event. Reverted and confirmed
  # green.
  test "done_invocation/3 delivers done.invoke.<id> with invokeid set, and an empty <finalize/> auto-assigns its donedata" do
    Process.register(self(), :invoke_lifecycle_test_listener)

    machine = compile!(lifecycle_doc())

    {:ok, session} =
      Session.start_link(machine,
        trace: true,
        subscribers: [self()],
        invoke_handlers: %{"test:lifecycle" => LifecycleHandler}
      )

    session_id = Session.session_id(session)

    wait_for_status(session, fn s -> s.configuration == MapSet.new(["a"]) end)

    # ADR-0051 decision 5: the host's own door for a handler-backed
    # invocation's completion. `donedata`'s `"result"` name matches
    # `<invoke namelist="result">`, so the empty `<finalize/>` auto-assigns
    # it (decision 6) - the same auto-assign path a `scxml` invocation's own
    # `<donedata>` drives, now proven for a handler-delivered event too.
    Session.done_invocation(session, "inv1", %{"result" => 42})

    wait_for_snapshot(session, fn snap -> snap.datamodel["result"] == 42 end)

    stream = StreamOrder.drain(session_id)

    assert Enum.any?(stream, fn
             {:effect,
              {:trace,
               %Effect.Trace.EventDequeued{
                 event: %Event{name: "done.invoke.inv1", invokeid: "inv1"}
               }}} ->
               true

             _other_message ->
               false
           end)
  end

  # ADR-0068's own fixture: the same handler-backed invocation as
  # `lifecycle_doc/0`, with the two transitions decision 1 claims both work.
  # `parked` is entered by the *specific* name, `late` by the bare
  # `error.communication` after the invocation is gone - the pair is what
  # makes the discard test below assert something other than "no transition
  # was written".
  defp failure_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a" datamodel="predicator">
        <datamodel>
            <data id="reason"/>
            <data id="attempts"/>
        </datamodel>
        <state id="a">
            <invoke id="inv1" type="test:lifecycle"/>
            <transition event="error.communication.invoke.inv1" target="parked">
                <assign location="reason" expr="_event.data.reason"/>
                <assign location="attempts" expr="_event.data.attempts"/>
            </transition>
            <transition event="go" target="b"/>
        </state>
        <state id="parked"/>
        <state id="b">
            <transition event="error.communication" target="late"/>
        </state>
        <state id="late"/>
    </scxml>
    """
  end

  # A chart written against the bare `error.communication` ADR-0051 decision
  # 1's table names - the shape an author would have written before this
  # door existed. Separate from `failure_doc/0` on purpose: there, the
  # specific transition is document-ordered first and would win the
  # selection regardless of whether the prefix rule works at all.
  defp bare_communication_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <invoke id="inv1" type="test:lifecycle"/>
            <transition event="error.communication" target="parked"/>
        </state>
        <state id="parked"/>
    </scxml>
    """
  end

  defp start_failure_session(xml) do
    Process.register(self(), :invoke_lifecycle_test_listener)

    {:ok, session} =
      Session.start_link(compile!(xml),
        trace: true,
        subscribers: [self()],
        invoke_handlers: %{"test:lifecycle" => LifecycleHandler}
      )

    wait_for_status(session, fn s -> s.configuration == MapSet.new(["a"]) end)
    assert_receive {:start, "inv1"}, 1_000
    session
  end

  # sabotage: `Statifier.Session`'s `build_failure_event/3` is changed to
  # name the event `"error.invoke." <> invoke_id` - the candidate shape
  # ADR-0068 decision 1 rejected -> no transition in `failure_doc/0` matches
  # it (neither the specific name nor the bare `error.communication` is a
  # token prefix of `error.invoke.inv1`), the chart sits in "a", and
  # `wait_for_status/2` below times out. Reverted and confirmed green.
  test "failed_invocation/3 parks the chart on error.communication.invoke.<id> and its payload is readable" do
    session = start_failure_session(failure_doc())

    # ADR-0068 decision 3: the host's door, called when *its* retry policy is
    # exhausted - not anything the handler or the library decided.
    Session.failed_invocation(session, "inv1", reason: "timeout", attempts: 3)

    wait_for_status(session, fn s -> s.configuration == MapSet.new(["parked"]) end)

    snapshot = Session.snapshot(session)
    assert snapshot.datamodel["reason"] == "timeout"
    assert snapshot.datamodel["attempts"] == 3

    # Decision 4's terminal pop: a permanently failed invocation leaves the
    # table exactly as a completed one does.
    refute Enum.any?(Session.invocations(session), &(&1.invoke_id == "inv1"))
  end

  # sabotage: `Statifier.Session`'s `build_failure_event/3` is changed to
  # name the event `"error.invoke." <> invoke_id` -> `error.communication`
  # is not a token prefix of that, so nothing in `bare_communication_doc/0`
  # matches, the chart sits in "a", and `wait_for_status/2` below times out.
  # Reverted and confirmed green. This is deliberately the same mutation the
  # test above names: what separates the two is the *document*, since
  # `failure_doc/0`'s specific transition would win selection there whether
  # or not the prefix rule works at all.
  test "a chart written against the bare error.communication catches invoke exhaustion unedited" do
    session = start_failure_session(bare_communication_doc())

    Session.failed_invocation(session, "inv1", reason: "timeout")

    # Spec 3.12.1's suffix extension plus the descriptor prefix rule: the
    # shorter descriptor matches the longer name, so ADR-0051 decision 1's
    # published classification keeps working for a failure spelled more
    # specifically.
    wait_for_status(session, fn s -> s.configuration == MapSet.new(["parked"]) end)
  end

  # sabotage: `build_failure_event/3`'s `Keyword.get(failure, :attempts,
  # :undefined)` default is changed to `nil` - ADR-0037's rejected spelling
  # -> the delivered `data` carries `"attempts" => nil`, which is the
  # datamodel's *null*, and the `:undefined` match in the assertion below
  # reddens. Reverted and confirmed green.
  test "an omitted reason defaults to \"unknown\" and omitted attempts/detail read as undefined" do
    session = start_failure_session(failure_doc())
    session_id = Session.session_id(session)

    Session.failed_invocation(session, "inv1")

    wait_for_status(session, fn s -> s.configuration == MapSet.new(["parked"]) end)

    stream = StreamOrder.drain(session_id)

    assert Enum.any?(stream, fn
             {:effect,
              {:trace,
               %Effect.Trace.EventDequeued{
                 event: %Event{
                   name: "error.communication.invoke.inv1",
                   invokeid: "inv1",
                   data: %{
                     "reason" => "unknown",
                     "attempts" => :undefined,
                     "detail" => :undefined
                   }
                 }
               }}} ->
               true

             _other_message ->
               false
           end)
  end

  # sabotage: `Statifier.Session`'s `{:failed_invocation, _, _}` clause is
  # changed to deliver through `enqueue_event/2` (an ordinary `{:event, _}`
  # entry) instead of `enqueue_invoked/3` -> the entry is no longer
  # invocation-tagged, 6.4.3's drain-time discard no longer applies to it,
  # the report for the already-cancelled "inv1" is delivered anyway, and the
  # chart moves to "late" instead of staying in "b". Reverted and confirmed
  # green.
  test "a report for an invocation already cancelled is discarded, not delivered" do
    session = start_failure_session(failure_doc())

    # "go" exits "a", which cancels "inv1" (6.4.3) and pops its table entry.
    # A cast's `{:continue, :drain}}` runs to completion before the next
    # message is taken, so the cancel is fully applied by the time the
    # report below is cast.
    Session.send_event(session, "go")
    assert_receive {:cancel, "inv1"}, 1_000
    wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)

    Session.failed_invocation(session, "inv1", reason: "timeout")

    # The chart stays in "b": `late`'s bare `error.communication` transition
    # would fire if the report were delivered, so this is an assertion about
    # the discard rather than about no transition existing.
    wait_for_status(session, fn s -> s.configuration == MapSet.new(["b"]) end)
    assert Session.status(session).configuration == MapSet.new(["b"])
  end
end
