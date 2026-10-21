# How to extend Statifier: `<invoke>` handlers, `<send>` types and host functions

**Read this to:** connect an SCXML document to your own code, through
`<invoke>`, `<send type="...">`, or functions in `cond` and `expr`.

**Short version:** write a module for the seam (`Statifier.Invoke.Handler`,
`Statifier.Send.Processor`, or `Predicator.FunctionProvider`). Register it per
session. Planning callbacks stay pure. Your host does the I/O and reports the
result.

This guide is for a host application author. Examples of real computation are
a database call, a background job, an LLM agent loop, and an external API. For
the interpreter's design, see [docs/architecture.md](architecture.md).

## What the seam is for

`docs/datamodel.md` says why the datamodel stays non-evaluative and does not
follow ECMAScript:

> Real computation belongs in the host application, reached through
> `<invoke>` handlers and external `<send>` - controlled, typed, supervised.

A `Statifier.Invoke.Handler` serves an `<invoke type="...">` value that the
built-in engine does not know. The library ships only `scxml` and its long-URI
spelling, `http://www.w3.org/TR/scxml/` (with or without the trailing slash).

For a durable `<send delay>`, see [docs/durable-timers.md](durable-timers.md).
That is a different seam.

## Writing a `Statifier.Invoke.Handler`

A handler is a module that implements the `Statifier.Invoke.Handler`
behaviour: three required callbacks and one optional callback.

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

**Planning callbacks.** `start/2`, `cancel/2`, and `forward/3` are pure. They
run inside the fold of `Statifier.Session.Effects.plan/2`. They use no process,
no clock, and no I/O. They return instructions that describe what must happen,
and perform nothing. A durable host with no `Statifier.Session` process can
therefore plan invocations the same way `Statifier.Session` does.

**`perform/2`.** This is the impure half. It is the only callback that can
touch the outside world. An executor (`Statifier.Session` is one) calls it to
carry out an instruction that a planning callback returned. It is optional. A
handler whose planning callbacks never return one of its own instructions does
not need it.

**Instructions.** Instructions are opaque outside the library, with one
exception: `{:handler, __MODULE__, payload}`. To hand work to your own
`perform/2`, return this instruction from `start/2`, `cancel/2`, or
`forward/3`. `payload` is the data that your `perform/2` clause needs.

**`ctx`.** `ctx` is a plain map, not a struct. Every planning callback
receives it unchanged:

```elixir
%{session_id: session_id, invoke_types: invoke_types, invoke_handlers: invoke_handlers}
```

- A handler usually needs only `session_id` (spec 5.10's `_sessionid`). Use it
  when the external system must know who is asking.
- `ctx` carries no pid, no `%Statifier.MachineState{}`, and no session struct.
  A handler cannot reach `Statifier.Session` internals through it.
- Read the identity of the invocation (`invoke_id`, `type`, `src`, `params`,
  `content`) from the `%Statifier.Effect.Invoke{}` that `start/2` receives as
  its first argument.

### A complete worked example

This handler serves an invented type, `"myapp:authorize"`. It hands a card
authorization to a background job system. The job reports the approval or
decline later:

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

The job reports through `Statifier.Session.done_invocation/3`, not through this
module. It can finish minutes or days later, and on a different node. Next:
register the handler.

## Registering a handler

Register handlers per session, on `Statifier.Session.start_link/2`:

```elixir
Statifier.Session.start_link(machine,
  invoke_handlers: %{"myapp:authorize" => MyApp.AuthorizeHandler}
)
```

`:invoke_handlers` is a `%{type_string => module}` map. The default is `%{}`.
It registers no type beyond the built-in `scxml`/bare-URI set. Passing nothing
changes no observable behavior.

Decision: [ADR-0051](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0051-invoke-handlers-are-registered-per-session.md)

- Registration is per session, not global. A session that drives a different
  chart, or a different tenant, can register a different set. No handler is
  reachable from every session in the process. A multi-tenant host that runs
  different chart deployments for different tenants gives each session its own
  set.
- The set is fixed for the whole lifetime of the session, like
  `:max_macrostep_rounds`. You cannot add or remove a handler in a session that
  already runs. Start a new session with a different `:invoke_handlers` map.

A session that drives a different chart registers a different set. A signup
wizard that runs an A/B test needs variant assignment and conversion recording,
not anything to do with cards:

```elixir
Statifier.Session.start_link(wizard_machine,
  invoke_handlers: %{
    "myapp:assign_variant" => MyApp.AssignVariantHandler,
    "myapp:signup" => MyApp.SignupStepHandler,
    "myapp:conversion" => MyApp.ConversionHandler
  }
)
```

### Nested charts: `:inherit_invoke_handlers`

Per-session registration stops at the session boundary. A chart that uses
`<invoke type="scxml">` to start another chart crosses that boundary. A child
session starts with an empty registry by default. If the nested chart has its
own `<invoke type="myapp:authorize">`, the child raises `error.execution` there,
plans nothing, and parks at that state, even though the root registered the
handler.

The `:inherit_invoke_handlers` option of `start_link/2` closes that gap. It is
opt-in:

```elixir
Statifier.Session.start_link(root_machine,
  invoke_handlers: MyApp.InvokeHandler.invoke_handlers(),
  inherit_invoke_handlers: true
)
```

`true` gives every child that this session starts for an `<invoke>` two
things: this session's `:invoke_handlers` map, and `inherit_invoke_handlers:
true`. One opt-in at the root registers the same handlers down the whole invoke
tree. The default is `false`, which starts children exactly as before.

It is opt-in for the same reason as `:inherit_observers` (ADR-0050 decision 2).
A default-on inheritance would run a host's handlers inside child charts that
nobody registered them for, on an upgrade, when no caller asked for it.

Inheritance is a hand-off at start time. It is not a shared registry.

- The child fixes its dispatch map and its `%MachineState{}` `invoke_types`
  stamp when it boots, from the map that it received. The per-session rule of
  ADR-0051 decision 2 therefore does not change.
- Two roots with different sets each give their own subtrees their own set.
- Handlers pass down independently of `:invoke_source`, which ADR-0038 leaves
  to its own option.
- Handlers pass down independently of `:inherit_observers`, which is an
  observation option, not a registration option.

Decision: [ADR-0050](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0050-invoked-children-inherit-observation-by-opt-in.md)
decision 2, [ADR-0051](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0051-invoke-handlers-are-registered-per-session.md)
decision 2, [ADR-0038](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0038-invoke-source-resolves-at-the-session-boundary.md)

## The common case: a sync handler

Most registered types are calls, not lifecycles. You pass the params to some
code and take back a `donedata` map or a failure. Against
`Statifier.Invoke.Handler` directly, every host writes the same adapter:

- one `{:handler, __MODULE__, payload}` instruction from `start/2`
- empty plans from `cancel/2` and `forward/3`
- a `perform/2` that finds the session and calls `done_invocation/3` or
  `failed_invocation/3`

The library provides this adapter once. `Statifier.Invoke.SyncHandler` is the
two-callback shape:

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

`Statifier.Invoke.SyncHandler.Adapter` is the `Statifier.Invoke.Handler` over a
list of such modules:

```elixir
defmodule MyApp.InvokeHandler do
  use Statifier.Invoke.SyncHandler.Adapter,
    handlers: [MyApp.CardAuth.Handlers, MyApp.Signup.Handlers]
end
```

That one module answers both registrations that a host owes, from the same
list:

```elixir
{:ok, machine} = Statifier.Compiler.compile(document)

Statifier.Session.start_link(machine,
  invoke_handlers: MyApp.InvokeHandler.invoke_handlers()
)
```

`Statifier.Compiler.compile/1` expects a document that
`Statifier.Validator.validate/3` already accepted, and does not run those checks
again. `Statifier.compile/2` runs the validator first.

| Call | `<send>` `<param>` with neither `expr` nor `location` | With both |
|---|---|---|
| `Statifier.compile/2` | refused as `{:param_no_value, name}` | refused as `{:param_expr_and_location, name}` |
| `Statifier.Compiler.compile/1` on an unvalidated document | raises `FunctionClauseError` | compiles as a `location` param, and `expr` is ignored |

Validate first, or compile from source with `Statifier.compile/2`.

- `MyApp.InvokeHandler.invoke_types/0` is the sorted union of every type that
  its handler modules claim. Give this list to your document compiler as the
  set to check an `<invoke type>` against.
- `invoke_handlers/0` is the same union, mapped to the adapter.
- One is derived from the other. The types that a chart can name and the types
  that a session answers cannot differ.
- To add a type, add one line in one handler module.

**Errors.** `{:error, reason}` from `handle/3` is permanent. A sync handler has
retry policy behind it: the call was made and it answered. This differs from a
`perform/2` error under the general behaviour. The adapter reports the error
straight through `failed_invocation/3`, and `reason` reaches the chart as
`_event.data.reason`. If a chart must branch on the failure class, name each
class with a string. The adapter passes any other term through `inspect/1`.

**When to use the full behaviour.** Use `Statifier.Invoke.Handler` itself when:

- the invocation outlives the performing turn
- it has something to cancel
- it has an inbox to autoforward into
- it needs `invoke_id`, `src`, or `content` from the `%Statifier.Effect.Invoke{}`

The sections below describe that case. They also apply to a sync handler
through the adapter, including the idempotency requirement, which the adapter
cannot meet for a handler.

## Async and long-lived invocations

`invoke_id` stays stable across a persist/reload cycle. It is a deterministic
counter on `%Statifier.MachineState{}`, not a newly generated value. If you
replay the same drive from the same persisted position, you get the same
`invoke_id` for the same `<invoke>` element. A `done.invoke.<id>` that arrives
minutes or days after `start/2` planned it therefore uses a stable name.

A reload must land on the same chart revision that it was saved against, or
fail with an error. It must not resume the wrong states. See
[docs/persistence.md](persistence.md).

Decision: [ADR-0008](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0008-uxid-for-identifiers.md), as amended

Your host reports completion with `Statifier.Session.done_invocation/3`:

```elixir
@spec done_invocation(server :: server(), invoke_id :: String.t(), donedata :: term()) :: :ok
def done_invocation(server, invoke_id, donedata \\ nil)
```

Call it with the owning session and the `invoke_id` that your `start/2`
received. The owning session is the one whose `<invoke>` started the work. It
is never a child session, because a handler-backed invocation has no child
session.

The function builds `done.invoke.<invoke_id>` from `donedata` and delivers it
as an ordinary invoked event. It has the same discard at drain time as any
other invocation-tagged entry. If the invocation was cancelled before the event
is dequeued, the library drops the event, per spec 6.4.3.

## Reading a child's outcome

A `type="scxml"` child can finish in several ways. It reports which way
through one channel only: the data of `done.invoke.<invoke_id>`. This data is
the `<donedata>` of the child's top-level `<final>`. Nothing else crosses the
invoke boundary. The `id` of the final does not cross it, and the event name
does not carry it. There is no `done.invoke.<id>.approved` to route on.

Decision: [ADR-0051](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0051-invoke-handlers-are-registered-per-session.md)
decision 5. Spec 3.7 and 5.5.

The convention:

1. Use one top-level `<final>` for each declared outcome.
2. Give each `<final>` a `<donedata>`.
3. Route in the parent on `_event.data`.
4. Put an unconditioned `done.invoke.<invoke_id>` transition last.

An authoring layer that generates these charts must emit this form:

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

The unconditioned transition is required. A child final with no `<donedata>`
delivers a done event with no data. Then `_event.data` and
`_event.data.outcome` read `:undefined`, which no cond can match. Every
conditioned transition falls through to the last one.

A loose `==` against `:undefined` evaluates to `:undefined`, not to `false`. A
non-boolean cond is false and also raises an `error.execution` (spec 5.9.1).
The routing does not change. A parent that must not see that error event writes
its conds with `===`.

This section sets a convention over the existing channel. It changes no engine
behavior, and a host has nothing to opt into. A test pins it:
`test/statifier/session/invoke_child_outcome_test.exs`.

## Reporting permanent failure

`done_invocation/3` reports work that finished. For work that will never
finish, use `failed_invocation/3`. Otherwise the chart waits forever in its
invoking state:

```elixir
@spec failed_invocation(server :: server(), invoke_id :: String.t(), failure :: keyword()) :: :ok
def failed_invocation(server, invoke_id, failure \\ [])
```

Call it with the same owning session and `invoke_id`. Call it when your own
retry policy is exhausted and you have decided that the invocation is over.

- The function builds `error.communication.invoke.<invoke_id>`.
- It delivers the event on the same invocation-tagged entry, with the same
  discard at drain time. A cancel that arrived first still wins.
- The library removes the table entry of the invocation in both cases. A
  permanently failed invocation is over, as a completed one is.

`failure` is a keyword list. The function reads three optional keys. The
library does not interpret any of them:

| Key | Read from a chart as | Absent |
|---|---|---|
| `:reason` | `_event.data.reason` | `"unknown"` |
| `:attempts` | `_event.data.attempts` | `undefined` |
| `:detail` | `_event.data.detail` | `undefined` |

### A worked example: a payload that will never decode

A host can find that the stored arguments of a started invocation will never
decode again. Causes are a retired codec version, a rotated key, or a corrupt
row. This is a permanent failure of an invocation that already started. Report
it through `failed_invocation/3`, with `reason: "undecodable"`:

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

A chart that invokes `myapp:capture` to take a payment can park that invocation
on `error.communication.invoke.inv_3`. It reads `_event.data.reason` to tell an
undecodable payload from an exhausted gateway retry.

The decision note of 2026-08-29 in ADR-0068 (st-uumw) records why this uses the
invoke-failure family and not a new family. It does not decide the timer case,
an undecodable delayed-send payload.

**Who calls it.** Only the host can call `failed_invocation/3`. A handler
callback must not call it.

- `start/2`, `cancel/2`, and `forward/3` are pure planning callbacks and must
  not perform I/O.
- A `perform/2` that returns `{:error, term()}` gives a transient signal. It
  means that this attempt failed, and a retry policy absorbs such failures.
- Only the layer that owns the policy knows when the policy has run out. For
  the same reason, the host reports completion and the library does not infer
  it.

**The event name.** The name is a suffix of `error.communication`, not a new
`error.invoke` family. Spec 3.12.1 lets a platform extend the name of a
generated event with a suffix, because the descriptor prefix rule keeps the
shorter name matching. Both of these transitions work. The first also works in
charts written before this function existed:

```xml
<!-- catches any invoke's permanent failure, and any other communication error -->
<transition event="error.communication" target="failed"/>

<!-- parks one invocation specifically, for operator recovery -->
<transition event="error.communication.invoke.inv_3" target="needs_attention">
    <log expr="_event.data.reason"/>
</transition>
```

Decision: [ADR-0068](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0068-permanent-invoke-failure-is-a-suffixed-error-communication.md)
holds the full argument. It includes why the event goes on the external queue
with the rest of the invocation's traffic and is not raised internally.

### No session process? Build the event yourself

`done_invocation/3` and `failed_invocation/3` take a live `Statifier.Session`.
A host that drives `Statifier.Interpreter` directly has no session process to
give them. It calls `Statifier.Invoke.Answer.done/3` or
`Statifier.Invoke.Answer.failed/3`. These build the event for the two session
functions. The host gives the returned event to its next drive:

```elixir
event = Statifier.Invoke.Answer.failed(run_id, "inv_3", reason: "exhausted", attempts: 5)
{:ok, machine_state, effects} = Statifier.Interpreter.handle_event(machine_state, event)
```

The events, payload rules, and names are the same. One implementation serves
both, so a host without a session process and a live session cannot differ.

The host must do the liveness check that the drain of a session does. It must
drop an answer for an invocation that the chart already cancelled, and it
checks against its own record of which invocations are live. Next: the section
"Answering an invocation with no session process" in
[docs/persistence.md](persistence.md).

## At-least-once: handlers must be idempotent

`perform/2` MAY be called more than once for the same `invoke_id`. A host can
crash after it starts an instruction and before it durably records that the
instruction ran. After recovery, the host can run the same drive again. This
produces the byte-identical instruction again. A handler that implements
`perform/2` MUST be idempotent on `invoke_id`.

The library cannot deduplicate. It has no view of the durable store of your
host, so it has no database and no job queue to check a prior attempt against.
It gives you `invoke_id` as the idempotency key for this reason. The key is
stable by construction (see above), not only by convention, so you can safely
key your own dedup table on it.

## What an unregistered type does

An `<invoke>` whose type (or evaluated `typeexpr`) resolves to no registered
handler raises `error.execution`.

No 6.4 MUST requires this. It follows from two clauses of the spec's local
cache:

- Clause 3.12.2 separates `error.execution` (errors internal to the execution
  of the document) from `error.communication` (errors while the processor tries
  to communicate with an external entity).
- Clause 6.2.5 gives the unsupported-type case of `<send>` as the direct
  analogue. It raises `error.execution` for the same reason.

An unregistered type never tried to communicate, because this deployment
implements no such service. A registered handler that fails to reach its
service is different: it did try, so that is an `error.communication`.

Decision: [ADR-0051](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0051-invoke-handlers-are-registered-per-session.md)
holds the full argument and the corpus that pins both outcomes.

## Testing your handler: the conformance case

`Statifier.Testing.HandlerCase` checks everything that this document requires
of a handler. It generates a conformance suite for your implementation from two
lines in a test module:

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

Decision: [ADR-0065](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0065-handler-conformance-case-in-statifier-testing.md)

The generated tests verify these points:

- The planning callbacks are deterministic and have no effects.
- `perform/2` is idempotent on `invoke_id` (the "At-least-once" section above,
  judged against your `observed_effects/1`).
- Cancel of an unknown `invoke_id` never raises.
- `{:error, _}` from `start/2` becomes `error.execution` in a minimal driving
  chart.
- Handler exceptions propagate and are not rescued.

You can override the fixtures (`conformance_invoke/0`, `conformance_ctx/0`,
`conformance_event/0`) for a handler that reads `params`, `src`, or `content`.
Each check is also a public function on the module. The module documentation
gives the contract of each check.

**What the case does not check.** It generates no check for permanent failure.
The host's retry layer calls `failed_invocation/3`, not the handler. A
handler-scoped case cannot see whether your retry policy reaches that function
when it gives up. Write that test where your retry policy lives.

The case does cover the one failure path that a handler owns outright:
`{:error, _}` from `start/2` becomes `error.execution`.

## A naming note

`Statifier.Invoke.Handler` (and its registration) is not `Statifier.Registry`.
`Statifier.Registry` is the session registry that the embedder places, keyed by
session id. It does `#_scxml_<sessionid>` routing, not `<invoke>` dispatch.

The two are unrelated concepts. They share the word "registry" in casual
conversation. Do not confuse the per-session handler registration in this guide
with looking up a session by id.

Decision: [ADR-0027](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0027-embedder-placed-session-runtime.md)

## Where the library will not help

The library does not do two things on behalf of a handler:

- **It never fetches a URI.** The engine never dereferences `<invoke
  src="...">`. The same policy applies to `<data src>`. If the engine
  dereferenced a URI named in a document by default, the author of the document
  could use it for request forgery. If your handler must reach a URI, do it in
  ordinary application code, under your own security policy.
  Decision: [ADR-0024](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0024-data-src-is-never-fetched.md),
  [ADR-0038](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0038-invoke-source-resolves-at-the-session-boundary.md)
  (for `<invoke>`).
- **It never rescues a handler exception into an event.** The library does not
  catch an exception that `start/2`, `cancel/2`, `forward/3`, or `perform/2`
  raises. It does not turn the exception into `error.execution` or
  `error.communication`. The exception crashes the session process. This is
  intentional, for the same reason as the idempotency requirement above. The
  session does not rescue a handler exception into a default value (the
  moduledoc gives the same reasoning).

Two rules about return values:

- `start/2` can return `{:error, term()}`. This is the one documented failure
  path of a planning callback. The library plans it as `error.execution`, the
  same class as an unregistered type, because no communication was attempted.
- The library does not interpret the return value of `perform/2`. Your handler
  must observe an `{:error, term()}` from it (log it, retry it, or raise it).
  The session does not recover from it and does not turn it into an event.

These rules are about return values, not about failure in general. When your retry policy has given up, call
`Statifier.Session.failed_invocation/3` (above). The library infers nothing.
You decide when the invocation is over.

## The `<send>` half: host-registered send types

`<invoke>` is one of the two seams that `docs/datamodel.md` names. External
`<send>` is the other. Spec 6.2.5 says that the `type` of a `<send>`
"specifies the method that the SCXML processor MUST use to deliver the message
to its target". The type names an Event I/O Processor. That processor reads the
`target`.

The built-in processor answers three spellings:

- the attribute omitted
- `"scxml"`
- the processor URI `http://www.w3.org/TR/scxml/#SCXMLEventProcessor`

A host can register more types for each session, in the same shape as
`:invoke_handlers`.

Decision: [ADR-0069](https://github.com/riddler/statifier-ex/blob/v2.8.0/docs/adr/0069-host-registered-send-types.md)

The library implements everything that ADR-0069 decides: registration,
classification by the core, the pre-start check, hand-off with the event
already built, the host-owned timer, cancel routing, the miss function, and the
`_ioprocessors` entry. One question is still open. See "After a resume" below.

### Spelling a send to a host processor

The host's delivery mechanism goes in `type`. The processor's own address goes
in `target`:

```xml
<send type="myapp:sink" target="joined_records" event="impression.joined">
    <param name="impression_id" expr="impression_id"/>
    <param name="click_id" expr="click_id"/>
</send>
```

A registered type is any string outside the three built-in spellings. A
`<host>:<name>` short form such as `myapp:sink` is a registered type, and 6.2.5
permits the short form.

For a registered type, the core never parses `target`. It is an opaque string
for the processor. The core does not call `Statifier.Send.Target.parse/1` and
does not use the ADR-0048 route snapshot for it. `joined_records` above is an
invalid target for the built-in processor. Here the core passes it through
unchanged.

### Registering the types

Register send types per session, on `Statifier.Session.start_link/2`:

```elixir
Statifier.Session.start_link(machine,
  send_types: %{"myapp:sink" => MyApp.SinkProcessor}
)
```

`:send_types` is a `%{type_string => module}` map. Each module is a
`Statifier.Send.Processor`. A value can also be `{module, opts}`, and the
options reach the processor (see "Registration options" in
`Statifier.Send.Processor`).

- The default is `%{}`, which registers nothing. Only the built-in spellings
  work, and with no `:send_types` nothing observable changes.
- The session derives the registered set from the keys of the map with
  `Statifier.Send.Types.from_send_types/1`, the one constructor.
- It stamps the set on `%Statifier.MachineState{}` as `send_types`, at a fresh
  start and at a resume.
- As with `:invoke_handlers`, the set is fixed for the whole lifetime of the
  session.

**Built-in names.** The library refuses a map that names a built-in spelling
before the session boots. It returns
`{:error, {:send_types, {:built_in_types, types}}}`, with every offending key
named and sorted. A built-in send can never go to a host processor.

**The registration check.** At a fresh start, the session asks every
registration whose processor exports the optional `check_registration/2` if it
can serve the registration.

- It asks in the order of the type strings.
- It refuses the first rejected registration in the caller, before it starts
  any session process, with
  `{:error, {:send_types, {:invalid_registration, type, reason}}}`.
- No process exits, so there is no crash report.
- A map that names a built-in spelling gets the built-in refusal above
  instead.
- A resume does not ask. The `_ioprocessors` entries that its position carries
  stay.

**Nested charts.** `:inherit_send_types` is the `<send>` counterpart of
`:inherit_invoke_handlers`, with the same start-time rules. `true` starts every
child that this session starts for an `<invoke>` with this session's
`:send_types` map and `inherit_send_types: true`. The default is `false`, and
children then register no send type.

### What the core does with each type

`Statifier.Send.Types.classify/2` is the one classifier. The core's check in
`Statifier.Machine.Content.Send` answers through it:

| `type` resolves to | What the core does |
|---|---|
| built-in: absent, `"scxml"`, or the processor URI | as before ADR-0069: C.1's target vocabulary, the ADR-0048 route snapshot, the library's own timer for a delayed send |
| a type in the session's registered set | builds the ordinary `%Statifier.Effect.Send{}` or `%Statifier.Effect.SendDelayed{}`, with `target` unread |
| any other type | raises `error.execution` carrying the `sendid`, aborts the executable-content block, and produces no effect |

The last row is the MUST of 6.2.5. The core makes the send id and writes
`idlocation` before the refusal, as for every rejected send.

- With no registration, the stamped set is `nil`. Here `nil` refuses every
  non-built-in type. This differs from `<invoke>`, where `nil` permits.
- The core resolves a `typeexpr` when it evaluates the `<send>`, and judges it
  there. No earlier check judges it.

Decision: [ADR-0047](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0047-send-static-target-type-invalidity-rejects-in-the-core.md),
[ADR-0069](https://github.com/riddler/statifier-ex/blob/v2.8.0/docs/adr/0069-host-registered-send-types.md)
decision 2 (the `nil` difference).

### Writing a `Statifier.Send.Processor`

The library hands the send of a registered type to its module. The library
does not deliver anything for it. The behaviour has the same split as
`Statifier.Invoke.Handler`:

| Callback | Purity | Called with |
|---|---|---|
| `deliver/3` | pure planning | the send effect the core produced, the event built from it, and the plan context |
| `cancel/2` | pure planning | the `%Statifier.Effect.Cancel{}` naming a delayed send this processor holds, and the plan context |
| `perform/2` (optional) | the impure half | one `{:handler, module, payload}` instruction a planning callback returned |
| `ioprocessors_entry/1` (optional) | pure | the registered type string; returns the processor's `_ioprocessors` value |
| `check_registration/2` (optional) | pure | the registered type string and the registration's options; returns `:ok` or `{:error, reason}`, asked at a fresh start only |

The planning callbacks return `{:ok, instructions}` and perform nothing. The
usual instruction is `{:handler, __MODULE__, payload}`, which the session
routes back to `perform/2`. The plan context is a plain map that carries
`session_id` and no pid, so a processor cannot reach the session through it.

**The library builds the event.** `Statifier.Send.Event.build/3` is the one
place that builds it.

- It sets `name` and `data`.
- It sets `sendid` only when the author wrote `id` or `idlocation`.
- It sets the `caller_context` of a delayed send.
- It defaults `origin` and `origintype` to the `#_scxml_<sessionid>` of the
  sender and the SCXML processor URI.

`deliver/3` receives the event with these defaults. A processor that wants
replies to reach its own address, not the session of the sender, builds the
event again with `:origin` and `:origintype`.

**A delayed send uses your timer.** For a `%Statifier.Effect.SendDelayed{}` of
a registered type, the session schedules nothing. The processor owns the delay.
The discard at termination in spec 6.2 is its check at fire time.
[Durable timers](durable-timers.md) applies to the built-in types only.

Decision: [ADR-0054](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md)
decision 4.

**The cancel reaches the holder.** A `<cancel>` always cancels the library's
own timers under its send id. If a processor received a delayed send under that
id, the session remembers it. The same `<cancel>` then reaches the `cancel/2`
of that processor, and the session releases the hold. A processor must accept a
cancel for a send that it already fired.

**Idempotency.** `perform/2` can be called more than once for the same send.
After a crash and a retry, a host can perform the same effect again. A
processor must be idempotent on the components of the dedup key, read from the
effect:

- the send id
- the step counters
- `c_index`
- `owner`
- `ordinal`

The session scope comes from your host. Every send of a registered type
carries an `ordinal`. An immediate send gets it only because its type is
registered. A delayed send always has one.

Decision: [ADR-0054](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0054-durable-timers-consume-the-effect-vocabulary.md)
decision 3 (the dedup key),
[ADR-0059](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0059-per-execution-ordinal-on-durable-timer-effects.md)
(amendment of 2026-09-19, accepted and implemented: an immediate send of a
registered type carries an ordinal).

**A host without a session process.** A host that drives
`Statifier.Interpreter` directly reads the effect from the return value of the
core and calls `Statifier.Send.Event.build/3` itself.

- If it plans through `Statifier.Session.Effects.plan/2`, the plan context
  carries `send_types` (the stamped set), `send_processors` (the `:send_types`
  map), and `held_sends`.
- If the context lacks them, the plan treats the send of a registered type as
  the `error.execution` that an unsupported type gets.
- Such a host re-stamps `send_types` on every load, together with `routes` and
  `invoke_types`. See [Hosting without a session](hosting-without-session.md).

### Reporting a miss: `failed_send/3`

A processor can fail to deliver while the sender still exists. Causes are no
route, a sink that refused the event, or a retry policy that ran out. The
processor reports the miss through the session function `failed_send/3`, which
has the same shape as `failed_invocation/3`:

```elixir
@spec failed_send(server :: server(), send :: Effect.Send.t() | Effect.SendDelayed.t(), failure :: keyword()) :: :ok
def failed_send(server, send, failure \\ [])
```

`server` is the sending session. `send` is the effect that `deliver/3`
received.

1. The session writes the `error.communication` of C.1 onto its own internal
   queue. It uses `Statifier.Interpreter.deliver_internal/5`, with the content
   position of the send as the origin.
2. Then it runs to quiescence.
3. `_event.sendid` is the send id, whether or not the author named the send.
   This is the rule of 5.10.1 for an error event that a failed send triggers.

Decision: [ADR-0039](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0039-session-detected-send-failures-re-enter-the-core.md)
(`deliver_internal/5` is the single write-back function).

A chart can therefore tell its sends apart:

```xml
<transition event="error.communication" cond="_event.sendid == 'joined'" target="retry"/>
```

`failure` takes the place of the keyword list of `failed_invocation/3`. The
library does not read it, and the event carries no payload.

**Who calls it.** Only the host can call `failed_send/3`. A planning callback
must not call it. `deliver/3` and `cancel/2` perform nothing. A `perform/2`
that returns `{:error, term()}` gives a transient signal for the retry policy
that wraps it. Only the layer that owns that policy knows that a send missed
for good.

**The host owns the dead letter.** The sender can reach a final state, can be
cancelled, or can no longer exist. Then the C.1 queue does not exist, and
`failed_send/3` writes nothing. A finished session ignores the call, and a cast
to a process that is gone is dropped.

- The library keeps no record of the miss.
- Your host must record the miss as a dead letter, keyed by the dedup key of
  the send, with its reason. It must not drop the miss silently.
- A subscriber learns that the sender finished from `{:halted, reason}`.
  `Statifier.Session.status/1` gives the same information.
- A processor whose route creates its target on a miss (get-or-create) has no
  miss to report.

Decision: [ADR-0069](https://github.com/riddler/statifier-ex/blob/v2.8.0/docs/adr/0069-host-registered-send-types.md)
decision 5.

**No session process.** A host that drives `Statifier.Interpreter` holds its
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

`{:error, :not_running}` means that the sender finished. The dead letter is
then also the host's.

### `_ioprocessors`

Spec 5.10 binds `_ioprocessors` to one entry for each Event I/O Processor that
a session supports, and a registered type is one. A session that registers
`myapp:sink` can read

```xml
<transition cond="_ioprocessors['myapp:sink'] !== undefined" target="can_join"/>
```

The entry key is the type string. The entry value comes from your processor:

- The optional `ioprocessors_entry/1` returns the map for that type. The value
  is an empty map if the processor does not implement the callback.
- If the entry must address the session (for example, a location that a
  receiver POSTs to), implement the optional `ioprocessors_entry/2` instead. It
  receives the session id and the options of the registration.
- The value must have string keys at every level, as every datamodel value
  does. Otherwise `Statifier.Send.Types.from_send_types/1` raises
  `ArgumentError`, and the session does not start.

The entry of the SCXML processor does not change. Its key is its URI, and it
holds the `location` of the session. A session with no `:send_types` carries
that entry alone.

**When the entries change.** The session writes the entries when it starts, and
they persist with the datamodel. Only a refresh or replacement by the host
rewrites them. A resumed session reads the entries that it started with.

The re-stamp of `send_types` by the driver on a resume replaces the set of the
classifier. It does not rewrite `_ioprocessors`. Re-stamp the set that the
session started with. A different set after a resume needs registration during
the session, which ADR-0069 names as a trigger to reopen the decision.

**Refreshing.** The same set with different options (for example, a moved base
URL) is a refresh by the host, not a new registration.

- Offline: re-stamp the position with the new options. Then call
  `Statifier.MachineState.refresh_ioprocessors/1` before you resume it.
- Running session, one type: `Statifier.Session.replace_send_type/3` replaces
  the registration of that type. In the same call, it recomputes the entry of
  that type from the new options. It adds and drops no type.
- Live session, all types: `Statifier.Session.refresh_ioprocessors/1` asks
  again, from the registration that the session holds. Use it for an entry that
  reads a value that changes while the session runs (for example, a location
  that your front end rotated).

Both refreshes work this way: for each type that `_ioprocessors` already has a
key for, they ask every processor that exports `ioprocessors_entry/2` for its
entry again. They change no other entry and no key.

### The Basic HTTP processor

The library ships one registered processor: `Statifier.Send.BasicHTTP`. It is
the Basic HTTP Event I/O Processor of SCXML appendix C.2. It delivers a send as
an HTTP POST, and it turns a POST that the front end of your host receives into
an event. Next: [The Basic HTTP Event I/O Processor](basichttp.md) covers how
to register it, the front end that your host writes around its decoder, and the
mapping in both directions.

### After a resume

The state of a live session records which processor holds which delayed send.
The persisted position does not include it. A session that resumes from a
position holds nothing. A `<cancel>` that it runs for a delayed send, handed
over before the position was saved, reaches no processor. Nothing tells your
processor to fire or drop that send.

What a resumed session must do about those sends is not decided yet. Until it
is decided, a host whose processor keeps a delayed send across a resume cancels
or fires it from its own record, keyed by the send id and the session scope.

### The pre-start check

The core refuses a send when the `<send>` runs. A host that must refuse a chart
before it starts calls `Statifier.Send.Types.unsupported_sends/2` with the
compiled chart and the set that it will start the chart with:

```elixir
send_types = %{"myapp:sink" => MyApp.SinkProcessor}
{:ok, machine} = Statifier.compile(source)

types = Statifier.Send.Types.from_send_types(send_types)

case Statifier.Send.Types.unsupported_sends(machine, types) do
  [] -> Statifier.Session.start_link(machine, send_types: send_types)
  unsupported -> {:error, {:unregistered_send_types, unsupported}}
end
```

It returns every `<send>` whose literal `type` attribute is not in the set.

- Each result is `%{type: type, location: location}`, with the location of the
  `<send>` element.
- The results follow the content order of the compiled chart (`c_index`) and
  include nested content.
- The function is pure and total.
- It cannot see a `typeexpr`, so the refusal by the core stays as the backstop.

It is not a `Statifier.Validator` check. `Statifier.Validator.validate/3`
judges a document against the spec and takes no deployment state. A chart is
not invalid because it names a processor that this deployment has not
registered.

Decision: [ADR-0069](https://github.com/riddler/statifier-ex/blob/v2.8.0/docs/adr/0069-host-registered-send-types.md)
decision 3.

## Host functions for `cond` and `expr`

A guard often needs a fact that the event does not carry. Examples are how many
paths a change touches, whether a timestamp is in business hours, or whether
two intervals overlap. Register a
function and call it from the chart, instead of computing the fact into the
event payload:

```xml
<transition event="change" cond="blast_radius(_event.data.paths) &lt; 10" target="auto"/>
```

### Writing a provider

A provider is a module that implements `Predicator.FunctionProvider`. Its
`functions/0` maps each name to `{arity, atom}`. The atom names a public
function on the same module. That function takes the argument list and the
evaluation context:

```elixir
defmodule MyApp.Guards do
  @behaviour Predicator.FunctionProvider

  @impl Predicator.FunctionProvider
  def functions, do: %{"blast_radius" => {1, :blast_radius}}

  def blast_radius([paths], _context) when is_list(paths),
    do: {:ok, paths |> Enum.map(&Path.dirname/1) |> Enum.uniq() |> length()}

  def blast_radius([_other], _context), do: {:error, "blast_radius expects a list"}
end
```

Return `{:ok, value}` or `{:error, message}`. An error becomes
`error.execution` at the call, as with any other evaluation failure. A guard
that errors is false.

A name must not be one that the chart already has. You cannot replace `In` or
the builtins of predicator (`len`, `Math.abs`, `Date.now`, and others). The
library refuses a provider that names one.

### A function must be pure

A registered function reads only its arguments, and the `host` term of the
context if it needs it. It does no I/O, reads no clock and no random source,
and keeps no state of its own.

The reason: the library evaluates a guard again when it replays a recording. A
resumed session evaluates later guards against the position that it was saved
at. A function that gave a different answer the second time would make a replay
differ from the run that it records.

Read anything that changes, such as the time or a database row, before you send
the event. Put the value in the event data.

### Registering the providers

Pass the same list when you compile the chart and when you run it:

```elixir
providers = [MyApp.Guards]

{:ok, machine} = Statifier.compile(source, function_providers: providers)
{:ok, session} = Statifier.Session.start_link(machine, function_providers: providers)
```

`Statifier.compile/2` checks every call that the chart makes. A call to a name
that is not `In`, a builtin, or a registered function fails the compile with a
`Statifier.Compiler.Error` whose reason is `{:unknown_function, name,
source}`. The compile checks names only. The session evaluates with the
functions that its own option registers.

A tool that checks charts without loading your modules declares the names
instead: `Statifier.compile(source, function_names: ["blast_radius"])`. The
compiled chart persists the declared names, so a `Statifier.Chart` blob
recompiles without the modules.

`Statifier.Session.start_link/2` refuses a list that does not resolve, before
the session starts, with `{:error, {:function_providers, reason}}`. A host that
drives `Statifier.Interpreter` directly passes the option to
`Statifier.MachineState.new/2` (through `Statifier.initialize/2`).

### After a resume

A persisted position does not carry the functions.

- A session that starts with `:resume` stamps the list that you pass to it. Pass
  the same list as at the start.
- A host that resumes a position itself re-stamps it with
  `Statifier.MachineState.put_function_providers/2` before the first drive.
- A recording keeps the list, and `Statifier.Replay` uses it. To replay a
  recording, load the provider modules.
- A child session that starts for an `<invoke>` does not inherit the list. A
  chart that is given as `<invoke>` content cannot call a host function.
