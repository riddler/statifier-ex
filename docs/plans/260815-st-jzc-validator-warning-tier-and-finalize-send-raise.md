---
date: 2026-08-15
researcher: Claude
git_commit: b52208e6f8d1aaa1be70427b803fa97d0a4f6824
branch: st-jzc-validator-warning-tier
repository: statifier-ex
beads_issue: st-jzc
topic: "The validator's warning tier, and 6.5's send/raise ban in <finalize>"
tags: [plan, validator, invoke, finalize, observability]
status: draft
last_updated: 2026-08-15
last_updated_by: Claude
---

# Validator warning tier, and 6.5's send/raise ban in `<finalize>` Implementation Plan

## Overview

Give `Statifier.Validator` a second, non-fatal finding channel - a warning
tier - and put spec 6.5.2's ban on event-raising executable content inside
`<finalize>` on it, so a nonconformant document is told about rather than
refused. Bead: st-jzc.

Two things land, and the first is the larger: a `Statifier.Validator.Warning`
struct with its own closed reason union, a warning-check list beside the
existing error-check list, a uniform three-element return from `validate/2`,
and a `warnings` field on `Statifier.Machine` so the finding survives to the
caller of `Statifier.compile/1`. On top of that, `Checks.Invoke` gains a
`warn/2` that walks each `<invoke>`'s `finalize` block and reports forbidden
content.

## Current State Analysis

**There is no severity axis anywhere in `lib/statifier/`.**
`Statifier.Validator.Error` (`lib/statifier/validator/error.ex:75-82`) is
exactly three enforced fields - `reason`, `message`, `location` - over a closed
41-variant `reason` union (`error.ex:33-73`), one public constructor per
variant. `Statifier.Validator.validate/2`
(`lib/statifier/validator.ex:87-99`) flat-maps 18 captured `check/2` closures,
sorts by `location.start_offset`, and returns `{:ok, document}` only when the
list is empty. No branch anywhere produces anything but `{:error, errors}` from
a constructed `Error`.

**The absence is a recorded decision, not an oversight.** Decision 4 of
`docs/plans/260808-st-l5k.5-document-validator.md:296-314` settled "errors only,
no warnings" because every check was a spec MUST and a warning channel would
have had zero producers. The same decision named the escape hatch this bead
uses: "Decision 3's struct shape makes adding a channel later purely additive -
a `{:ok, document, warnings}` arm or a second list needs no change to any
existing reason." `docs/plans/260812-st-t8w-idless-compound-final-validator.md`
reaffirmed it; `docs/plans/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md:187-191`
deferred the 6.5 check for exactly this reason. This plan does not re-argue
that lineage; it exercises the hatch the lineage named.

**Blast radius.** One production call site pattern-matches `validate/2`:
`lib/statifier.ex:62`, a `with` clause inside `Statifier.compile/1`. 74 test
call sites across 60 files match it, roughly 55 of them
`{:ok, document} = Validator.validate(document, xml)` fixture setup in tests
that are not about validation at all. Nothing in `lib/` renders a validator
finding; the repo's only formatter is `format_errors/1` at
`test/support/case.ex:184`, reached from `parse_document/1` (`case.ex:160-165`),
which consumes `Statifier.compile/1` rather than `validate/2` directly.
`Statifier.compile/1`'s `{:ok, Machine.t()}` has no room for a warning today
(`lib/statifier.ex:58`).

**Only half of 6.5 is checkable today.** `<raise>` is a first-class
`Document.content_node()` (`lib/statifier/document.ex:99-100`) and lowers,
compiles, and executes inside `<finalize>` right now
(`lib/statifier/interpreter.ex:641-670`). `<send>` has no
`Statifier.Document.Send` module and no entry in lowering's dispatch map
(`lib/statifier/lowering.ex:53-78`), so a `<send>` anywhere - inside
`<finalize>` included - is already a hard lowering error,
`{:unsupported_element, "send"}` (`lowering.ex:149-155`,
`lib/statifier/lowering/error.ex:44-50`), before the validator ever runs.

**`<finalize>` is an ordinary `%Document.Block{}`.**
`Document.Invoke.finalize` is `Block.t() | nil`
(`lib/statifier/document/invoke.ex`, `finalize` field), `nil` meaning no
`<finalize>` child and `%Block{content: []}` meaning a written but childless
one. `Checks.Invoke.check/2` already walks every `<invoke>` in the document
(`lib/statifier/validator/checks/invoke.ex:36-41`) but never descends into
`finalize.content`.

**ADR-0012's seams do not reach the validator.** Every row of
`docs/observability.md`'s seam table names `MachineState`, `Interpreter`,
`Effect`/`Effect.Trace.*`, `Compiler`/`Machine.State`/`Transition`/`Content`,
`Event.Cause`, or the `Interpreter.*` query modules. The validator runs before a
Machine exists, returns a value rather than emitting effects, and appears in
neither ADR-0012 nor `docs/observability.md`.

## Desired End State

After this plan:

1. `Statifier.Validator.Warning` exists: three enforced fields
   (`reason`, `message`, `location`) mirroring `Validator.Error`'s shape
   character for character, with its own closed `reason` union, one public
   constructor per variant, and a `code/1` tag extractor. Exactly one variant
   exists: `{:finalize_forbidden_content, element :: binary()}`.
2. `Statifier.Validator.validate/2` returns
   `{:ok, Document.t(), [Warning.t()]} | {:error, [Error.t()], [Warning.t()]}` -
   uniform arity on both arms, so no caller can match one shape and miss the
   other. The error arm still carries warnings, because contract 1
   (collect-all, never fail-fast) applies to both channels.
3. `Statifier.Validator.Checks.Invoke.warn/2` walks each `<invoke>`'s
   `finalize` block, descending through `<if>` branches and `<foreach>` bodies,
   and reports one warning per forbidden node found, at that node's own
   location.
4. `Statifier.Machine` carries `warnings: [Validator.Warning.t()]`, defaulting
   to `[]`, and `Statifier.compile/1` stamps the validator's warnings onto the
   machine it returns. `compile/1`'s `@spec` is unchanged.
5. `docs/adr/0033-*.md` records the decision; `docs/adr/README.md`,
   `docs/architecture.md`, `docs/observability.md`, and `Statifier.Validator`'s
   own moduledoc all say the tier exists.
6. Existing checks' pass/reject behavior is byte-for-byte unchanged: no reason
   moves from `Error` to `Warning`, and the 18-entry `@checks` list is
   untouched.

**How to verify the end state**: a document with `<raise>` inside `<finalize>`
compiles to a `%Machine{}` whose `warnings` list holds one
`{:finalize_forbidden_content, "raise"}` warning at the `<raise>`'s own line,
and the same document without the `<raise>` compiles to a machine with
`warnings: []`. Full `mix quality` is green, and `mix gate.verify` attests the
run was a full gate.

### Key Discoveries:

- `lib/statifier/validator.ex:87-99` - `validate/2`'s flat-map/sort/case body,
  the single place a second channel plugs in.
- `lib/statifier/validator/error.ex:4-10` - the moduledoc already establishes
  that `Validator.Error` and `Lowering.Error` share a *shape*, not a type, so a
  future common diagnostic protocol can adopt both. A third struct in that
  family is the established move, not a new idea.
- `test/statifier/validator/layer_test.exs:125-155` - AST-walks `error.ex` and
  `checks/*.ex` to assert one constructor per reason tag and one producer per
  tag. It reads `@error_source "lib/statifier/validator/error.ex"` and matches
  `Error.<fun>` calls specifically, so a `Warning` module and `Warning.<fun>`
  calls neither satisfy nor break it - a sibling test is needed.
- `lib/statifier/validator/checks/script.ex:86-92` - the `descend/1` recursion
  through `%DIf{branches:}` and `%DForeach{content:}`, the walk to model. Three
  identical copies already exist (`assign.ex:97-103`, `if.ex:95-102`); this
  plan adds a fourth rather than extracting a shared one, matching the repo's
  existing per-file duplication.
- `lib/statifier/machine.ex` - `@enforce_keys` does not include
  `global_scripts`, which is a plain `defstruct` default. `warnings: []` joins
  it the same way, so no existing `%Machine{}` construction site changes.
- `.doctor.exs` holds 100% thresholds on every axis, so every new module,
  public function, and struct needs `@moduledoc`, `@doc`, `@spec`, and a struct
  `@type`.
- `lib/mix/statifier/adr_guard.ex` (ADR-0018 check) flags a bead id added in
  any comment or doc under `lib/` or `test/`, and only `ADR-0018-exempt`
  clears it. No new doc or comment may say "st-jzc"; cite the spec clause or an
  ADR number instead.
- Spec 6.5.2, quoted from the local cache
  (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html:4424-4429`):
  "In a conformant SCXML document, the executable content inside `<finalize>`
  MUST NOT raise events or invoke external actions. In particular, the `<send>`
  and `<raise>` elements MUST NOT occur." The MUST NOT is on the behavior;
  the two element names are the named instance.

## What We're NOT Doing

- **No existing check is reclassified.** The research document's table
  (`docs/research/260815-st-jzc-validator-warning-tier-and-finalize-send-raise.md`,
  "which checks reject what the engine could run past") lists roughly 20 reasons
  across 11 checks whose documents the interpreter could physically execute.
  None moves. The bead's acceptance criteria say existing pass/reject behavior
  is unchanged, and several of those reasons exist *only* because lowering
  deliberately declined to refuse the shape - reclassifying them re-opens which
  layer holds the line, which is the question ADR-0026 answered case by case and
  is a direction-level call rather than a side effect of adding a tier. The
  table stays available as the input to a future bead.
- **No `:strict` option.** `docs/plans/260808-st-700-relaxed-parsing-options.md:29`
  assigns warnings-as-errors to the validator, and it is still homeless after
  this plan. `validate/2` has no options argument today; adding one to serve a
  hypothetical caller is the same speculative API the founding Decision 4
  declined. The uniform three-tuple makes warnings-as-errors a one-line
  decision at any call site, which is the point of returning them as data.
  Recorded in ADR-0033's Consequences so it does not go quiet.
- **No `<send>`-specific arm, and no new lowering refusal.** `<send>` is not
  representable in a lowered `Document`, so a `%Document.Send{}` clause in the
  walk would be dead code the coverage gate cannot exercise. The check's
  forbidden set is stated as a set with one member today; `Checks.Invoke`'s
  moduledoc names `<send>` as the member that joins it when `<send>` lands.
- **No trace effect, no `Logger`, no `:telemetry`, no formatter.** See
  Decision 7 below.
- **No change to `test/support/case.ex` or any corpus test.** Because warnings
  ride on a `Machine` field rather than a third element of `compile/1`'s return,
  `parse_document/1` and `test_scxml/4` keep their current shapes. A
  warning-producing document still compiles and still runs.
- **No change to `test/passing_tests.json`'s format or to
  `mix test.regression`.** The ratchet reads exit status only
  (`lib/mix/tasks/test.regression.ex:90,96-100`); its `internal_tests` globs
  pick up new test files automatically.
- **No corpus regeneration.** `tools/corpus/` never calls `Statifier.compile/1`
  or `Validator.validate/2`.

## Implementation Approach

Four phases. Phase 1 is documentation-only and records the direction the other
three implement. Phase 2 builds the tier and its one producer in a single
commit, because a `Warning` struct with no producer would be uncovered code and
a producing check with no channel could not be wired - neither is green alone.
Phase 3 carries the warning past the compiler boundary to the caller. Phase 4
is the surrounding documentation and the changelog fragment.

The seven questions the research document left open are settled below. Each is
a decision this plan makes, not a question it forwards.

### Decision 1: the check reports the general rule, with the element as payload

**Settles research open questions 1 and 2.**

The reason tag is `{:finalize_forbidden_content, element :: binary()}` - one
variant, carrying the offending element's name as data, the way
`{:duplicate_id, id}` carries an id. The `@doc` quotes 6.5.2's sentence in full
so the general reading ("MUST NOT raise events or invoke external actions") is
what a reader finds, with `<send>` and `<raise>` named as its instance.

Rationale: a tag per element name would multiply the reason union every time a
new element becomes representable inside a block, and the spec's normative
sentence is not about two names. A payload-carrying general tag admits `<send>`,
and a nested `<invoke>` if one ever becomes a `content_node()`, without
reopening the union - which is exactly what `error.ex:12-15`'s "later additions
add a constructor per reason rather than reopening the type" discipline asks
for.

The forbidden set today is `{%Document.Raise{}}`, one member, because `<send>`
cannot appear in a lowered `Document` at all (`lowering.ex:53-78` has no
`"send"` key). `<send>` inside `<finalize>` is therefore already reported, as a
hard lowering error - a stronger response than a warning, and correct while
`<send>` is unimplemented engine-wide. When `<send>` lands and becomes a
`content_node()`, this check is its home: one `%Document.Send{}` clause in the
walk, no new reason tag, no ADR. `Checks.Invoke`'s moduledoc states that
obligation so the `<send>` implementer finds it. The alternative - ADR-0026's
move of putting the rule in the `<send>` builder - is rejected here because
this rule is contextual (`<send>` is legal everywhere except under
`<finalize>`), and a builder does not know its ancestor.

### Decision 2: a separate `Warning` struct, not a `severity` field on `Error`

**Settles research open question 4.**

`Statifier.Validator.Warning` is a new module mirroring `Validator.Error`'s
three-field shape with its own closed `reason` union.

Rationale, in order of weight:

1. `error.ex:4-10` already states the pattern: two diagnostic structs share a
   *shape* with character-identical field names so a future common protocol can
   adopt both "without either layer's reason union leaking into the other's."
   A third member of that family is the established move.
2. A `severity` field on `Error` would make `{:error, errors}` structurally
   capable of containing non-errors, and would put a severity decision at each
   of 41 constructors - 41 places to get it wrong, for a distinction only one of
   them uses.
3. `test/statifier/validator/layer_test.exs`'s one-reason-one-constructor
   invariant over `error.ex` stays untouched and keeps meaning what it says. A
   sibling test asserts the same invariant over `warning.ex`.
4. `lib/statifier/machine_state.ex:325-330` records the repo's one stated
   preference on this shape: `trace` is "a plain boolean, not a level... a
   later level would arrive as a separate field so this one never turns into a
   comparison." A separate struct is that preference applied to a struct.

### Decision 3: `validate/2` returns three elements on both arms

**Settles research open question 3, first half.**

```elixir
@spec validate(document :: Document.t(), source :: binary()) ::
        {:ok, Document.t(), [Warning.t()]} | {:error, [Error.t()], [Warning.t()]}
```

Both arms carry warnings. Rationale: contract 1 in the validator's moduledoc is
collect-all, never fail-fast, and dropping warnings when an error fires would
make the warning channel fail-fast against the error channel. Uniform arity also
means no caller can pattern-match one arm and silently miss the payload on the
other - the failure mode the research document flagged at `lib/statifier.ex:62`,
where a mismatched arity falls through a `with` and becomes the function's
return value.

This is the shape the founding Decision 4 named as the additive hatch, so this
plan takes the lineage's own answer rather than inventing a fourth.

Cost, stated plainly: 74 test call sites change, roughly 55 of them the purely
mechanical `{:ok, document} = ` becoming `{:ok, document, _warnings} = `. That
churn lands in one commit in Phase 2, and it is the honest price of the tier
being visible to every caller rather than reachable only through a second
function.

Rejected alternative: keeping `validate/2` at two elements and adding a separate
`Validator.warnings/2`. It builds `Context` twice per compile, splits one
traversal into two public functions that must be kept in sync, and hides the
tier from every existing caller - which makes the churn look smaller by making
the feature quieter.

### Decision 4: warnings ride to the caller on `Machine.warnings`

**Settles research open question 3, second half: yes, a warned document still
compiles.**

`Statifier.Machine` gains `warnings: [Validator.Warning.t()]`, a plain
`defstruct` default of `[]`, not in `@enforce_keys`.
`Statifier.compile/1` threads them:

```elixir
def compile(source) when is_binary(source) do
  with {:ok, root} <- parse(source),
       {:ok, document} <- Lowering.lower(root),
       {:ok, document, warnings} <- Validator.validate(document, source),
       {:ok, machine} <- Compiler.compile(document) do
    {:ok, %Machine{machine | warnings: warnings}}
  end
end
```

`compile/1`'s `@spec` is unchanged: `{:ok, Machine.t()} | {:error, [error()]}`.

Rationale:

- ADR-0012 item 3 already puts retained diagnostics on the Machine - locations
  on states, transitions, and executable content, span tables on compiled
  expressions. A warning is a diagnostic with a location; the Machine is where
  this project already keeps those.
- `compile/1` is one of the four functions of the public surface (ADR-0006). A
  third tuple element there would change the return of the most-called function
  in the library for a payload most callers ignore, and would churn
  `test/support/case.ex` and every direct caller. A defaulted field is
  additive: existing code compiles and runs unchanged.
- The Machine stays valid by construction (`docs/architecture.md` principle 4).
  A warning is a statement about the *document*'s conformance, not about the
  Machine's validity - the whole point of the tier is that the document
  compiles.
- The field is where a debugger or an embedder would look, and it survives as
  long as the machine does, unlike a value returned once and discarded.

Rejected alternative: `{:ok, Machine.t(), [Warning.t()]}` from `compile/1`. It
buys nothing the field does not, and costs every caller.

### Decision 5: no existing check is reclassified

**Settles research open question 5.** Stated in full under "What We're NOT
Doing" above. The short form: the bead's acceptance criteria forbid it, and
several candidate reasons exist only because lowering deliberately declined to
refuse the shape, so moving them re-opens a layering question rather than
flipping a label.

### Decision 6: `:strict` does not land here

**Settles research open question 6.** Stated under "What We're NOT Doing". The
short form: with one producer and no options argument on `validate/2`, a
warnings-as-errors switch is API for a caller that does not exist, and the
three-element return makes it a one-line decision at any call site. ADR-0033's
Consequences records that the option is still unassigned.

### Decision 7: one surfacing seam, and it is the `Machine.warnings` field

**Settles research open question 7.**

No trace effect, no `Logger`, no `:telemetry`, no `Inspect` implementation, no
formatter in `lib/`. The channel is: `validate/2` returns them, `compile/1`
stamps them, `Machine.warnings` holds them.

Rationale: ADR-0012's seams are all interpreter- and Machine-side and none is
mechanically reachable from `validate/2`, which runs before a Machine exists
and has no `MachineState` to gate on. st-cmq.6's precedent for declining a seam
applies directly - it rejected a `Trace.InvokeSet` row because `Effect.Invoke`
was already visible without it, calling a trace row "additive observability with
no caller"
(`docs/plans/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md:196-199`).
Nothing in `lib/` renders a validator finding today, so a second channel would
have no reader either. `docs/observability.md`'s seam table gains one row for
the field, which is the documentation change that keeps the table's claim to be
exhaustive true.

---

## Phase 1: ADR-0033, the warning tier decision

### Overview

Record the direction before implementing it. This phase is required rather than
optional: it reverses a decision recorded twice (Decision 4 of
`docs/plans/260808-st-l5k.5-document-validator.md`, reaffirmed by
`docs/plans/260812-st-t8w-idless-compound-final-validator.md`), it adds an axis
to the public API, and it adds a field to `Statifier.Machine`. `docs/adr/README.md`
puts new ADRs at the next number in the three-section format; 0032 is the
highest today, so this is 0033.

Documentation only. No Elixir changes.

### Changes Required:

#### 1. The ADR

**File**: `docs/adr/0033-validator-warning-tier.md` (new)
**Changes**: Three sections, Context / Decision / Consequences, matching the
format of `docs/adr/0026-script-as-predicator-statement-programs.md`.

- **Context**: the validator's error-only shape; Decision 4's rationale and the
  additive hatch it named; 6.5.2's MUST NOT quoted from the spec cache; the
  fact that the ban is stated to the document author, not to the processor, so
  refusing the document is the wrong strength of response.
- **Decision**: a separate `Validator.Warning` struct with its own closed reason
  union (Decision 2 above); `validate/2` returns three elements on both arms
  (Decision 3); warnings ride to the caller on `Machine.warnings` and
  `compile/1`'s `@spec` is unchanged (Decision 4); the surfacing seam is that
  field and nothing else (Decision 7).
- **Consequences**: existing checks keep their pass/reject behavior and no
  reason moves (Decision 5); `:strict` is still unassigned and is now
  implementable by any caller (Decision 6); `<send>` inside `<finalize>` stays
  a lowering error until `<send>` is representable, at which point
  `Checks.Invoke` is its home (Decision 1); a warned document still compiles,
  so `Machine` being valid-by-construction is unaffected.

The ADR must not name a bead id anywhere - `lib/mix/statifier/adr_guard.ex`'s
ADR-0018 check covers `lib/` and `test/` only, but ADR-0018 itself is about all
code-adjacent prose and the ADRs already follow it. Cite spec clauses, plan
paths, and ADR numbers.

#### 2. The ADR index

**File**: `docs/adr/README.md`
**Changes**: one row appended to the table.

```
| [0033](0033-validator-warning-tier.md) | The validator has a warning tier; warnings ride on the Machine | accepted |
```

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality` is green (this phase touches no Elixir, so the ADR guard,
      format, compile, credo, dialyzer, doctor, and test stages are all
      unaffected; running it confirms that).
- [ ] `mix gate.verify` exits zero, attesting the run was a full, unprofiled,
      unscoped gate.
- [ ] `docs/adr/0033-validator-warning-tier.md` exists and contains the three
      headings `## Context`, `## Decision`, `## Consequences`.
- [ ] `grep -c "0033" docs/adr/README.md` returns at least 1.
- [ ] `grep -r "st-jzc" docs/adr/` returns nothing.

#### Manual Verification:
- [ ] The Context section's 6.5.2 quotation matches the local spec cache
      verbatim, checked against
      `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html`
      rather than from memory.
- [ ] Each of the seven decisions above appears in the ADR, and the Consequences
      section states the two things this ADR deliberately leaves undone
      (`:strict`, and the `<send>` half).
- [ ] The ADR reads as a decision record, not as a summary of this plan: it
      argues from the spec and from the existing struct shapes, not from phase
      numbers.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before moving
to the next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: The warning tier and its one producer

### Overview

The `Warning` struct, its one reason and constructor, `Checks.Invoke.warn/2`,
the `@warning_checks` list, `validate/2`'s new three-element return, and every
call site that has to move with it.

These do not split. A `Warning` struct with no producer is uncovered code that
fails the coverage stage; a `warn/2` with nowhere to be wired is dead code that
fails the same stage; and `validate/2`'s new arity breaks
`lib/statifier.ex:62` and 74 test call sites the moment it changes, so all of
that is one green unit.

### Changes Required:

#### 1. The warning struct

**File**: `lib/statifier/validator/warning.ex` (new)
**Changes**: mirrors `lib/statifier/validator/error.ex`'s shape exactly -
three enforced fields, a closed `reason` union, one public constructor per
variant, and a `code/1` tag extractor. The moduledoc states the mirror
relationship the way `error.ex:4-10` states its own, and states what
distinguishes the two unions: a `Warning` reason is a document-conformance
finding the engine has a defined behavior for either way, and never gates
compilation.

```elixir
defmodule Statifier.Validator.Warning do
  @moduledoc """
  The validator's non-fatal finding shape ...
  """

  alias Statifier.Parser.Location

  @type reason :: {:finalize_forbidden_content, element :: binary()}

  @enforce_keys [:reason, :message, :location]
  defstruct [:reason, :message, :location]

  @type t :: %__MODULE__{
          reason: reason(),
          message: binary(),
          location: Location.t()
        }

  @spec code(reason :: reason()) :: atom()
  def code(reason) when is_tuple(reason), do: elem(reason, 0)

  @spec finalize_forbidden_content(element :: binary(), location :: Location.t()) :: t()
  def finalize_forbidden_content(element, %Location{} = location) when is_binary(element) do
    %__MODULE__{
      reason: {:finalize_forbidden_content, element},
      message: "<#{element}> must not occur inside <finalize>",
      location: location
    }
  end
end
```

The constructor's `@doc` quotes 6.5.2 in full and says the location is the
offending node's own span, never the `<invoke>`'s - matching how every
constructor in `error.ex` documents its location choice.

#### 2. The check

**File**: `lib/statifier/validator/checks/invoke.ex`
**Changes**: add a public `warn/2` alongside `check/2`, leaving `check/2` and
all five 6.4.1 arms untouched. The moduledoc gains a section naming 6.5.2, the
one-member forbidden set, and the obligation that `<send>` joins the set when
`Statifier.Document.Send` exists.

```elixir
@spec warn(document :: Document.t(), context :: Context.t()) :: [Warning.t()]
def warn(%Document{states: states}, %Context{}) do
  states
  |> flatten()
  |> Enum.flat_map(& &1.invoke)
  |> Enum.flat_map(&warn_finalize/1)
end

defp warn_finalize(%DInvoke{finalize: nil}), do: []

defp warn_finalize(%DInvoke{finalize: %Block{content: content}}) do
  content
  |> Enum.flat_map(&descend/1)
  |> Enum.flat_map(&forbidden/1)
end

defp forbidden(%DRaise{location: location}),
  do: [Warning.finalize_forbidden_content("raise", location)]

defp forbidden(_other), do: []
```

`descend/1` is a fourth copy of the recursion at
`lib/statifier/validator/checks/script.ex:86-92` - through `%DIf{branches:}`
and `%DForeach{content:}` - with the same explanatory comment shape. The repo
already carries three copies rather than a shared helper; this plan follows
that rather than extracting one, because extracting it would touch three
working checks for no behavior change.

#### 3. The validator

**File**: `lib/statifier/validator.ex`
**Changes**: a `@warning_checks` list beside `@checks`, a second flat-map/sort
over the same `Context`, and a three-element return on both arms. The moduledoc
gains a fifth contract and revises its opening: it is still the only gate in
front of the Machine compiler, and it now also carries findings that do not
gate.

```elixir
@warning_checks [
  &Invoke.warn/2
]

@spec validate(document :: Document.t(), source :: binary()) ::
        {:ok, Document.t(), [Warning.t()]} | {:error, [Error.t()], [Warning.t()]}
def validate(%Document{} = document, source) when is_binary(source) do
  context = Context.build(document, source)

  errors = run(@checks, document, context)
  warnings = run(@warning_checks, document, context)

  case errors do
    [] -> {:ok, document, warnings}
    errors -> {:error, errors, warnings}
  end
end

defp run(checks, document, context) do
  checks
  |> Enum.flat_map(fn check -> check.(document, context) end)
  |> Enum.sort_by(fn finding -> finding.location.start_offset end)
end
```

One `Context.build/2` per call, as today.

#### 4. The one production call site

**File**: `lib/statifier.ex`
**Changes**: line 62's `with` clause becomes
`{:ok, document, _warnings} <- Validator.validate(document, source)`. Warnings
are discarded in this phase and threaded in Phase 3; the underscore prefix is
what keeps the compile stage's `warnings_as_errors: true` green in between.
`compile/1`'s `@spec` and moduledoc do not change in this phase.

#### 5. Every test call site

**Files**: 60 files under `test/` (`grep -rl "Validator.validate" test/`)
**Changes**: mechanical. `{:ok, document} = Validator.validate(...)` becomes
`{:ok, document, _warnings} = ...`; `{:error, errors} = Validator.validate(...)`
becomes `{:error, errors, _warnings} = ...`. Roughly 55 of the 74 are fixture
setup in tests that are not about validation. No assertion semantics change.

Not every affected site names `Validator.validate` on its own line. Several
per-check test files wrap the call in a local `validate!/1`
(`test/statifier/validator/checks/invoke_test.exs:15-17`) and then
pattern-match the wrapper's result at every assertion, so the migration has to
follow the wrapper's callers too. `grep -rln "defp validate!\|defp validate("
test/` enumerates the files where that indirection exists; the compiler will
not catch a stale match there, only the test run will.

#### 6. New tests

**File**: `test/statifier/validator/checks/invoke_test.exs`
**Changes**: new `describe "warn/2"` block. Cases: a `<raise>` directly inside
`<finalize>`; a `<raise>` nested inside an `<if>` branch inside `<finalize>`; a
`<raise>` nested inside a `<foreach>` body inside `<finalize>`; two `<raise>`
elements reporting two warnings in document order; a `<log>` inside
`<finalize>` producing none; `finalize: nil` producing none;
`%Block{content: []}` producing none; a `<raise>` in `<onentry>` (outside any
`<finalize>`) producing none. Each asserts the reason tuple and the
`location.start_line` of the offending node, matching the per-check assertion
idiom already used in this file.

Every one of these asserts `lib/` behavior and gets a sabotage note per
`docs/testing.md`, format `# sabotage: <what was broken> -> red`. Valid
mutations for this check: drop the `%DIf{}` clause from `descend/1` (the nested
cases go red); make `forbidden/1` match `%DLog{}` instead of `%DRaise{}` (the
positive cases go red); return the `<invoke>`'s location instead of the node's
(the `start_line` assertions go red). Deleting a function body is not a valid
mutation.

**File**: `test/statifier/validator_test.exs`
**Changes**: assert `validate/2`'s three-element shape on both arms - a clean
document returns `{:ok, ^document, []}`, a document with both an error and a
warning returns `{:error, errors, warnings}` with both lists populated (the
collect-all contract now applying across channels), and warnings are sorted by
`start_offset` the same way errors are. Sabotage notes on each: drop the
warning list from the `{:error, ...}` arm; remove the sort from `run/3`.

**File**: `test/statifier/validator/warning_layer_test.exs` (new)
**Changes**: the sibling of `layer_test.exs` over
`lib/statifier/validator/warning.ex` - every `@type reason` tag has exactly one
constructor, no two constructors share a tag, and every tag is produced by some
module under `lib/statifier/validator/checks/`. It is a structural AST walk
asserting no runtime `lib/` behavior, so it carries
`# sabotage: n/a - ...` exemption notes in the same words `layer_test.exs`
uses at `:119-124` and `:137-142`.

#### 7. The changelog fragment

**File**: `changelog.d/st-jzc.md` (new)
**Changes**: one `### Changed` heading and one line for `validate/2`'s return.
This is a public API change, and it differs from v1 (whose validator returned
bare `String.t()` warnings), so the "while v2 is unreleased" rule in
`changelog.d/README.md` is satisfied.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality` is green - format, compile with `warnings_as_errors`,
      credo `--strict`, dialyzer (the new `@spec`s must typecheck against the
      new return shape), doctor at 100% on every axis, coverage, the ADR guard,
      the gate guard, and the regression ratchet.
- [ ] `mix quality --profile loop` is the command to use between edits; it does
      not satisfy this phase on its own.
- [ ] `mix gate.verify` exits zero.
- [ ] `mix test.regression` passes - the ratchet's `internal_tests` globs pick
      up the new test files automatically.
- [ ] `grep -rn "Validator.validate" lib/ test/` shows no remaining
      two-element pattern match at a *direct* call site. This grep is a
      convenience, not the guarantee: several test files reach `validate/2`
      through a local `validate!/1` wrapper
      (`test/statifier/validator/checks/invoke_test.exs:15-17` is the worked
      example, with roughly 20 call sites behind it), and a stale pattern match
      on a wrapper's result is invisible to it. The full test suite inside
      `mix quality` is what actually decides this - a missed site is a
      `MatchError` at run time.
- [ ] `grep -rn "st-jzc" lib/ test/` returns nothing (ADR-0018's guard).
- [ ] Every new `test` block in the three test files above is preceded by a
      `# sabotage:` line.

#### Manual Verification:
- [ ] Each sabotage note names a mutation actually performed, and each
      mutation reddened the test it sits above and no more than it should have.
- [ ] Spec-conformance judgment: the check's forbidden set and its message
      match 6.5.2's clause as quoted from the local spec cache, and the
      `@doc` on `finalize_forbidden_content/2` quotes it rather than
      paraphrasing. This is a document-conformance clause, not Appendix D
      pseudocode, so no Appendix D function is touched and ADR-0002's
      line-for-line rule has nothing to bind here.
- [ ] The 74-site test migration changed no assertion's meaning - spot-check
      ten of the mechanical edits and confirm each only widened a pattern. The
      sample is not free: it must include every file whose call sites do not
      literally read `{:ok, document} = Validator.validate` or
      `{:error, errors} = Validator.validate`, because those are the ones a
      grep cannot find. `test/statifier/validator/checks/invoke_test.exs`,
      which pattern-matches the result of a local `validate!/1` wrapper, is one
      of them; find the rest with
      `grep -rln "defp validate!\|defp validate(" test/`.
- [ ] `Checks.Invoke.check/2`'s five 6.4.1 arms and their tests are byte-for-byte
      unchanged, confirming the acceptance criterion that existing pass/reject
      behavior did not move.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before moving
to the next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 3: Warnings reach the caller on `Machine.warnings`

### Overview

Phase 2 leaves warnings computed and discarded at `lib/statifier.ex:62`. This
phase carries them past the compiler boundary onto the machine the caller
receives, without changing `Statifier.compile/1`'s `@spec`.

### Changes Required:

#### 1. The Machine field

**File**: `lib/statifier/machine.ex`
**Changes**: `warnings: []` joins `global_scripts: []` as a plain `defstruct`
default, outside `@enforce_keys`, with `warnings: [Warning.t()]` on the `@type
t`. A moduledoc section explains what the field is and, as importantly, what it
is not: warnings are statements about the source document's conformance, not
about the Machine's validity, so the valid-by-construction property
(`docs/architecture.md` principle 4) is untouched. It cites ADR-0033 and
ADR-0012 item 3 for why retained diagnostics live here.

Because `warnings` is a defaulted field outside `@enforce_keys`, no existing
`%Machine{}` construction site in `lib/statifier/compiler.ex` changes.

#### 2. The threading

**File**: `lib/statifier.ex`
**Changes**: `compile/1` binds the warnings, calls `Compiler.compile/1`
explicitly inside the `with` rather than as its `do` body, and stamps the
field. The `@spec` stays `{:ok, Machine.t()} | {:error, [error()]}`; the
`@doc` gains a sentence saying a compiled machine carries the validator's
non-fatal findings on `warnings`, and that a document with warnings still
compiles.

```elixir
with {:ok, root} <- parse(source),
     {:ok, document} <- Lowering.lower(root),
     {:ok, document, warnings} <- Validator.validate(document, source),
     {:ok, machine} <- Compiler.compile(document) do
  {:ok, %Machine{machine | warnings: warnings}}
end
```

#### 3. Tests

**File**: `test/statifier_test.exs`
**Changes**: a document with `<raise>` inside `<finalize>` compiles to
`{:ok, %Machine{warnings: [%Warning{reason: {:finalize_forbidden_content,
"raise"}}]}}`, and the same document without the `<raise>` compiles to
`warnings: []`. Sabotage: drop the `%Machine{machine | warnings: warnings}`
stamp so the field stays `[]` -> the first assertion goes red.

**File**: `test/statifier/machine_test.exs`
**Changes**: assert the field's default is `[]` on a machine built from a
document with no warnings, so the default is pinned rather than incidental.
Sabotage: change the `defstruct` default to `nil` -> red.

#### 4. The changelog fragment

**File**: `changelog.d/st-jzc.md`
**Changes**: an `### Added` heading and one line for `Machine.warnings`,
alongside Phase 2's `### Changed` line. One file may carry more than one
heading (`changelog.d/README.md`, Format).

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality` is green, including dialyzer against the unchanged
      `compile/1` `@spec` and the new `Machine.t()` type.
- [ ] `mix gate.verify` exits zero.
- [ ] `mix test.regression` passes.
- [ ] `changelog.d/st-jzc.md` carries both an `### Added` and a `### Changed`
      heading, using only the headings `changelog.d/README.md` permits.
- [ ] `grep -n "@spec compile" lib/statifier.ex` still shows
      `{:ok, Machine.t()} | {:error, [error()]}` - the public spec did not
      change.
- [ ] `grep -rn "st-jzc" lib/ test/` returns nothing.

#### Manual Verification:
- [ ] Spec-conformance judgment: no Appendix D function is touched by this
      phase; `Statifier.compile/1` is a pipeline facade and
      `Statifier.Machine` is a data structure, so ADR-0002's line-for-line
      rule has nothing to bind. Confirm by reading the diff that no
      `lib/statifier/interpreter*` file appears in it.
- [ ] A machine compiled from a warning-free document is indistinguishable
      from one compiled before this phase apart from the new field - checked by
      running the interpreter suite and confirming nothing depended on
      `%Machine{}`'s field count.
- [ ] The sabotage mutations were performed and reverted, and each note names
      the mutation it describes.

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before moving
to the next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 4: Documentation

### Overview

Make the project's own documents say what the code now does. Three documents
currently describe a validator with one channel and a seam table that claims to
be exhaustive.

Documentation only. No Elixir changes.

### Changes Required:

#### 1. The architecture document

**File**: `docs/architecture.md`
**Changes**: the Layers diagram's `Validator (structural + semantic checks)`
line gains a note that the validator produces two channels, and principle 4's
paragraph gains a sentence distinguishing a finding that gates (an error, which
is what principle 4 is about) from one that does not (a warning, which rides on
the Machine and never blocks compilation). Cites ADR-0033.

#### 2. The observability document

**File**: `docs/observability.md`
**Changes**: one row appended to the "Where the seams live" table:

```
| validator warnings retained on the compiled Machine (ADR-0033) | `Statifier.Validator.Warning`, `Statifier.Machine.warnings` |
```

plus a sentence in the surrounding prose saying that this is the whole seam -
there is no trace effect, no logger, and no telemetry for a validator finding,
because the return value and the field are the channel.

#### 3. The testing document

**File**: `docs/testing.md`
**Changes**: none expected. Confirm during this phase that nothing in it
describes the validator's return shape; if it does, correct it.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality` is green.
- [ ] `mix gate.verify` exits zero.
- [ ] `grep -n "0033" docs/architecture.md docs/observability.md` matches in
      both files.
- [ ] `grep -rn "{:ok, document}" docs/` returns no stale description of
      `validate/2`'s old two-element shape.

#### Manual Verification:
- [ ] The observability seam table reads as complete again: a reader looking
      for "where does a validator finding surface" finds the row and stops.
- [ ] `docs/architecture.md` principle 4 still reads as a statement about the
      Machine type rather than about diagnostics, with the warning sentence
      subordinate to it.
- [ ] No document names a bead id or a phase number (ADR-0018).

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before moving
to the next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Testing Strategy

### Unit Tests:

- **`test/statifier/validator/checks/invoke_test.exs`** - the eight `warn/2`
  cases listed in Phase 2: direct child, nested in `<if>`, nested in
  `<foreach>`, two occurrences in document order, a benign `<log>`, absent
  `<finalize>`, empty `<finalize>`, and a `<raise>` outside any `<finalize>`.
  The last three are the edge cases that matter most: `finalize: nil` versus
  `%Block{content: []}` is a distinction `Document.Invoke`'s moduledoc says 6.5
  requires, and a `<raise>` in `<onentry>` must not be caught by a walk that
  starts from the wrong root.
- **`test/statifier/validator_test.exs`** - the return shape on both arms, and
  the document-order sort applied to warnings as well as errors.
- **`test/statifier/validator/warning_layer_test.exs`** - the structural
  one-reason-one-constructor-one-producer invariant over `warning.ex`, mirroring
  `layer_test.exs`.
- **`test/statifier_test.exs`** - the end-to-end assertion that a warned
  document compiles and the warning is on `machine.warnings`.
- **`test/statifier/machine_test.exs`** - the field's `[]` default.

Every test that asserts `lib/` behavior carries a `# sabotage: <mutation> -> red`
line above it, and the structural layer test carries the stated
`# sabotage: n/a - ...` exemption instead (`docs/testing.md`).

### Manual Testing Steps:

1. In `iex -S mix`, compile a document with `<raise event="x"/>` inside
   `<finalize>` inside `<invoke>` and confirm `{:ok, machine}` comes back with
   one warning on `machine.warnings`, its `location.start_line` pointing at the
   `<raise>` and not at the `<invoke>`.
2. Compile the same document with the `<raise>` moved into `<onentry>` and
   confirm `machine.warnings == []`.
3. Compile a document with `<send>` inside `<finalize>` and confirm it is still
   an `{:error, [%Lowering.Error{reason: {:unsupported_element, "send"}}]}` -
   the `<send>` half of 6.5 remains a lowering refusal, as Decision 1 states.
4. Compile a document that trips both a hard error (a duplicate id) and the
   warning, and confirm `Validator.validate/2` returns both lists populated -
   the collect-all contract across channels.
5. Initialize and run the warned document to confirm the `<raise>` inside
   `<finalize>` still executes exactly as it did before this bead: the tier
   reports, it does not change behavior.

## Corpus/Ratchet Notes

No corpus regeneration. `tools/corpus/` never calls `Statifier.compile/1` or
`Validator.validate/2`; its only match for "validate" is spec prose in an
exclusion reason (`tools/corpus/scxml_w3/exclusions.exs:17`).

No change to `test/passing_tests.json`'s format or to `mix test.regression`,
which reads exit status only (`lib/mix/tasks/test.regression.ex:90,96-100`). A
warning-producing-but-passing document is invisible to the ratchet, which is
correct: a warning must not change whether a test passes. The registry's
`internal_tests` globs cover new files under `test/statifier/` automatically, so
the new test files join the ratchet without an edit - and `test/passing_tests.json`
is an ADR-0011-guarded path, so not editing it also means no ledger entry in
`docs/quality-gate-changes.md` is needed for this bead.

The 35 W3C mandatory `<invoke>` files still carry
`required_features: [:invoke_elements]` and still `flunk` through the feature
gate (`test/support/feature_detector.ex:112-113`); none is in the registry, and
none moves here.

## References

- Source document: `docs/research/260815-st-jzc-validator-warning-tier-and-finalize-send-raise.md`
- Related ADRs: `docs/adr/0012-debuggability-designed-into-the-core.md`,
  `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `docs/adr/0018-no-process-jargon-in-code-comments.md`,
  `docs/adr/0026-script-as-predicator-statement-programs.md`,
  and the new `docs/adr/0033-validator-warning-tier.md` this plan's Phase 1
  writes
- Prior decisions this plan revisits:
  `docs/plans/260808-st-l5k.5-document-validator.md:296-314` (Decision 4),
  `docs/plans/260812-st-t8w-idless-compound-final-validator.md`,
  `docs/plans/260815-st-cmq.6-invoke-lowering-and-states-to-invoke.md:187-191`
  (the deferral) and `:196-199` (the declined-seam precedent),
  `docs/plans/260808-st-700-relaxed-parsing-options.md:29` (`:strict`)
- Similar implementation: `lib/statifier/validator/checks/script.ex:68-92`
  (the `descend/1` walk), `lib/statifier/validator/error.ex:75-102` (the struct
  and constructor shape to mirror),
  `test/statifier/validator/layer_test.exs:125-155` (the layer test to mirror)
- Spec: 6.5.2 Children, local cache
  `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/scxml-rec.html:4418-4429`
- Bead: `st-jzc`
