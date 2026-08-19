# ADR-0051: Invoke handlers are registered per session

Status: accepted (2026-08-18) - re-argues ADR-0047 decision 5 in part (scoped
to `<invoke>`; the `<send>` 6.2.5 processor set is untouched and decision 5
stands unamended for it); extends ADR-0048's snapshot-as-value shape to a
second consumer, at a per-session rather than per-drive cadence

## Context

`st-cmq.8` asks for a supported way to register `<invoke>` handlers for types
beyond `scxml`, so that `docs/datamodel.md:17`'s promise - "real computation
belongs in the host application, reached through `<invoke>` handlers" - names
a seam that actually exists. Today it does not: no project-authored
`@callback` exists anywhere in `lib/`, and the only invoke type this engine
recognizes is decided by a hardcoded three-way string test,
`Statifier.Send.Target.supported_invoke_type?/1`.

That function has exactly two callers, and ADR-0047 decision 4 is why they
cannot drift: "the two sites apply one shared classifier." One is core
bookkeeping - `maybe_record_active_invocation/5` decides whether an
invocation is recorded in `active_invocations` at all - and the other is the
session planner's rejection arm, `plan_invoke/2`, which raises
`error.execution` for a type the classifier refuses. Registering a new type
means both sites have to agree on the answer, or the drift ADR-0047 decision
4 forbids reappears: a planner that starts an invocation the core never
recorded, which `<finalize>` would never run for, which would never be
autoforwarded to, and which would leave no `%Effect.CancelInvoke{}` on exit.

ADR-0047 decision 5 named this bead as its own reopen trigger:

> The named reopen trigger: an embedder-registrable processor-type set. If
> that lands, the 6.2.5 check becomes deployment state and moves back to the
> boundary (or into a caller-supplied capability), and this decision is
> re-argued in that record.

Decision 5 is about two type sets that happen to share one module,
`Statifier.Send.Target`: the `<send>` Event I/O Processor set (6.2.5) and the
`<invoke>` service type set (6.4). This bead registers `<invoke>` handlers
only. It does not make `<send type>` registrable and does not touch
`Statifier.Send.Target.supported_type?/1` or its placement in
`Statifier.Machine.Content.Send.execute/2`, so decision 5's trigger fires for
the `<invoke>` half alone.

Two more constraints bound the shape:

- **ADR-0048** already blessed a shape for handing the core deployment state
  it must judge against: a caller-declared, point-in-time value on
  `%MachineState{}`, chosen over a resolver function on three grounds - a
  value cannot perform a lookup, so ADR-0003's purity stays structural; a
  value is recordable, where a resolver's answers must be captured call by
  call; and a resolver's freshness advantage is illusory, since both shapes
  are point-in-time truth with the same time-of-check/time-of-use window.
- **Bead note 4** (the embedder requirements gathered from a production
  CQRS/Oban host evaluation) disprefers a global mutable registry: multi-tenant
  hosts run a different handler palette per chart, and replay determinism
  must not depend on handler presence at replay time.

The bead's acceptance criterion cites "per spec 6.4" for the unregistered-type
error. Section 6.4 of the local spec cache, isolated from its normative
heading to the next section's, is 11,256 characters and contains zero
occurrences of `error.execution` and zero of `error.communication`. The
outcome the criterion names is right; its citation is not, and this record
gives the outcome its actual ground rather than repeating the citation.

## Decision

**1. An unregistered invoke type raises `error.execution`, on 3.12.2's
internal-versus-communication split plus 6.2.5's explicit `<send>` analogue -
not on a 6.4 MUST, which does not exist.** Two clauses, both quoted verbatim
from the local cache, do the work 6.4 cannot:

> Two error events are defined in this specification: 'error.communication'
> and 'error.execution'. The former cover errors occurring while trying to
> communicate with external entities, such as those arising from `<send>` and
> `<invoke>`, while the latter category consists of errors internal to the
> execution of the document, such as those arising from expression
> evaluation. (3.12.2)

> If the SCXML Processor does not support the type that is specified, it MUST
> place the event error.execution on the internal event queue. (6.2.5, for
> `<send>`)

3.12.2's distinguishing question is whether communication with an external
entity was attempted. For an unregistered type it was not - this deployment
implements no such service, so nothing was ever reached for - which is the
same fact pattern 6.2.5 assigns `error.execution` to on the `<send>` side.
`<invoke>`'s genuine communication failure already exists and already raises
`error.communication`: `Statifier.Invoke.Source` failing to resolve `src`
(ADR-0038), where a handler *was* found and reaching the service failed. So
the rule:

| Failure | Event | Ground |
|---|---|---|
| Type names no registered handler | `error.execution` | 3.12.2's "internal to the execution of the document" plus 6.2.5's explicit analogue |
| A registered handler fails to reach its service | `error.communication` | 3.12.2's "trying to communicate with external entities" - already the `Invoke.Source` path |

This is today's behavior, unchanged. `st-5fbw` pinned it at five layers
(`test/statifier/send/target_test.exs`,
`test/statifier/interpreter/invoke_pass_test.exs`,
`test/statifier/interpreter/cancel_invoke_test.exs`,
`test/statifier/session/effects_test.exs`,
`test/statifier/session/invoke_start_child_test.exs`), and every one of those
pins stays green under this decision.

**2. Handler modules are a per-session `:invoke_handlers` option; the
registered *type set* is a caller-declared value on `%MachineState{}`,
stamped once per session via `MachineState.new/2` options rather than per
drive.** ADR-0048 decision 1's three grounds carry over verbatim to this
second consumer: a value cannot perform a lookup, so ADR-0003 stays
structural rather than by convention; a value is recordable, where a
resolver's answers would have to be captured call by call; and a resolver's
freshness advantage is illusory, since the target can still change between
the core's check and the actual dispatch either way.

Its cadence does not carry over. `Statifier.Send.Routes` is stamped before
every drive because session liveness changes between drives - a target
session can start or die between one `handle_event/2` and the next. The
registered invoke-handler set does not share that property: it is a
`start_link/2` option, fixed for the session's whole lifetime, exactly like
`:max_macrostep_rounds`. Stamping it per drive would model a fact that never
changes as though it might, at the cost of a stamp on every drive instead of
one at session start. So it joins `MachineState.new/2`'s options beside
`:routes` and is recorded once in `Statifier.Session.Recording`'s
`@normalized_opts`, not re-stamped or re-recorded per drive.

**3. ADR-0047 decision 5 is re-argued and split.** `<send>`'s 6.2.5 processor
set stays static, and decision 5 stands unamended there: this bead does not
make `<send type>` registrable, adds no second Event I/O Processor, and
leaves `Statifier.Send.Target.supported_type?/1` exactly where ADR-0047
decision 1 put it. `<invoke>`'s type set becomes deployment state.

Decision 4's anti-drift property is preserved by one shared classifier,
`Statifier.Invoke.Types.registered?/2`, answering at both the core's
`maybe_record_active_invocation/5` and the planner's `plan_invoke/2`, exactly
as `Statifier.Send.Target.supported_invoke_type?/1` answered both sites
before it. The session derives the `%MachineState{}`-stamped set from the
same handler map the planner dispatches on - one constructor, not two - so
the stamped set and the dispatch map cannot diverge by construction rather
than by discipline.

**4. The behaviour is three pure planning callbacks (`start/2`, `cancel/2`,
`forward/3`) plus one optional performing callback (`perform/2`), with
`{:handler, module, term}` as the single opaque instruction.** The three
planning callbacks are called from `Statifier.Session.Effects.plan/2`'s pure
fold and return instructions, not IO; `perform/2` is the impure half an
executor calls to run one. The host owns the IO and the dedup: `perform/2`
MAY be called more than once for the same `invoke_id` after a crash and
retry, and a handler MUST be idempotent on it. `invoke_id` is the natural
idempotency key because it is a deterministic `%MachineState{}` counter
(ADR-0008 as amended), not a freshly generated value, so re-running a drive
after a crash produces the byte-identical instruction with the byte-identical
id. The library performs no dedup itself and cannot: it has no view of the
host's durable store. This answers bead note 3's ask for either documented
idempotency expectations or a start shaped as returned instructions the host
owns; it does both, because the second gives the first for free.

**5. `done.invoke.<id>` and donedata for a non-scxml handler come back
through a public `Statifier.Session.done_invocation/3`.** The event's shape
is the documented contract for a process-less host: 6.4's MUST here is on the
*service* ("Once the external service has finished processing it MUST return
a special event 'done.invoke.id'"), not on this engine, so the engine's job
is to provide the door and document what arrives through it. The built-in
scxml handler routes through the same function rather than a second
construction site.

**6. `<finalize>` auto-assign stays unconditional across types.** 6.4 makes
the interpretation platform-specific for a non-scxml service, quoted
verbatim from the local cache:

> For targets of other invoked service types, the interpretation of `<param>`
> and `<content>` elements and the 'src' and 'namelist' attributes is
> platform-specific. However, these services MUST treat values specified by
> `<param>` and namelist identically.

Both readings conform, so the choice is this platform's to make and record
rather than the spec's to force. `auto_assign_finalize/5` already runs off
the arriving event regardless of type; keeping it that way wins on three
grounds - making it type-conditional would give the core a second reason to
consult the registered set, for a case with no consumer; `<finalize>`
semantics would then vary by deployment, which is a strictly worse debugging
story under ADR-0012; and an empty `<finalize/>` is the author's explicit
request to auto-assign, the least surprising thing to honor uniformly across
handler types.

**7. Named reopen triggers, recorded the way ADR-0047 and ADR-0048 record
theirs:**

- An embedder-registrable `<send>` Event I/O Processor set, which is decision
  5's own trigger, unfired by this record and left for its own.
- A corpus document naming a non-scxml invoke type, which would reopen the
  feature-detector question this bead deliberately leaves untouched (no
  conformance document in the corpus names a non-scxml type today, so a
  registry entry for it would gate a set of zero files).
- A host needing mid-session re-registration, which decision 2's fixed
  per-session cadence does not serve; a host with that need starts a
  different session with a different `:invoke_handlers` map today.

## Consequences

- The registered-type set becomes core-visible: `%MachineState{}` gains an
  `invoke_types` field (`nil` meaning "the built-in set only," mirroring
  `Statifier.Send.Routes`'s `nil` convention), and both
  `maybe_record_active_invocation/5` and `plan_invoke/2` consult
  `Statifier.Invoke.Types.registered?/2` against it instead of
  `Statifier.Send.Target.supported_invoke_type?/1` directly - which keeps
  delegating to that function for the built-in scxml/URI membership, so 6.4's
  short-form and long-URI reasoning stays in exactly one place.
- `Statifier.Invoke.Handler` becomes the repo's first project-authored
  `@behaviour`; the built-in scxml handler,
  `Statifier.Invoke.Handler.Scxml`, moves today's child-session start
  mechanics behind it with no observable change for `type=scxml` invocations.
- `Statifier.Session.Invocations`' entry type gains a pid-less shape for a
  handler-backed invocation, since ADR-0027's registry precedent assumed a
  child session process behind every entry.
- With no `:invoke_handlers` passed, every observable behavior in the repo is
  byte-identical to today - the empty-registration case is this decision's
  own proof, not a separate claim.
- `docs/extending.md` becomes the destination `docs/datamodel.md:17`'s
  promise has always pointed at but never had.
- What would reopen this record: any of decision 7's three named triggers.

## Related

- ADR-0047 (decision 4's anti-drift property, decision 5's reopen trigger,
  the neutral-namespace precedent this record's `Statifier.Invoke.Types`
  follows for `Statifier.Send.Routes`)
- ADR-0048 (the snapshot-as-value shape and its three grounds, adopted here
  at a per-session cadence)
- ADR-0003 (pure core), ADR-0008 (invoke id as a deterministic counter),
  ADR-0012 (resumable microstep position), ADR-0024 and ADR-0038 (a handler
  must not make the library fetch a URI on its behalf), ADR-0027 (the
  session-id registry `Statifier.Invoke.Types` is carefully not named after),
  ADR-0029 and ADR-0034 (replay's pure fold and its four-input tuple)
