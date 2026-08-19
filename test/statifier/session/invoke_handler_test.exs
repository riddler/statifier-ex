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
end
