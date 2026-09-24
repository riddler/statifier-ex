# Extending Statifier: `<invoke>` handlers and `<send>` types

This is a guide for a host application author who wants to reach real
computation - a database call, a background job, an LLM agent loop, an
external API - from an SCXML document's `<invoke>` element. It does not
re-explain the interpreter's architecture; see `docs/architecture.md` for
that. It shows you how to write and register a handler. The last section,
"The `<send>` half", covers registering a host Event I/O Processor type for
`<send type="...">`.

## What the seam is for

`docs/datamodel.md` names the reason Statifier's datamodel stays
non-evaluative rather than chasing ECMAScript:

> Real computation belongs in the host application, reached through
> `<invoke>` handlers and external `<send>` - controlled, typed, supervised.

Until now that sentence named an intention with no destination. This document
is the destination: a `Statifier.Invoke.Handler` is how your application
registers itself to serve an `<invoke type="...">` value the built-in engine
does not already know (`scxml` and its long-URI spelling,
`http://www.w3.org/TR/scxml/`, with or without the trailing slash, are the
only types shipped in the library itself). If what you are after is a durable `<send delay>` rather than an
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

### Nested charts: `:inherit_invoke_handlers`

Per-session registration stops at the session boundary, and a chart that
`<invoke type="scxml">`s another chart crosses one. A child session is started
with an **empty** registry by default, so a nested chart whose own
`<invoke type="myapp:authorize">` needs a registered handler raises
`error.execution` there even though the root registered it - the child plans
nothing and parks at that state.

`start_link/2`'s `:inherit_invoke_handlers` is the opt-in that closes that
gap:

```elixir
Statifier.Session.start_link(root_machine,
  invoke_handlers: MyApp.InvokeHandler.invoke_handlers(),
  inherit_invoke_handlers: true
)
```

`true` hands every child this session starts for an `<invoke>` both this
session's `:invoke_handlers` map **and** `inherit_invoke_handlers: true` of
its own, so one opt-in at the root registers the same handler palette down
the whole invoke tree. The default is `false`, which starts children exactly
as before.

It is opt-in rather than the default for the reason `:inherit_observers` is
(ADR-0050 decision 2): a default-on inheritance would start running a host's
handlers inside child charts nobody registered them for, on an upgrade, with
no caller having asked for it.

Inheritance is a **start-time hand-off, not a shared registry**. The child's
dispatch map and its `%MachineState{}` `invoke_types` stamp are fixed at the
child's own boot from the map it was handed, so ADR-0051 decision 2's
per-session cadence above is unchanged, and two roots with different palettes
still hand their own subtrees their own. Handlers descend independently of
`:invoke_source`, which ADR-0038 leaves to its own option, and independently
of `:inherit_observers`, which is an observation knob rather than a
registration one.

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

### No session process? Build the event yourself

Both doors take a live `Statifier.Session`. A host driving
`Statifier.Interpreter` directly, with no session process at all, has none to
hand them - so it calls `Statifier.Invoke.Answer.done/3` or
`Statifier.Invoke.Answer.failed/3`, which are the construction sites the two
doors themselves call through, and feeds the returned event to its next
drive:

```elixir
event = Statifier.Invoke.Answer.failed(run_id, "inv_3", reason: "exhausted", attempts: 5)
{:ok, machine_state, effects} = Statifier.Interpreter.handle_event(machine_state, event)
```

Same events, same payload rules, same names - one implementation, so a
process-less host and a live session cannot drift apart. What the host takes
on instead is the liveness check a session's drain does for itself: an answer
for an invocation the chart already cancelled must be dropped by the host,
against the host's own record of which invocations are live.
[docs/persistence.md](persistence.md)'s "Answering an invocation with no
session process" is the full recipe.

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

## The `<send>` half: host-registered send types

`<invoke>` is one of the two seams `docs/datamodel.md` names; external
`<send>` is the other. Spec 6.2.5 says a `<send>`'s `type` "specifies the
method that the SCXML processor MUST use to deliver the message to its
target" - the type names an Event I/O Processor, and the `target` is read by
that processor. The library's built-in processor answers three spellings:
the attribute omitted, `"scxml"`, and the processor URI
`http://www.w3.org/TR/scxml/#SCXMLEventProcessor`.
[ADR-0069](https://github.com/riddler/statifier-ex/blob/v2.8.0/docs/adr/0069-host-registered-send-types.md) lets a host register more,
per session, in the same shape `:invoke_handlers` has.

This section describes what the library does today. Everything ADR-0069
decides is built: the registration, the core's classification of every
`<send>` against it, the pre-start check, the hand-off of a registered
type's send to your module with its event already built, the host-owned
timer for a delayed send, the cancel routing, the miss door and the
`_ioprocessors` entry. One question is still open, and "After a resume"
below says what it is and what your host does until it is decided.

### Spelling a send to a host processor

The host's delivery mechanism goes in `type`, and the processor's own
address goes in `target`:

```xml
<send type="myapp:sink" target="joined_records" event="impression.joined">
    <param name="impression_id" expr="impression_id"/>
    <param name="click_id" expr="click_id"/>
</send>
```

A registered type is any string outside the three built-in spellings; a
`<host>:<name>` short form such as `myapp:sink` is one, and 6.2.5 permits
the short form. For a registered type the core never parses `target`: it is
an opaque string for the processor, so neither
`Statifier.Send.Target.parse/1` nor the ADR-0048 route snapshot is consulted
for it. `joined_records` above would be an invalid target for the built-in
processor, and it is carried through verbatim here.

### Registering the types

Send types are registered per session, on `Statifier.Session.start_link/2`:

```elixir
Statifier.Session.start_link(machine,
  send_types: %{"myapp:sink" => MyApp.SinkProcessor}
)
```

`:send_types` is a `%{type_string => module}` map, each module a
`Statifier.Send.Processor`. The default is `%{}`, which registers nothing:
only the built-in spellings are supported, and with no `:send_types` passed
nothing observable changes. The session derives the registered set from
the map's own keys through `Statifier.Send.Types.from_send_types/1`, the one
constructor, and stamps it on `%Statifier.MachineState{}` as `send_types`,
at a fresh start and at a resume alike. Like `:invoke_handlers`, the set is
fixed for the session's whole lifetime.

A map that names a built-in spelling is refused before the session boots,
with `{:error, {:send_types, {:built_in_types, types}}}`, every offending
key named and sorted. A built-in send can never be redirected to a host
processor.

`:inherit_send_types` is the `<send>` counterpart of
`:inherit_invoke_handlers`, on the same start-time terms: `true` starts every
child this session starts for an `<invoke>` with this session's
`:send_types` map and `inherit_send_types: true` of its own. The default is
`false`, which starts children registering no send type.

### What the core does with each type

`Statifier.Send.Types.classify/2` is the one classifier, and the core's
check in `Statifier.Machine.Content.Send` answers through it:

| `type` resolves to | What the core does |
|---|---|
| built-in: absent, `"scxml"`, or the processor URI | as before ADR-0069: C.1's target vocabulary, the ADR-0048 route snapshot, the library's own timer for a delayed send |
| a type in the session's registered set | builds the ordinary `%Statifier.Effect.Send{}` or `%Statifier.Effect.SendDelayed{}`, with `target` unread |
| any other type | raises `error.execution` carrying the `sendid`, aborts the executable-content block, and produces no effect |

The last row is 6.2.5's MUST. The send id is minted and `idlocation`
written before the refusal, as for every rejected send (ADR-0047). With no
registration the stamped set is `nil`, and `nil` refuses every non-built-in
type - unlike `<invoke>`'s permissive `nil` (ADR-0069 decision 2 gives the
reason). A `typeexpr` is resolved when the `<send>` is evaluated and judged
here, in the core, and nowhere earlier.

### Writing a `Statifier.Send.Processor`

A registered type's send is handed to its module, and the library delivers
nothing for it itself. The behaviour has `Statifier.Invoke.Handler`'s split:

| Callback | Purity | Called with |
|---|---|---|
| `deliver/3` | pure planning | the send effect the core produced, the event built from it, and the plan context |
| `cancel/2` | pure planning | the `%Statifier.Effect.Cancel{}` naming a delayed send this processor holds, and the plan context |
| `perform/2` (optional) | the impure half | one `{:handler, module, payload}` instruction a planning callback returned |
| `ioprocessors_entry/1` (optional) | pure | the registered type string; returns the processor's `_ioprocessors` value |

The planning callbacks return `{:ok, instructions}` and perform nothing; the
usual instruction is `{:handler, __MODULE__, payload}`, which the session
routes back to `perform/2`. The plan context is a plain map carrying
`session_id` and no pid, so a processor cannot reach into the session
through it.

**The event is built for you.** `Statifier.Send.Event.build/3` is the one
construction site: `name`, `data`, `sendid` only when the author wrote `id`
or `idlocation`, a delayed send's `caller_context`, and `origin` and
`origintype` defaulting to the sender's `#_scxml_<sessionid>` and the SCXML
processor URI. `deliver/3` receives it with those defaults. A processor that
wants replies to reach its own address rather than the sender's session
builds it again with `:origin` and `:origintype`.

**A delayed send is your timer.** For a registered type's
`%Statifier.Effect.SendDelayed{}` the session schedules nothing: the
processor owns the delay, and spec 6.2's discard at termination is its
fire-time check (ADR-0054 decision 4). [Durable timers](durable-timers.md)
stays the guide for the built-in types only.

**The cancel reaches the holder.** A `<cancel>` always cancels the
library's own timers under its send id. When a processor was handed a
delayed send under that id, the session remembers it, and the same
`<cancel>` reaches that processor's `cancel/2`, after which the hold is
released. A processor must tolerate a cancel for a send it has already
fired.

**Idempotency.** `perform/2` may be called more than once for the same
send: after a crash and a retry a host may perform the same effect again.
A processor must be idempotent on the components of ADR-0054 decision 3's
dedup key read off the effect - the send id, the step counters, `c_index`,
`owner`, and `ordinal` - with the session scope your host supplies. Every
registered-type send carries an `ordinal`: an immediate one gets it only
because its type is registered (ADR-0059's amendment of 2026-09-19, at
proposed), and a delayed one always has one.

A host driving `Statifier.Interpreter` directly reads the effect off the
core's return and calls `Statifier.Send.Event.build/3` itself. If it plans
through `Statifier.Session.Effects.plan/2`, the plan context carries
`send_types` (the stamped set), `send_processors` (the `:send_types` map)
and `held_sends`; a context without them plans a registered type's send as
the `error.execution` an unsupported type gets. Such a host re-stamps
`send_types` on every load, beside `routes` and `invoke_types` (see
[Hosting without a session](hosting-without-session.md)).

### Reporting a miss: `failed_send/3`

A processor that cannot deliver while the sender still exists - no route,
a sink that refused the event, a retry policy that ran out - reports the
miss through the session door, in `failed_invocation/3`'s shape:

```elixir
@spec failed_send(server :: server(), send :: Effect.Send.t() | Effect.SendDelayed.t(), failure :: keyword()) :: :ok
def failed_send(server, send, failure \\ [])
```

`server` is the sending session and `send` is the effect `deliver/3` was
handed. The session writes C.1's `error.communication` onto its own
internal queue through `Statifier.Interpreter.deliver_internal/5`,
ADR-0039's single write-back door, with the send's content position as the
origin, and runs to quiescence. `_event.sendid` is the send id whether or
not the author named the send - 5.10.1's rule for an error event triggered
by a failed send - so a chart can tell its sends apart:

```xml
<transition event="error.communication" cond="_event.sendid == 'joined'" target="retry"/>
```

`failure` sits where `failed_invocation/3` takes its keyword list; the
library does not read it, and the event carries no payload.

**This is the host's call, never a planning callback's.** `deliver/3` and
`cancel/2` perform nothing, and `perform/2` returning `{:error, term()}` is
a transient signal for whatever retry policy wraps it. Only the layer that
owns that policy knows a send has missed for good.

**The dead letter is the host's.** When the sender has reached a final
state, was cancelled, or no longer exists, C.1's queue does not exist, and
`failed_send/3` writes nothing: a finished session ignores it and a cast to
a process that is gone is dropped. The library absorbs nothing, so your
host records the miss itself as a dead letter keyed by the send's dedup
key, with its reason, and never drops it silently (ADR-0069 decision 5). A
subscriber learns the sender finished from `{:halted, reason}`, and
`Statifier.Session.status/1` answers it too. A processor whose route
creates its target on a miss (get-or-create) has no miss to report.

**No session process.** A host driving `Statifier.Interpreter` holds its
own `%MachineState{}` and makes the same write directly:

```elixir
{:ok, machine_state, effects} =
  Statifier.Interpreter.deliver_internal(
    machine_state,
    :platform,
    "error.communication",
    {:content, send.c_index, send.owner},
    sendid: send.send_id
  )
```

`{:error, :not_running}` is the finished-sender case, and the dead letter
is then the host's the same way.

### `_ioprocessors`

Spec 5.10 binds `_ioprocessors` to one entry for each Event I/O Processor
a session supports, and a registered type is one. A session registering
`myapp:sink` reads

```xml
<transition cond="_ioprocessors['myapp:sink'] !== undefined" target="can_join"/>
```

The entry is keyed by the type string, and its value is the map your
processor's optional `ioprocessors_entry/1` returns for that type - an
empty map when it does not implement the callback. The value must be
string-keyed at every level, as every datamodel value is;
`Statifier.Send.Types.from_send_types/1` raises `ArgumentError` otherwise,
so a bad value fails the session's start. The SCXML processor's own entry,
keyed by its URI and holding the session's `location`, is unchanged, and a
session with no `:send_types` carries that entry alone.

The entries are written once, when the session starts, and persist with
the datamodel. A resumed session reads the entries it started with: the
driver's re-stamp of `send_types` on a resume replaces the classifier's set
and does not rewrite `_ioprocessors`. Re-stamp the set the session started
with; a different set after a resume would need mid-session registration,
which ADR-0069 names as a trigger that would reopen it.

### After a resume

Which processor holds which delayed send is the live session's own state,
not part of the persisted position. A session resumed from a position
holds nothing, so a `<cancel>` it runs for a delayed send handed over
before the position was saved reaches no processor, and nothing tells your
processor to fire or drop such a send. What a resumed session should do
about those sends is not decided yet. Until it is, a host whose processor
keeps a delayed send across a resume cancels or fires it by its own
record, keyed by the send id and the session scope.

### The pre-start check

The core's refusal happens when the `<send>` runs. A host that would rather
refuse a chart before starting it calls
`Statifier.Send.Types.unsupported_sends/2` with the compiled chart and the
set it will start the chart with:

```elixir
send_types = %{"myapp:sink" => MyApp.SinkProcessor}
{:ok, machine} = Statifier.compile(source)

types = Statifier.Send.Types.from_send_types(send_types)

case Statifier.Send.Types.unsupported_sends(machine, types) do
  [] -> Statifier.Session.start_link(machine, send_types: send_types)
  unsupported -> {:error, {:unregistered_send_types, unsupported}}
end
```

It returns every `<send>` whose literal `type` attribute the set does not
contain, as `%{type: type, location: location}` with the `<send>` element's
location, in the compiled chart's content order (`c_index`), nested
content included. It is pure and total.
It cannot see a `typeexpr`, so the core's refusal stays the backstop.

It is not a `Statifier.Validator` check, deliberately: ADR-0069 decision 3
places it outside, because `Statifier.Validator.validate/3` judges a
document against the spec and takes no deployment state. A chart is not
invalid for naming a processor this deployment has not registered.
