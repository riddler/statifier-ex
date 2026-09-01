# The sync handlers the adapter under test serves. Two modules rather than
# one, because everything worth asserting about the registry helper - the
# union, the deduplication, and which module answers a type both of them
# claim - needs two.
#
# `handle/3` records into the *test process's* dictionary with set
# semantics, the same observation point
# `Statifier.Testing.HandlerCaseTest.Conformant` uses: it is a real
# observation of a performed effect, it dies with the test, and being a set
# is what makes it idempotent - which is exactly the obligation
# `Statifier.Invoke.SyncHandler`'s moduledoc leaves with the handler rather
# than the adapter. Note the effect is only observable when `perform/2` is
# called in-process (the conformance case does); a session performs it in
# the session process, where these tests observe the chart instead.
defmodule Statifier.Invoke.SyncHandler.AdapterTest.Alpha do
  @moduledoc false
  @behaviour Statifier.Invoke.SyncHandler

  @impl Statifier.Invoke.SyncHandler
  def invoke_types, do: ["test:alpha", "test:shared"]

  @impl Statifier.Invoke.SyncHandler
  def handle(type, params, ctx) do
    record(ctx)
    {:ok, %{"who" => "alpha", "type" => type, "plan" => Map.get(params, "plan", "none")}}
  end

  @spec observed(session_id :: String.t()) :: MapSet.t()
  def observed(session_id), do: Process.get({__MODULE__, session_id}, MapSet.new())

  defp record(%{session_id: session_id}) do
    key = {__MODULE__, session_id}
    Process.put(key, MapSet.put(Process.get(key, MapSet.new()), :handled))
    :ok
  end
end

defmodule Statifier.Invoke.SyncHandler.AdapterTest.Beta do
  @moduledoc false
  @behaviour Statifier.Invoke.SyncHandler

  @impl Statifier.Invoke.SyncHandler
  def invoke_types, do: ["test:odd_failure", "test:beta", "test:shared", "test:fail"]

  @impl Statifier.Invoke.SyncHandler
  def handle("test:fail", _params, _ctx), do: {:error, "card_declined"}
  def handle("test:odd_failure", _params, _ctx), do: {:error, {:weird, 1}}
  def handle(type, _params, _ctx), do: {:ok, %{"who" => "beta", "type" => type}}
end

defmodule Statifier.Invoke.SyncHandler.AdapterTest.Handler do
  @moduledoc false
  use Statifier.Invoke.SyncHandler.Adapter,
    handlers: [
      Statifier.Invoke.SyncHandler.AdapterTest.Alpha,
      Statifier.Invoke.SyncHandler.AdapterTest.Beta
    ]
end

# A sync handler that answers with the context it was handed, for the
# host-driven routing arm: `dispatch/4` is public for a host driving the
# pure core with no session, and what such a host has to say about a call is
# its own context, not the plan context a session threads.
defmodule Statifier.Invoke.SyncHandler.AdapterTest.Echo do
  @moduledoc false
  @behaviour Statifier.Invoke.SyncHandler

  @impl Statifier.Invoke.SyncHandler
  def invoke_types, do: ["test:echo"]

  @impl Statifier.Invoke.SyncHandler
  def handle(_type, _params, ctx), do: {:ok, %{"ctx" => ctx}}
end

# A module that is not a sync handler at all, for the ArgumentError arm.
defmodule Statifier.Invoke.SyncHandler.AdapterTest.NotAHandler do
  @moduledoc false
end

defmodule Statifier.Invoke.SyncHandler.AdapterTest do
  use ExUnit.Case, async: false

  # `async: false` matches `test/statifier/session/invoke_handler_test.exs`'s
  # own idiom: the end-to-end tests below drive a real `Statifier.Session`
  # process to quiescence.

  # The whole seam under one `use`: the adapter is an ordinary
  # `Statifier.Invoke.Handler`, so it owes the same contract every handler
  # owes, and this is the family's own case for saying so (ADR-0053).
  # `perform/2` is called in-process here, so `Alpha`'s dictionary set is a
  # real observation point.
  use Statifier.Testing.HandlerCase,
    handler: Statifier.Invoke.SyncHandler.AdapterTest.Handler,
    type: "test:alpha"

  alias Statifier.{Compiler, Event, Lowering, Parser, Session, Validator}
  alias Statifier.Effect.Invoke
  alias Statifier.Invoke.SyncHandler.Adapter
  alias Statifier.Invoke.SyncHandler.AdapterTest.{Alpha, Beta, Echo, Handler, NotAHandler}
  alias Statifier.Invoke.Types, as: InvokeTypes

  # The conformance case's observation point: what `Alpha.handle/3` recorded
  # for the session the case's own fixture context names. Read off
  # `conformance_ctx/0` rather than spelled out, so the two cannot drift.
  @spec observed_effects(invoke_id :: String.t()) :: MapSet.t()
  def observed_effects(_invoke_id), do: Alpha.observed(conformance_ctx().session_id)

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp wait_for_status(session, pred, attempts \\ 50)

  defp wait_for_status(_session, _pred, 0),
    do: flunk("status/1 never satisfied the predicate")

  defp wait_for_status(session, pred, attempts) do
    status = Session.status(session)

    if pred.(status) do
      status
    else
      Process.sleep(5)
      wait_for_status(session, pred, attempts - 1)
    end
  end

  # One chart for every end-to-end case: it invokes `type`, records whatever
  # comes back, and parks in `answered` or `failed`. Reading the payload
  # through `<assign>` rather than off the wire is deliberate - what a chart
  # author can see is the only observation that pins the adapter's reporting
  # half, and it is the idiom `invoke_handler_test.exs` already uses.
  defp call_doc(type) do
    """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="calling"
           datamodel="predicator">
        <datamodel>
            <data id="who"/>
            <data id="called_type"/>
            <data id="plan"/>
            <data id="reason"/>
            <data id="attempts"/>
        </datamodel>
        <state id="calling">
            <invoke id="call" type="#{type}">
                <param name="plan" expr="'pro'"/>
            </invoke>
            <transition event="done.invoke.call" target="answered">
                <assign location="who" expr="_event.data.who"/>
                <assign location="called_type" expr="_event.data.type"/>
                <assign location="plan" expr="_event.data.plan"/>
            </transition>
            <transition event="error.communication.invoke.call" target="failed">
                <assign location="reason" expr="_event.data.reason"/>
                <assign location="attempts" expr="_event.data.attempts"/>
            </transition>
        </state>
        <state id="answered"/>
        <state id="failed"/>
    </scxml>
    """
  end

  defp start_call_session(type) do
    {:ok, session} =
      Session.start_link(compile!(call_doc(type)), invoke_handlers: Handler.invoke_handlers())

    on_exit(fn -> if Process.alive?(session), do: Session.stop(session) end)
    session
  end

  describe "the derived registrations" do
    # sabotage: `Adapter.invoke_types/1`'s `Enum.uniq()` is dropped ->
    # "test:shared" appears twice in the union and the assertion below
    # reddens on the duplicate. Reverted and confirmed green.
    test "invoke_types/0 is the sorted, deduplicated union across the handler modules" do
      assert Handler.invoke_types() == [
               "test:alpha",
               "test:beta",
               "test:fail",
               "test:odd_failure",
               "test:shared"
             ]
    end

    # sabotage: the generated `invoke_handlers/0` is changed to pass
    # `hd(@sync_handlers)` instead of `__MODULE__` -> every type maps to
    # `Alpha`, which implements no `Statifier.Invoke.Handler` callback, and
    # the value assertion below reddens. Reverted and confirmed green.
    test "invoke_handlers/0 points every type at the adapter, over exactly invoke_types/0's set" do
      handlers = Handler.invoke_handlers()

      assert Map.keys(handlers) |> Enum.sort() == Handler.invoke_types()
      assert Enum.uniq(Map.values(handlers)) == [Handler]
    end

    # sabotage: `Statifier.Invoke.Types.from_handlers/1` is changed to
    # `new(types: [])` -> the snapshot registers none of the adapter's types
    # and every `registered?/2` assertion below reddens. Reverted and
    # confirmed green.
    test "the core's registered-type snapshot derives from the same map, so the three sets agree" do
      types = InvokeTypes.from_handlers(Handler.invoke_handlers())

      for type <- Handler.invoke_types() do
        assert InvokeTypes.registered?(types, type),
               "#{type} is in invoke_types/0 but not registered in the core's snapshot"
      end

      refute InvokeTypes.registered?(types, "test:never_registered")
    end

    # sabotage: `module_types/1`'s `function_exported?/3` guard is removed
    # so the module is called blind -> the failure is an
    # `UndefinedFunctionError` rather than the named `ArgumentError`, and
    # `assert_raise` reddens. Reverted and confirmed green.
    test "a :handlers entry that is not a sync handler is named, not left to fail mid-drive" do
      assert_raise ArgumentError, ~r/does not export invoke_types\/0/, fn ->
        Adapter.invoke_types([Alpha, NotAHandler])
      end
    end

    # sabotage: `__using__/1`'s `Keyword.get(opts, :handlers) || raise` is
    # changed to `Keyword.get(opts, :handlers, [])` -> the module compiles
    # with an empty handler list instead of refusing, and `assert_raise`
    # below reddens. Reverted and confirmed green.
    test "use without :handlers refuses at compile time rather than serving nothing" do
      assert_raise ArgumentError, ~r/requires :handlers/, fn ->
        Code.compile_quoted(
          quote do
            defmodule Statifier.Invoke.SyncHandler.AdapterTest.NoHandlers do
              use Statifier.Invoke.SyncHandler.Adapter
            end
          end
        )
      end
    end
  end

  describe "routing" do
    # sabotage: `dispatch/4`'s `Enum.find/2` is changed to `Enum.reverse/1
    # |> Enum.find/2` -> "test:shared" resolves to `Beta`, the module that
    # claims it second, and the documented first-wins assertion reddens.
    # Reverted and confirmed green.
    test "a type two modules claim is answered by the first one in the list" do
      ctx = %{session_id: "sess_x", invoke_types: nil, invoke_handlers: %{}}

      assert {:ok, %{"who" => "alpha"}} =
               Adapter.dispatch([Alpha, Beta], "test:shared", %{}, ctx)

      assert {:ok, %{"who" => "beta"}} =
               Adapter.dispatch([Beta, Alpha], "test:shared", %{}, ctx)
    end

    # sabotage: `dispatch/4`'s `nil ->` arm is changed to route to
    # `hd(modules)` -> an unclaimed type reaches `Alpha.handle/3`, which
    # answers `{:ok, _}`, and the `{:error, {:unknown_invoke_type, _}}`
    # match below reddens. Reverted and confirmed green.
    test "a type no module claims is an unknown_invoke_type error, not a wrong answer" do
      ctx = %{session_id: "sess_x", invoke_types: nil, invoke_handlers: %{}}

      assert {:error, {:unknown_invoke_type, "test:nobody"}} =
               Adapter.dispatch([Alpha, Beta], "test:nobody", %{}, ctx)
    end

    # sabotage: `dispatch/4`'s `module.handle(type, params, ctx)` is changed
    # to pass `%{}` -> the host's own context never reaches the handler and
    # the match below reddens on an empty map (with four session-path tests
    # reddening alongside it, since `Alpha` matches on `session_id`).
    # Reverted and confirmed green.
    test "a host's own context is routed through untouched, not just a plan context" do
      assert {:ok, %{"ctx" => %{run_id: "run_7"}}} =
               Adapter.dispatch([Echo], "test:echo", %{}, %{run_id: "run_7"})

      assert {:ok, %{"ctx" => %{}}} = Adapter.dispatch([Echo], "test:echo", %{}, %{})
    end

    # The spec is the deliverable here, not a description of one: a host
    # driving the pure core routes through `dispatch/4` only if dialyzer
    # lets it hand its own context, so the widened contract is asserted
    # against the compiled beam rather than left to the next reader of the
    # source.
    #
    # sabotage: `dispatch/4`'s fourth argument is typed back to
    # `SyncHandler.ctx()` -> the stored argument is a `:remote_type` naming
    # `Statifier.Invoke.SyncHandler.ctx`, and the `:user_type` match below
    # reddens. Reverted and confirmed green.
    test "dispatch/4's context is the widened map, not the session's plan context" do
      assert {:ok, types} = Code.Typespec.fetch_types(Adapter)

      assert Enum.any?(types, fn
               {:type, {:dispatch_ctx, {:type, _line, :map, :any}, []}} -> true
               _other -> false
             end),
             "dispatch_ctx/0 is no longer the unconstrained map a host context needs"

      assert {:ok, specs} = Code.Typespec.fetch_specs(Adapter)
      {_signature, [spec]} = Enum.find(specs, &match?({{:dispatch, 4}, _spec}, &1))
      {:type, _line, :fun, [{:type, _product_line, :product, arguments}, _return]} = spec

      assert [_modules, _type, _params, ctx] = arguments

      assert {:ann_type, _ctx_line,
              [{:var, _var_line, :ctx}, {:user_type, _use_line, :dispatch_ctx, []}]} =
               ctx
    end
  end

  describe "the planning callbacks" do
    # sabotage: `plan_start/3`'s payload drops the `:type` key ->
    # `perform/3`'s
    # payload match fails and, before that, the assertion below reddens on
    # the missing key. Reverted and confirmed green.
    test "start/2 plans exactly one {:handler, adapter, payload} instruction" do
      invoke = %Invoke{
        invoke_id: "inv_1",
        type: "test:alpha",
        src: nil,
        params: %{"plan" => "pro"},
        content: nil,
        autoforward: false,
        state_index: 0,
        invoke_index: 0,
        macrostep: 1,
        microstep: 1,
        round: 1
      }

      assert {:ok, [{:handler, Handler, payload}]} = Handler.start(invoke, %{session_id: "s"})
      assert payload == %{invoke_id: "inv_1", type: "test:alpha", params: %{"plan" => "pro"}}
    end

    # sabotage: `params/1`'s `defp params(_absent), do: %{}` clause is
    # changed to return `:undefined` unchanged -> the payload carries
    # `:undefined`, `handle/3`'s `map()` contract is broken, and the
    # assertion below reddens. Reverted and confirmed green.
    test "an <invoke> with no <param> normalizes to an empty map, not :undefined" do
      invoke = %Invoke{
        invoke_id: "inv_1",
        type: "test:alpha",
        src: nil,
        params: :undefined,
        content: nil,
        autoforward: false,
        state_index: 0,
        invoke_index: 0,
        macrostep: 1,
        microstep: 1,
        round: 1
      }

      assert {:ok, [{:handler, Handler, %{params: %{}}}]} =
               Handler.start(invoke, %{session_id: "s"})
    end

    # sabotage: `plan_cancel/2` is changed to return `{:ok, [{:stop_child,
    # invoke_id}]}` -> a sync call plans a child stop it never had, and the
    # empty-list assertion reddens. Reverted and confirmed green.
    test "cancel/2 and forward/3 plan nothing, for an invocation with no lifecycle" do
      ctx = %{session_id: "s"}

      assert {:ok, []} = Handler.cancel("inv_1", ctx)
      assert {:ok, []} = Handler.forward("inv_1", %Event{name: "ping", type: :external}, ctx)
    end
  end

  describe "perform/2 reporting, end to end through a session" do
    # sabotage: `perform/3`'s `{:ok, donedata}` arm is changed to call
    # `Session.done_invocation(&1, invoke_id)` with no donedata -> the chart
    # still reaches "answered" but every `<assign>` reads `undefined`, and
    # the datamodel assertions below redden. Reverted and confirmed green.
    test "an {:ok, donedata} answer reaches the chart as done.invoke.<id>'s payload" do
      session = start_call_session("test:alpha")

      wait_for_status(session, fn s -> s.configuration == MapSet.new(["answered"]) end)

      snapshot = Session.snapshot(session)
      assert snapshot.datamodel["who"] == "alpha"
      assert snapshot.datamodel["called_type"] == "test:alpha"
      assert snapshot.datamodel["plan"] == "pro"
    end

    # sabotage: `perform/3`'s `{:error, reason}` arm is changed to call
    # `Session.done_invocation/3` -> the chart parks in "answered" instead
    # of "failed" and `wait_for_status/2` below times out. Reverted and
    # confirmed green.
    test "an {:error, reason} answer is permanent: error.communication.invoke.<id>, no attempts" do
      session = start_call_session("test:fail")

      wait_for_status(session, fn s -> s.configuration == MapSet.new(["failed"]) end)

      snapshot = Session.snapshot(session)
      assert snapshot.datamodel["reason"] == "card_declined"

      # The adapter counts no attempts because it makes none, and ADR-0037's
      # spelling for "the host said nothing" is `:undefined` - distinct from
      # a host that counted zero.
      assert snapshot.datamodel["attempts"] == :undefined
    end

    # sabotage: `reason/1`'s catch-all `inspect(reason)` clause is changed
    # to return the term unchanged -> a non-binary reaches the datamodel as
    # a tuple and the string assertion below reddens. Reverted and confirmed
    # green.
    test "a reason that is not a string is inspected rather than dropped" do
      session = start_call_session("test:odd_failure")

      wait_for_status(session, fn s -> s.configuration == MapSet.new(["failed"]) end)

      assert Session.snapshot(session).datamodel["reason"] == "{:weird, 1}"
    end

    # sabotage: `report/2`'s `nil ->` arm is changed to `deliver.(nil)` ->
    # the call raises out of the reporting path instead of answering, and
    # the match below reddens. Reverted and confirmed green.
    test "a session id that resolves to nothing is an answer, not a raise" do
      ctx = %{session_id: "sess_never_started", invoke_types: nil, invoke_handlers: %{}}
      payload = %{invoke_id: "inv_1", type: "test:alpha", params: %{}}

      assert {:error, {:session_not_registered, "sess_never_started"}} =
               Adapter.perform([Alpha, Beta], payload, ctx)
    end
  end
end
