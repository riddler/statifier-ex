# ADR-0036: A failed `<send>` argument discards the message

Status: accepted (2026-08-15)

## Context

`<send>` can carry several kinds of argument that need evaluation before the
message is dispatched: `eventexpr`, `targetexpr`, `typeexpr`, `delayexpr`,
`idlocation`, a `namelist` location, each `<param>`'s `expr` or `location`,
and `<content expr>`. The question is what happens to the message - and to
any effect the core would otherwise emit - when one of those evaluations
fails.

Spec 6.2.2 answers it at the element level, in the same paragraph that
governs `delay`:

> The Processor MUST evaluate all arguments to `<send>` when the `<send>`
> element is evaluated, and not when the message is actually dispatched. If
> the evaluation of `<send>`'s arguments produces an error, the Processor
> MUST discard the message without attempting to deliver it.

That MUST is unqualified: it covers every argument named above, `<content
expr>` included, with no attribute-by-attribute carve-out.

Spec 5.6.2, on `<content>` generally, answers what looks like the same
question differently:

> If the evaluation of 'expr' produces an error, the Processor MUST place
> error.execution in the internal event queue and use the empty string as
> the value of the `<content>` element.

Read on its own, a failed `<content expr>` under `<send>` would make the
message's content the empty string and still dispatch it. That collides with
6.2.2's "discard the message without attempting to deliver it" for the exact
same failure. 5.6.2 resolves its own generality two sentences earlier, in the
same section:

> The use of the `<content>` element depends on the context in which it
> occurs. See 5.5 `<donedata>`, 6.2 `<send>` and 6.4 `<invoke>` for details.

5.6.2's empty-string rule is the generic default for a context with no rule
of its own. `<send>` has one - 6.2.2's element-level discard - and 5.6.2
points at 6.2 by name as the place to look. 6.2.2 wins for the same structural
reason ADR-0021 already used to prefer a field-specific clause over 5.6's
generic one, and ADR-0031 used to prefer 6.4's element-level MUST over 5.6 for
`<invoke>`: a clause written for this exact element beats a clause written for
`<content>` in general.

The same argument resolves the adjacent `<param>` question. Spec 5.7 says a
failed `<param>` evaluation causes the Processor to "ignore the name and
value" - a per-`<param>` rule that `<donedata>` implements
(`lib/statifier/interpreter/exit_entry.ex:1074`). But 6.2.2's discard is
element-level and specific to `<send>`'s context, exactly as 6.4's discard is
specific to `<invoke>`'s. `<invoke>` resolved the identical 5.7-versus-6.x
collision the identical way in ADR-0031, whose `resolve_params/2` halts on
first failure rather than skipping the failed pair
(`lib/statifier/interpreter.ex:1329-1342`). ADR-0031 is precedent for the
resolution method here, not authority over `<send>`'s own case: `<send>` has
its own controlling clause (6.2.2), just as `<invoke>` has its own (6.4).

ADR-0021 covers `<content expr>` under `<donedata>` only, and reads its own
scope limit forward explicitly:

> This decision reaches `<content expr>` under `<donedata>` only. It says
> nothing about `<content>` under `<send>` or `<invoke>`, which are not yet
> implemented: when they land they must answer the 5.6 question for their own
> context rather than inherit this answer, and the default expectation there
> is the opposite - 5.6's empty-string rule applies unchanged to a payload
> bound for an external receiver ... If they conclude those contexts should
> also yield no data, that is an amendment to this record's scope limit, not
> a silent extension of it.

`<send>` lands on "no data" too, by a different route than `<donedata>` did -
not because `_event.data`'s blank-field clause outranks 5.6 here, but because
6.2.2's own discard MUST removes the message before 5.6's empty-string rung
would ever apply. That is an amendment to ADR-0021's scope limit, recorded
here as this decision states it, not silently folded into that record's own
reasoning.

## Decision

**A failure while evaluating any of `<send>`'s arguments - `eventexpr`,
`targetexpr`, `typeexpr`, `delayexpr`, `idlocation`, a `namelist` location, a
`<param>`'s `expr` or `location`, or `<content expr>` - raises
`error.execution` and discards the message: `execute/2` returns `{:error,
reason}`, the block runner converts it to `error.execution` (its sole such
site), and no `Effect.Send` or `Effect.SendDelayed` is produced for that
`<send>`.**

The first failing argument stops evaluation of the rest, mirroring
`resolve_params/2`'s halt-on-first-failure shape for `<invoke>`. There is no
partial message: 6.2.2's "discard the message" names an all-or-nothing
outcome, not a message assembled from whichever arguments happened to
succeed.

**`<param>` under `<send>` follows 6.2.2's discard, not 5.7's ignore.** A
failed `<param>` aborts the whole `<send>`, exactly as a failed `<content
expr>` does, because both are arguments 6.2.2's MUST covers without
distinction.

**The empty-string value 5.6.2 names is never constructible under `<send>`.**
Every path that would reach it - a failed `<content expr>`, specifically - is
intercepted by 6.2.2's discard first. This is the decision's outcome, not an
omission: `<send>` never dispatches a message whose content evaluation
failed, so there is no surviving message for an empty string to be the value
of.

**Scope.** This record covers `<send>` only. `<invoke>` already has its own
answer in ADR-0031. Neither record claims `<content>` under any future
element; each element that carries `<content>` answers the 5.6 question for
its own context, per ADR-0021's own instruction.

## Consequences

- `docs/adr/0021-donedata-content-expr-failure-yields-no-data.md` gets a
  one-sentence pointer under its scope limit recording that `<send>`
  answered the deferred question here, and how. That record's own reasoning
  and `<donedata>` decision are unchanged.
- `Statifier.Effect.Send` and `Statifier.Effect.SendDelayed`'s moduledocs
  cite this record for the argument-failure path, rather than re-arguing the
  case inline, per ADR-0018's rule that ADR numbers are the durable citation
  form.
- A `<send>` with a failing `namelist` location or a failing `<param>`
  produces the same outcome as one with a failing `<content expr>`: one
  `error.execution`, no effect. Nothing about which argument failed changes
  the outcome, matching 6.2.2's undifferentiated "arguments" wording.
- Whoever implements a *successful* `<content>` under `<send>` still owes 5.6
  and 6.2.3's "pass the resulting data to the external service" their own
  resolution; this record settles only the failure path.
