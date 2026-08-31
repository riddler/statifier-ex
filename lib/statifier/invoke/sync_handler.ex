defmodule Statifier.Invoke.SyncHandler do
  @moduledoc """
  The narrow half of `Statifier.Invoke.Handler`: a module that **answers a
  call and reports the result**, with no lifecycle of its own.

  `Statifier.Invoke.Handler` is the general seam ADR-0051 opened, and it is
  general on purpose - four callbacks split across a pure planning half and
  an impure performing half, because a background job, a child session, and
  a durable workflow all need that much room. Most `<invoke type>` values a
  host actually registers need none of it. They are calls: hand these
  params to some code, take back a `donedata` map or a failure, and let the
  chart move on. Writing that shape against the full behaviour means every
  host writing the same adapter - one `{:handler, __MODULE__, payload}`
  instruction from `start/2`, empty plans from `cancel/2` and `forward/3`,
  and a `perform/2` that looks up the session and calls
  `Statifier.Session.done_invocation/3` or
  `Statifier.Session.failed_invocation/3`. That adapter is the same every
  time, so this library writes it once:
  `Statifier.Invoke.SyncHandler.Adapter`.

  This module is the behaviour that adapter dispatches to. Implementing it
  is two callbacks:

      defmodule MyApp.Signup.Handlers do
        @behaviour Statifier.Invoke.SyncHandler

        @impl Statifier.Invoke.SyncHandler
        def invoke_types, do: ["myapp:signup", "myapp:provision"]

        @impl Statifier.Invoke.SyncHandler
        def handle("myapp:signup", params, _ctx), do: {:ok, %{"plan" => params["plan"]}}
        def handle("myapp:provision", params, _ctx), do: MyApp.Accounts.provision(params)
      end

  ## Why `invoke_types/0` is a callback rather than a registration

  A host has to declare the same set of type strings twice: once to
  `Statifier.Compiler` (or whatever compiles its documents) as the set a
  chart naming an unregistered type should be *linted* against, and once to
  `Statifier.Session.start_link/2` as the `:invoke_handlers` map a session
  will actually *answer*. Those two sets coming apart is the failure this
  seam exists to prevent - a chart that compiles clean and then meets
  `error.execution` at runtime, or a handler nobody can reach because no
  document may name it.

  Making the set a callback on the module that serves it means both are
  derived from one place: `Statifier.Invoke.SyncHandler.Adapter.invoke_types/1`
  builds the union for the compiler and
  `Statifier.Invoke.SyncHandler.Adapter.invoke_handlers/2` builds the map
  for the session, from the same list of modules. Adding a type is one line
  in one module, and neither derived set can be forgotten.

  ## `ctx`

  `ctx` is `Statifier.Invoke.Handler`'s own plan context, handed through
  unchanged:

      %{session_id: session_id, invoke_types: invoke_types, invoke_handlers: invoke_handlers}

  `session_id` (spec 5.10's `_sessionid`) is the field a sync handler
  reaches for - it is what an external system is told about who is asking,
  and it is what the adapter itself uses to find the session to report
  back to. It carries no pid, no `%Statifier.MachineState{}` and no session
  struct, by construction rather than by discipline, and it is a plain map,
  so a key added to it later is additive for every handler already written.

  ## Idempotency still applies

  `Statifier.Invoke.Handler`'s `perform/2` MAY be called more than once for
  the same `invoke_id` - a host that crashed between performing an
  instruction and durably recording that it ran replays the drive and
  produces the byte-identical instruction again. The adapter does not (and
  cannot) deduplicate that: it has no view of a host's durable store. So
  `c:handle/3` inherits the obligation whole. A handler that only reads is
  idempotent for free; a handler that **writes** keys its write on
  something stable, and `invoke_id` is the value the library guarantees is
  stable by construction (ADR-0008 as amended: it is a deterministic
  `%Statifier.MachineState{}` counter, not a freshly minted value).

  `c:handle/3` is not handed `invoke_id`, which is deliberate: a sync
  handler that needs a durable key needs the *host's* key - which run, which
  order, which tenant - and the honest place to get that is the host's own
  driver, not this seam. A handler that genuinely wants `invoke_id` writes
  against `Statifier.Invoke.Handler` directly, which is still there and is
  still the general answer.

  ## When this is the wrong shape

  Reach for `Statifier.Invoke.Handler` itself, not this, when the
  invocation:

    * outlives the performing turn - a background job, an HTTP call whose
      reply arrives later, anything reported from a different node. The
      whole point of `done_invocation/3` being a *door* is that it can be
      knocked on minutes or days later, and a sync handler answers before
      `c:handle/3` returns;
    * has something to cancel (spec 6.4.3) or an inbox to autoforward into
      (6.4.2's `autoforward`). The adapter plans nothing for either, because
      a call answered inside its own turn has neither;
    * needs `invoke_id`, `src`, or `content` off the
      `%Statifier.Effect.Invoke{}`. `c:handle/3` sees the type and the
      `<param>` values, and nothing else.

  ## Terminal failure

  `{:error, reason}` from `c:handle/3` is **permanent**, and that is a
  property of this shape rather than a choice the adapter makes.
  `Statifier.Session.failed_invocation/3` documents itself as the host's
  call and not a handler callback's, because a `perform/2` error is
  ordinarily a transient signal belonging to whatever retry policy wraps
  it. A sync handler has no such policy: the call was made, it answered,
  and no later answer is coming. The adapter is that policy, in its
  degenerate form - one attempt, no retries - which is what licenses it to
  reach the door on a sync handler's behalf. A host that wants retries
  wants the general behaviour and a job runner underneath it.
  """

  @typedoc """
  The plan context - `Statifier.Invoke.Handler.ctx/0`, handed through
  unchanged. See the moduledoc's "`ctx`" section.
  """
  @type ctx :: Statifier.Invoke.Handler.ctx()

  @typedoc """
  What a successful call answers with: spec 6.4's `<donedata>`, delivered to
  the chart as `done.invoke.<invoke_id>`'s `_event.data`. A map is the
  ordinary shape - it is what a chart's `assign_to`/`_event.data.<key>`
  reads - but the library does not interpret it and neither does the
  adapter, so any term a host's own charts can read is allowed.
  """
  @type donedata :: term()

  @doc """
  Every `<invoke type>` value this module answers.

  Read twice, and that is the point (see the moduledoc): the union across a
  host's handler modules is both the set its compiler lints documents
  against and the key set of the `:invoke_handlers` map its sessions are
  started with. Order does not matter -
  `Statifier.Invoke.SyncHandler.Adapter.invoke_types/1` sorts and dedups the
  union - but a module that returns its own list sorted is easier to read
  against the chart that names them.
  """
  @callback invoke_types() :: [String.t()]

  @doc """
  Answers one call.

  `type` is the `<invoke type>` string - passed even to a module serving a
  single type, so the common case of one module answering a family of
  related names is a `case`/multi-clause head rather than a module per
  name. `params` is the `<param>` values the invocation carried, always a
  map: the adapter normalizes the "no params at all" case
  (`Statifier.EventData`'s `:undefined`) to `%{}` so a handler never has to
  match two shapes of "no arguments". `ctx` is the plan context.

  `{:ok, donedata}` becomes `done.invoke.<invoke_id>` with `donedata` as its
  `_event.data`. `{:error, reason}` becomes
  `error.communication.invoke.<invoke_id>`, permanently (see the moduledoc's
  "Terminal failure"); `reason` reaches the chart as `_event.data.reason`,
  a **string**, so a binary is passed through unchanged and any other term
  is `inspect/1`-ed - name your failure classes with strings if the chart is
  meant to branch on them.

  Raising is not a documented answer. The library never rescues a handler
  exception into an event (`docs/extending.md`, "Where the library will not
  help"), and neither does the adapter, so a raise here crashes the
  performing turn rather than failing the invocation. Errors are events:
  return one.
  """
  @callback handle(type :: String.t(), params :: map(), ctx :: ctx()) ::
              {:ok, donedata()} | {:error, term()}
end
