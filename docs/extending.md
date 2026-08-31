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
itself). If what you are after is a durable `<send delay>` rather than an
`<invoke>`, that is a different seam - see `docs/durable-timers.md`.

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

Here is a minimal handler for an invented type, `"myapp:authorize"`, that
hands a card authorization to a background job system and reports the
approval or decline later:

```elixir
defmodule MyApp.AuthorizeHandler do
  @moduledoc """
  Serves `<invoke type="myapp:authorize">` by enqueuing a background job
  that authorizes a card transaction against the account's remaining budget.
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
    MyApp.Jobs.AuthorizeJob.enqueue_idempotent(invoke_id, session_id, params)
  end

  def perform({:cancel, invoke_id}, _ctx) do
    MyApp.Jobs.AuthorizeJob.cancel(invoke_id)
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
  invoke_handlers: %{"myapp:authorize" => MyApp.AuthorizeHandler}
)
```

`:invoke_handlers` is a `%{type_string => module}` map. The default is `%{}`,
which registers no type beyond the built-in `scxml`/bare-URI set - passing
nothing changes no observable behavior (ADR-0051). A session that drives a
different chart registers a different palette - a signup wizard running an
A/B test reaches for variant assignment and conversion recording rather than
anything to do with cards:

```elixir
Statifier.Session.start_link(wizard_machine,
  invoke_handlers: %{
    "myapp:assign_variant" => MyApp.AssignVariantHandler,
    "myapp:signup" => MyApp.SignupStepHandler,
    "myapp:conversion" => MyApp.ConversionHandler
  }
)
```

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

## The common case: a sync handler

Most registered types are not lifecycles. They are calls: hand these params
to some code, take back a `donedata` map or a failure, let the chart move
on. Written against `Statifier.Invoke.Handler` directly, every host writes
the same adapter for that - one `{:handler, __MODULE__, payload}`
instruction out of `start/2`, empty plans out of `cancel/2` and `forward/3`,
and a `perform/2` that finds the session and calls `done_invocation/3` or
`failed_invocation/3`. The library writes it once.

`Statifier.Invoke.SyncHandler` is the two-callback shape:

```elixir
defmodule MyApp.Signup.Handlers do
  @behaviour Statifier.Invoke.SyncHandler

  @impl Statifier.Invoke.SyncHandler
  def invoke_types, do: ["myapp:signup", "myapp:provision"]

  @impl Statifier.Invoke.SyncHandler
  def handle("myapp:signup", params, _ctx), do: {:ok, %{"plan" => params["plan"]}}
  def handle("myapp:provision", params, _ctx), do: MyApp.Accounts.provision(params)
end
```

and `Statifier.Invoke.SyncHandler.Adapter` is the `Statifier.Invoke.Handler`
over a list of them:

```elixir
defmodule MyApp.InvokeHandler do
  use Statifier.Invoke.SyncHandler.Adapter,
    handlers: [MyApp.CardAuth.Handlers, MyApp.Signup.Handlers]
end
```

That one module answers both of the registrations a host owes, and answers
them from the same list:

```elixir
{:ok, machine} = Statifier.Compiler.compile(document)

Statifier.Session.start_link(machine,
  invoke_handlers: MyApp.InvokeHandler.invoke_handlers()
)
```

`MyApp.InvokeHandler.invoke_types/0` is the sorted union of every type its
handler modules claim - the list a host hands its own document compiler as
the set to lint an `<invoke type>` against - and `invoke_handlers/0` is that
same union mapped to the adapter. They are derived one from the other rather
than written beside each other, which is the point: the set a chart is
allowed to name and the set a session will actually answer cannot come
apart, and adding a type is one line in one handler module.

`{:error, reason}` from `handle/3` is **permanent**, unlike a `perform/2`
error under the general behaviour. A sync handler has no retry policy behind
it - the call was made and it answered - so the adapter reports it straight
through `failed_invocation/3`, with `reason` reaching the chart as
`_event.data.reason`. Name your failure classes with strings if a chart is
meant to branch on them; any other term is `inspect/1`-ed.

Reach for `Statifier.Invoke.Handler` itself instead when the invocation
outlives the performing turn, has something real to cancel, has an inbox to
autoforward into, or needs `invoke_id`, `src`, or `content` off the
`%Statifier.Effect.Invoke{}`. Everything below this section is written for
that case, and all of it still applies to a sync handler through the
adapter - the idempotency obligation especially, which the adapter cannot
discharge on a handler's behalf.

## Async and long-lived invocations

`invoke_id` stays stable across a persist/reload cycle because it is not a
freshly generated value - it is a deterministic counter carried on
`%Statifier.MachineState{}` (ADR-0008, as amended). Replaying the same drive
from the same persisted position always produces the same `invoke_id` for the
same `<invoke>` element, so a `done.invoke.<id>` that arrives minutes or days
after `start/2` planned it is still addressing a stable, recognizable name.
For what "persisted position" means safely - the reload has to land on the
same chart revision it was saved against, or fail loudly rather than resume
the wrong states - see [docs/persistence.md](persistence.md).

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

## Reading a child's outcome

A `type="scxml"` child that can finish several ways reports *which* way
through one channel only: `done.invoke.<invoke_id>`'s data, which is the
child's top-level `<final>`'s `<donedata>` (ADR-0051 decision 5, spec 3.7 and
5.5). Nothing else crosses the invoke boundary. The final's `id` does not, and
the event name never carries it, so there is no `done.invoke.<id>.approved` to
route on.

The convention that follows - and the one an authoring layer generating these
charts should emit - is one top-level `<final>` per declared outcome, each
carrying `<donedata>`, and a parent that routes on `_event.data` with an
unconditioned `done.invoke.<invoke_id>` transition last:

```xml
<state id="authorizing">
    <invoke id="auth" type="scxml">
        <param name="amount" expr="amount"/>
        <content><!-- a child whose finals carry <param name="outcome" .../> --></content>
    </invoke>
    <transition event="done.invoke.auth" cond="_event.data.outcome == 'approved'" target="captured"/>
    <transition event="done.invoke.auth" cond="_event.data.outcome == 'declined'" target="rejected"/>
    <transition event="done.invoke.auth" target="unhandled"/>
</state>
```

The unconditioned arm is not decoration. A child final carrying no
`<donedata>` delivers a done event with no data at all, so `_event.data` -
and `_event.data.outcome` with it - reads `:undefined` rather than any value a
cond can match, and every conditioned arm falls through to that last
transition. One wrinkle worth knowing there: a loose `==` against `:undefined`
evaluates to `:undefined` rather than to `false`, and a non-boolean cond is
false *plus* an `error.execution` (spec 5.9.1). The routing is unaffected, but
a parent that would rather not see that error event spells its conds `===`.

This section decides a convention over the existing channel; it changes no
engine behavior, and there is nothing here a host has to opt into.
`test/statifier/session/invoke_child_outcome_test.exs` pins it.

## Reporting permanent failure

`done_invocation/3` is the door for work that finished. Work that will never
finish needs the other door, or the chart waits forever in its invoking state:

```elixir
@spec failed_invocation(server :: server(), invoke_id :: String.t(), failure :: keyword()) :: :ok
def failed_invocation(server, invoke_id, failure \\ [])
```

Call it with the same owning session and `invoke_id`, at the moment **your own
retry policy is exhausted** and you have decided the invocation is over. It
constructs `error.communication.invoke.<invoke_id>` and delivers it on exactly
the same invocation-tagged entry, under exactly the same drain-time discard: a
cancel that got there first still wins, and the invocation's table entry is
popped either way, because a permanently failed invocation is over in the same
sense a completed one is.

`failure` is a keyword list read for three optional keys, none of which the
library interprets:

| Key | Read from a chart as | Absent |
|---|---|---|
| `:reason` | `_event.data.reason` | `"unknown"` |
| `:attempts` | `_event.data.attempts` | `undefined` |
| `:detail` | `_event.data.detail` | `undefined` |

### A worked example: a payload that will never decode

A host that stores an invocation's arguments in its own opaque encoding can
find, on a later attempt, that the stored payload will never decode again: a
retired codec version, a rotated key, a corrupt row. That is a permanent
failure of an invocation that already started, so it is reported through this
same door, with `reason: "undecodable"`:

```elixir
Statifier.Session.failed_invocation(session, "inv_3",
  reason: "undecodable",
  attempts: 1,
  detail: {:decode_error, :codec_version_retired}
)
```

| Key | Value here | Why |
|---|---|---|
| `:reason` | `"undecodable"` | the spelling to use for a permanently undecodable stored payload, so a `cond` reads the same across hosts |
| `:attempts` | as the host counted them, typically `1` | one decode was attempted and it will not become decodable by attempting it again |
| `:detail` | the codec's typed error, verbatim | uninterpreted by the library, exactly like any other `:detail` |

A chart that invokes `myapp:capture` to take a payment parks that invocation on
`error.communication.invoke.inv_3` and reads `_event.data.reason` to tell an
undecodable payload apart from an exhausted gateway retry. ADR-0068's decision
note of 2026-08-29 records why this is the invoke-failure family rather than a
new one (st-uumw); the timer half - an undecodable *delayed-send* payload - is
not decided by it.

**This is the host's call, never a handler callback's.** `start/2`, `cancel/2`,
and `forward/3` are pure planning callbacks that may not perform IO at all, and
`perform/2` returning `{:error, term()}` is a *transient* signal - it means this
attempt failed, which is what a retry policy exists to absorb. Only the layer
that owns the policy knows when the policy has run out, which is the same
reason completion is reported rather than inferred.

The event name is deliberately a suffix of `error.communication` rather than a
new `error.invoke` family. Spec 3.12.1 lets a platform extend a generated
event's name with a suffix precisely because the descriptor prefix rule keeps
the shorter name matching, so both of these work, and the first one works in
charts written before this door existed:

```xml
<!-- catches any invoke's permanent failure, and any other communication error -->
<transition event="error.communication" target="failed"/>

<!-- parks one invocation specifically, for operator recovery -->
<transition event="error.communication.invoke.inv_3" target="needs_attention">
    <log expr="_event.data.reason"/>
</transition>
```

ADR-0068 records the full argument, including why the event rides the external
queue with the rest of the invocation's traffic rather than being raised
internally.

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

## Testing your handler: the conformance case

Everything this document requires of a handler is also pinned mechanically:
`Statifier.Testing.HandlerCase` (ADR-0065) generates a conformance suite for
your implementation from two lines in a test module:

```elixir
defmodule MyApp.AuthorizeHandlerConformanceTest do
  use ExUnit.Case, async: false

  use Statifier.Testing.HandlerCase,
    handler: MyApp.AuthorizeHandler,
    type: "myapp:authorize"

  # The observation point for the idempotency check: return the observable
  # effects attributable to invoke_id - enqueued jobs, written rows,
  # whatever your perform/2 produces.
  def observed_effects(invoke_id) do
    MyApp.Jobs.AuthorizeJob.enqueued_for(invoke_id)
  end
end
```

The generated tests verify the planning callbacks are deterministic and
effect-free, `perform/2` is idempotent on `invoke_id` (the "At-least-once"
section above, judged against your `observed_effects/1`), cancel of an
unknown `invoke_id` never raises, `{:error, _}` from `start/2` surfaces as
`error.execution` in a minimal driving chart, and handler exceptions
propagate un-rescued. Fixtures are overridable (`conformance_invoke/0`,
`conformance_ctx/0`, `conformance_event/0`) for a handler that reads
`params`, `src`, or `content`; every check is also a plain public function
on the module for suites that want them one at a time. See the module's own
documentation for the full contract of each check.

One part of an async handler's contract the case deliberately does **not**
generate a check for: reporting permanent failure. `failed_invocation/3` is
called by the host's retry layer, not by the handler, so a handler-scoped
conformance case has no view of the thing that would need asserting - whether
your retry policy actually reaches the door when it gives up. Write that test
where your retry policy lives. What the case does cover on the failure side is
the one failure path a handler owns outright: `{:error, _}` from `start/2`
surfacing as `error.execution`.

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
  the session recovers from or turns into an event on your behalf. That is a
  statement about the *return value*, not about failure generally: once your
  retry policy has given up, `Statifier.Session.failed_invocation/3` above is
  how you say so, and the library still infers nothing - you decide when the
  invocation is over and tell it.
