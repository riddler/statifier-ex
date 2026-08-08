# Relaxed Parsing Options Implementation Plan

## Overview

v1 accepted boilerplate-free SCXML fragments by **rewriting the source string**
before handing it to the XML parser. v2 cannot do that without breaking the
span contract every diagnostic is built on. This plan carries the *capability*
over by direction (a) from the bead - relax the CHECK, never patch the INPUT -
makes it a stated and mechanically pinned commitment rather than an accident of
the current implementation, and records where the strict half lives. Beads
issue: st-700.

## Current State Analysis

### v1, the thing being carried over

`../statifier/lib/statifier/parser/scxml.ex` normalizes before parsing:

- `parse/2`, line 21: `normalized_xml = normalize_xml(xml_string, opts)`
- `:relaxed`, default **true** (line 48): inserts `xmlns="http://www.w3.org/2005/07/scxml"`
  into the `<scxml>` start tag when no `xmlns=` is present, and `version="1.0"`
  when no `version=` is present.
- `:xml_declaration`, default **false** (line 49, `maybe_add_xml_declaration/2`
  at line 65): prepends `<?xml version="1.0" encoding="UTF-8"?>\n`. v1's own
  docs give the reason for the `false` default: prepending a line shifts every
  reported line number by one.
- `Statifier.parse/2` also carries `:strict` (warnings as errors). That is a
  validator concern, not an XML-boilerplate concern, and the bead already
  assigns it to st-l5k.5. Out of scope here.

### v2, verified empirically, not assumed

Run against this worktree (`mix run` on a scratch script), source
`<scxml initial="a"><state id="a"><transition event="go" target="b" cond="x &gt; 1"/></state><state id="b"/></scxml>`
- no `xmlns`, no `version`:

- `Statifier.Parser.parse/1` returns `{:ok, root}`.
- `Statifier.Lowering.lower/1` returns `{:ok, %Statifier.Document{}}` with the
  full state and transition tree, `xmlns: nil`, `version: nil`.
- Every span slices back out of the **original** binary correctly, including
  the `cond` value span (offsets 73..81, slicing `x &gt; 1`), which is exactly
  what ADR-0014's attribute-relative expression arithmetic consumes.
- The same document with full boilerplate lowers to the same tree plus
  `xmlns`/`version` values and their `attribute_locations` entries.
- A root bound to a genuinely foreign namespace still errors with
  `{:foreign_element, "scxml", uri}`.

So **the relaxed half already works today**, and it works by the mechanism
direction (a) describes:

- `Statifier.Lowering.Namespace.resolve/2` (`lib/statifier/lowering/namespace.ex:63-68`)
  resolves an unprefixed name against the `:default` binding, which is `nil`
  when no bare `xmlns` is in scope.
- `Statifier.Lowering.lower/1:66` and `walk_child/4:113` both dispatch when
  `uri in [nil, Namespace.scxml_namespace()]` - the lenient `nil` branch.
- `version` is read verbatim into `%Statifier.Document{}`
  (`lib/statifier/lowering/builders.ex:64`) and never checked by anything.
- `lib/statifier/parser.ex` performs **no** normalization of any kind; its
  moduledoc already states "Nothing is validated, normalized, or resolved".

This is not accidental: it is
`docs/plans/260807-st-l5k.4-lowers-dom-to-document.md` Decision 8, which chose
the lenient `nil` case explicitly ("heredoc unit-test fixtures should not have
to declare `xmlns` on every root") and which explicitly assigned the opposite
check elsewhere: "`Document.xmlns` is lowered verbatim from the root's `xmlns`
attribute with no check that it is the SCXML namespace - that check is
st-l5k.5's."

### What is actually missing

1. **The commitment is undocumented.** Nobody reading `Statifier.Parser`'s or
   `Statifier.Lowering`'s moduledoc learns that a boilerplate-free fragment is
   supported, or that support is a promise rather than a side effect. The next
   person to tighten the namespace guard has nothing telling them they would
   be breaking a documented capability.
2. **The commitment is untested at the span level.** `namespace_test.exs:65`
   pins that a fragment with no `xmlns` lowers, but nothing anywhere pins that
   a span from *such a parse* slices out of the *caller's* binary, which is the
   whole reason direction (a) was chosen over (b) and (c).
3. **There is no line-shift regression guard.** Nothing would catch a future
   contributor re-introducing v1's prepended XML declaration.
4. **The strict half has no home.** st-l5k.5 is not implemented and no
   validator module exists. Its bead's eight listed checks do not include a
   boilerplate check, so today the strict half is not merely unimplemented, it
   is unscoped.
5. **No changelog fragment** records that `:relaxed` and `:xml_declaration`
   are gone from the v2 API surface. `changelog.d/README.md`'s narrower
   rewrite-era rule ("write a fragment when v2 differs from v1") is met: two
   public options disappear and their behavior changes character.

### Key Discoveries

- `lib/statifier/parser/location.ex:69` - `slice/2` is `binary_part(source,
  start_offset, end_offset - start_offset)` against a caller-supplied
  `source`. Any rewrite invalidates every span unless offsets are translated.
- `test/statifier/parser/location_accuracy_test.exs:14-36` - the existing
  accuracy sweep is a reusable *property* (slice every element and attribute
  span back out and check it reconstructs), with no hardcoded line numbers.
  Phase 2 reuses this shape rather than inventing a new assertion style.
- `lib/statifier/lowering.ex:66` and `:113` - the leniency lives in a bare
  `uri in [nil, ...]` expression duplicated at two call sites, with no name.
- `lib/statifier/parser.ex:30` - the parser already discards the prolog and
  the XML declaration entirely, so v1's `:xml_declaration` option would in v2
  produce *no observable effect except a line shift*. That is decisive for
  dropping it.
- `docs/architecture.md`, "What is deliberately out of scope": "**v1 API
  compatibility.** The conformance corpus is the compatibility contract, not
  v1's module surface." Carrying the capability is required; carrying the
  option names is not.
- ADR-0014 fixes the span shape and the attribute-relative arithmetic
  (`value_location.start_offset + span.start`) that a rewritten source would
  silently corrupt.
- `docs/testing.md:85-127` - the sabotage protocol, including the
  `# sabotage: n/a - ...` form for harness plumbing.

## Desired End State

A caller can hand `Statifier.Parser.parse/1` a fragment with no XML
declaration, no `xmlns`, and no `version`, lower it, and every location on
every resulting node slices correctly out of the binary they passed in - and
that is a written, tested promise rather than an emergent property. The
absence of boilerplate is *observable* downstream (`Document.xmlns == nil`,
`Document.version == nil`, no `:xmlns` / `:version` key in
`attribute_locations`) so the validator can report it with a span when
st-l5k.5 lands. No option named `:relaxed` or `:xml_declaration` exists on any
v2 function.

Verification: Phase 2's tests pass, `mix quality` is green, and
`changelog.d/st-700.md` exists.

## What We're NOT Doing

- **Not rewriting the source string, ever** - not in `parse/1`, not behind an
  option, not behind a convenience entry point. Directions (b) and (c) are
  rejected below.
- **Not adding a `:relaxed` or `:xml_declaration` option.** `parse/1` keeps its
  arity and its bare-binary signature.
- **Not implementing the boilerplate rejection itself.** The two checks
  ("root's `xmlns` is the SCXML namespace" and "root has `version=\"1.0\"`")
  are validator checks and are recorded as st-l5k.5 scope, not written here.
- **Not building a validator module** to house them early. Standing up
  `Statifier.Validator` with two checks would pre-empt st-l5k.5's own design
  (its bead already specifies the module shape, the error struct, and the
  shared index) and would land a module whose eight real checks are missing.
- **Not touching `:strict`** (warnings-as-errors). Different concern, st-l5k.5.
- **Not adding a top-level `Statifier.parse/2`.** `lib/statifier.ex` is still a
  stub moduledoc; designing the public facade is a separate piece of work and
  bolting a two-option facade onto it here would prejudge it.
- **Not writing an ADR.** See Open Questions.

## Implementation Approach

**Direction (a) is chosen: relax the check, not the input.**

The bead calls (a) "likely the right answer"; the empirical probe upgrades that
to "already the answer, undeclared". The justification against the location
contract is the decisive one:

- `Location.slice/2` takes the caller's `source` as its second argument. Under
  (a) the binary the caller passed **is** the binary Saxy and
  `Statifier.Parser.Markup` scanned, so every offset is exact by construction
  and there is nothing to keep in sync.
- Direction (b) - rewrite plus an offset-translation table - would make every
  span correct only through a translation step that every consumer must
  remember to apply. ADR-0014's whole point is that a span is *arithmetic*
  (`value_location.start_offset + span.start`), usable without ceremony;
  interposing a translation table turns a field access into an API and gives
  every future consumer a way to be silently wrong. It buys nothing (a) does
  not already give, at considerable machinery cost.
- Direction (c) - a separate normalizing convenience entry point - would ship a
  second parse path whose spans point into a string the caller never saw. That
  is exactly the failure mode v1 documented and lived with, re-introduced
  voluntarily, and it forks the location contract in two so that "does this
  span slice out of my source?" becomes a question about which function you
  called.

So the work is: **name the leniency, document it, pin it with tests that assert
against the original binary, record the API-surface change, and record where
strictness lives.**

### The default, decided

**Relaxed acceptance is unconditional and is the only behavior.** There is no
option and therefore no default to flip.

The reasoning to carry into the moduledoc: v1's `:relaxed` defaulted to `true`,
so v2 keeps the *observable default* v1 users had. What changes is that
relaxation is no longer a mode - it is what the parser and lowering layers *are*
(`Statifier.Parser`'s moduledoc: "Nothing is validated, normalized, or
resolved"), so an off switch would not be an option on parsing but a validator
check placed one layer too low. `Statifier.Document` deliberately stays the
pre-validation type that can hold malformed shapes
(`lib/statifier/document.ex:9-12`); a document with `xmlns: nil` is one of
those shapes, fully representable, and reporting it is the validator's job.
`:xml_declaration` is dropped outright, with no replacement: v2 discards the
prolog (`lib/statifier/parser.ex:30`), so the option's only remaining effect
would be the line shift v1 defaulted it off to avoid.

### The strict half, decided

Rejecting a boilerplate-free fragment becomes **two st-l5k.5 validator checks**,
not an option on `parse` or `lower`:

- root `xmlns`, when written, is `http://www.w3.org/2005/07/scxml`; when
  absent, report it (spec 3.2 requires the namespace).
- root `version` is `"1.0"` (spec 3.2 requires it).

Both are reportable **with a span today**: a written-but-wrong `xmlns` has
`document.attribute_locations[:xmlns]`, and an absent one has no key, which is
precisely the "was it written" question `lib/statifier/document.ex:31-39`
defines - the check falls back to `document.location` (the `<scxml>` element)
for the absent case. Phase 2 pins that this information survives lowering, so
st-l5k.5 inherits a tested substrate rather than a promise.

This is the layering-correct home and it is where Decision 8 already put the
sibling check. The cost, stated plainly: **between this bead landing and
st-l5k.5 landing, there is no way to reject a boilerplate-free fragment.** That
is accepted because during that window there is no way to reject a document
with a duplicate state id, an unresolvable transition target, or a `<final>`
with state children either - the validator is simply not built yet, and adding
a private one-off rejection path for this single case would have to be unwound
when it is.

Recommended follow-up (do **not** create it as part of implementing this plan;
recommend it to the human): extend st-l5k.5's description with these two checks
as items 9 and 10, or file a child bead under it. See "Open Questions".

## Phase 1: Name the leniency and state the commitment

### Overview

Give the lenient dispatch branch a name and a moduledoc, so the capability is
declared where a maintainer would read it before tightening the guard. No
behavior changes.

### Changes Required:

#### 1. A named predicate for the lenient branch
**File**: `lib/statifier/lowering/namespace.ex`
**Changes**: Add `scxml_vocabulary?/1` and document the leniency as a
commitment, citing st-700 and Decision 8.

```elixir
@doc """
Whether `uri` dispatches as SCXML's own vocabulary: the SCXML namespace
itself, or **no namespace at all**.

The `nil` case is the relaxed-parsing commitment (st-700). A fragment that
declares no `xmlns` - `<scxml><state id="a"/></scxml>` - lowers exactly as
its fully-declared twin does. v1 achieved this by inserting `xmlns=` into
the source string before parsing; v2 relaxes this check instead, so spans
still slice out of the binary the caller passed (`Location.slice/2`) with
no translation step. Tightening this predicate would break a documented
capability, not merely a fixture.

Reporting an absent or non-SCXML `xmlns` is the validator's job (st-l5k.5),
which has `Document.xmlns` and its `attribute_locations` entry to report
from.
"""
@spec scxml_vocabulary?(uri :: String.t() | nil) :: boolean()
def scxml_vocabulary?(uri), do: uri in [nil, @scxml_namespace]
```

#### 2. Use it at both dispatch sites
**File**: `lib/statifier/lowering.ex`
**Changes**: Replace the duplicated `uri in [nil, Namespace.scxml_namespace()]`
at `lower/1` (line 66) and `walk_child/4` (line 113) with
`Namespace.scxml_vocabulary?(uri)`. Behavior identical.

#### 3. State the contract where callers read it
**File**: `lib/statifier/parser.ex`
**Changes**: Add a `## Relaxed input` section to the moduledoc under "What it
does not do". Content, in this repo's voice:

- `parse/1` takes the caller's binary and parses *that binary*. It never
  normalizes, and in particular never inserts `xmlns` or `version` into the
  start tag and never prepends an XML declaration. Every span therefore slices
  out of the caller's own source with `Location.slice/2`, and ADR-0014's
  attribute-relative arithmetic needs no translation.
- Boilerplate-free fragments are supported, unconditionally and with no
  option. v1's `:relaxed` (default `true`) and `:xml_declaration` (default
  `false`) have no v2 equivalents: relaxation is not a mode here, it is what
  this layer is, and the prolog is discarded anyway so an inserted declaration
  would buy nothing but v1's documented line shift.
- Rejecting a fragment for missing boilerplate is the validator's job
  (st-l5k.5), because a `%Document{}` with `xmlns: nil` is representable and
  this layer reports only what it cannot represent.

**File**: `lib/statifier/lowering.ex`
**Changes**: One short `## Relaxed input` moduledoc paragraph pointing at
`Namespace.scxml_vocabulary?/1` as the mechanism, so the reader who starts at
lowering finds it too.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] `grep -n "uri in \[nil" lib/statifier/lowering.ex` returns nothing (both
      sites now go through the named predicate)
- [x] Existing lowering tests unchanged and green (this phase is behavior-neutral)

#### Manual Verification:
- [ ] The moduledoc states the default decision (relaxed is unconditional;
      `:relaxed`/`:xml_declaration` are gone) in the terms the bead asks for
- [ ] Wording matches the surrounding house style in these files (hyphens, not
      em dashes; the existing moduledocs' "here is the rejected alternative and
      why" voice)

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 2: Pin the commitment with span-level tests

### Overview

The bead's core requirement: "pin it with a test that parses a boilerplate-free
fragment and slices a span back out of the ORIGINAL binary." Everything here is
new test code asserting `lib/` behavior, so **every test gets a sabotage line**
per `docs/testing.md`.

### Changes Required:

#### 1. New test file
**File**: `test/statifier/lowering/relaxed_input_test.exs`
**Changes**: New `Statifier.Lowering.RelaxedInputTest`, `async: true`. Follow
`test/statifier/lowering/namespace_test.exs`'s `parse!/1` + `lower!/1` helper
shape and pattern-matching assertion style.

Tests (each with its own `# sabotage: ... -> red` line naming a *specific*
mutation, per `docs/testing.md:106-115` - never "delete the function body"):

1. **A boilerplate-free fragment lowers to the same tree as its fully-declared
   twin.** Reuse `namespace_test.exs`'s `strip/1` comparison idea: lower
   `<scxml initial="a">...` with no `xmlns`/`version` and the same document with
   both, and assert the stripped trees are equal. Sabotage: change
   `Namespace.scxml_vocabulary?/1` to `uri == @scxml_namespace`.

2. **Every span from a boilerplate-free parse slices out of the ORIGINAL
   binary.** The acceptance criterion. Use a *multi-line* heredoc fragment with
   no `xmlns`, no `version`, no XML declaration, and walk every element and
   every attribute asserting `Location.slice/2` against the source variable the
   test itself holds. This is the same property
   `test/statifier/parser/location_accuracy_test.exs:14-36` already implements;
   prefer importing/duplicating its helper shape over inventing a weaker
   assertion. Sabotage: have `Parser.parse/1` scan a normalized copy
   (`"<?xml version=\"1.0\"?>\n" <> source`) while still returning spans
   against it - i.e. re-introduce v1's rewrite - and confirm the slices go
   wrong. This sabotage is the one that matters: it is the exact failure
   direction (b)/(c) would have shipped.

3. **Line and column numbers are the caller's own.** A fragment whose
   `<state id="A"/>` is on line 3 reports `start_line: 3`. This is the
   `:xml_declaration` line-shift regression guard and it is worth stating as
   its own test because a prepended declaration passes test 2's byte-offset
   check on a single-line fixture but fails this one. Sabotage: prepend a
   declaration line inside `parse/1` before scanning.

4. **A cond span from a boilerplate-free parse still lands on the expression.**
   ADR-0014's consumer (st-mp4). Lower a fragment with
   `<transition cond="x &gt; 1"/>`, take
   `transition.attribute_locations[:cond]`, slice it out of the original
   source, and assert it is the raw `x &gt; 1`. Sabotage: shift
   `Attributes.put_location/4` to store `attribute.location` (the whole
   `name="value"`) instead of `value_location`.

5. **Absent boilerplate is observable, with a place to report from.** Assert
   `%Document{xmlns: nil, version: nil}` and that
   `attribute_locations` has neither `:xmlns` nor `:version`, while
   `document.location` still spans the whole `<scxml>` element - the fallback
   span st-l5k.5's check will underline. Sabotage: make
   `Attributes.put_location/4` insert a key with a `nil` value for absent
   attributes.

6. **Written boilerplate is still captured, with an accurate span.** The other
   half of test 5: with `xmlns=` and `version=` written, both values lower and
   both `attribute_locations` entries slice back to the raw values. Guards
   against "fixing" leniency by dropping the attributes on the floor. Sabotage:
   drop the `:xmlns` `put_location` call from `build_scxml/2`.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] New file runs green: `mix test test/statifier/lowering/relaxed_input_test.exs`
- [x] Coverage does not regress (the Tests stage in a bare `mix quality`
      measures it; a scoped or `--quick` run does not)

#### Manual Verification:
- [ ] **Every** sabotage was actually performed, went red, and was reverted -
      not written from imagination. `docs/testing.md`'s protocol is the point of
      this phase, and test 2's rewrite sabotage in particular is the evidence
      that direction (a) is what is being tested.
- [ ] Each sabotage comment names one specific mutation, in present tense, and
      the test it sits above is the test that reddens

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Phase 3: Record the API-surface change

### Overview

The user-visible half: a changelog fragment stating what a v1 user must know,
and the closing full gate.

### Changes Required:

#### 1. Changelog fragment
**File**: `changelog.d/st-700.md`
**Changes**: New file. `changelog.d/README.md`'s rewrite-era rule applies -
this is a public API difference from v1, so it earns a fragment; the format
rules are one line per change, present tense, no nested bullets, and for a
breaking change say what to do about it.

```markdown
### Removed

- Drops `Statifier.Parser.parse/2`'s `:relaxed` and `:xml_declaration`
  options. Fragments without `xmlns`, `version`, or an XML declaration parse
  unconditionally now, so callers that passed `relaxed: true` drop the option;
  callers that passed `relaxed: false` should wait for validation, which is
  where a missing SCXML namespace is reported.

### Changed

- Source locations always refer to the binary you passed in. v1's relaxed mode
  rewrote the source and shifted reported positions; v2 never rewrites, so a
  span slices back out of your own string.
```

(The exact wording is the implementer's; these two headings and these two facts
are the content.)

### Success Criteria:

#### Automated Verification:
- [x] `changelog.d/st-700.md` exists and uses only standard Keep a Changelog
      headings
- [x] **Full gate, unscoped and unprofiled**: `mix quality`
- [x] Full-gate provenance proven, not remembered: `mix gate.verify`
- [x] No gate-config file was touched, so `mix gate.check` (the Gate guard
      stage) needs no `docs/quality-gate-changes.md` entry - confirm it reports
      clean rather than assuming it

#### Manual Verification:
- [ ] The fragment reads as a migration note for a 1.x user, not as a
      transcript of this bead
- [ ] The deferred st-l5k.5 checks have been raised with the human (see Open
      Questions) - the plan recommends the bead edit; it does not make it

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

## Testing Strategy

### Unit Tests

All new tests live in `test/statifier/lowering/relaxed_input_test.exs` and are
enumerated in Phase 2. The shape is deliberate:

- Assertions are pattern matches against structs, not chains of `assert ==` on
  fields, matching the existing lowering tests.
- Span assertions go through `Location.slice/2` against the test's *own*
  source variable. No test writes down a line number except test 3, where the
  line number *is* the thing under test.
- The fixtures are heredocs at 4-space base indentation per `CLAUDE.md`.

Edge cases worth covering inside the above:

- Single-line fragment and multi-line fragment (a rewrite bug can hide in one
  and not the other).
- `xmlns` absent but a *prefixed* foreign child present - still errors, so
  leniency did not become blanket acceptance. Reuse the existing
  `namespace_test.exs` coverage rather than duplicating it; add only if the
  boilerplate-free root changes the path.

### Conformance Tests

None expected. All 278 corpus documents with an unprefixed `<scxml>` declare
`xmlns=` (Decision 8), so the corpus never exercises the lenient branch and
`test/passing_tests.json` should not move. **If it does move, that is a signal
to investigate, not to ratchet** - nothing in this plan should change how a
declared document parses.

### Manual Testing Steps

1. In `iex -S mix`, parse
   `~s(<scxml initial="a"><state id="a"/></scxml>)` and confirm `{:ok, _}` from
   both `Statifier.Parser.parse/1` and `Statifier.Lowering.lower/1`.
2. Slice the root's location back out of that same binary and confirm it is the
   whole element, byte for byte.
3. Re-read `Statifier.Parser`'s moduledoc as a first-time caller and confirm it
   answers "can I skip the boilerplate?" and "will my line numbers be right?"
   without reading any source.
4. Perform each Phase 2 sabotage for real; confirm red, revert, confirm green.

## References

- Beads issue: `st-700`
- Related beads: `st-l5k.3` (the DOM and `parse/1` this extends), `st-l5k.5`
  (validator - the strict half's home), `st-mp4` (spans into cond diagnostics)
- Related ADRs: `docs/adr/0014-expression-spans-in-cond-diagnostics.md` (the
  span shape and arithmetic a rewrite would corrupt),
  `docs/adr/0012-debuggability-designed-into-the-core.md`
- Prior plan: `docs/plans/260807-st-l5k.4-lowers-dom-to-document.md`,
  Decision 8 (leniency chosen, and the xmlns check assigned to st-l5k.5)
- Prior plan: `docs/plans/260807-st-l5k.3-sax-dom-source-locations.md`,
  Decision 1 (why locations come from a second scan of *the caller's* source)
- v1 reference: `../statifier/lib/statifier/parser/scxml.ex:20-71`
  (`normalize_xml/2`, `maybe_add_xml_declaration/2`)
- v2 code: `lib/statifier/parser.ex:75`, `lib/statifier/parser/location.ex:69`,
  `lib/statifier/lowering.ex:66,113`,
  `lib/statifier/lowering/namespace.ex:63`,
  `lib/statifier/lowering/builders.ex:46-73`,
  `lib/statifier/lowering/attributes.ex:80-99`,
  `lib/statifier/document.ex:31-39`
- Test to model on: `test/statifier/parser/location_accuracy_test.exs:14-36`,
  `test/statifier/lowering/namespace_test.exs`
- Conventions: `docs/testing.md:85-127` (sabotage), `changelog.d/README.md`

## Open Questions

Recorded per the unattended-run instruction. None blocks implementation; each
has a decision already made in this plan, and each is a call a human may want
to revisit.

1. **Should st-l5k.5 formally absorb the two boilerplate checks?** This plan
   defers "reject a fragment missing `xmlns`/`version`" to the validator and
   recommends adding them as items 9 and 10 of st-l5k.5's description (or a
   child bead under it). **No bead was created or edited** - that is a human's
   call and outside an implementing agent's authority. Until it happens the
   deferral lives only in this document, which is the weakest link in the plan.

2. **Does this decision warrant an ADR?** It is a deliberate, cross-cutting
   API-surface choice (span fidelity beats v1 option compatibility) of the kind
   ADRs exist for. It was **not** written, on the grounds that it is a
   corollary of two settled decisions rather than a new one: ADR-0014 fixes the
   span contract, and `docs/architecture.md` already declares v1 API
   compatibility out of scope. If a reviewer disagrees, the moduledoc text from
   Phase 1 is most of an ADR draft already.

3. **Should `Statifier.parse/2` exist, and would it change this answer?**
   `lib/statifier.ex` is a stub. If the eventual public facade runs
   parse -> lower -> validate in one call, a `strict: true` option on *that*
   function is a plausible future spelling of v1's `:relaxed` - it would sit
   above the validator rather than inside the parser, so it is compatible with
   this plan, not a contradiction of it. Designing that facade is deliberately
   not attempted here.

4. **Is "no way to reject a boilerplate-free fragment until st-l5k.5 lands"
   acceptable?** This plan says yes, because the same is true of every other
   document-level error today. A reviewer who wants the gap closed sooner
   should reprioritize st-l5k.5 rather than ask for a one-off rejection path
   here, which would have to be unwound when the validator lands.

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The moduledoc states the default decision (relaxed is unconditional;
      `:relaxed`/`:xml_declaration` are gone) in the terms the bead asks for
- [ ] Wording matches the surrounding house style in these files (hyphens, not
      em dashes; the existing moduledocs' "here is the rejected alternative and
      why" voice)

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

### Phase 2

- [ ] **Every** sabotage was actually performed, went red, and was reverted -
      not written from imagination. `docs/testing.md`'s protocol is the point of
      this phase, and test 2's rewrite sabotage in particular is the evidence
      that direction (a) is what is being tested.
- [ ] Each sabotage comment names one specific mutation, in present tense, and
      the test it sits above is the test that reddens

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---

### Phase 3

- [ ] The fragment reads as a migration note for a 1.x user, not as a
      transcript of this bead
- [ ] The deferred st-l5k.5 checks have been raised with the human (see Open
      Questions) - the plan recommends the bead edit; it does not make it

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the full `mix quality` as the phase gate. In interactive
execution, pause here for manual confirmation from the human that the manual
testing was successful before proceeding to the next phase. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically (via `/commit --auto`); Manual Verification items are deferred
and surfaced once at the end instead of blocking here.

---
