defmodule Statifier.Invoke.SyncHandler.Adapter do
  @moduledoc """
  The `Statifier.Invoke.Handler` every host writing
  `Statifier.Invoke.SyncHandler` modules would otherwise write by hand,
  plus the two derived registrations those modules feed.

  A host `use`s this in one module, naming its sync handlers:

      defmodule MyApp.InvokeHandler do
        use Statifier.Invoke.SyncHandler.Adapter,
          handlers: [MyApp.CardAuth.Handlers, MyApp.Signup.Handlers]
      end

  and gets the four `Statifier.Invoke.Handler` callbacks plus three
  readings of that list: `invoke_types/0` and `invoke_handlers/0` - the two
  sets a host has to declare, both derived from it - and `sync_handlers/0`,
  the list itself, for a host driving the pure core with no session to
  report to.

      Statifier.Compiler.compile(document, known_invoke_types: MyApp.InvokeHandler.invoke_types())
      Statifier.Session.start_link(machine, invoke_handlers: MyApp.InvokeHandler.invoke_handlers())

  ## One adapter, not one per handler module

  Three sync-handler modules do not need three `Statifier.Invoke.Handler`
  implementations. The four callbacks are identical for all of them - the
  only difference is which type strings each answers, and that is data, not
  code. So `invoke_handlers/0` points **every** registered type at the one
  adapter module, and the adapter routes each call back to whichever
  handler module claimed that type. Three modules each implementing four
  callbacks identically would be this adapter written three times.

  Nothing stops a host from having several adapters - one per bounded
  context, say - each with its own handler list. What it must not do is
  register the same type string in two of them and merge the maps, since
  the merge silently keeps one.

  ## The two registrations cannot come apart

  `invoke_handlers/0` is built **from** `invoke_types/0`, not beside it:
  one union of `c:Statifier.Invoke.SyncHandler.invoke_types/0` across the
  handler list, sorted and deduplicated, then every member mapped to this
  adapter. Session start closes the same loop from the other end -
  `Statifier.Invoke.Types.from_handlers/1` derives the core's registered-type
  snapshot from the `:invoke_handlers` map's own keys (ADR-0051 decision
  3's "one constructor"). So the set the compiler lints a document against,
  the set a session dispatches on, and the set the pure core classifies
  against are three readings of one list of modules, and registering a new
  type is one line in one handler module and nothing anywhere else.

  ## Routing, and the type claimed twice

  `dispatch/4` routes a type to the **first** module in the list that
  claims it. A type claimed by two modules is a host bug this module does
  not raise on: the union still contains it exactly once, so nothing
  observable goes wrong except that the second module never answers. The
  list is ordered and the host wrote it, which is the same posture
  `Statifier.Send.Routes` and a palette take toward the caller's own
  ordering. A type **no** module claims is `{:error, {:unknown_invoke_type,
  type}}` - reachable only for a session started with a hand-built
  `:invoke_handlers` map that names this adapter for a type its handlers do
  not serve, since a map built by `invoke_handlers/0` cannot contain one.

  ## What the callbacks do

  `start/2` plans exactly one `{:handler, __MODULE__, payload}` instruction
  carrying the three facts `perform/2` needs: the `invoke_id` the answer is
  reported against, the type to route on, and the `<param>` values. Pure.

  `cancel/2` and `forward/3` plan nothing, and there is nothing dishonest
  about that. A sync call is answered inside the performing turn, so by the
  time a cancel could be planned the invocation is either already reported
  or never will be - and the contract's "a handler MUST tolerate cancelling
  an `invoke_id` it no longer knows" is satisfied for free by a handler
  that keeps no table to look one up in. Autoforwarding (6.4.2) delivers
  the parent's external events to a running invocation's inbox, and a call
  with no inbox has nowhere to put the copy.

  `perform/2` is the impure half: it routes the call, then reports the
  answer to the session `ctx.session_id` names through
  `Statifier.Session.done_invocation/3` or
  `Statifier.Session.failed_invocation/3`. Reaching the session needs
  `Statifier.Registry` running, which is what `Statifier.Supervisor` places;
  a session id that resolves to nothing is
  `{:error, {:session_not_registered, id}}` rather than a raise, because a
  session that went away while its call was out is an ordinary thing to
  observe. Errors are events here too.

  ## Idempotency

  `perform/2` MAY be called more than once for the same `invoke_id`, and
  this adapter deduplicates nothing - it has no view of a host's durable
  store, exactly as `Statifier.Invoke.Handler` says the library has none. A
  second call re-runs `c:Statifier.Invoke.SyncHandler.handle/3` and reports
  again; the *reporting* half is harmless twice
  (`Statifier.Session.done_invocation/3` for an invocation already popped
  is a documented no-op), so the whole obligation lands on the handler,
  where the moduledoc of `Statifier.Invoke.SyncHandler` leaves it.

  ## Failure reporting

  `{:error, reason}` from a sync handler is permanent by construction - see
  `Statifier.Invoke.SyncHandler`'s "Terminal failure" - so it is reported
  through `failed_invocation/3` immediately, with `reason` normalized to
  the string a chart reads as `_event.data.reason`: a binary passes
  through, anything else is `inspect/1`-ed. No `:attempts` is sent, and
  that absence is the honest datum: this adapter is a retry policy that
  makes no attempts to count, and `Statifier.Session.failed_invocation/3`
  documents an absent `:attempts` as reading `undefined` (ADR-0037), which
  is distinct from a host that counted zero.
  """

  alias Statifier.Effect.Invoke
  alias Statifier.Invoke.SyncHandler
  alias Statifier.Session

  @typedoc """
  The instruction payload `start/2` plans and `perform/2` consumes. Not part
  of the public contract - `Statifier.Session.Effects`'s instruction
  vocabulary is opaque outside the library - but named because `perform/2`'s
  spec has to say something, and a host reading a trace of planned
  instructions will see this shape.
  """
  @type payload :: %{invoke_id: String.t(), type: String.t(), params: map()}

  @typedoc """
  What `dispatch/4` threads to the handler it routes to: any map.

  A session's own drive supplies `t:Statifier.Invoke.SyncHandler.ctx/0` -
  the plan context, with `session_id` and the two registrations - and that
  is still the context `perform/3` requires, because reporting the answer
  needs `ctx.session_id` to report it to. Routing needs none of it.
  `dispatch/4` reads no key of the context at all; it resolves the module
  from `type` and hands the context through untouched.

  So the type is `map()` rather than the plan context, and that is the
  honest shape rather than a loosening: `dispatch/4` is public *for* the
  host driving the pure core with no session (see its doc), and such a
  host has no `session_id` to put in a plan context. Typed narrowly, the
  only thing the spec achieved was to make the documented use a contract
  violation - the host re-implemented the routing beside this function
  instead of delegating to it.

  The agreement about what the map contains is then between that host and
  its own handler modules, which is where it can be kept: a handler
  written against `c:Statifier.Invoke.SyncHandler.handle/3`'s declared
  `ctx` still gets exactly that from a session, and a handler a host also
  drives itself matches on whichever shape it is handed.
  """
  @type dispatch_ctx :: map()

  @doc """
  Generates the `Statifier.Invoke.Handler` implementation and the two
  derived registrations over `:handlers`.

  `:handlers` is required and is the list of
  `Statifier.Invoke.SyncHandler` modules this adapter serves, in the order
  `dispatch/4` resolves a type against.
  """
  @spec __using__(opts :: Macro.t()) :: Macro.t()
  defmacro __using__(opts) do
    handlers =
      Keyword.get(opts, :handlers) ||
        raise ArgumentError,
              "use Statifier.Invoke.SyncHandler.Adapter requires :handlers - " <>
                "the list of Statifier.Invoke.SyncHandler modules this adapter serves"

    quote do
      @behaviour Statifier.Invoke.Handler

      # `unquote(__MODULE__)` rather than an injected `alias`: this macro
      # writes into the host's own namespace, and an `Adapter` alias there
      # would be a name the host did not choose and might already use.
      @sync_handlers unquote(handlers)

      @doc """
      The `Statifier.Invoke.SyncHandler` modules this adapter serves, in
      dispatch order.
      """
      @spec sync_handlers() :: [module()]
      def sync_handlers, do: @sync_handlers

      @doc """
      Every `<invoke type>` this adapter answers, sorted and deduplicated -
      the list a host hands a compiler as `:known_invoke_types`.
      """
      @spec invoke_types() :: [String.t()]
      def invoke_types, do: unquote(__MODULE__).invoke_types(@sync_handlers)

      @doc """
      The `%{invoke type => module}` map a session is started with
      (ADR-0051), every type pointed at this adapter.
      """
      @spec invoke_handlers() :: %{String.t() => module()}
      def invoke_handlers,
        do: unquote(__MODULE__).invoke_handlers(@sync_handlers, __MODULE__)

      @doc """
      Plans the one `{:handler, __MODULE__, payload}` instruction this
      adapter's sync call needs. Pure.
      """
      @impl Statifier.Invoke.Handler
      @spec start(invoke :: Statifier.Effect.Invoke.t(), ctx :: Statifier.Invoke.Handler.ctx()) ::
              {:ok, [term()]}
      def start(invoke, ctx),
        do: unquote(__MODULE__).plan_start(__MODULE__, invoke, ctx)

      @doc """
      Plans nothing: a call answered inside its own turn has nothing to
      cancel, and no table to tolerate an unknown id against. Pure.
      """
      @impl Statifier.Invoke.Handler
      @spec cancel(invoke_id :: String.t(), ctx :: Statifier.Invoke.Handler.ctx()) ::
              {:ok, [term()]}
      def cancel(invoke_id, ctx), do: unquote(__MODULE__).plan_cancel(invoke_id, ctx)

      @doc """
      Plans nothing: a call has no inbox to autoforward a parent's event
      into. Pure.
      """
      @impl Statifier.Invoke.Handler
      @spec forward(
              invoke_id :: String.t(),
              event :: Statifier.Event.t(),
              ctx :: Statifier.Invoke.Handler.ctx()
            ) :: {:ok, [term()]}
      def forward(invoke_id, event, ctx),
        do: unquote(__MODULE__).plan_forward(invoke_id, event, ctx)

      @doc """
      Runs one planned call and reports the answer to the session
      `ctx.session_id` names. The impure half; MAY be called more than once
      for the same `invoke_id`, so the sync handler it routes to carries the
      idempotency obligation.
      """
      @impl Statifier.Invoke.Handler
      @spec perform(instruction :: term(), ctx :: Statifier.Invoke.Handler.ctx()) ::
              :ok | {:error, term()}
      def perform(instruction, ctx),
        do: unquote(__MODULE__).perform(@sync_handlers, instruction, ctx)
    end
  end

  @doc """
  The union of `c:Statifier.Invoke.SyncHandler.invoke_types/0` across
  `modules`, sorted and deduplicated.

  The single union in the library: `invoke_handlers/2` is built from this
  answer rather than from a second walk of `modules`, so the compiler's set
  and the session's map are two readings of one list (see the moduledoc's
  "The two registrations cannot come apart").

  Raises `ArgumentError` for a module that does not export `invoke_types/0`
  - a host naming a module that is not a sync handler learns it here rather
  than at the `UndefinedFunctionError` a session would raise mid-drive.
  """
  @spec invoke_types(modules :: [module()]) :: [String.t()]
  def invoke_types(modules) when is_list(modules) do
    modules
    |> Enum.flat_map(&module_types/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The `%{invoke type => module}` map a session is started with: every type
  `modules` claim, pointed at `adapter`.

  `adapter` is the module implementing `Statifier.Invoke.Handler` - the one
  that `use`s this module, not one of the sync handlers, which implement no
  `Statifier.Invoke.Handler` callback of their own.
  """
  @spec invoke_handlers(modules :: [module()], adapter :: module()) :: %{String.t() => module()}
  def invoke_handlers(modules, adapter) when is_list(modules) and is_atom(adapter) do
    modules |> invoke_types() |> Map.new(&{&1, adapter})
  end

  @doc """
  Routes one call to the first module in `modules` claiming `type`.

  Public because a host driving the pure core itself - a durable stepper
  with no `Statifier.Session` process to report to - performs its
  invocations its own way and still wants the routing, without the
  reporting half `perform/3` supplies.

  `ctx` is whatever that caller has to say about the call, handed to the
  handler untouched: `t:dispatch_ctx/0`, any map, and not the plan context
  `perform/3` needs. A session's drive passes its plan context; a durable
  stepper passes what it knows, typically its own run id. Neither is a
  special case here, because routing reads no key of it.
  """
  @spec dispatch(
          modules :: [module()],
          type :: String.t(),
          params :: map(),
          ctx :: dispatch_ctx()
        ) ::
          {:ok, SyncHandler.donedata()} | {:error, term()}
  def dispatch(modules, type, params, ctx)
      when is_list(modules) and is_binary(type) and is_map(params) do
    case Enum.find(modules, &(type in module_types(&1))) do
      nil -> {:error, {:unknown_invoke_type, type}}
      module -> module.handle(type, params, ctx)
    end
  end

  @doc """
  Plans the one `{:handler, adapter, payload}` instruction a sync call
  needs. Pure; the `start/2` a `use`-ing module delegates to.

  Named `plan_*` rather than `start`/`cancel`/`forward` because a
  `use`-ing module's generated callbacks carry those names at those
  arities, and one module defining `cancel/2` twice - once as the callback,
  once as the helper it delegates to - reads as a mistake even where the
  compiler is fine with it.
  """
  @spec plan_start(adapter :: module(), invoke :: Invoke.t(), ctx :: SyncHandler.ctx()) ::
          {:ok, [{:handler, module(), payload()}]}
  def plan_start(adapter, %Invoke{} = invoke, _ctx) do
    payload = %{
      invoke_id: invoke.invoke_id,
      type: invoke.type,
      params: params(invoke.params)
    }

    {:ok, [{:handler, adapter, payload}]}
  end

  @doc """
  Plans nothing. Pure; see the moduledoc on why a sync call has nothing to
  cancel.
  """
  @spec plan_cancel(invoke_id :: String.t(), ctx :: SyncHandler.ctx()) :: {:ok, []}
  def plan_cancel(_invoke_id, _ctx), do: {:ok, []}

  @doc """
  Plans nothing. Pure; see the moduledoc on why a sync call has no inbox to
  autoforward into.
  """
  @spec plan_forward(
          invoke_id :: String.t(),
          event :: Statifier.Event.t(),
          ctx :: SyncHandler.ctx()
        ) :: {:ok, []}
  def plan_forward(_invoke_id, _event, _ctx), do: {:ok, []}

  @doc """
  Runs one planned call and reports the answer to the session
  `ctx.session_id` names. The impure half; the `perform/2` a `use`-ing
  module delegates to.
  """
  @spec perform(modules :: [module()], instruction :: payload(), ctx :: SyncHandler.ctx()) ::
          :ok | {:error, {:session_not_registered, String.t()}}
  def perform(modules, %{invoke_id: invoke_id, type: type, params: params}, ctx) do
    case dispatch(modules, type, params, ctx) do
      {:ok, donedata} ->
        report(ctx, &Session.done_invocation(&1, invoke_id, donedata))

      {:error, reason} ->
        report(ctx, &Session.failed_invocation(&1, invoke_id, reason: reason(reason)))
    end
  end

  @spec module_types(module :: module()) :: [String.t()]
  defp module_types(module) when is_atom(module) do
    Code.ensure_loaded!(module)

    if function_exported?(module, :invoke_types, 0) do
      module.invoke_types()
    else
      raise ArgumentError,
            "#{inspect(module)} does not export invoke_types/0 - " <>
              "a Statifier.Invoke.SyncHandler.Adapter :handlers entry must implement " <>
              "the Statifier.Invoke.SyncHandler behaviour"
    end
  end

  # `Statifier.EventData`'s own spelling for "the `<invoke>` carried no
  # `<param>` at all" is `:undefined`, and normalizing it here is what lets
  # `c:Statifier.Invoke.SyncHandler.handle/3` take `map()` rather than two
  # shapes of "no arguments".
  @spec params(params :: term()) :: map()
  defp params(params) when is_map(params), do: params
  defp params(_absent), do: %{}

  # The failure class the chart reads as `_event.data.reason`, which
  # `Statifier.Session.failed_invocation/3` documents as a string. A binary
  # is the handler having named its own class and is passed through; any
  # other term is a handler that did not, and `inspect/1` is the only honest
  # thing left - not a default that hides a failure, since the alternative
  # is dropping the reason entirely.
  @spec reason(reason :: term()) :: String.t()
  defp reason(reason) when is_binary(reason), do: reason
  defp reason({:unknown_invoke_type, type}), do: "unknown_invoke_type:#{type}"
  defp reason(reason), do: inspect(reason)

  @spec report(ctx :: SyncHandler.ctx(), deliver :: (pid() -> :ok)) ::
          :ok | {:error, {:session_not_registered, String.t()}}
  defp report(%{session_id: session_id}, deliver) do
    case whereis(session_id) do
      nil -> {:error, {:session_not_registered, session_id}}
      pid -> deliver.(pid)
    end
  end

  # `Registry.lookup/2` raises `ArgumentError` when `Statifier.Registry`
  # itself is not running - no ETS table backs a registry nobody started -
  # which is exactly the "no runtime placed" case a bare
  # `Statifier.Session.start_link/2` caller is allowed to be in. Folding it
  # into the same absent-session answer keeps a reporting path from being
  # where a host learns its supervisor is missing, and mirrors what
  # `Statifier.Session`'s own `registry_lookup/1` does for `<send>` routing.
  @spec whereis(session_id :: String.t()) :: pid() | nil
  defp whereis(session_id) do
    case Registry.lookup(Statifier.Registry, session_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end
end
