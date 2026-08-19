# Extending Statifier: `<invoke>` handlers

This is a guide for a host application author who wants to reach real
computation - a database call, a background job, an LLM agent loop, an
external API - from an SCXML document's `<invoke>` element. It does not
re-explain the interpreter's architecture; see `docs/architecture.md` for
that. It shows you how to write and register a handler.

## What the seam is for

`docs/datamodel.md` names the reason Statifier's datamodel stays
non-evaluative rather than chasing ECMAScript:

> Real computation belongs in the host application, reached through
> `<invoke>` handlers and external `<send>` - controlled, typed, supervised.

Until now that sentence named an intention with no destination. This document
is the destination: a `Statifier.Invoke.Handler` is how your application
registers itself to serve an `<invoke type="...">` value the built-in engine
does not already know (`scxml` and its long-URI spelling,
`http://www.w3.org/TR/scxml/`, are the only types shipped in the library
itself).

## Writing a `Statifier.Invoke.Handler`

A handler is a module implementing the `Statifier.Invoke.Handler` behaviour:
three required callbacks and one optional one.

```elixir
@callback start(invoke :: Statifier.Effect.Invoke.t(), ctx :: Statifier.Invoke.Handler.ctx()) ::
            {:ok, [instruction()]} | {:error, term()}

@callback cancel(invoke_id :: String.t(), ctx :: Statifier.Invoke.Handler.ctx()) ::
            {:ok, [instruction()]}

@callback forward(invoke_id :: String.t(), event :: Statifier.Event.t(), ctx :: Statifier.Invoke.Handler.ctx()) ::
            {:ok, [instruction()]}

@callback perform(instruction :: instruction(), ctx :: Statifier.Invoke.Handler.ctx()) ::
            :ok | {:error, term()}
```

`start/2`, `cancel/2`, and `forward/3` are **pure**. They run inside
`Statifier.Session.Effects.plan/2`'s own fold, alongside the planning for
every other effect - no process, no clock, no I/O. They decide *what* should
happen and return a list of instructions describing it; they never perform
anything themselves. This is what lets a durable host that drives
`Statifier.Interpreter` directly, with no `Statifier.Session` process at all,
plan invocations the same way `Statifier.Session` does.

`perform/2` is the **impure** half - the only callback allowed to touch the
outside world. An executor (`Statifier.Session` is one) calls it to actually
carry out one of the instructions a planning callback returned. It is
optional: a handler whose planning callbacks never return one of its own
instructions needs no `perform/2` at all.

The instruction vocabulary a planning callback returns is opaque outside the
library, with one exception a handler author needs: `{:handler, __MODULE__,
payload}`. Returning this instruction from `start/2` (or `cancel/2`,
`forward/3`) is how you hand work to your own `perform/2` - `payload` is
whatever your `perform/2` clause needs to do it.

`ctx` is a plain map, not a struct, handed to every planning callback
unchanged:

```elixir
%{session_id: session_id, invoke_types: invoke_types, invoke_handlers: invoke_handlers}
```

The field a handler author actually reaches for is `session_id` (spec 5.10's
`_sessionid`) - useful when the external system you are calling needs to know
who is asking. `ctx` carries no pid, no `%Statifier.MachineState{}`, and no
session struct, so a handler cannot reach into `Statifier.Session` internals
through it. Per-invocation identity - `invoke_id`, `type`, `src`, `params`,
`content` - is read off the `%Statifier.Effect.Invoke{}` struct `start/2`
already receives as its own argument.

### A complete worked example

Here is a minimal handler for an invented type, `"myapp:enrich"`, that hands
a payload to a background job system and reports completion later:

```elixir
defmodule MyApp.EnrichHandler do
  @moduledoc """
  Serves `<invoke type="myapp:enrich">` by enqueuing a background job.
  """

  @behaviour Statifier.Invoke.Handler

  alias Statifier.Effect.Invoke

  @impl Statifier.Invoke.Handler
  def start(%Invoke{invoke_id: invoke_id, params: params}, ctx) do
    {:ok, [{:handler, __MODULE__, {invoke_id, ctx.session_id, params}}]}
  end

  @impl Statifier.Invoke.Handler
  def cancel(invoke_id, _ctx) do
    {:ok, [{:handler, __MODULE__, {:cancel, invoke_id}}]}
  end

  @impl Statifier.Invoke.Handler
  def forward(_invoke_id, _event, _ctx) do
    # This handler's jobs do not accept autoforwarded events.
    {:ok, []}
  end

  @impl Statifier.Invoke.Handler
  def perform({invoke_id, session_id, params}, _ctx) do
    # MUST be idempotent on invoke_id - see "At-least-once" below.
    MyApp.Jobs.EnrichJob.enqueue_idempotent(invoke_id, session_id, params)
  end

  def perform({:cancel, invoke_id}, _ctx) do
    MyApp.Jobs.EnrichJob.cancel(invoke_id)
    :ok
  end
end
```

When the background job finishes - possibly minutes or days later, possibly
from a different node entirely - it reports back through
`Statifier.Session.done_invocation/3` (see below), not through this module.

## Registering a handler

Handlers are registered per session, on `Statifier.Session.start_link/2`:

```elixir
Statifier.Session.start_link(machine,
  invoke_handlers: %{"myapp:enrich" => MyApp.EnrichHandler}
)
```

`:invoke_handlers` is a `%{type_string => module}` map. The default is `%{}`,
which registers no type beyond the built-in `scxml`/bare-URI set - passing
nothing changes no observable behavior (ADR-0051).

Registration is **per session, not global**, on purpose: a multi-tenant host
that runs different chart deployments for different tenants can give each
session a different handler palette, rather than every deployed handler being
reachable from every session process-wide.

The set is also **fixed for the session's whole lifetime**: it is a
`start_link/2` option, exactly like `:max_macrostep_rounds`, not something
re-stamped or re-registered mid-session. A host that needs a different
handler palette starts a different session with a different
`:invoke_handlers` map; there is no supported way to add or remove a handler
from a session already running.

## Async and long-lived invocations

`invoke_id` stays stable across a persist/reload cycle because it is not a
freshly generated value - it is a deterministic counter carried on
`%Statifier.MachineState{}` (ADR-0008, as amended). Replaying the same drive
from the same persisted position always produces the same `invoke_id` for the
same `<invoke>` element, so a `done.invoke.<id>` that arrives minutes or days
after `start/2` planned it is still addressing a stable, recognizable name.

The door your host uses to report completion is
`Statifier.Session.done_invocation/3`:

```elixir
@spec done_invocation(server :: server(), invoke_id :: String.t(), donedata :: term()) :: :ok
def done_invocation(server, invoke_id, donedata \\ nil)
```

Call it with the owning session (the one whose `<invoke>` started the work,
never a child of it - a handler-backed invocation has no child session at
all) and the `invoke_id` your `start/2` was handed. It constructs
`done.invoke.<invoke_id>` from `donedata` and delivers it exactly as an
ordinary invoked event, subject to the same drain-time discard as any other
invocation-tagged entry: if the invocation was cancelled before the event is
dequeued, it is dropped rather than delivered, per spec 6.4.3.

## At-least-once: handlers must be idempotent

`perform/2` **MAY be called more than once for the same `invoke_id`.** A host
that crashes between starting an instruction and durably recording that it
ran may re-run the same drive after recovery, producing the byte-identical
instruction again. A handler implementing `perform/2` **MUST be idempotent on
`invoke_id`.**

The library performs no deduplication itself, and cannot: it has no view of
your host's durable store, no database, no job queue, nothing to check a
prior attempt against. `invoke_id` is the idempotency key you are handed for
exactly this reason - it is stable by construction (see above), not merely by
convention, so keying your own dedup table on it is sound.

## What an unregistered type does

An `<invoke>` whose type (or evaluated `typeexpr`) resolves to no registered
handler raises `error.execution`. This follows from two clauses of the
spec's local cache rather than from a 6.4 MUST that does not exist: 3.12.2
distinguishes `error.execution` (errors internal to the execution of the
document) from `error.communication` (errors while trying to communicate with
an external entity), and 6.2.5 gives `<send>`'s own unsupported-type case as
the explicit analogue, raising `error.execution` for exactly this reason. An
unregistered type never attempted communication with anything - this
deployment implements no such service - so it falls on the `error.execution`
side.

This contrasts with a *registered* handler that fails to reach its service:
that is `error.communication`, because communication genuinely was attempted
and failed. See ADR-0051 for the full argument and the corpus that pins both
outcomes.

## A naming note

`Statifier.Invoke.Handler` (and its registration) is not
`Statifier.Registry`. `Statifier.Registry` is the embedder-placed session
registry keyed by session id (ADR-0027) - `#_scxml_<sessionid>` routing, not
`<invoke>` dispatch. The two are unrelated concepts that happen to share the
word "registry" in casual conversation; do not confuse per-session handler
registration described here with looking a session up by id.

## Where the library will not help

Two things the library deliberately does not do on a handler's behalf:

- **It never fetches a URI.** `<invoke src="...">` is never dereferenced by
  the engine itself, for the same security posture that governs `<data src>`
  (ADR-0024) and that ADR-0038 applies specifically to `<invoke>`: a
  document-named URI dereferenced by the engine by default is a
  request-forgery surface handed to whoever authored the document. If your
  handler needs to reach a URI, do it as ordinary application code, under
  your own security policy.
- **It never rescues a handler exception into an event.** An exception raised
  from `start/2`, `cancel/2`, `forward/3`, or `perform/2` is not caught and
  turned into `error.execution` or `error.communication` for you - it crashes
  the session process, deliberately, on the same reasoning the moduledoc
  gives for the idempotency requirement above rather than a
  rescue-to-default. `start/2` returning `{:error, term()}` is the one
  documented failure path a planning callback has, and it is planned as
  `error.execution` - the same class an unregistered type gets, since no
  communication was ever attempted. `perform/2`'s return value is not
  interpreted by the library at all: an `{:error, term()}` there is your own
  handler's concern to observe (log it, retry it, raise it), not something
  the session recovers from or turns into an event on your behalf.
