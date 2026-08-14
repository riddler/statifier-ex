# ADR-0021: A failed donedata content expr yields no data

Status: accepted (2026-08-13)

This records a decision already made and already shipped (the st-af3.7
branch); it is written after the fact to move the argument from a code
comment into a standing record, and it changes no behavior. If review of
this record concludes the behavior is wrong, that is a new issue against
the behavior, not an edit here.

## Context

`<donedata>` supplies the `data` field of the `done.state.*` event a
`<final>` state raises (and of the terminal done outcome at top level).
One of its forms is `<content expr="...">`, whose expression is evaluated
at done time. The question is what the done event's `data` carries when
that evaluation fails.

The spec answers it twice, and the answers conflict. Section 5.6, on
`<content>` generally:

> When the SCXML Processor evaluates the `<content>` element, if the
> 'expr' value expression is present, the Processor MUST evaluate it and
> use the result as the output of the `<content>` element. If the
> evaluation of 'expr' produces an error, the Processor MUST place
> error.execution in the internal event queue and use the empty string as
> the value of the `<content>` element.

Read literally, a failed `<content expr>` under `<donedata>` would make
`_event.data` the empty string. But section 5.10.1, on the event
structure's `data` field specifically:

> The receiving SCXML Processor SHOULD reformat this data to match its
> data model, but MUST NOT otherwise modify it. If the conversion is not
> possible, the Processor MUST leave the field blank and MUST place an
> error 'error.execution' in the internal event queue.

"Leave the field blank" and "use the empty string as the value" name
different outcomes for the same field: in this engine's value space a
blank `data` field is `nil` (predicator's `undefined`), which is
distinguishable from `""` by the exact comparison the conformance suite
uses. The routing clause B.2.6 sides with the field-specific reading:

> When `<content>` is a child of `<donedata>`, the Processor MUST
> interpret its value as defined in B.2.8.1 _event.data.

and B.2.8.1's ladder has no empty-string-on-error rung.

The tie is broken by a mandatory W3C conformance test.
`test/scxml_tests/mandatory/content/test528_test.exs` is exactly this
document - `<content expr="return"/>` under `<donedata>`, where `return`
is unbound - and its pass path is guarded by
`cond="_event.data === undefined"`. That spelling is the W3C
`conf:emptyEventData` macro, recorded as a deliberate emission choice in
`tools/corpus/scxml_w3/exclusions.exs`, not a rewrite artifact. It passes
when `data` is `nil` and fails forever if `data` is `""`. The test's own
description string quotes 5.6's empty-string sentence, so the working
group published, as mandatory, a test whose assertion contradicts the
letter of the clause it cites - which is the strongest available evidence
of the intended semantics for the `<donedata>` context.

ADR-0002 makes deviations from the spec semantic bugs unless a comment
cites a mechanical reason. This deviation is semantic, not mechanical -
the engine could return `""` and chooses not to - so it needs a decision
record, not just the comment at the fold site where it first landed.

## Decision

**When the evaluation of `<content expr>` under `<donedata>` fails, the
interpreter raises `error.execution` and the done event carries no data:
`_event.data` is `nil` (predicator `undefined`), not the empty string
5.6 names.**

The site is `donedata/2` in `lib/statifier/interpreter/exit_entry.ex`,
whose `{:compiled, ...}` arm raises via `MachineState.raise_platform/4`
and returns `nil` donedata on failure. Three reasons, in order of weight:

1. **The mandatory test asserts it.** test528's
   `cond="_event.data === undefined"` only passes with `nil`. Following
   5.6's letter reddens a mandatory conformance test permanently.
2. **The field-specific clause beats the generic one.** 5.10.1 is
   normative about the event's `data` field; 5.6 is normative about
   `<content>`'s output generically, and `<content>`'s primary context
   in 5.6 is a payload handed to an external service, where an output
   value is required and `""` is the safe one. 5.6 itself says "the use
   of the `<content>` element depends on the context in which it
   occurs", and B.2.6 routes the `<donedata>` context to B.2.8.1's
   `_event.data` rules, which have no empty-string rung.
3. **`nil` is the shape of "no data" everywhere else in the engine.** A
   `<final>` with no `<donedata>` at all, and a `<donedata>` whose only
   `<param>` fails, both produce `nil` data. `""` would make the
   error path the one place "nothing" is spelled differently.

**Scope limit.** This decision reaches `<content expr>` under
`<donedata>` only. It says nothing about `<content>` under `<send>` or
`<invoke>`, which are not yet implemented: when they land they must
answer the 5.6 question for their own context rather than inherit this
answer, and the default expectation there is the opposite - 5.6's
empty-string rule applies unchanged to a payload bound for an external
receiver, because B.2.6 routes those contexts to the Event I/O Processor
and the platform, not to B.2.8.1.

## Consequences

- test528 passes, and stays passing under the regression ratchet.
- The engine knowingly violates the letter of one MUST in 5.6, in one
  scoped context, with the contradicting MUST in 5.10.1 and the mandatory
  test as the recorded justification. A conformance reader diffing this
  interpreter against 5.6 finds the answer here instead of re-deriving it
  from a code comment.
- The fold-site comment in `lib/statifier/interpreter/exit_entry.ex`
  cites this record instead of re-arguing the case inline, per ADR-0018's
  rule that ADR numbers are the durable citation form.
- Whoever implements `<content>` under `<send>` or `<invoke>` must
  decide the failure value for that context explicitly. If they conclude
  those contexts should also yield no data, that is an amendment to this
  record's scope limit, not a silent extension of it.
