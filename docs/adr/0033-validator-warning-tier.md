# ADR-0033: The validator gets a warning tier

Status: accepted (2026-08-15)

## Context

`Statifier.Validator.validate/2` has exactly two shapes today:
`{:ok, Document.t()}` when every check passes, or `{:error, [Error.t()]}`
when at least one does not (`lib/statifier/validator.ex`). `Error` itself
(`lib/statifier/validator/error.ex`) is a closed, 41-variant tagged-tuple
union with one public constructor per variant - every member of that union
is a spec MUST the document violated, and every violation refuses the
document outright. There is no severity axis anywhere under
`lib/statifier/validator/`: a finding either blocks compilation or it does
not exist.

That shape was a deliberate decision, not an oversight. When the validator
was designed (`docs/plans/260808-st-l5k.5-document-validator.md`, Decision
4), the record settled on errors only, no warnings, because every check
enforced a spec MUST and a warning channel would have had zero producers -
API with no caller is speculative API. The same decision named the escape
hatch a future producer would use: the struct's shape makes adding a
second channel later purely additive - a third element on `validate/2`'s
return, or a second finding list, needs no change to any existing reason.
`docs/plans/260812-st-t8w-idless-compound-final-validator.md` reaffirmed
the errors-only posture on the same grounds.

Spec 6.5.2 gives that hatch its first producer. Quoted verbatim from the
local spec cache (`scxml-rec.html`, the paragraph immediately following the
6.5.2 "Children" clause):

> In a conformant SCXML document, the executable content inside
> `<finalize>` MUST NOT raise events or invoke external actions. In
> particular, the `<send>` and `<raise>` elements MUST NOT occur.

The sentence is a MUST NOT, but it is addressed to the document, not to the
processor: it tells an author what a conformant document looks like, the
same way 4.3.2's "`<else>` MUST occur after all `<elseif>` tags" does. It is
not one of 5.9's processor-facing MUSTs (validate, reject, raise
`error.execution`) that name what the engine itself is obliged to do on
encountering a violation. Refusing the whole document for a rule stated to
its author is a stronger response than the clause asks for, and the engine
already has a defined, spec-conformant behavior for the content the rule
forbids - `<raise>` lowers, compiles, and executes inside `<finalize>` like
any other executable content (`lib/statifier/interpreter.ex`). An
error-only validator has only one lever for a MUST like this: refuse the
document. This tier is the second lever.

## Decision

`Statifier.Validator.Warning` is a new struct, not a `severity` field
folded onto `Error`. It mirrors `Error`'s enforced three-field shape
(`reason`, `message`, `location`), keeps its own closed `reason` union
disjoint from `Error`'s, and gets its own `code/1` tag extractor and one
public constructor per variant. `Error`'s own moduledoc already states that
it and `Lowering.Error` share a *shape*, not a type, precisely so a later
diagnostic struct can join the family without either layer's reason union
leaking into the other's; `Warning` is that later member. A `severity`
field on `Error` was rejected: it would make `{:error, errors}`
structurally capable of holding non-errors, and it would put a severity
judgment at each of `Error`'s constructors rather than at the one place
that actually needs it.

`validate/2` returns three elements on both arms:

```
{:ok, Document.t(), [Warning.t()]} | {:error, [Error.t()], [Warning.t()]}
```

Both arms carry warnings, including the error arm. The validator's own
collect-all-never-fail-fast contract applies to both channels equally:
dropping warnings whenever an error also fires would make the warning
channel fail-fast against the error channel, which is not a rule either
channel asks for on its own. Uniform arity also means no caller can
pattern-match one arm's shape and silently miss the payload on the other.

Warnings ride to the caller on `Statifier.Machine.warnings`, a plain
`defstruct` default of `[]`, not an enforced key. `Statifier.compile/1`
stamps the validator's warnings onto the machine it builds; its `@spec`
stays `{:ok, Machine.t()} | {:error, [error()]}`, unchanged. This follows
the retained-diagnostics precedent ADR-0012 item 3 already set for
locations on states, transitions, and executable content: a warning is a
diagnostic with a location, and the Machine is where this project already
keeps those. It also keeps `compile/1` - one of the four functions of the
public surface - returning the same shape it always has; a defaulted field
is additive, so every existing caller compiles and runs unchanged.

The field is the whole surfacing seam. There is no trace effect, no
`Logger` call, no `:telemetry` event, and no formatter for a validator
finding. `validate/2` returns the list, `compile/1` copies it onto the
field, and that is the channel end to end. ADR-0012's seams are all
interpreter- and Machine-side; a validator finding is produced before a
Machine exists and has no `MachineState` to gate a trace effect on, so none
of those seams reach here, and nothing in `lib/` renders a validator
finding today that a second channel would need to feed.

## Consequences

Every existing check keeps its pass/reject behavior exactly as it was: no
reason moves from `Error`'s union to `Warning`'s, and no check that used to
refuse a document now merely warns about it. The tier is additive capacity,
not a reclassification of what is already there.

`:strict` (warnings-as-errors) is still unassigned to any caller. Before
this record, `validate/2` had no options argument and only one possible
severity, so a strict switch would have been API built for a caller that
did not exist. The three-element return makes the choice a one-line
decision at any call site - collapse `warnings` into the error path, or
don't - without `validate/2` itself growing an argument to make that choice
for every caller.

`<send>` inside `<finalize>` is 6.5.2's other named instance, and it is not
reachable by this tier yet: `<send>` is not representable in a lowered
`Document` at all, so any `<send>` anywhere in a document, `<finalize>`
included, is already a hard lowering error before the validator runs. That
is a stronger response than a warning, and it is correct while `<send>` is
unimplemented engine-wide. When `<send>` becomes a lowered content node,
`Statifier.Validator.Checks.Invoke` - the check this warning's one producer
lives in - is its home: one additional clause in the same walk, no new
reason tag, because the reason this record settles on is the general rule
("forbidden content inside `<finalize>`", carrying the offending element's
name as data) rather than one tag per element name.

A document that trips this warning still compiles to a `Machine` exactly
as it would have without the finding - the whole point of a tier that does
not gate. `Machine` being valid by construction is a statement about the
Machine's own type, not about the source document's spec conformance, and
this record does not touch that property: a warning describes the
document, and the document still lowers, validates past the error checks,
and compiles.
