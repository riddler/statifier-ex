# ADR-0047: Static send target/type invalidity rejects in the core

Status: accepted (2026-08-17) - amends 0039 in part (the rejected
alternative is scoped to liveness); reachability stays out of the core and
test496's fix is deferred to its own bead and record - decision 5 re-argued
in part by 0051 (scoped to `<invoke>`; the `<send>` 6.2.5 processor set is
untouched and decision 5 stands unamended for it)

## Context

st-yizi reports two mandatory W3C failures with one root cause: a `<send>`'s
target/type validity is decided in `Statifier.Session.Effects.plan_send/3` -
session-side, after `Statifier.Interpreter.handle_event/2` has already run
the whole macrostep containing the `<send>` to quiescence.
`docs/research/260817-st-yizi-send-target-validity-block-abort-and-order.md`
establishes the mechanics; the two consequences are:

- **test159** (`test/scxml_tests/mandatory/evaluationof_executable_content/test159_test.exs`):
  `<send event="thisWillFail" target="baz"/>` is followed by an `<assign>`
  in the same `<onentry>` block. Spec 4.9:

  > If the processing of an element causes an error to be raised, the
  > processor MUST NOT process the remaining elements of the block. (The
  > execution of other blocks of executable content is not affected.)

  The core evaluates the sibling `<assign>` because it has no idea the
  target is bad - the `{:invalid, _}` classification happens only when the
  session plans the effect list, after the block already ran.

- **test496** (`test/scxml_tests/mandatory/scxml_event_processor/test496_test.exs`):
  `<send ... target="#_scxml_foo"/>` followed by `<raise event="foo"/>`. The
  target parses cleanly but names no live session, so C.1 requires
  `error.communication` on the sender's internal queue - and the test only
  passes if that error is visible before `foo` is processed. Because
  `handle_event/2` folds to quiescence before the session ever sees the
  effect, the `<raise>`'s `foo` has been dequeued and matched by
  `<transition event="*">` long before `Statifier.Session.deliver/5` can
  discover the miss. No post-hoc re-ordering - ADR-0044's deferral included -
  can recover this; the answer has to exist while the core is still inside
  the block.

The research's first finding is the load-bearing one: **these are two
different checks, not one.** `Statifier.Session.Target.parse/1` is a pure
string classifier - `"baz"` is `{:invalid, "baz"}` from the string alone,
with no registry, no process, no liveness anywhere in the answer. So is
`supported_type?/1`. Reachability - "does `#_scxml_foo` name a session that
is currently live" - is a separate question that only the registry can
answer, and `parse/1`'s own moduledoc disclaims it. The spec splits the
failures the same way: 6.2.4 and 6.2.5 give the static half
`error.execution`, C.1 gives the liveness half `error.communication`:

> If the value of the 'target' or 'targetexpr' attribute is not supported
> or invalid, the Processor MUST place the error error.execution on the
> internal event queue. If it is unable to dispatch the message, the
> Processor MUST place the error error.communication on the internal event
> queue. (6.2.4)

> If the SCXML Processor does not support the type that is specified, it
> MUST place the event error.execution on the internal event queue. (6.2.5)

> If the sending SCXML session specifies a session that does not exist or
> is inaccessible, the SCXML Processor MUST place the error
> error.communication on the internal event queue of the sending session.
> (C.1)

**What the record already says.** ADR-0039's rejected alternative reads:

> **Move target routing into the core**, so the core itself decides whether
> a target resolves and raises the failure inline during `handle_event/2`.
> This is foreclosed outright: ADR-0003's pure core knows nothing about
> which sessions are live, and ADR-0027 places the registry - the only
> source of truth for "does this session id resolve" - on the embedder side
> of the session boundary. Teaching the core to consult it would make the
> core aware of live sessions, which both records already forbid.

Every load-bearing phrase in that paragraph is about liveness: "whether a
target *resolves*", "which sessions are *live*", "the *registry*". The
argument does not reach a registry-free string classification, but the
headline phrase "target routing" can be read to, and this repo does not
quietly contradict its own record - so the scoping is made explicit here,
as an amendment in part, rather than ridden past. Placement of the static
check in the planner was a locality choice of st-cmq.5's plan (keeping it
beside the registry-dependent arm), not something any ADR required; ADR-0036
already runs the exact mechanism the fix needs, converting `<send>` argument
failures to `error.execution` plus block abort through
`Statifier.Interpreter.Content`'s fold.

**What the corpus already pins.** test332
(`test/scxml_tests/mandatory/system_variables/test332_test.exs`, in
`test/passing_tests.json`) sends to the same invalid target `"baz"` with
`idlocation="Var1"` and asserts `Var1===_event.sendid` on the resulting
error event, per 5.10.1:

> in the case of error events triggered by a failed attempt to send an
> event, the Processor MUST set this field to the send id of the triggering
> `<send>` element.

So the fix cannot be the one-line rejection it first looks like: the send
id must still be minted, the `idlocation` write must still land, and the
resulting `error.execution` must still carry `sendid` - all of which the
session-side `execution_error/1` does today and a naive early `{:error, _}`
in `Send.execute/2`'s `with` chain would lose, regressing test332 while
fixing test159.

## Decision

**1. The static half - 6.2.4's invalid target and 6.2.5's unsupported type -
is decided in the core, inside `Statifier.Machine.Content.Send.execute/2`,
and rejection takes ADR-0036's channel: `{:error, ...}` out of the node, no
`Effect.Send`/`Effect.SendDelayed` produced, `error.execution` and 4.9 block
abort supplied by `Statifier.Interpreter.Content`'s existing fold.** The
check runs after argument evaluation (a `targetexpr` that fails to evaluate
is still ADR-0036's case; one that evaluates to `"baz"` is this record's)
and covers immediate and delayed sends alike, since both flow through the
same `execute/2` - which also honors 6.2.2/6.2.3's requirement that
arguments are checked when the element is evaluated, not when a delayed
message fires.

Ordering within `execute/2`, forced by test332 and 5.10.1: the send id is
minted and `idlocation` written *before* the validity check, and the
rejection returns the composite `{:error, context, reason}` form - not the
two-element leaf form - so the advanced `send_counter` and the datamodel
write survive the halt. An invalid-target `<send>` therefore still consumes
a send id (research open question 4, settled: the corpus observes it), and
ADR-0035's counter semantics are unchanged.

The failing node's `error.execution` carries `sendid`. The block runner's
conversion site (`raise_execution_error/4`) today stamps only
`data: reason`; carrying the sendid through the fatal channel is a widening
of the runner's error model, which `docs/architecture.md` explicitly names
as "a separate, ADR-governed thing" from an element's own code - this
record is that governance. The concrete encoding (a structured reason the
conversion site destructures, or an opts extension) is implementation
detail; the contract is that the raised event's `sendid` field equals the
minted id, per 5.10.1's unconditional MUST. One observability note: the
`idlocation` write's `:datamodel_change` effect is not emitted on the
failure path, because the composite error return carries no effects slot -
the write itself is in the datamodel (test332 reads it there), and live and
replay agree since both derive from the core.

**2. ADR-0039 is amended in part, by scoping, not reversal.** The rejected
alternative's foreclosure is restated as: the core never makes a *liveness*
determination - it never knows whether a target resolves, never consults
the registry, never becomes aware of live sessions. A pure, registry-free
classification of the target *string* (and of the `type` string) is not
routing and was never inside the foreclosure's stated grounds. Everything
else in ADR-0039 stands: `deliver_internal/5` remains the single write-back
door for every failure the *session* detects, and the session keeps
detecting every failure that needs the registry.

**3. The classifier moves to a neutral home, `Statifier.Send.Target`,
mirroring `Statifier.Invoke.Source` (ADR-0038).** (Research open question
2, settled.) `Statifier.Session.Target`'s namespace says "session
concern", which stops being true the moment the core calls it. The module
stays one pure module with the same functions; `Statifier.Session.Effects`
keeps calling it for its own arms. Whether `supported_invoke_type?/1`
travels with it or stays behind is implementation detail.

**4. The session planner's `{:invalid, _}` and unsupported-type arms stay -
they are a boundary check, not dead code.** `Session.interpret/2` is public
(ADR-0029): an embedder can hand the session effects no core drive
produced, and those effects never passed the core's check. The planner's
arms are the only validity gate on that path. The two sites apply one
shared classifier (decision 3), so they cannot drift.

**5. The supported-type set stays static, so 6.2.5's check may run in the
core.** (Research open question 1, settled for now.) This engine implements
exactly one Event I/O Processor; `supported_type?/1` is a fixed three-way
string test with no deployment state behind it. The named reopen trigger:
an embedder-registrable processor-type set. If that lands, the 6.2.5 check
becomes deployment state and moves back to the boundary (or into a
caller-supplied capability), and this decision is re-argued in that record -
the 6.2.4 target check is unaffected either way.

That trigger has since fired for one half only. ADR-0051 makes the
`<invoke>` service-type set embedder-registrable and re-argues this decision
for `<invoke>` alone: the registered set becomes a caller-declared value on
`%MachineState{}`, so the check is deployment state that the core may still
read. The `<send>` 6.2.5 Event I/O Processor set is untouched - it remains a
fixed string test, and this decision stands unamended for it. Decision 4's
shared-classifier property is preserved on both sides.

**6. test496 - the liveness half - is explicitly deferred to its own bead
and its own record.** st-yizi fixes test159 (and keeps test332 green);
test496 stays red, outside the ratchet, until the follow-on lands. The
deferral is proportionality, not doubt that the bug is real: every viable
shape sits squarely on the ground ADR-0039 actually forecloses, and each
drags a surface this bug-fix bead should not decide in passing. The
follow-on record has to settle, at minimum:

- **The shape**: a route-resolution snapshot passed into `handle_event/2`
  (research shape C) versus a caller-supplied resolver in ADR-0030/0038's
  capability pattern (shape D). Suspending the macrostep at the `<send>`
  (shape E) is disfavored here as a steer, not a decision: its suspension
  point is mid-block, not the microstep boundary ADR-0012 constraint 1
  makes resumable, so it is the largest change with the least precedent.
- **Replay**: how the reachability answer is recorded. ADR-0034 re-drives
  the pure core with no session behind it, and ADR-0029's four-input tuple
  does not account for a fifth input; a snapshot is at least a recordable
  value, where a resolver's answers must be captured call by call.
- **ADR-0027's self-addressing carve-out**: the session resolves
  `sid == state.session_id` ahead of the registry today; a core-side
  reachability answer relocates that carve-out.
- **Staleness**: a snapshot is point-in-time truth that can go stale within
  one macrostep (a target session dying mid-block); the record must say
  what that means, noting the registry read itself is point-in-time truth
  regardless.
- **Whether `error.communication` aborts the block** (research open
  question 3): 4.9 speaks of an error raised while processing an element;
  a dispatch failure discovered asynchronously is arguably outside that
  window, and test496 passes either way - the follow-on picks a reading
  and writes it down.

## Consequences

- st-yizi implements decision 1 and 3-4: the check in
  `lib/statifier/machine/content/send.ex`, the module move to
  `lib/statifier/send/target.ex` (session callers re-aliased), the
  sendid-bearing fatal conversion in `lib/statifier/interpreter/content.ex`,
  and tests - test159 goes green and enters the ratchet via
  `mix test.baseline add`; test332 is the regression guard for the
  mint-before-reject ordering.
- ADR-0039's status line gains "amended in part by 0047"; its body stands
  as written, with this record as the scoping, per the convention ADR-0046
  describes. ADR-0003, ADR-0027, ADR-0035, and ADR-0036 need no edits:
  nothing here makes the core impure or registry-aware, the send counter's
  semantics are unchanged, and ADR-0036's mechanism is reused for a
  neighboring clause (6.2.4/6.2.5 beside 6.2.2), not rewritten.
- The session's `execution_error/1` arm becomes unreachable from
  core-produced effects and stays reachable from `interpret/2` batches
  (decision 4); its doc comment should say so, citing this record.
- A follow-on bead is filed for test496 carrying the five bullets of
  decision 6 as its record's agenda; until it lands, test496 remains a
  known-red mandatory test assigned to that bead, and nothing gates it out
  (ADR-0011 posture, unchanged).
- Known 5.10.1 gap, noted and not decided here: ADR-0036's
  argument-evaluation failures raise `error.execution` with no `sendid`
  even when the author wrote `id`. The sendid-capable conversion channel
  decision 1 introduces would serve a fix, but claiming that case belongs
  to a record that argues it against 6.2.2's discard semantics, not to this
  one in passing.
- What would reopen this record: an embedder-registrable Event I/O
  Processor set (decision 5's trigger), or the follow-on record choosing a
  shape for reachability that wants the static check somewhere other than
  `execute/2` - in which case that record supersedes this one's placement
  argument explicitly.
