# ADR-0069: Host-registered send types fill the Event I/O Processor slot

Status: accepted (2026-09-19) - amends ADR-0047 decision 5 for `<send>`
(the half ADR-0051 left unfired: the 6.2.5 Event I/O Processor set
becomes per-session deployment state); answers ADR-0055 decision 3's
named trigger with the three things that decision says the opening record
owes; amends ADR-0054 decision 2 in part (its host rule for a delayed
send with a non-nil target is scoped to the built-in types); ADR-0047
decisions 1-4, ADR-0051's `<invoke>` set, and ADR-0055 decisions 1 and 2
are unchanged

## Context

A host that routes events between durable executions, and out of them to
its own sinks (a Pub/Sub topic, a webhook, a queue), needs a chart to be
able to say "hand this event to the host's delivery mechanism named X".
The natural spelling is a `<send>`. Today no spelling of it works, and the
reasons are in this repo's records and code. Code cites below were read at
`efb6601`.

**The send type set is closed and checked in the core.**
[ADR-0047](0047-send-static-target-type-invalidity-rejects-in-the-core.md)
decision 1 put 6.2.4's invalid-target check and 6.2.5's unsupported-type
check inside `Statifier.Machine.Content.Send.execute/2`, where they run
after argument evaluation and before any effect exists, so a rejection
takes 4.9's block abort. The type half is
`Statifier.Send.Target.supported_type?/1`, which accepts exactly three
values: `nil` (the attribute omitted), the short form `"scxml"`, and the
processor URI `http://www.w3.org/TR/scxml/#SCXMLEventProcessor`. The
target half is `Statifier.Send.Target.parse/1`, which accepts no target
(`:self`), `#_internal` and `_internal`, `#_parent` and `_parent`,
`#_scxml_<sessionid>`, and any other `#_<invokeid>`; every other string is
`{:invalid, target}`. The session planner applies the same two functions
at `Statifier.Session.interpret/2`'s boundary (`plan_send/3` and
`plan_send_delayed/3` in `Statifier.Session.Effects`), which is ADR-0047
decision 4's shared-classifier property. So `<send type="myapp:sink">`
raises `error.execution` for its type, and `<send target="myapp:sink">`
raises `error.execution` for its target.

**ADR-0047 decision 5 named this record's trigger.** It kept the type set
static "so 6.2.5's check may run in the core" and named the reopen
trigger: "an embedder-registrable processor-type set. If that lands, the
6.2.5 check becomes deployment state and moves back to the boundary (or
into a caller-supplied capability), and this decision is re-argued in that
record." ADR-0051 fired that trigger for `<invoke>` only. Its shape is the
precedent this record follows: handler modules passed per session as
`:invoke_handlers` on `Statifier.Session.start_link/2`, inherited by
invoked children only under `:inherit_invoke_handlers`, with the
registered type set derived from that one map
(`Statifier.Invoke.Types.from_handlers/1`) and stamped on
`%MachineState{}` as a caller-declared value, so the core and the planner
answer from one classifier (`Statifier.Invoke.Types.registered?/2`).
ADR-0051 decision 7 lists "an embedder-registrable `<send>` Event I/O
Processor set" as a trigger it left unfired.

**The spec already has the slot.** 6.2.5, quoted from the local spec
cache:

> The type of the `<send>` operation specifies the method that the SCXML
> processor MUST use to deliver the message to its target. [...] If the
> SCXML Processor does not support the type that is specified, it MUST
> place the event error.execution on the internal event queue.

> Processors MAY support other types such as web-services, SIP or basic
> HTTP GET. When they do so, they SHOULD assign such types the URI of the
> description of the relevant Event I/O Processor.

The TYPE names the delivery mechanism; the TARGET is read by that
mechanism. So the host's mechanism belongs in `type`, and the target is
that mechanism's own address string. Putting the host's name in `target`
instead would collide with C.1's special-target vocabulary, which
`parse/1` owns.

**[ADR-0055](0055-non-self-delayed-send-routes-stay-the-librarys.md)
decision 3 deferred the external-session route with a named trigger** -
"the first consumer that needs a durable delayed send between sessions
with host-stable ids" - and names three things the record that fires it
owes: the event carrier, the miss semantics when the sender is gone, and
the identity story. A durable router is that consumer: it addresses
executions by a host-stable address, delivers events between them, and
schedules their delays on its own durable timers. ADR-0055's identity item
has two halves, and both are answered below: whether the target can be
named by a host-stable id, and whether the *sender's* identity (for
`origin`, and for ADR-0054 decision 3's session scope) survives a restart.

What the code says about the sender's identity today:

- The delivered event is built session-side. `delivered_event/2` in
  `Statifier.Session.Effects` stamps `origin` with the sending session's
  `#_scxml_<sessionid>` location
  (`Statifier.Evaluator.SystemVariables.scxml_location/1`), `origintype`
  with the processor URI, `sendid` only when the author wrote `id` or
  `idlocation` (the effect's `id_from_author?`), and `caller_context` from
  a `%SendDelayed{}` (ADR-0063). The function is private, so a host
  cannot build that event itself.
- ADR-0060 decision 3 settled that a resumed session keeps the persisted
  position's `_sessionid`, so `origin` names the same sender across a
  resume. A restart that is not a resume still mints a fresh id
  (ADR-0027 decision 4, which ADR-0060 decision 3 says it does not amend).
- ADR-0054 decision 3's session scope is `_sessionid` for a live session
  or the host's own durable id for a process-less host, and ADR-0051's
  2026-09-12 Note records that a durable host's execution id is that host's
  own `_sessionid` for the execution.

## Decision

**1. The `type` attribute is the slot: a host registers an Event I/O
Processor type, and a chart names it in `type` with the processor's own
route in `target`.** A sink is spelled

```xml
<send type="myapp:sink" target="joined_records" event="impression.joined">
  <param name="impression_id" expr="impression_id"/>
  <param name="click_id" expr="click_id"/>
</send>
```

and a send to another execution through the host's address table is
spelled with its own registered type:

```xml
<send type="myapp:execution" target="click_attribution" event="click.recorded">
  <param name="key" expr="impression_id"/>
</send>
```

For a registered type the engine never parses `target`: it is an opaque
string the processor reads, and neither `Statifier.Send.Target.parse/1`
nor the ADR-0048 route snapshot is consulted for it. A registered type
string is any string outside the built-in spellings. 6.2.5 recommends
the URI of the processor's description (a SHOULD) and permits short
forms ("Processors MAY define short form notations"); a
`<host>:<name>` string such as `myapp:sink` is such a short form, and a
host may register the long URI as well. The built-in spellings
(`nil`, `"scxml"`, the processor URI) cannot be registered; a
registration naming one is refused when the session starts, so a
built-in send can never be redirected to a host processor.

This amends ADR-0047 decision 5 for `<send>` the way ADR-0051 amended it
for `<invoke>`: the 6.2.5 set becomes deployment state. Decision 5 named
two destinations for it, "back to the boundary (or into a
caller-supplied capability)", and this record takes neither as written. A
capability in this repo is a resolver function (ADR-0047 decision 6's
shape D, which ADR-0048 decision 1 rejected); decision 2 below takes
ADR-0048's and ADR-0051's shape instead, a caller-declared value on
`%MachineState{}` that the core judges against. ADR-0047 decisions 1-4
stand: the check stays in `execute/2`, the static half stays
registry-free, and the planner keeps its boundary arm.

**2. Registration is per session, beside `:invoke_handlers`, in the same
shape.** `Statifier.Session.start_link/2` gains a `:send_types` option, a
`%{type_string => module}` map, and an `:inherit_send_types` flag that
hands the map to invoked children exactly as `:inherit_invoke_handlers`
hands theirs (default `false`: a child registers nothing). The registered
set is derived from that map's keys by one constructor and stamped on
`%MachineState{}` as a `send_types` value through `MachineState.new/2`'s
options, once per session (ADR-0051 decision 2's cadence, not ADR-0048's
per-drive one). One shared classifier, the send counterpart of
`Statifier.Invoke.Types.registered?/2`, answers at both sites ADR-0047
decision 4 names: `Statifier.Machine.Content.Send.execute/2` and the
`Statifier.Session.Effects` planner. The built-in membership keeps
delegating to `Statifier.Send.Target.supported_type?/1`, so 6.2.5's
short-form and URI reasoning stays in one place.

`nil` for `send_types` means "no declaration", and for `<send>` that is
the built-in set only - today's behaviour, which already refuses every
other type in the core. This differs from `<invoke>`'s permissive `nil`
(ADR-0051's 2026-09-01 Note) on purpose: that permissiveness protected a
caller who reads `Effect.Invoke` off the core with no registration, and
no caller today reads an unsupported-type `<send>` off the core, because
the core has never emitted one.

**3. An unregistered type is refused statically, and the refusal has two
sites.**

- **In the core, always (6.2.5's MUST).** `execute/2`'s static half
  classifies the resolved type against the stamped set before any effect
  is built. An undeclared type raises `error.execution` on the internal
  queue with `sendid` and aborts the block, exactly as ADR-0047 decision 1
  does today: the send id is minted and `idlocation` written first, and no
  `%Effect.Send{}` or `%Effect.SendDelayed{}` is produced. "Static" is
  ADR-0047's sense: a registry-free classification of a string against a
  value, with no liveness question in it. A `typeexpr` resolves at
  evaluation time and is judged here only.
- **Before an execution starts, where the host asks for it.** A pure check
  the host calls with a chart and a type set lists every `<send>` whose
  literal `type` attribute the set does not contain, with its location, so
  a host can refuse to start or activate a chart that names a processor it
  never registered. It lives outside `Statifier.Validator`, whose
  `validate/3` judges a document against the spec and takes no deployment
  state (its one option relaxes a namespace rule for invoke content,
  ADR-0042), and it cannot see a `typeexpr`; the core check above stays
  the backstop for both.

**4. A registered type's send is handed to the host, with the event
already built.** When the type is registered, `execute/2` produces the
ordinary `%Effect.Send{}` or `%Effect.SendDelayed{}` (type, target, event,
data, send id, and the position counters the ADR-0054 dedup key reads).
What the host receives is that effect plus the event the library would
deliver:

- **The event carrier (ADR-0055's first item).** A public, pure builder
  takes a send effect and the sender's session id and returns the
  `%Statifier.Event{}` that `delivered_event/2` builds today: `name` from
  `event`, `data`, `sendid` gated on `id_from_author?`, `caller_context`
  from a delayed send, and `origin` and `origintype`. The builder accepts
  an `origin` and `origintype` from the processor, defaulting to the
  sender's `#_scxml_<sessionid>` and the SCXML processor URI. 5.10.1 asks
  that `origin` and `origintype` let the receiver `<send>` a response back
  "via the Event I/O Processor specified in 'origintype'", so a processor
  with its own reply address stamps that address as `origin` and its own
  type as `origintype`. `delivered_event/2` becomes a caller of this
  builder, not a second construction site. This is the door ADR-0055
  decision 3's first item anticipated ("most plausibly a session-side
  door"): a function a session and a process-less host both call, never
  a field on the core effect (ADR-0055 decision 2).
- **In a `Statifier.Session`,** the planner hands the effect and the built
  event to the registered module (a behaviour whose planning half is pure
  and whose performing half the host runs, ADR-0051 decision 4's split).
  **A process-less host** reads the effect off the pure core and calls the
  builder itself.
- **A delayed send of a registered type is the host's timer, never the
  library's.** The session schedules nothing for it and hands the
  `%SendDelayed{}` to the processor, which owns the delay. A `<cancel>`
  whose send id names such a send is handed to the same processor under
  ADR-0054 decision 3's cancellation key. Today the planner's cancel arm
  emits `{:notify, effect}` and `{:cancel_timers, send_id}`, the latter
  its only cancellation instruction, and `%Effect.Cancel{}` carries no
  type, so the session keeps which processor holds each registered-type
  delayed send id and routes the cancel by it; a process-less host already
  consumes `%Effect.Cancel{}` under that key. Spec 6.2's discard at
  termination is the host's fire-time check (ADR-0054 decision 4).
  ADR-0054 decision 2's host rule, as ADR-0055 decision 3 restates it
  ("for any non-nil target, leave the timer to the library"), reads over
  the built-in types only.
- **Idempotency.** A processor MUST be idempotent on the ADR-0054
  decision 3 dedup key's components read off the effect. An
  `%Effect.Send{}` carries every component except two: the session scope,
  which is the host's to supply, and ADR-0059's `ordinal`. The reason is
  the one ADR-0051 decision 4 gives for `perform/2`: after a crash and
  retry, a host may perform the same effect more than once.

Per type class:

| `type` resolves to | Refusal | `target` read as | ADR-0048 route snapshot | Delayed send's timer | Delivered event built by |
|---|---|---|---|---|---|
| built-in: absent, `"scxml"`, or the processor URI | 6.2.4's invalid target and ADR-0048's unreachable route, as today | C.1's vocabulary, by `Target.parse/1` | judged for an immediate send, as today | the library's (ADR-0054 decision 2) | the builder, called by the session as today |
| a type in the declared set | none | the processor's opaque route string | not consulted | the host's | the builder, called by the processor or the process-less host |
| any other type | `error.execution` in the core, block aborted | not read | not consulted | none: no effect exists | none |

**5. For the session route, ADR-0055's three owed items.** This record
opens host-stable delivery between executions through a registered type
(decision 1's `myapp:execution`), not by making `#_scxml_<sessionid>`
host-deliverable. The library's `#_scxml_`, `#_parent`, `#_<invokeid>` and
`#_internal` routes stay the library's, and ADR-0055 decisions 1 and 2
stand unchanged.

- **The event carrier** is decision 4's builder.
- **The miss semantics when the sender is gone: a host-side dead letter.**
  A processor that cannot deliver while the sender still exists reports
  the miss, and the sender gets C.1's `error.communication`, carrying the
  send's `sendid`, on its internal queue. For a `Statifier.Session` sender
  the report goes through a new public session door in
  `Statifier.Session.failed_invocation/3`'s shape (ADR-0068 decision 3):
  `failed_send/3`, taking the owning session, the send effect the
  processor was handed, and a failure keyword list, and called by the
  host, never by a processor's pure planning half. The session then writes
  the error through `Statifier.Interpreter.deliver_internal/5`, ADR-0039's
  single write-back door, with the effect's content position as the
  origin. That function takes the `%MachineState{}` the session holds
  privately, so a host cannot call it for a live session. A process-less
  host holds its own `%MachineState{}` and calls `deliver_internal/5`
  directly. When the sender has reached a final state or no longer
  exists, C.1's queue does not exist. The host then records the
  miss as a dead letter keyed by the send's dedup key, with its reason;
  the library absorbs nothing and the host never drops it silently. A
  silent discard would mirror 6.2's termination rule but would hide a real
  delivery failure from the only party that can act on it, which
  ADR-0012's debuggability rule counts against. A library-absorbed
  obligation would need a durable store the library does not have
  (ADR-0054 decision 3: the library "has no view of the host's store"). A
  processor whose route creates its target on a miss (get-or-create) has
  no miss to report.
- **The identity story, target half.** The target is the host's address
  `(scope, document, key)`: an opaque scope string, the stable document
  id, and a key. The host's own address table resolves it to an execution
  id, so host-stable ids exist outside the session id space and the engine
  never sees them; the route string and the params carry whatever the
  processor needs to build the address.
- **The identity story, sender half.** What the serialization work
  settled: a resumed session keeps its `_sessionid` (ADR-0060 decision 3),
  so a builder-stamped default `origin` names the same sender across a
  resume, and the host's execution id is its own `_sessionid` for the
  execution, which is ADR-0054 decision 3's session scope. What remains: a
  restart that is not a resume mints a fresh id (ADR-0027 decision 4), so
  a reply addressed to a default `origin` can miss after one. A processor
  that needs replies to survive a restart stamps its own address as
  `origin` (decision 4's builder), and the reply then travels through the
  host's address table rather than the session id space.

## Consequences

- What moves in `lib/` when this is implemented:
  - a `send_types` field on `%MachineState{}` and its option on
    `MachineState.new/2`;
  - the shared classifier and its one constructor from the `:send_types`
    map;
  - `reject_reason/4` in `Statifier.Machine.Content.Send` consults the
    classifier, and for a registered type skips the target parse and the
    route snapshot;
  - `plan_send/3` and `plan_send_delayed/3` in `Statifier.Session.Effects`
    plan a registered type to its module;
  - the public event builder, with `delivered_event/2` calling it;
  - the public send-miss door `Statifier.Session.failed_send/3`
    (decision 5), writing through `deliver_internal/5`;
  - the cancel routing of decision 4: the session keeps which processor
    holds each registered-type delayed send id and hands that
    processor the `<cancel>`, beside today's `{:cancel_timers, send_id}`
    arm for the library's own timers;
  - the pre-start check of decision 3;
  - `:send_types` and `:inherit_send_types` on
    `Statifier.Session.start_link/2`, stamped at both boot arms the way
    `invoke_types` is;
  - `send_types` joins `routes` and `invoke_types` in the fields the
    position blob drops and blanks on decode (ADR-0064), re-stamped by the
    driver on resume;
  - `Statifier.Session.Recording` normalizes `:send_types` as strings,
    never atoms or code, under ADR-0057 decision 5's rule for
    `:invoke_handlers`.
- What does not move: `Statifier.Send.Target.parse/1` and
  `supported_type?/1` keep their accepted sets; ADR-0047 decisions 1-4
  stand; ADR-0051's `<invoke>` set, `:invoke_handlers` and
  `Statifier.Invoke.Types` are untouched; the ADR-0048 route snapshot and
  its reachability rule for built-in targets are unchanged. With no
  `:send_types` passed, every observable behaviour is byte-identical to
  today.
- 5.10: "The SCXML Processor MUST bind the variable _ioprocessors to a set
  of values, one for each Event I/O Processor that it supports." A
  registered type is a supported processor for that session, so its entry
  joins `_ioprocessors`; the value is the processor's to supply. The
  implementing change decides how the entry is written and how it reads on
  resume.
- Open question, recorded rather than decided: ADR-0059 closed the foreach
  collision of the dedup key for delayed sends with an `ordinal`, and
  `%Effect.Send{}` has no such field. An immediate registered-type send
  with an author-written `id` inside a `<foreach>` yields one dedup key
  per iteration's identical position. The implementing change either gives
  `%Effect.Send{}` the ordinal or documents ADR-0054's original guidance
  for this case.
- No conformance result moves: the corpus names no type outside the
  built-in set.
- ADR-0055's Consequences also list "an embedder-registrable Event I/O
  Processor set" as a reopen trigger for that record, one that "would
  re-pose routing per-processor and could carry its own delivery doors".
  This record fires that trigger too: routing is re-posed per processor
  for registered types only, and the delivery doors are decision 4's
  builder and decision 5's `failed_send/3`.
- What would reopen this record: a host needing mid-session registration
  (the ADR-0051 decision 7 trigger, for sends); a corpus document naming a
  non-built-in send type; or a consumer that needs a host to deliver a
  `#_scxml_<sessionid>` target itself, which this record does not open:
  it answers ADR-0055 decision 3's trigger through a registered type
  instead.

## Related

- [ADR-0047](0047-send-static-target-type-invalidity-rejects-in-the-core.md) (decision 5 amended; decisions 1-4 relied on)
- [ADR-0051](0051-invoke-handlers-are-registered-per-session.md) (the per-session registration shape, the one-constructor rule, the planning and performing split)
- [ADR-0055](0055-non-self-delayed-send-routes-stay-the-librarys.md) (decision 3's trigger and its three owed items)
- [ADR-0039](0039-session-detected-send-failures-re-enter-the-core.md) (the write-back door)
- [ADR-0048](0048-send-reachability-judged-against-a-route-snapshot.md) (the route snapshot, not consulted for registered types)
- [ADR-0054](0054-durable-timers-consume-the-effect-vocabulary.md) (decision 2's host rule amended in part, scoped to the built-in types; the dedup and cancellation keys, the fire-time check)
- [ADR-0057](0057-recording-identity-and-serialization.md) (recording normalization)
- [ADR-0060](0060-resuming-a-session-from-a-persisted-position.md) (the session id across a resume)
- [ADR-0063](0063-caller-context-on-external-events-and-durable-timer-effects.md) (`caller_context`)
- [ADR-0064](0064-position-blob-drops-the-per-drive-snapshot-fields.md) (the dropped position fields)
- [ADR-0068](0068-permanent-invoke-failure-is-a-suffixed-error-communication.md) (the `failed_invocation/3` door shape `failed_send/3` follows)

## Note (2026-09-19): accepted ahead of its implementation

The operator accepted this record on 2026-09-19. The acceptance is the
record's, not an implementation's: no decision, consequence or Related
entry changes here, and the amends and answers clauses in the Status line
stand as written. This note decides nothing.

Nothing in `lib/` carries a registered send type today. `send_types` and
`inherit_send_types` have no occurrence in `lib/` or `test/` at `9c3cbf1`,
and the engine work the Consequences list under "What moves in `lib/` when
this is implemented" is scheduled rather than landed. Until that change
lands, the library behaves exactly as the same bullet's last sentence says
it does with no `:send_types` passed: byte-identical to today.

The record mixes sentences about code that exists with sentences about
code that does not, so this note says plainly which is which.

- The **Context** section describes today's code, and its cites hold. They
  were read at `efb6601`, and each was re-read at `9c3cbf1` before this
  note: the closed three-value type set and the target vocabulary, the two
  classifier functions, the planner's boundary arm, the private
  `delivered_event/2` and its four stamps, and the three sender-identity
  facts all stand unchanged.
- **Decisions 1 through 5 speak in the present tense about a registered
  type, and none of that behaviour exists yet.** Decision 1's two example
  sends and its refusal to parse a registered type's `target`; decision
  2's `:send_types` and `:inherit_send_types` options, the one
  constructor, the `send_types` value on `%MachineState{}` and the shared
  classifier; decision 3's core arm and its pre-start check; decision 4's
  public event builder, the planner's hand-off to a registered module, the
  host-owned delayed-send timer and the cancel routing; and decision 5's
  `failed_send/3` door and its dead letter are all decided and unbuilt.
  In decision 4's per-type-class table, only the first row - the built-in
  types - describes what the library does today; the second row is the
  decided-and-unbuilt behaviour and the third is today's refusal.
- The **open question** the Consequences record is still open, and the
  two branches it offers stand differently against ADR-0059. Branch
  one - giving `%Effect.Send{}` an `ordinal` - would amend ADR-0059
  decision 5, whose closing rule reads "the two durable-timer effects
  carry `ordinal`; no other effect does, because no other effect is
  durably stored." Branch two - documenting ADR-0054's original author
  guidance for this case - leaves `ordinal` off `%Effect.Send{}` and so
  stands with that rule; what it touches is ADR-0059 decision 3, which
  withdrew that guidance in a sentence scoped to a delayed send: "The
  residual-collision paragraph of ADR-0054 decision 3 is withdrawn, and
  with it the author guidance: a hand-written `id` on a
  `<send delay="...">` inside a `<foreach>` is fully supported under a
  durable scheduler once the field ships." The tension between the two
  records sits in rationale rather than in decisions: ADR-0059
  decision 5 argues from the effect this record's decision 4 rehomes -
  "immediate `%Send{}` is delivered inside the drive that produced it
  and is never stored" - while decision 4 here hands a registered
  type's immediate send to a host module that may store it, so that
  premise stops holding for registered types once this record is built.
  This record names ADR-0059 in decision 4 and in the open question, but
  cites neither its decision 3 nor its decision 5, and ADR-0059 is not in
  the Related list.

Three citation notes, none of which changes what the record decides.

- `Statifier.Machine.Content.Send.execute/2` and `reject_reason/4` name a
  `Statifier.ExecutableContent` protocol implementation and a private
  function inside it, not public functions of that module; `execute/2`
  returns a rejection tuple and `Statifier.Interpreter.Content` names the
  event. ADR-0047 and ADR-0048 use the same shorthand for `execute/2`,
  and this record inherits it; `reject_reason/4` is cited by this record
  alone.
- The `nil` comparison in decision 2 cites ADR-0051's 2026-09-01 Note,
  which is the `nil`-stays-permissive half of that day. ADR-0051's
  `### Amendment 2026-09-01` is the other half - a declared set that omits
  the type is refused in the core - and it is the nearer precedent for
  decision 3's core refusal.
- The Context's statement that a durable host's execution id is that
  host's own `_sessionid` cites ADR-0051's 2026-09-12 Note, which is
  premised on statifier_persistence `sp-ADR-0011` at *proposed*. That
  premise has since firmed: ADR-0068's 2026-09-13 Note records
  `sp-ADR-0011` accepted on 2026-09-13.

Premise surface: `lib/` and `test/` at `9c3cbf1`, where `send_types` has
no occurrence; this record's own Context cites re-read at the same commit;
and ADR-0047, ADR-0048, ADR-0051, ADR-0054, ADR-0055, ADR-0059 and
ADR-0068 as they stand on `main` at that commit.
