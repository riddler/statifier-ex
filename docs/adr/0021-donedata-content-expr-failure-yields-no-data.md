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

`<send>` has since answered this for its own context: ADR-0036 finds that a
failed `<content expr>` under `<send>` also yields no data, but by 6.2.2's
element-level discard rather than by this record's `_event.data`-blank-field
reasoning - the message is discarded before 5.6's empty-string rung would
apply at all.

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

## Note (2026-09-02): the failure gets an observable channel on `Effect.Done`

A dated note rather than an amendment. The decision above is untouched: a
failed `<donedata>` expression still yields no data, `_event.data` is still
`nil`/`:undefined`, and test528 still passes for the reason recorded. What
this note settles is a *residue* the decision left behind, in a place that
did not exist when it was written, so no accepted text is edited and the
record's Status is unchanged. The shape follows the family convention (a
dated `## Note` heading, no Status line of its own).

### The residue

The decision fixed the value. It did not fix the **observability** of the
failure, because at the time the raised `error.execution` survived on the
returned state's internal queue and was diagnosis enough.

`Statifier.Interpreter.exit_interpreter/1` then grew item 7, an ADR-0002
mechanical deviation that discards the internal queue last of all so a
`status: :done` machine state is quiescent by construction and
`Statifier.Position.export/1` will accept it. That discard runs *after* the
exit walk, so it takes the donedata raise with it. The consequence is stated
in that function's own doc item 5: the returned terminal state does not show
the event, and nothing else in the run does either, because the event loop
has already stopped and no reader is left to dequeue it.

That leaves `Effect.Done`'s `donedata: :undefined` as the only remaining
signal, and it is not a signal at all - it is the *same* value a bare
`<final>` with no `<donedata>` produces. A host reading the effect stream
cannot tell "this chart declared donedata and its expression failed" from
"this chart declared none", which are very different facts about a run.
Giving the failure an effect of its own was explicitly out of reach for
`exit_interpreter/1` alone: it is an effect-vocabulary change.

### The decision

**`Statifier.Effect.Done` gains `donedata_error`, and
`Statifier.Effect.Trace.Done` mirrors it.** The field is `nil` when the
donedata resolved cleanly and `nil` for a bare final that declared none;
otherwise it carries the `data` of the `error.execution` the resolution
raised - in practice the `%Statifier.Evaluator.Error{}` that
`Statifier.Interpreter.ExitEntry.donedata/2` passes to
`MachineState.raise_platform/4`. The two `:undefined`s are now distinct, and
the discard costs no diagnostic.

Four properties are part of the decision rather than of the implementation:

1. **Additive only.** No existing field changes meaning, `donedata` keeps
   the value this record's Decision fixed, and no raise site moves. A
   consumer that ignores the new field sees exactly what it saw before.
2. **An observation, not a new path.** `exit_interpreter/1` reads the
   internal queue either side of its `donedata/2` call and attributes only
   what that call appended. `donedata/2` does not grow a second return
   value, and `raise_platform/4` remains the single way a donedata failure
   is signalled. The alternative - threading an error out of every arm of
   `donedata/2` - would have put the same fact in two places and invited
   them to disagree.
3. **The window is a diff, not a scan.** An `error.execution` from an
   earlier `<onexit>` block, or a `done.state.*` the stopped loop never
   dequeued, is routinely still queued when the exit walk begins.
   Attributing one of those to the final's donedata would be worse than the
   gap this note closes: a bare final would report someone else's failure as
   its own.
4. **Several failures carry the first, in document order.** A `<donedata>`
   whose `<param>`s each fail raises one `error.execution` per failure
   (spec 5.7's "MUST ignore the name and value" keeps the fold going rather
   than aborting it). The field is singular and carries the first; the rest
   go with the queue exactly as they did before. A list was rejected as a
   shape that would make the common single-failure case pay for the rare
   one, and that would be a wider contract than the observability gap
   justifies.

### The format consequence

`%Statifier.Effect.Done{}` and `%Statifier.Effect.Trace.Done{}` gaining a
defstruct key changes the shape of structs a recording blob can hold. Both
are performable effects a host may hand to `Statifier.Session.interpret/2`
(`Statifier.Session.Effects.plan_one/2` has clauses for `{:done, _}` and
`{:trace, _}`), and `Statifier.Session.Recording.put_interpret/3` stores an
`interpret/2` batch verbatim - so a blob written before this note can hold
copies of either without the key, and reading such a map as the new struct
is the silent misread ADR-0057 decision 4's obligation names.

`Statifier.Session.Recording`'s `@format_version` therefore bumps `4 -> 5`,
and this note blesses the same default ADR-0063 decision 5 blessed for its
own two bumps: the decoder reads version-4 blobs and defaults
`donedata_error: nil` onto each stored done effect on import, which is safe
exactly because a version-4 blob predates the field - no run it holds could
have reported one. Versions 1 through 4 stay readable.

`Statifier.Position` and `Statifier.Chart` are untouched: a position is
written at quiescence and holds no effects, and the chart did not change
shape.

### Consequences

- A host distinguishing a failed donedata from an absent one reads
  `donedata_error`, not `donedata`.
- Downstream, `statifier_persistence`'s donedata-failure handling asserts
  `donedata: :undefined` and keeps passing unchanged; the new field is
  available to it but not required. `statifier_blocks` pins `:undefined` for
  a bare final and is unaffected.
- What would reopen this note: a caller that genuinely needs every error
  from a multi-`<param>` failure rather than the first, which would be an
  argument about property 4's shape and would have to say what it does with
  the set that the first does not give it.
