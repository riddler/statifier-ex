# ADR-0031: A failed invoke argument evaluation aborts the invocation

Status: accepted (2026-08-15)

## Context

Spec 6.4, on `<invoke>` execution:

> When the `<invoke>` element is executed, if the evaluation of its
> arguments produces an error, the SCXML Processor MUST terminate the
> processing of the element without further action.

That MUST covers every argument an `<invoke>` element can carry: `type` or
`typeexpr`, `src` or `srcexpr`, `id` or `idlocation`, `namelist`, each
`<param>`'s `expr` or `location`, and `<content expr>`. "Terminate the
processing of the element without further action" names an outcome neither
5.6's generic empty-string rule nor ADR-0021's `nil`-donedata rule
addresses: there is no service instance to start, so there is no value to
hand it - the question those two answers "what value does a failed
argument contribute" does not arise here.

Spec 5.9.1 and 5.9.3 still require the standard error-events treatment.
5.9.1, on conditional expressions:

> If a conditional expression cannot be evaluated as a boolean value
> ('true' or 'false') or if its evaluation causes an error, the SCXML
> Processor MUST treat the expression as if it evaluated to 'false' and
> MUST place the error 'error.execution' in the internal event queue.

5.9.3, on value expressions generally:

> If a value expression does not return a legal data value, the SCXML
> Processor MUST place the error 'error.execution' in the internal event
> queue.

`<invoke>`'s arguments are location and value expressions in 5.9.2's and
5.9.3's sense, so a failure among them still raises `error.execution` on
the internal queue even though 6.4 abandons the invocation itself.
Appendix D's own comment on the invoke pass's post-processing re-check -
"Invoking may have raised internal error events and we iterate to handle
them" - confirms that this is the intended interaction rather than an
oversight in the pseudocode: invoking is expected to be able to raise, and
the loop that calls it is written to notice.

Two existing records carry scope limits shaped exactly like this question,
and both left it open on purpose. ADR-0021's Decision section, on a failed
`<content expr>` under `<donedata>`:

> **Scope limit.** This decision reaches `<content expr>` under
> `<donedata>` only. It says nothing about `<content>` under `<send>` or
> `<invoke>`, which are not yet implemented: when they land they must
> answer the 5.6 question for their own context rather than inherit this
> answer, and the default expectation there is the opposite - 5.6's
> empty-string rule applies unchanged to a payload bound for an external
> receiver, because B.2.6 routes those contexts to the Event I/O Processor
> and the platform, not to B.2.8.1.

ADR-0024's Decision section, on `<data src>` fetching:

> **Scope limit.** This decision covers `<data src>` only. `<assign>` has
> no `src` in this engine's surface today, and `<content>` fetching for
> `<send>`/`<invoke>` payloads, if ever implemented, must argue its own
> case - those sit at the effect boundary where a fetch may genuinely be
> expressible, so they do not inherit this answer.

Neither anticipated 6.4's clause. ADR-0021 expected `<content>` under
`<invoke>` to need its own 5.6 answer once implemented, on the assumption
an invocation happens and its content's value is at stake; 6.4 forecloses
that question for a *failed* argument by removing the invocation itself.
ADR-0024 expected `<content>` fetching for `<invoke>` to argue its own
case for whether the core dereferences a URI at all; that question still
needs an answer, and this record gives it while closing the other one.

## Decision

**A failure while evaluating any of an invocation's arguments -
`typeexpr`, `srcexpr`, `idlocation`, a `<param>`'s `expr` or `location`, a
`namelist` location, or `<content expr>` - raises `error.execution` via
`MachineState.raise_platform/4` with origin `{:invoke, state_index,
invoke_index}`, and produces no `Effect.Invoke` for that invocation.**

Sibling invocations of the same state are unaffected: 6.4's MUST is scoped
to "the element" - the one `<invoke>` whose argument failed - not to the
state's whole `invoke` list, so a state with two invocations where one's
`typeexpr` fails still emits an `Effect.Invoke` for the other.

**The core never dereferences `src` or `srcexpr`.** This record closes
ADR-0024's `<invoke>`-shaped scope limit: whether anything downstream
fetches the resolved URI, and under what security posture, is st-cmq.7's
call, exactly as ADR-0024's own Decision already routes an equivalent
question for `<data src>` to the embedder rather than the core.

This is a third answer to ADR-0021's open question, not the amendment its
own scope-limit paragraph anticipated. ADR-0021 expected a future
`<content>`-under-`<invoke>` record to choose between its `nil` and 5.6's
`""`; 6.4's clause makes that choice moot for the failure case specifically,
because a failed argument yields no invocation to contribute data to at
all. A successful `<content expr>` under `<invoke>` still needs 5.6's
value-versus-empty-string question answered when the invoke pass is
implemented (Phase 6 of the plan this record supports), but that is a
question about a value handed to a started service, not about the failure
path this record settles.

## Consequences

- Closes ADR-0021's and ADR-0024's `<invoke>`-shaped scope limits with a
  third answer - "no invocation at all" - rather than either record's own
  anticipated amendment. Neither record needs editing: both scope-limit
  paragraphs already deferred the `<invoke>` case explicitly, and this
  record is the deferred case's answer, cited from here rather than
  folded back into either original.
- A document with a state carrying several `<invoke>` elements, one of
  which has a failing argument, still starts every invocation whose
  arguments succeeded. The failure is per-element, matching 6.4's own
  wording ("the element") rather than per-state.
- The invoke pass's post-processing re-check (Appendix D's "Invoking may
  have raised internal error events and we iterate to handle them",
  ADR-0032's re-entry) is the mechanism that lets a failed argument's
  `error.execution` be handled inside the same `main_event_loop/1` call
  that raised it, rather than waiting for the next external event.
- `Statifier.Effect.Invoke`'s moduledoc and the invoke pass's
  implementation cite this record rather than re-arguing the case inline,
  per ADR-0018's rule that ADR numbers are the durable citation form.
- Whoever implements a *successful* `<content>` under `<invoke>` still
  owes 5.6's value-versus-empty-string question its own answer; this
  record settles only the failure path.
