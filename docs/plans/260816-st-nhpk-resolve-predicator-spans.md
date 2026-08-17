# Resolving predicator spans to document locations Implementation Plan

## Overview

Add `Statifier.Parser.Location.resolve_span/4`, the public, `@spec`'d helper
that composes an attribute's `value_location` (a raw-source span) with a
predicator expression span (1-based `{{line, column}, {line, column}}`,
exclusive end) into an absolute `Location.t()`, correct even when the raw
attribute text contains entity or character references. Correct the two
moduledocs that today document a byte-offset-plus-span arithmetic which cannot
be written, because a predicator span carries no offset. Bead: st-nhpk
(mirrors sui-czr).

## Current State Analysis

**Nothing performs the composition today.** `grep -rn "resolve_span" lib`
returns nothing, so no runtime behavior is wrong; what is wrong is the recipe
two moduledocs hand every future consumer of an ADR-0014 item 4 payload
(statifier-ui first).

**The false claim, verbatim.** `lib/statifier/parser/location.ex:7-10`:

> Keeping both line/column and byte offsets is what makes ADR-0014's
> attribute-relative expression spans translatable into document positions by
> plain arithmetic: `value_location.start_offset + span.start` is a byte
> offset, convertible back to a line/column with `at_offset/2` if needed.

`lib/statifier/parser/dom/attribute.ex:7-9` repeats it in shorter form
("`value_location.start_offset` is what turns it into a document position").
`deps/predicator/lib/predicator/types.ex:117,140` fix the actual shape:
`position :: {line, column}` (1-based) and
`span :: {start :: position(), end_exclusive :: position()}`. There is no
integer to add to `start_offset`; the claim is a type error, not loose prose.

**Both coordinate systems already agree on units.** `Location` columns count
Unicode codepoints (`lib/statifier/parser/markup.ex:292-298`,
`location.ex:74-80`), and predicator's lexer tokenizes a charlist, advancing
`col + 1` per character and `line + 1, col 1` on `?\n`
(`deps/predicator/lib/predicator/lexer.ex:213-226`). Both ends are exclusive
(`types.ex:131-134`; `Location`'s moduledoc line 3). So the composition is a
coordinate walk, not a conversion.

**The entity problem is real and measured.** Verified by probe against this
worktree's parser:

| raw attribute text | `Attribute.value` (Saxy) |
|---|---|
| `x &lt; 1&#10;and\ty &gt; 2` | `x < 1\nand\ty > 2` |
| `a\nb` (literal newline) | `a\nb` (not normalized to a space) |
| `a &foo; b` (undeclared) | `a &foo; b` (kept verbatim) |
| `a &#x1F600; b` | `a 😀 b` |

Three consequences the algorithm must handle: a reference shifts columns; a
`&#10;` shifts *lines* in the expanded string while the raw stays on one line;
and an undeclared entity is kept verbatim, so "a raw `&...;` always collapses
to one expanded codepoint" is false. Saxy is called with no `:expand_entity`
option (`lib/statifier/parser.ex:113`), so `:keep` is the behavior in force,
and Saxy does not apply XML 1.0 3.3.3 attribute-value normalization.

**The expanded string is exactly what predicator counted.**
`Statifier.Compiler.Expressions.compile/3`
(`lib/statifier/compiler/expressions.ex:85-94`) passes the attribute value to
`Predicator.compile_with_spans/1` **untrimmed** and stores it as the third
element of `{:compiled, compiled, source}`.
`Statifier.Evaluator.Error.new/2` (`lib/statifier/evaluator/error.ex:43-45`)
carries that same string as `:source` next to the lifted `:span`. So every
holder of an ADR-0014 item 4 payload already holds the expanded string whose
coordinates the span is expressed in.

**The Machine does not retain the document source.** ADR-0041 rejected
retaining it precisely because "a span is only usable with the source in hand,
so the parent's entire source binary must ride the `Machine`"
(`docs/adr/0041-content-markup-lowers-to-a-source-slice.md:129-134`). The
resolving caller is therefore an embedder that already holds the source it
compiled - which is why the helper takes `source` as a parameter rather than
reading it from anywhere.

**st-18y's primitive is the correctness oracle.** `Location.slice/2`
(`location.ex:68-72`) plus the fixture-wide sweep in
`test/statifier/parser/location_accuracy_test.exs:13-41` is the established way
this repo proves a span is right: slice it back out and check the text, with no
line number hardcoded.

### Key Discoveries

- `deps/predicator/lib/predicator/types.ex:140` - `span` is a pair of
  `{line, column}` positions, exclusive end, no offset anywhere.
- `deps/predicator/lib/predicator/lexer.ex:225-226` - `?\r` advances **neither**
  line nor column in predicator's lexer, unlike `Location`'s cursor.
- `lib/statifier/parser/markup.ex:292-303` - `Location` columns are codepoints,
  matching predicator's per-character lexer.
- `lib/statifier/compiler/expressions.ex:85-94` - attribute expressions are
  compiled untrimmed, so the compiled `source` starts exactly at
  `value_location.start_offset` in expanded coordinates.
- `lib/statifier/compiler/expressions.ex:148-156` - `inline_value/1` **does**
  trim, but it can never return a `{:compiled, ...}` arm, so no span from it
  ever needs resolving.
- `docs/adr/0041-...:129-134` - the Machine deliberately does not carry source.
- `docs/adr/0014-expression-spans-in-cond-diagnostics.md:88-93` - item 4 fixes
  what an expression failure names; this helper is what makes the `:span` in
  that payload renderable.
- `lib/statifier/document.ex:41-44` and `lib/statifier/parser.ex:64-67` restate
  the *caveat* (entity-expanded value versus raw span) but not the false
  arithmetic; both stay true after this change.

## Desired End State

`Statifier.Parser.Location` exports

```elixir
@spec resolve_span(
        value_location :: t(),
        span :: Predicator.Types.span(),
        value :: binary(),
        source :: binary()
      ) :: t()
```

which returns the absolute document span of the subexpression `span` covers,
exclusive end preserved, correct in the presence of entity references,
character references, multi-byte characters, and multi-line attribute values.
Verification is by st-18y's primitive: `Location.slice(resolved, source)`
equals the raw source text of that subexpression. Both moduledocs describe the
helper instead of arithmetic that cannot be written, and `mix quality` is
green.

## What We're NOT Doing

- **Not recording raw value text on `DOM.Attribute`, `Document`, or
  `Machine`.** This is the bead's stated design call; see "The design call"
  below for the reasoning. `dom/attribute.ex:18`'s "if one ever does, the fix
  is for the scanner to record the raw value text alongside its span" is
  retired by this plan rather than implemented.
- **Not changing `DOM.Attribute`, the lowering, the compiler, or the Machine at
  all.** No struct gains a field; the change is one new function plus doc text.
- **Not wiring a renderer.** Nothing in `lib/` calls `resolve_span/4` after this
  bead; the consumer is statifier-ui. A helper with no in-repo caller is the
  deliberate outcome - the bead exists because the *documented* recipe was
  unwritable, not because a caller is blocked in this repo.
- **Not editing any ADR.**
  `docs/adr/0041-content-markup-lowers-to-a-source-slice.md:143-145` calls
  `markup_location.start_offset + child_offset` "the same plain arithmetic
  ADR-0014 fixed for expression spans". Its own arithmetic is sound - a child
  compile over a verbatim slice yields real byte offsets into that slice - only
  the analogy to ADR-0014 is inexact. ADRs are dated records of a decision, not
  living documentation; correcting prose inside an accepted one is out of scope
  here.
- **Not editing the research documents** under `docs/research/` that repeat the
  arithmetic (`260807-st-l5k.2:129`, `260807-st-l5k.4:544`,
  `260808-st-l5k.5:201,495`). They are dated snapshots of what was believed
  then, and rewriting them would falsify the record.
- **Not handling a trimmed expression source.** `resolve_span/4` requires that
  `value`'s position `{1, 1}` be `value_location`'s start. That holds for every
  attribute-sourced expression (`compile/3` does not trim) and for a `<script>`
  body passed untrimmed. A caller that trims before compiling must adjust the
  anchor itself; the `@doc` says so.
- **Not adding a corpus or ratchet change.** No conformance result can move:
  no evaluation path changes.

## Implementation Approach

### The design call: recompute the raw text, take the expanded text from the caller

The bead frames the choice as "record raw value text on the DOM, or recompute
it from `Location.slice/2` on demand". The answer is **recompute**, and the
reasoning splits into two halves, because two strings are involved.

**The raw text is recomputed, never stored.** `Location.slice(value_location,
source)` reproduces it exactly and is already the repo's sanctioned move for
this (`location.ex:60-67`, and every assertion in
`test/statifier/parser/location_accuracy_test.exs`). Storing it instead would:
duplicate every attribute value in the DOM on the hot parse path to serve a
cold diagnostic path; not actually reach the consumer, because the DOM is
discarded at lowering and the resolving caller holds a `Machine` plus a source
binary, never a `DOM.Attribute`; and, to reach the consumer, force the raw text
onto `Document` and `Machine` too - permanently growing the Machine in exactly
the way ADR-0041 declined for the same value
(`docs/adr/0041-...:129-134`). Since the helper needs `source` in hand
regardless (there is no other way to produce absolute offsets), storing the
slice would buy nothing that `source` does not already provide.

**The expanded text is a parameter, not a reconstruction.** This is the one
place this plan departs from the bead's sketched 3-arity signature, and it is
what makes the helper *exact* rather than *modelled*. Predicator counted
columns in the expanded string; if the helper reconstructed that string by
re-implementing Saxy's expansion rules, every divergence (Saxy's `:keep` for
undeclared entities, a future Saxy applying XML 3.3.3 normalization, a
character-reference form mis-modelled) would silently mis-underline instead of
failing loudly. Taking `value` makes the walk a verified alignment of two
strings this repo already holds - and it costs the caller nothing, because
`Evaluator.Error` carries `source` and `span` side by side
(`lib/statifier/evaluator/error.ex:28-35`) and `Machine.expr()`'s
`{:compiled, _, source}` third element is the same string.

### The algorithm

A single left-to-right lockstep walk over `raw = slice(value_location, source)`
and `value`, carrying two cursors:

- a **raw cursor** `{offset, line, column}`, seeded from `value_location`'s
  start, advanced exactly the way `Markup.advance/2` advances
  (`markup.ex:294-298`): `+byte_size` on offset, `line + 1, column 1` on `\n`,
  else `column + 1`;
- an **expanded cursor** `{line, column}`, seeded `{1, 1}` - predicator's
  coordinate origin.

At each step, one *unit* is consumed from each side:

1. If `raw` begins with a reference token matching
   `&(#[0-9]+|#x[0-9A-Fa-f]+|name);` **and** `value` begins with that token's
   decoded codepoint, consume the whole token from `raw` (advancing the raw
   cursor per codepoint) and one codepoint from `value`. This is the shifting
   case: `&lt;` is four raw columns and one expanded column; `&#10;` is five
   raw columns on one raw line and one expanded *line* break.
2. Otherwise, if the leading codepoints are equal, consume one from each. This
   covers plain text and an undeclared `&foo;` that Saxy kept verbatim, since
   there the two strings agree character for character.
3. Otherwise, if the raw codepoint is TAB/LF/CR and the expanded codepoint is a
   space, consume one from each. XML 1.0 3.3.3 attribute-value normalization;
   Saxy does not do it today, so this clause is inert, but it keeps the walk
   exact rather than desynced if it ever starts.
4. Otherwise the two strings do not describe the same text: **desync**.

The expanded cursor advances `line + 1, column 1` on a `\n`, holds still on a
`\r` (mirroring `deps/predicator/lib/predicator/lexer.ex:225-226`, with an
inline comment citing it), and `column + 1` otherwise. The raw cursor's `\r`
handling is unchanged, since it must keep describing the document.

Before consuming each unit, the current expanded cursor is compared against the
span's two target positions; the raw cursor is captured the first time the
expanded cursor reaches or passes each. Both targets resolve by the identical
rule, which is what preserves the exclusive-end convention: the exclusive end
position is the position of the first codepoint *not* covered, and it maps to
the raw position of the first raw codepoint not covered.

Two degradations, both documented and tested, neither of which raises - a
diagnostic renderer must never be the thing that crashes:

- a target position past the end of `value` clamps to `value_location`'s end;
- a desync (case 4) returns `value_location` unchanged, which underlines the
  whole attribute value: less precise, never wrong.

`nil` is not accepted for either `value_location` (nilable on
`DOM.Attribute`/`Machine.Data`) or `span` (nil when predicator could not
attribute one, per ADR-0014 item 4). The function pattern-matches
`%Location{}` and a two-position tuple; a caller holding `nil` has nothing to
resolve and falls back to the owning node's own `location`. The `@doc` states
this so the fallback stays the caller's decision rather than a silent one.

### Layering note

`Location` lives under `lib/statifier/parser/` and references no predicator
type today. `Predicator.Types.span()` appears here in a `@spec` only - no
runtime call, no struct. The documented layering prohibition is specific to
`lib/statifier/document/` (`lib/statifier/document.ex:20`) and does not reach
the parser. Naming the upstream type rather than inlining
`{{pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}}` is
deliberate: a predicator span shape change should redden dialyzer here.

## Phase 1: `Location.resolve_span/4` and the two moduledocs

### Overview

Add the helper, its unit tests, and the corrected doc text. One commit: leaving
the false arithmetic standing next to the correct helper would be a
self-contradicting tree, and the helper without the doc fix does not satisfy
the bead's acceptance criteria either.

### Changes Required:

#### 1. The helper

**File**: `lib/statifier/parser/location.ex`
**Changes**: Add `resolve_span/4` plus its private walk. Shape:

```elixir
@doc """
The absolute document span of the subexpression `span` covers.

`value_location` is the raw-source span of an attribute's value (the text
inside the quotes); `value` is the entity-expanded string that was handed to
predicator - `Machine.expr()`'s `{:compiled, _, source}` third element, or
`Statifier.Evaluator.Error`'s `:source` - and `span` is a predicator span
over `value`, 1-based line/column with an exclusive end
(`t:Predicator.Types.span/0`). The returned location's end is exclusive too.

`value` is required rather than reconstructed: predicator counted columns in
that exact string, and a reference in the raw source (`&lt;`, `&#10;`) makes
raw and expanded coordinates diverge. Walking the two together is what keeps
the result exact; re-deriving the expansion here would only model it. The raw
text is *not* required, because `slice/2` recovers it from `source`.

Requires `value`'s position `{1, 1}` to be `value_location`'s start - true of
every attribute-sourced expression, since
`Statifier.Compiler.Expressions.compile/3` does not trim. A caller that
trimmed before compiling must adjust the anchor itself.

Degrades rather than raising: a position past the end of `value` clamps to
`value_location`'s end, and a `value` that does not describe the same text as
the raw slice returns `value_location` whole - underlining the entire
attribute value instead of a subexpression.

A `nil` `value_location` or a `nil` span has nothing to resolve; the caller
falls back to the owning node's own `location` rather than calling this.
"""
@spec resolve_span(
        value_location :: t(),
        span :: Predicator.Types.span(),
        value :: binary(),
        source :: binary()
      ) :: t()
def resolve_span(
      %__MODULE__{} = value_location,
      {{_start_line, _start_column}, {_end_line, _end_column}} = span,
      value,
      source
    )
    when is_binary(value) and is_binary(source) do
  # slice the raw text, walk raw/value in lockstep, capture the raw cursor
  # at each of the span's two target positions, build the Location.
end
```

The walk is the four-case unit rule from "The algorithm" above, as a private
recursive function over `{raw_rest, value_rest, raw_cursor, expanded_pos}`,
with the reference decode table (`lt gt amp quot apos` plus `&#N;` / `&#xN;`)
private to this module. Every decode is validated against `value` before it is
believed, so the table can only ever cause a fallback, never a wrong answer.

#### 2. The `Location` moduledoc

**File**: `lib/statifier/parser/location.ex`
**Changes**: Replace lines 7-10 (the "plain arithmetic" paragraph) with text
that says a predicator span has no offset in it, and names `resolve_span/4` as
the composition. Roughly:

```
Keeping both line/column and byte offsets is what lets an ADR-0014
expression span be resolved into an absolute document span: the line/column
half is the coordinate system a predicator span speaks
(`t:Predicator.Types.span/0` is a pair of 1-based `{line, column}`
positions - there is no offset in it, so no arithmetic on `start_offset`
stands in for the composition), and the offset half is what makes the
result sliceable back out of the source. `resolve_span/4` does the
composition, accounting for entity references in the raw text.
```

#### 3. The `DOM.Attribute` moduledoc

**File**: `lib/statifier/parser/dom/attribute.ex`
**Changes**: Two edits. Lines 7-9 stop claiming `value_location.start_offset`
"turns it into a document position" and point at
`Statifier.Parser.Location.resolve_span/4` as the anchor's consumer. Lines
14-18 keep the entity caveat (it is true and worth stating) but replace the
"if one ever does, the fix is for the scanner to record the raw value text"
sentence with the resolution actually taken: `resolve_span/4` accounts for the
difference by walking the raw slice against the expanded value, and
`Location.slice(value_location, source)` recovers the raw text on demand, so
nothing needs to be stored here.

#### 4. Changelog fragment

**File**: `changelog.d/st-nhpk.md`
**Changes**: New file, `### Added` section - a public helper that maps a
predicator expression span onto absolute document coordinates, entity
references included. A capability v1 never had, so it earns a fragment under
`changelog.d/README.md`'s narrower v2 rule.

#### 5. Unit tests

**File**: `test/statifier/parser/location_test.exs`
**Changes**: New `describe "resolve_span/4"` block, each test asserting through
`Location.slice/2` on a real parsed document rather than on hand-written
numbers, and each carrying its `# sabotage:` line. Cases:

1. plain ASCII, no references - span over `score` in `score > 5`;
2. a reference *before* the span - `1 &lt; score` - proving the +3 raw shift;
3. `&#10;` inside the value, span on expanded line 2 - proving a line shift
   that the raw source does not have;
4. multi-byte text before the span (`café`) - codepoint columns, byte offsets;
5. a literal newline inside the raw attribute value - absolute line is the
   document's, not the value's;
6. exclusive end preserved - `end_offset - start_offset` equals the byte size
   of the subexpression, and a zero-width span resolves zero-width;
7. an undeclared entity kept verbatim (`&foo;`) - the 1:1 clause carries it;
8. a `\r` in the value - the expanded column holds still, mirroring
   predicator's lexer;
9. a target past the end of `value` - clamps to `value_location`'s end;
10. a `value` that does not describe the raw slice - returns `value_location`
    whole;
11. a synthetic `value` pairing a raw TAB/LF/CR with a space, exercising the
    normalization clause (case 3). No Saxy-produced `value` can reach it
    today, so this is the only way to cover that branch - and covering it is
    required, not optional: the clause stays in the code deliberately, and
    deleting it to satisfy coverage would be going green by weakening the
    check.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` is green (`mix quality --profile loop` while
      iterating; a loop-profile green does not satisfy this phase)
- [x] `mix gate.verify` confirms the green run was a full, unscoped gate
- [x] `grep -n "start_offset + span" lib/` returns nothing
- [x] `mix docs` builds without a broken-reference warning for
      `resolve_span/4` (dialyzer in the full gate covers the
      `Predicator.Types.span()` reference resolving)
- [x] Doctor's 100% thresholds still pass - the new public function carries a
      `@doc` and a `@spec`
- [x] `changelog.d/st-nhpk.md` exists

#### Manual Verification:
- [ ] Spec judgment: Appendix D models no parsing, so the standard against
      which this code is read is not the pseudocode but the two coordinate
      contracts it joins - `t:Predicator.Types.span/0`'s 1-based, exclusive-end
      line/column pair and XML 1.0 3.3.3's attribute-value rules. Confirm by
      reading the cached spec (`spec-cache/scxml-rec.html` is not the authority
      here; XML 1.0 3.3.3 is) that treating TAB/LF/CR-versus-space as a 1:1
      match is normalization-correct
- [ ] The `\r` clause's inline comment cites
      `deps/predicator/lib/predicator/lexer.ex:225-226`, and the behavior still
      matches that code in the installed dep
- [ ] Both moduledocs read as a description of `resolve_span/4`, with no
      residual suggestion that adding to `start_offset` composes a span
- [ ] No regressions in related features: the parser, lowering, and compiler
      are untouched by inspection of the diff

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: End-to-end proof through the real compile and evaluate path

### Overview

Phase 1's tests feed `resolve_span/4` spans written by hand. This phase proves
the composition against spans predicator actually produced, reached through the
same path a diagnostic renderer will use - parse, compile with
`compile_with_spans/1`, evaluate to failure, read `Evaluator.Error`'s `:span`
and `:source`, resolve, slice - and extends the fixture-wide location sweep
with the identity property. Separately committable: test-only, no `lib/`
change, and it fails loudly on its own if Phase 1's walk is wrong.

### Changes Required:

#### 1. Round-trip test through the evaluator

**File**: `test/statifier/parser/location_span_resolution_test.exs` (new)
**Changes**: A small suite that does not live in `location_test.exs` because it
crosses the parser, compiler, and evaluator rather than unit-testing one
module. Each test:

1. parses a document whose `cond` contains an entity reference, e.g.
   `cond="1 &lt; score"`;
2. reaches the attribute's `value_location` (via the DOM, or via
   `Document`'s `attribute_locations[:cond]` - whichever the lowering already
   exposes for the node under test);
3. compiles the expanded value with
   `Statifier.Compiler.Expressions.compile/3`;
4. evaluates it against a `Predicator.Context.new(%{}, on_unbound: :error)` via
   `Statifier.Evaluator.evaluate/2`, which yields
   `{:error, %Statifier.Evaluator.Error{span: span, source: expr_source}}` with
   a real `UndefinedVariableError` span over `score` (ADR-0014 item 5);
5. asserts
   `Location.slice(Location.resolve_span(value_location, span, expr_source, xml), xml) == "score"`.

The local binding is deliberately named `expr_source`, not `source`: "source"
means two different things across this call. `Evaluator.Error.source` is the
*expanded expression string* and belongs in argument 3, while `resolve_span/4`'s
own fourth parameter, also named `source`, is the *raw document*. The call is
decided by position, and transposing 3 and 4 is the mistake this naming exists
to prevent.

A second case puts the failing identifier *after* a `&#10;`, so the assertion
exercises the line shift end to end.

A third case covers a compile-time `ParseError` (a malformed cond), and it does
**not** go through `Evaluator.Error` - nothing evaluates, so no evaluator error
is ever built. `Statifier.Compiler.Expressions.compile/3` returns
`{:error, %Statifier.Compiler.Error{reason: reason, location: location}}`, whose
`reason` is the single closed-union arm
`{:expression_compile_error, owner, source, %Predicator.Errors.ParseError{}}`
(`lib/statifier/compiler/error.ex:29-32`). The span for `resolve_span/4` is
`parse_error.span` (present in every compile mode, since it comes from the token
stream - `lib/statifier/compiler/expressions.ex:76-81`), and the expanded string
is the tuple's third element, not a top-level `:source` field. The assertion is
the same shape: the resolved span slices back out of the raw document as the
offending token.

#### 2. The identity property in the fixture sweep

**File**: `test/statifier/parser/location_accuracy_test.exs`
**Changes**: Extend the existing per-attribute sweep
(`assert_attribute_accurate/2`, lines 84-98) with one more property, applied to
every attribute of every fixture: resolving the *whole-value* span - from
`{1, 1}` to the position one past the last codepoint of `attribute.value`,
computed by walking `value` - must return `attribute.value_location` exactly.
No line number is written down, it runs over every fixture the file already
parses, and it is the strongest single statement of the helper's contract: the
full-value span is the identity.

### Success Criteria:

#### Automated Verification:
- [ ] Full `mix quality` is green (`mix quality --profile loop` while
      iterating)
- [ ] `mix gate.verify` confirms the run was a full, unscoped gate
- [ ] `mix test test/statifier/parser/location_span_resolution_test.exs
      test/statifier/parser/location_accuracy_test.exs` passes on its own
- [ ] Every new test carries a `# sabotage:` line naming the mutation that
      reddened it (or an explicit `# sabotage: n/a - ...` for the harness
      helper), per `docs/testing.md`
- [ ] No conformance movement to ratchet: `mix test.regression` still passes
      and `test/passing_tests.json` is unchanged by the diff

#### Manual Verification:
- [ ] Spec judgment: the resolved span underlines what a human reading the raw
      XML would underline - checked by eye on the entity fixture, since "the
      right span" is ultimately a rendering judgment no assertion fully
      captures
- [ ] The sabotage runs were actually performed (break the walk's reference
      clause, confirm red, revert), not merely annotated
- [ ] No regressions in related features: the existing location-accuracy sweep
      still covers what it did before the extension

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/statifier/parser/location_test.exs` - the ten `resolve_span/4` cases
  listed in Phase 1, each asserting through `Location.slice/2` rather than
  hardcoded coordinates, so an off-by-one anywhere in the walk reddens without
  a fixture rewrite.
- Key edge cases, restated as the properties they defend: a reference before
  the span (column shift), `&#10;` inside the span's prefix (line shift), a
  multi-byte prefix (codepoint versus byte columns), a literal newline in the
  raw value (document line versus value line), a zero-width span (exclusive-end
  identity), an undeclared entity (Saxy's `:keep`), a `\r` (predicator's lexer
  quirk), an out-of-range target (clamp), a mismatched `value` (fallback), and
  a synthetic TAB/LF/CR-versus-space pairing (the normalization clause, which
  no Saxy output can reach today and which coverage would otherwise leave
  bare).
- `test/statifier/parser/location_span_resolution_test.exs` - the same
  composition driven by spans predicator actually emitted.
- `test/statifier/parser/location_accuracy_test.exs` - the whole-value identity
  property over every fixture.

### Manual Testing Steps:

1. In `iex -S mix`, parse
   `~s(<scxml><transition cond="1 &lt; score" target="s"/></scxml>)`, take the
   `cond` attribute's `value_location`, compile the value with
   `Predicator.compile_with_spans/1`, evaluate against
   `Predicator.Context.new(%{}, on_unbound: :error)`, and resolve the error's
   span. Confirm `Location.slice/2` returns `"score"` and not `"core"` or
   `"e" <> _`.
2. Repeat with the same document reformatted so the attribute starts on line 3
   and the value contains `&#10;` before `score`. Confirm the resolved
   `start_line` is the document's line 3 - not 4, which is what an
   expanded-coordinate line number would give.
3. Read the rendered docs (`mix docs`, open
   `Statifier.Parser.Location`) and confirm a reader arriving cold gets a
   recipe they can follow, with no residual offset arithmetic.

## Corpus/Ratchet Notes

Nothing here can move a conformance result: no parse, lowering, validation,
compile, or evaluation behavior changes, and the new function has no caller in
`lib/`. `test/passing_tests.json` must be unchanged by both phases; a diff
against it is a signal that something in the change was not confined to docs
and a new leaf function. `mix test.regression` is listed in Phase 2's automated
criteria as that check.

## Open Questions

Recorded for the record and answered, per this skill's "no unresolved open
questions" rule - each was a judgment call this plan made rather than an
unknown it left standing.

1. **Arity 4 versus the bead's sketched 3.** Answered above under "The design
   call": the expanded string is a parameter because reconstructing it would
   model Saxy rather than observe it, and every caller of an ADR-0014 item 4
   payload already holds it. If review prefers the 3-arity shape, the cost is
   an in-repo re-implementation of entity expansion that can silently diverge
   from Saxy - which is the exact failure mode this bead exists to remove.
2. **Mirroring predicator's `\r` column quirk.** Answered: mirror it, with an
   inline comment citing the lexer line and a test pinning it, so an upstream
   change reddens here rather than mis-underlining in a renderer. The
   alternative - treating `\r` as an ordinary codepoint - is wrong against the
   installed dep today.
3. **Degradation policy.** Answered: clamp on overrun, whole-value on desync,
   never raise. A diagnostic path that crashes is worse than one that
   underlines too much.
4. **Saxy does not apply XML 1.0 3.3.3 attribute-value normalization** (probed:
   a literal newline survives into `Attribute.value`). Answered: not this
   bead's problem, and the walk is correct either way because it aligns to
   Saxy's actual output; case 3 of the unit rule keeps it exact if Saxy's
   behavior ever changes. Worth a separate bead against the parser if
   normalization is ever wanted for spec conformance - filing it is a human's
   call, not this plan's.

## References

- Bead: `st-nhpk` (mirrors `sui-czr`)
- Related ADRs: `docs/adr/0014-expression-spans-in-cond-diagnostics.md`
  (items 1, 2, 4, 5), `docs/adr/0012-debuggability-designed-into-the-core.md`
  (constraint 3), `docs/adr/0041-content-markup-lowers-to-a-source-slice.md`
  (why the Machine carries no source),
  `docs/adr/0004-predicator-as-the-datamodel.md`
- The false claims: `lib/statifier/parser/location.ex:7-10`,
  `lib/statifier/parser/dom/attribute.ex:7-9`
- The span contract: `deps/predicator/lib/predicator/types.ex:113-152`;
  the lexer's cursor: `deps/predicator/lib/predicator/lexer.ex:213-226`
- The cursor to mirror: `lib/statifier/parser/markup.ex:292-314`
- The compile seam: `lib/statifier/compiler/expressions.ex:83-94`
- The payload that carries the span: `lib/statifier/evaluator/error.ex:28-45`
- Similar implementation (the slice-it-back-out oracle):
  `test/statifier/parser/location_accuracy_test.exs:13-41,84-98`
- Testing rules: `docs/testing.md`; changelog rules:
  `changelog.d/README.md`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Spec judgment: Appendix D models no parsing, so the standard against
      which this code is read is not the pseudocode but the two coordinate
      contracts it joins - `t:Predicator.Types.span/0`'s 1-based, exclusive-end
      line/column pair and XML 1.0 3.3.3's attribute-value rules. Confirm by
      reading the cached spec (`spec-cache/scxml-rec.html` is not the authority
      here; XML 1.0 3.3.3 is) that treating TAB/LF/CR-versus-space as a 1:1
      match is normalization-correct
- [ ] The `\r` clause's inline comment cites
      `deps/predicator/lib/predicator/lexer.ex:225-226`, and the behavior still
      matches that code in the installed dep
- [ ] Both moduledocs read as a description of `resolve_span/4`, with no
      residual suggestion that adding to `start_offset` composes a span
- [ ] No regressions in related features: the parser, lowering, and compiler
      are untouched by inspection of the diff

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
