defmodule Statifier.Invoke.AnswerTest do
  use ExUnit.Case, async: false

  # `async: false` for `test/statifier/session/invoke_handler_test.exs`'s own
  # reason: the byte-identity block below drives a real `Statifier.Session`
  # process to quiescence, registers a named listener for its handler, and
  # drains the subscriber stream.
  #
  # The contract under test (ADR-0068's own "what would reopen this record"
  # bullet, and the 2026-09-02 decision note that closes it): the two events
  # that end a handler-backed invocation are
  # built by one public, pure module, so a host driving
  # `Statifier.Interpreter` with no `Statifier.Session` process at all can
  # answer an invocation it started. The identity tests are the load-bearing
  # half - a second construction site that merely *resembled*
  # `Statifier.Session`'s own would be the defect, not the feature.

  alias Statifier.{Compiler, Effect, Event, Lowering, Parser, Session, StreamOrder, Validator}
  alias Statifier.Effect.Invoke
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Invoke.Answer

  # sabotage: n/a - a `doctest` declaration is harness plumbing; the examples
  # it runs live in `lib/statifier/invoke/answer.ex`'s own `@doc`s and are
  # covered by the mutations recorded on the tests below.
  doctest Statifier.Invoke.Answer

  describe "done/3" do
    # sabotage: `done/3` drops `invokeid: invoke_id` from the constructed
    # event -> the struct match below fails on `invokeid: "inv_3"` against
    # `nil`, and `invoke_handler_test.exs`'s finalize test reddens with it,
    # since the `<finalize/>` pass matches on that very field. Reverted and
    # confirmed green.
    test "names the event done.invoke.<invoke_id> and stamps invokeid, origin and origintype" do
      event = Answer.done("sess_abc", "inv_3", %{"outcome" => "approved"})

      assert %Event{
               name: "done.invoke.inv_3",
               type: :external,
               data: %{"outcome" => "approved"},
               invokeid: "inv_3",
               origintype: origintype,
               cause: nil,
               sendid: nil,
               caller_context: nil
             } = event

      # C.1 / 5.10.1: the address an external entity would use to reach this
      # session, and the event processor that delivered it.
      assert event.origin == SystemVariables.scxml_location("sess_abc")
      assert origintype == SystemVariables.scxml_event_processor()
    end

    # sabotage: `done/3`'s `donedata \\ nil` default becomes `\\ :undefined`
    # -> the omitted-donedata event now carries the datamodel's *unbound*
    # spelling instead of a present null, and the `data: nil` match below
    # reddens. Reverted and confirmed green.
    test "donedata defaults to nil - the child that finished but produced nothing" do
      assert %Event{data: nil} = Answer.done("sess_abc", "inv_3")
    end

    # sabotage: `done/3` builds `data: inspect(donedata)` instead of
    # `data: donedata` -> the tuple arrives as its own printed form, this
    # test reddens, and so do the two above it. Reverted and confirmed green.
    test "any term is carried through as donedata, uninterpreted" do
      assert %Event{data: {:whatever, [1, 2, 3]}} =
               Answer.done("sess_abc", "inv_3", {:whatever, [1, 2, 3]})
    end
  end

  describe "failed/3" do
    # sabotage: `Answer.failed/3`'s name is changed to
    # `"error.invoke." <> invoke_id` - the candidate ADR-0068 decision 1
    # rejected -> this assertion reddens, and so does the parking test in
    # `test/statifier/session/invoke_handler_test.exs`, which is the pair
    # that proves the rename is a contract break and not a spelling
    # preference. Reverted and confirmed green.
    test "names the event error.communication.invoke.<invoke_id> (ADR-0068 decision 1)" do
      event = Answer.failed("sess_abc", "inv_3", reason: "exhausted", attempts: 5)

      assert %Event{
               name: "error.communication.invoke.inv_3",
               type: :external,
               invokeid: "inv_3",
               cause: nil
             } = event

      assert event.origin == SystemVariables.scxml_location("sess_abc")
      assert event.origintype == SystemVariables.scxml_event_processor()
      assert event.data == %{"reason" => "exhausted", "attempts" => 5, "detail" => :undefined}
    end

    # sabotage: `failed/3`'s `"reason"` default is changed from `"unknown"`
    # to `"missing"` -> a chart written against the documented default reads
    # a value that is not in ADR-0068 decision 2's table, and the map match
    # below reddens. Reverted and confirmed green.
    test "an omitted reason reads \"unknown\" and omitted attempts/detail read :undefined" do
      assert %Event{
               data: %{"reason" => "unknown", "attempts" => :undefined, "detail" => :undefined}
             } = Answer.failed("sess_abc", "inv_3")
    end

    # sabotage: `failed/3` builds the payload with atom keys
    # (`reason:`/`attempts:`/`detail:`) instead of string keys -> the sorted
    # key list below is no longer `["attempts", "detail", "reason"]`, and the
    # other two `failed/3` tests redden with it. Reverted and confirmed
    # green.
    test "the payload keys are strings, so one convention covers reading a failure and a send" do
      event = Answer.failed("sess_abc", "inv_3", reason: "undecodable", detail: {:decode, :v1})

      assert Map.keys(event.data) |> Enum.sort() == ["attempts", "detail", "reason"]
      assert event.data["detail"] == {:decode, :v1}
    end
  end

  describe "the Session path and the process-less path build the same event" do
    # These two are why the module is an extraction rather than a second
    # implementation. `Statifier.Session.done_invocation/3` and
    # `failed_invocation/3` call `Answer.done/3` and `Answer.failed/3`
    # themselves, so a divergence is impossible by construction - and these
    # tests are what keeps it impossible after someone inlines one of them
    # back for a "small" local change.

    # sabotage: `Statifier.Session`'s `{:done_invocation, _, _}` cast is
    # changed back to inlining `Event.external("done.invoke." <> invoke_id,
    # data: donedata, invokeid: invoke_id)` without `origin`/`origintype`
    # -> the delivered event no longer equals `Answer.done/3`'s, and the
    # `assert delivered == expected` below reddens on the two dropped
    # fields. Reverted and confirmed green.
    test "done_invocation/3's delivered event is byte-identical to Answer.done/3's" do
      session = start_lifecycle_session()
      session_id = Session.session_id(session)

      Session.done_invocation(session, "inv1", %{"result" => 42})

      wait_for_status(session, fn s -> s.configuration == MapSet.new(["finished"]) end)

      delivered = dequeued_event(session_id, "done.invoke.inv1")
      assert delivered == Answer.done(session_id, "inv1", %{"result" => 42})
    end

    # sabotage: `Statifier.Session`'s `{:failed_invocation, _, _}` cast is
    # changed to inline its own `Event.external/2` call with the same name
    # and `invokeid` but no `origin`/`origintype` and only the `"reason"`
    # key -> the two events stop being equal and the assertion below names
    # the divergence field by field. Reverted and confirmed green.
    test "failed_invocation/3's delivered event is byte-identical to Answer.failed/3's" do
      session = start_lifecycle_session()
      session_id = Session.session_id(session)

      Session.failed_invocation(session, "inv1", reason: "exhausted", attempts: 5)

      wait_for_status(session, fn s -> s.configuration == MapSet.new(["parked"]) end)

      delivered = dequeued_event(session_id, "error.communication.invoke.inv1")
      assert delivered == Answer.failed(session_id, "inv1", reason: "exhausted", attempts: 5)
    end
  end

  # A minimal `Statifier.Invoke.Handler` for `"test:answer"`: the invocation
  # exists so the session has a live table entry to answer, and nothing about
  # the handler itself is under test here.
  defmodule AnswerHandler do
    @moduledoc false
    @behaviour Statifier.Invoke.Handler

    @impl Statifier.Invoke.Handler
    def start(%Invoke{invoke_id: invoke_id}, _ctx) do
      {:ok, [{:handler, __MODULE__, {:start, invoke_id}}]}
    end

    @impl Statifier.Invoke.Handler
    def cancel(invoke_id, _ctx), do: {:ok, [{:stop_child, invoke_id}]}

    @impl Statifier.Invoke.Handler
    def forward(invoke_id, event, _ctx), do: {:ok, [{:forward, invoke_id, event}]}

    @impl Statifier.Invoke.Handler
    def perform(message, _ctx) do
      send(:invoke_answer_test_listener, message)
      :ok
    end
  end

  defp answer_doc do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a" datamodel="predicator">
        <state id="a">
            <invoke id="inv1" type="test:answer"/>
            <transition event="done.invoke.inv1" target="finished"/>
            <transition event="error.communication.invoke.inv1" target="parked"/>
        </state>
        <state id="finished"/>
        <state id="parked"/>
    </scxml>
    """
  end

  defp start_lifecycle_session do
    Process.register(self(), :invoke_answer_test_listener)

    {:ok, session} =
      Session.start_link(compile!(answer_doc()),
        trace: true,
        subscribers: [self()],
        invoke_handlers: %{"test:answer" => AnswerHandler}
      )

    wait_for_status(session, fn s -> s.configuration == MapSet.new(["a"]) end)
    assert_receive {:start, "inv1"}, 1_000
    session
  end

  # The delivered `%Event{}` itself, off the trace stream, so the comparison
  # is against what the chart actually dequeued rather than against anything
  # the test reconstructed.
  defp dequeued_event(session_id, name) do
    found =
      session_id
      |> StreamOrder.drain()
      |> Enum.find_value(fn
        {:effect, {:trace, %Effect.Trace.EventDequeued{event: %Event{name: ^name} = event}}} ->
          event

        _other_message ->
          nil
      end)

    found || flunk("no EventDequeued trace carrying #{name}")
  end

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
end
