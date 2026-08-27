defmodule Statifier.Testing.HandlerCase do
  @moduledoc """
  A reusable conformance case for `Statifier.Invoke.Handler` implementations
  - the second member of the `Statifier.Testing` family ADR-0053 opened, and
  the mechanical pin for the behaviour contract ADR-0051 decision 4 and
  `docs/extending.md` state in prose. A host application `use`s this module
  in a test alongside `use ExUnit.Case` and gets the contract checks as
  generated tests against its own handler:

      defmodule MyApp.AuthorizeHandlerConformanceTest do
        use ExUnit.Case, async: false
        use Statifier.Testing.HandlerCase,
          handler: MyApp.AuthorizeHandler,
          type: "myapp:authorize"
      end

  What the generated tests verify, each a clause of the documented contract:

  1. `start/2`, `cancel/2`, and `forward/3` are pure planning callbacks -
     deterministic for fixed inputs, observably effect-free, returning the
     documented shapes (`Statifier.Invoke.Handler`'s moduledoc, point 1).
  2. `perform/2` is idempotent on `invoke_id`: performing the handler's own
     planned instructions twice must not duplicate observable effects
     (point 2 there, and `docs/extending.md`'s "At-least-once" section).
     Idempotency needs an observation point only the implementor can name -
     see "The observation point" below.
  3. `cancel/2` after `start/2` plans without raising, and `cancel/2` for an
     invoke_id the handler never saw is a no-op, never a raise - the library
     plans cancels off the live invocation table, but a crash-recovering host
     may replay a cancel whose start it never durably recorded.
  4. `{:error, _}` from `start/2` surfaces as `error.execution` in the
     driving chart (ADR-0051 decision 1's classification table), pinned by
     driving a minimal chart fixture with a case-internal always-failing
     probe handler registered under the implementor's own type string.
  5. Handler exceptions propagate - the library never rescues them into an
     event (`docs/extending.md`, "Where the library will not help") - pinned
     with a case-internal raising probe the same way.

  Checks 4 and 5 pin the *library's* half of the contract with probe
  handlers rather than the implementation under test, on purpose: a
  conforming handler has no reason to expose a start that fails or raises on
  demand, and the point of running the pins downstream is that the contract
  an implementor builds against stays enforced by tests where the
  implementations live, not by this repository's suite alone. A handler
  whose `start/2` has a real failure path asserts its own half with
  `assert_erroring_start/3`.

  Every check is also a public function on this module, so a suite that
  wants different fixtures - or only one of the checks - calls them directly
  instead of `use`-ing the whole case.

  ## What this case deliberately does not check: terminal failure

  An async handler's contract has one clause no handler-scoped case can
  reach. When a host's retry policy for `invoke_id` is permanently
  exhausted, the host reports it with
  `Statifier.Session.failed_invocation/3`, which delivers
  `error.communication.invoke.<invoke_id>` on the same invocation-tagged
  entry - and under the same 6.4.3 drain-time discard - as
  `done.invoke.<invoke_id>` (ADR-0068, and `docs/extending.md`'s "Reporting
  permanent failure"). A chart that never hears it waits in its invoking
  state forever.

  That door belongs to the host's retry layer, not to the handler: the
  behaviour has no callback for it, and check 2's `perform/2` `{:error, _}`
  is a *transient* signal that a retry policy exists to absorb rather than a
  terminal one. So the thing worth asserting - that your policy actually
  reaches the door when it gives up - is invisible from here, and a
  generated check that only proved the door exists would pin this library
  instead of the implementation under test. Write that test where the retry
  policy lives. Check 4 above already covers the one failure path a handler
  owns outright, `{:error, _}` from `start/2`.

  ## Options

  - `:handler` (required) - the `Statifier.Invoke.Handler` implementation
    module under test.
  - `:type` (required) - the `<invoke type>` string the handler serves.

  ## The fixtures, and overriding them

  The generated tests plan against a synthetic `%Statifier.Effect.Invoke{}`,
  a plan context, and an autoforwarded event, built by `build_invoke/2`,
  `build_ctx/3`, and `build_event/1`. Each is reachable through an
  overridable function in the `use`-ing module, so a handler that reads
  `params`, `src`, or `content` overrides the one fixture it cares about:

  - `conformance_invoke/0` - the `%Statifier.Effect.Invoke{}` handed to
    `start/2`.
  - `conformance_ctx/0` - the plan context handed to every callback.
  - `conformance_event/0` - the `%Statifier.Event{}` handed to `forward/3`.
  - `observed_effects/1` - the observation point, below.

  ## The observation point

  The case cannot see your job queue, your database, or your test inbox, so
  idempotency (and planning purity) are judged against a function you
  declare: override `observed_effects/1` to return the observable effects
  attributable to the given `invoke_id` at the moment of the call - a list
  of enqueued jobs, a set of rows, whatever your `perform/2` writes. The
  default returns `:unobserved`, which skips the purity comparisons; the
  idempotency test **flunks** under that default whenever the handler
  actually routes instructions to `perform/2`, naming the override to
  write - a handler with real performed effects never gets a silent pass
  (ADR-0053's fail-not-skip discipline). A handler that routes nothing to
  `perform/2` needs no observation point, and its idempotency test asserts
  exactly that instead.
  """

  import ExUnit.Assertions

  alias Statifier.Effect.Invoke
  alias Statifier.{Event, Session}
  alias Statifier.Invoke.{Handler, Types}

  @typedoc """
  The observation point: returns the observable effects attributable to an
  `invoke_id`, or `:unobserved` when the `use`-ing module has not declared
  one - see the moduledoc's "The observation point" section.
  """
  @type observe :: (invoke_id :: String.t() -> term())

  # The invoke_id no fixture ever plans with, for the unknown-cancel check.
  @unknown_invoke_id "inv_conformance_unknown"

  @doc """
  Generates the conformance tests into the `use`-ing module, which must
  `use ExUnit.Case` first (the generated tests are ordinary `test` blocks).
  Options and the overridable fixture functions are described in the
  moduledoc.
  """
  @spec __using__(opts :: Macro.t()) :: Macro.t()
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts, handler_case: __MODULE__] do
      @handler_conformance_case handler_case
      @handler_conformance_handler Keyword.fetch!(opts, :handler)
      @handler_conformance_type Keyword.fetch!(opts, :type)

      @doc false
      @spec conformance_invoke() :: Statifier.Effect.Invoke.t()
      def conformance_invoke,
        do: @handler_conformance_case.build_invoke(@handler_conformance_type)

      @doc false
      @spec conformance_ctx() :: Statifier.Invoke.Handler.ctx()
      def conformance_ctx do
        @handler_conformance_case.build_ctx(
          @handler_conformance_type,
          @handler_conformance_handler
        )
      end

      @doc false
      @spec conformance_event() :: Statifier.Event.t()
      def conformance_event, do: @handler_conformance_case.build_event()

      @doc false
      @spec observed_effects(invoke_id :: String.t()) :: term()
      def observed_effects(_invoke_id), do: :unobserved

      defoverridable conformance_invoke: 0,
                     conformance_ctx: 0,
                     conformance_event: 0,
                     observed_effects: 1

      test "Invoke.Handler conformance: start/2 is a deterministic, effect-free planning callback" do
        @handler_conformance_case.assert_start_contract(
          @handler_conformance_handler,
          conformance_invoke(),
          conformance_ctx(),
          &observed_effects/1
        )
      end

      test "Invoke.Handler conformance: cancel/2 plans after start/2 and never raises for an unknown invoke_id" do
        @handler_conformance_case.assert_cancel_contract(
          @handler_conformance_handler,
          conformance_invoke(),
          conformance_ctx(),
          &observed_effects/1
        )
      end

      test "Invoke.Handler conformance: forward/3 is a deterministic, effect-free planning callback" do
        @handler_conformance_case.assert_forward_contract(
          @handler_conformance_handler,
          conformance_invoke(),
          conformance_ctx(),
          conformance_event(),
          &observed_effects/1
        )
      end

      test "Invoke.Handler conformance: perform/2 is idempotent on invoke_id" do
        @handler_conformance_case.assert_perform_idempotent(
          @handler_conformance_handler,
          conformance_invoke(),
          conformance_ctx(),
          conformance_event(),
          &observed_effects/1
        )
      end

      test "Invoke.Handler conformance: {:error, _} from start/2 surfaces as error.execution in the driving chart" do
        @handler_conformance_case.assert_error_start_raises_error_execution(
          @handler_conformance_type
        )
      end

      test "Invoke.Handler conformance: handler exceptions propagate, never rescued by the library" do
        @handler_conformance_case.assert_handler_exceptions_propagate(@handler_conformance_type)
      end
    end
  end

  @doc """
  A synthetic `%Statifier.Effect.Invoke{}` for planning against: `type` as
  given, `invoke_id` `"inv_1"` (the shape a generated platformid takes,
  ADR-0008 as amended), empty `params`, and zeroed counters. `overrides`
  replaces any field.
  """
  @spec build_invoke(type :: String.t()) :: Invoke.t()
  @spec build_invoke(type :: String.t(), overrides :: keyword()) :: Invoke.t()
  def build_invoke(type, overrides \\ []) do
    defaults = [
      invoke_id: "inv_1",
      type: type,
      src: nil,
      params: %{},
      content: nil,
      autoforward: false,
      state_index: 0,
      invoke_index: 0,
      macrostep: 1,
      microstep: 1,
      round: 1
    ]

    struct!(Invoke, Keyword.merge(defaults, overrides))
  end

  @doc """
  A plan context (`Statifier.Invoke.Handler.t:ctx/0`) declaring `type`
  registered and dispatching it to `handler` - the same three keys
  `Statifier.Session.Effects.plan/2` hands every planning callback.
  `overrides` merges over the defaults, since `ctx` is a plain map by
  contract.
  """
  @spec build_ctx(type :: String.t(), handler :: module()) :: Handler.ctx()
  @spec build_ctx(type :: String.t(), handler :: module(), overrides :: keyword()) ::
          Handler.ctx()
  def build_ctx(type, handler, overrides \\ []) do
    Map.merge(
      %{
        session_id: "sess_handler_conformance",
        invoke_types: Types.new(types: [type]),
        invoke_handlers: %{type => handler}
      },
      Map.new(overrides)
    )
  end

  @doc """
  A synthetic external event for `forward/3` (spec 6.4.2's `autoforward`):
  name `"conformance.ping"`, no data. `overrides` replaces any field.
  """
  @spec build_event() :: Event.t()
  @spec build_event(overrides :: keyword()) :: Event.t()
  def build_event(overrides \\ []) do
    struct!(Event, Keyword.merge([name: "conformance.ping", type: :external], overrides))
  end

  @doc """
  Contract check 1 for `start/2`: called twice with fixed inputs it returns
  the same value, of the documented shape (`{:ok, instructions}` or
  `{:error, term}`), and leaves `observe`'s reading for the invoke's own id
  unchanged - planning is deciding, never doing.
  """
  @spec assert_start_contract(
          handler :: module(),
          invoke :: Invoke.t(),
          ctx :: Handler.ctx(),
          observe :: observe()
        ) :: :ok
  def assert_start_contract(handler, invoke, ctx, observe) do
    before_planning = observe.(invoke.invoke_id)
    first = handler.start(invoke, ctx)
    second = handler.start(invoke, ctx)

    assert match?({:ok, instructions} when is_list(instructions), first) or
             match?({:error, _reason}, first),
           "start/2 must return {:ok, [instruction]} or {:error, term}, got: #{inspect(first)}"

    assert first == second,
           "start/2 must be deterministic for fixed inputs (it is a pure planning " <>
             "callback, ADR-0051 decision 4); two calls returned:\n" <>
             "  #{inspect(first)}\n  #{inspect(second)}"

    assert_planning_left_no_trace(observe, invoke.invoke_id, before_planning, "start/2")
    :ok
  end

  @doc """
  Contract check 3 for `cancel/2`: after `start/2` has planned, `cancel/2`
  for the same `invoke_id` deterministically plans `{:ok, instructions}`;
  for an `invoke_id` the handler never saw it is a no-op that returns
  `{:ok, instructions}` rather than raising; and neither call moves
  `observe`'s reading.
  """
  @spec assert_cancel_contract(
          handler :: module(),
          invoke :: Invoke.t(),
          ctx :: Handler.ctx(),
          observe :: observe()
        ) :: :ok
  def assert_cancel_contract(handler, invoke, ctx, observe) do
    before_planning = observe.(invoke.invoke_id)

    # Plan the start first: check 3 is about cancel *after* start, the
    # ordinary 6.4.3 lifecycle. Planning is pure, so this leaves no state
    # behind either way - the call is here for fidelity to the sequence.
    _planned_start = handler.start(invoke, ctx)

    first = handler.cancel(invoke.invoke_id, ctx)
    second = handler.cancel(invoke.invoke_id, ctx)

    assert match?({:ok, instructions} when is_list(instructions), first),
           "cancel/2 must return {:ok, [instruction]}, got: #{inspect(first)}"

    assert first == second,
           "cancel/2 must be deterministic for fixed inputs; two calls returned:\n" <>
             "  #{inspect(first)}\n  #{inspect(second)}"

    unknown =
      try do
        {:returned, handler.cancel(@unknown_invoke_id, ctx)}
      rescue
        exception -> {:raised, exception}
      end

    case unknown do
      {:returned, result} ->
        assert match?({:ok, instructions} when is_list(instructions), result),
               "cancel/2 for an unknown invoke_id must still return " <>
                 "{:ok, [instruction]}, got: #{inspect(result)}"

      {:raised, exception} ->
        flunk(
          "cancel/2 must be a no-op for an unknown invoke_id, never a raise - a " <>
            "crash-recovering host may replay a cancel whose start it never " <>
            "durably recorded. Raised: #{Exception.format(:error, exception)}"
        )
    end

    assert_planning_left_no_trace(observe, invoke.invoke_id, before_planning, "cancel/2")
    :ok
  end

  @doc """
  Contract check 1 for `forward/3`: called twice with fixed inputs it
  returns the same `{:ok, instructions}`, and leaves `observe`'s reading
  unchanged.
  """
  @spec assert_forward_contract(
          handler :: module(),
          invoke :: Invoke.t(),
          ctx :: Handler.ctx(),
          event :: Event.t(),
          observe :: observe()
        ) :: :ok
  def assert_forward_contract(handler, invoke, ctx, event, observe) do
    before_planning = observe.(invoke.invoke_id)
    first = handler.forward(invoke.invoke_id, event, ctx)
    second = handler.forward(invoke.invoke_id, event, ctx)

    assert match?({:ok, instructions} when is_list(instructions), first),
           "forward/3 must return {:ok, [instruction]}, got: #{inspect(first)}"

    assert first == second,
           "forward/3 must be deterministic for fixed inputs; two calls returned:\n" <>
             "  #{inspect(first)}\n  #{inspect(second)}"

    assert_planning_left_no_trace(observe, invoke.invoke_id, before_planning, "forward/3")
    :ok
  end

  @doc """
  Contract check 2: performing the handler's own planned `{:handler, module,
  payload}` instructions twice - the crash-and-replay shape
  `docs/extending.md`'s "At-least-once" section describes - must not
  duplicate the effects `observe` reads for the invoke's id, and each
  `perform/2` call must return `:ok` or `{:error, term}`.

  When the handler routes instructions to `perform/2` and `observe` still
  answers `:unobserved`, this flunks naming the `observed_effects/1`
  override to write - never a silent pass. When the handler routes nothing
  to `perform/2` (the built-in `scxml` handler's own shape), it asserts
  exactly that and no observation point is needed.
  """
  @spec assert_perform_idempotent(
          handler :: module(),
          invoke :: Invoke.t(),
          ctx :: Handler.ctx(),
          event :: Event.t(),
          observe :: observe()
        ) :: :ok
  def assert_perform_idempotent(handler, invoke, ctx, event, observe) do
    instructions = handler_instructions(handler, invoke, ctx, event)

    if instructions == [] do
      assert instructions == [],
             "no {:handler, module, payload} instructions planned - nothing routes " <>
               "to perform/2, so there is nothing to be idempotent about"
    else
      if observe.(invoke.invoke_id) == :unobserved do
        flunk("""
        #{inspect(handler)} routes #{length(instructions)} instruction(s) to \
        perform/2, so judging idempotency needs an observation point this case \
        cannot invent. Override observed_effects/1 in the module that `use`s \
        Statifier.Testing.HandlerCase to return the observable effects \
        attributable to the given invoke_id (enqueued jobs, written rows, \
        received messages - whatever your perform/2 produces).
        """)
      end

      perform_all(instructions, ctx)
      once = observe.(invoke.invoke_id)
      perform_all(instructions, ctx)
      twice = observe.(invoke.invoke_id)

      assert once == twice,
             "perform/2 must be idempotent on invoke_id (the library performs no " <>
               "deduplication and MAY re-run the same instruction after a crash, " <>
               "ADR-0051 decision 4); observed effects for " <>
               "#{inspect(invoke.invoke_id)} after one pass:\n  #{inspect(once)}\n" <>
               "after a second identical pass:\n  #{inspect(twice)}"
    end

    :ok
  end

  @doc """
  Contract check 4, the library's half: an `{:error, _}` from `start/2` is
  planned as `error.execution` (ADR-0051 decision 1 - a pure planning
  failure, no communication ever attempted). Drives a minimal chart whose
  initial state invokes `type`, registered to a case-internal probe handler
  whose `start/2` always returns `{:error, _}`, and asserts the chart
  transitions on `error.execution` - the observation a chart author
  actually has.
  """
  @spec assert_error_start_raises_error_execution(type :: String.t()) :: :ok
  def assert_error_start_raises_error_execution(type) do
    machine = compile_probe_chart(type)

    {:ok, session} =
      Session.start_link(machine, invoke_handlers: %{type => __MODULE__.FailingStart})

    try do
      await_configuration(session, MapSet.new(["failed"]))
    after
      Session.stop(session)
    end

    :ok
  end

  @doc """
  Contract check 5: an exception raised from a handler callback propagates
  and crashes the session - the library never rescues it into an event
  (`docs/extending.md`, "Where the library will not help"). Drives the same
  minimal chart with a case-internal probe whose `start/2` raises, and
  asserts the session process exits with that very exception.
  """
  @spec assert_handler_exceptions_propagate(type :: String.t()) :: :ok
  def assert_handler_exceptions_propagate(type) do
    machine = compile_probe_chart(type)
    previous_trap = Process.flag(:trap_exit, true)

    try do
      ExUnit.CaptureLog.capture_log(fn ->
        case Session.start_link(machine, invoke_handlers: %{type => __MODULE__.RaisingStart}) do
          {:ok, session} ->
            # Initialization runs after init/1 returns (handle_continue), so
            # the raise arrives as an exit of the linked session process.
            assert_receive {:EXIT, ^session, reason}, 1_000
            assert_probe_exception(reason)

          {:error, reason} ->
            assert_probe_exception(reason)
        end
      end)
    after
      Process.flag(:trap_exit, previous_trap)
    end

    :ok
  end

  @doc """
  The implementor's half of contract check 4, for a handler whose `start/2`
  has a real failure path: asserts `start/2` returns `{:error, _}` for
  `invoke`, deterministically. Not generated by `use` - a conforming handler
  need not expose a failing start at all - so a suite whose handler has one
  calls this itself with the failing fixture.
  """
  @spec assert_erroring_start(handler :: module(), invoke :: Invoke.t(), ctx :: Handler.ctx()) ::
          :ok
  def assert_erroring_start(handler, invoke, ctx) do
    first = handler.start(invoke, ctx)
    second = handler.start(invoke, ctx)

    assert match?({:error, _reason}, first),
           "expected start/2 to return {:error, term} for the erroring invoke, " <>
             "got: #{inspect(first)}"

    assert first == second,
           "start/2 must be deterministic for fixed inputs, erroring ones " <>
             "included; two calls returned:\n  #{inspect(first)}\n  #{inspect(second)}"

    :ok
  end

  # Collects the handler's own {:handler, module, payload} instructions
  # across the whole planning lifecycle - start, forward, cancel, in the
  # order a live invocation would see them. start/2's {:error, _} arm plans
  # no instructions by definition (the library raises error.execution
  # instead), so it contributes nothing here.
  @spec handler_instructions(
          handler :: module(),
          invoke :: Invoke.t(),
          ctx :: Handler.ctx(),
          event :: Event.t()
        ) :: [{:handler, module(), term()}]
  defp handler_instructions(handler, invoke, ctx, event) do
    started =
      case handler.start(invoke, ctx) do
        {:ok, instructions} -> instructions
        {:error, _reason} -> []
      end

    {:ok, forwarded} = handler.forward(invoke.invoke_id, event, ctx)
    {:ok, cancelled} = handler.cancel(invoke.invoke_id, ctx)

    for {:handler, _module, _payload} = instruction <- started ++ forwarded ++ cancelled,
        do: instruction
  end

  @spec perform_all(
          instructions :: [{:handler, module(), term()}],
          ctx :: Handler.ctx()
        ) :: :ok
  defp perform_all(instructions, ctx) do
    Enum.each(instructions, fn {:handler, module, payload} ->
      result = module.perform(payload, ctx)

      assert result == :ok or match?({:error, _reason}, result),
             "perform/2 must return :ok or {:error, term}, got: #{inspect(result)}"
    end)
  end

  @spec assert_planning_left_no_trace(
          observe :: observe(),
          invoke_id :: String.t(),
          before_planning :: term(),
          callback :: String.t()
        ) :: :ok
  defp assert_planning_left_no_trace(observe, invoke_id, before_planning, callback) do
    after_planning = observe.(invoke_id)

    if before_planning == :unobserved and after_planning == :unobserved do
      # No observation point declared - purity is still covered by the
      # determinism assertion, and the idempotency check is what enforces
      # declaring one when the handler performs anything.
      :ok
    else
      assert after_planning == before_planning,
             "#{callback} is a planning callback and must not perform - observed " <>
               "effects for #{inspect(invoke_id)} moved from " <>
               "#{inspect(before_planning)} to #{inspect(after_planning)} across " <>
               "planning calls"

      :ok
    end
  end

  # The minimal driving chart for checks 4 and 5: the initial state invokes
  # `type`; `error.execution` lands in "failed", any other error in "wrong"
  # ("error" prefix-matches every error.* descriptor, and document order
  # gives the specific transition priority). Neither target is final, so
  # the session stays alive to answer status polls.
  @spec compile_probe_chart(type :: String.t()) :: Statifier.Machine.t()
  defp compile_probe_chart(type) do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="invoking">
        <state id="invoking">
            <invoke id="inv_probe" type="#{type}"/>
            <transition event="error.execution" target="failed"/>
            <transition event="error" target="wrong"/>
        </state>
        <state id="failed"/>
        <state id="wrong"/>
    </scxml>
    """

    case Statifier.compile(xml) do
      {:ok, machine} ->
        machine

      {:error, errors} ->
        flunk(
          "the conformance probe chart did not compile for type " <>
            "#{inspect(type)}:\n" <> Enum.map_join(errors, "\n", & &1.message)
        )
    end
  end

  @spec await_configuration(
          session :: Session.server(),
          expected :: MapSet.t(String.t()),
          attempts :: non_neg_integer()
        ) :: :ok
  defp await_configuration(session, expected, attempts \\ 200) do
    observed = Session.status(session).configuration

    cond do
      observed == expected ->
        :ok

      attempts == 0 ->
        flunk(
          "expected the driving chart to reach #{inspect(Enum.sort(expected))} " <>
            "(error.execution observed), but it settled at " <>
            "#{inspect(Enum.sort(observed))}"
        )

      true ->
        Process.sleep(5)
        await_configuration(session, expected, attempts - 1)
    end
  end

  @spec assert_probe_exception(reason :: term()) :: :ok
  defp assert_probe_exception(reason) do
    assert match?({%RuntimeError{}, _stacktrace}, reason) and
             elem(reason, 0).message == __MODULE__.RaisingStart.message(),
           "expected the session to exit with the probe handler's own " <>
             "RuntimeError (the library must not rescue handler exceptions), " <>
             "got exit reason: #{inspect(reason)}"

    :ok
  end

  defmodule FailingStart do
    @moduledoc false
    # Contract check 4's probe: start/2 always takes the one documented
    # failure path a planning callback has.
    @behaviour Statifier.Invoke.Handler

    @impl Statifier.Invoke.Handler
    def start(_invoke, _ctx), do: {:error, :handler_conformance_probe}

    @impl Statifier.Invoke.Handler
    def cancel(_invoke_id, _ctx), do: {:ok, []}

    @impl Statifier.Invoke.Handler
    def forward(_invoke_id, _event, _ctx), do: {:ok, []}
  end

  defmodule RaisingStart do
    @moduledoc false
    # Contract check 5's probe: start/2 raises, and the exception must reach
    # the session's exit reason untouched.
    @behaviour Statifier.Invoke.Handler

    @message "handler conformance probe: handler exceptions must propagate un-rescued"

    @doc false
    @spec message() :: String.t()
    def message, do: @message

    @impl Statifier.Invoke.Handler
    def start(_invoke, _ctx), do: raise(@message)

    @impl Statifier.Invoke.Handler
    def cancel(_invoke_id, _ctx), do: {:ok, []}

    @impl Statifier.Invoke.Handler
    def forward(_invoke_id, _event, _ctx), do: {:ok, []}
  end
end
