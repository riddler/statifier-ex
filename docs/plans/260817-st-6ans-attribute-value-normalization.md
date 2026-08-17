---
date: 2026-08-17
planner: Claude
git_commit: 102eedce9dab0536d31c632f789e29fa84efabea
branch: st-6ans-attribute-normalization
repository: statifier-ex
beads_issue: st-6ans
topic: "XML 1.0 3.3.3 attribute-value normalization in the parser, guided by the raw source"
tags: [plan, parser, xml-conformance, locations]
status: ready
last_updated: 2026-08-17
last_updated_by: Claude
---

# Attribute Value Normalization (XML 1.0 3.3.3) Implementation Plan

## Overview

Make `Statifier.Parser.DOM.Attribute`'s `value` the XML 1.0 3.3.3-normalized,
entity-expanded string: a literal `#x20` / `#x9` / `#xA` / `#xD` inside an
attribute value becomes a space, a literal `\r\n` pair becomes one space, and a
character reference keeps its decoded character verbatim. `value_location`
keeps covering raw source unchanged. Bead: st-6ans. The decision this
implements is ADR-0043; it is accepted and is not reopened here.

## Current State Analysis

Saxy 1.6.1 applies neither XML 1.0 3.3.3 attribute-value normalization nor 2.11
line-break normalization. Probed in this worktree on 2026-08-17 through
`Statifier.Parser.parse/1`:

| raw attribute text | `Attribute.value` today | required by 3.3.3 |
|---|---|---|
| `a<LF>b` | `"a\nb"` | `"a b"` |
| `a<CR><LF>b` | `"a\r\nb"` | `"a b"` (one space; 2.11 folds first) |
| `a<CR>b` | `"a\rb"` | `"a b"` |
| `a<TAB>b` | `"a\tb"` | `"a b"` |
| `a&#10;b` | `"a\nb"` | `"a\nb"` (already correct) |
| `a&#13;b` | `"a\rb"` | `"a\rb"` (already correct) |
| `a&#9;b` | `"a\tb"` | `"a\tb"` (already correct) |

The Saxy-does-not-do-2.11 half of that table is a load-bearing finding the ADR
did not have: it means the normalization walk sees `"\r\n"` on **both** sides
(raw and Saxy value), so a naive per-unit mapping would emit two spaces, not
one. The CRLF fold has to be expressed over consumed units rather than per
codepoint. See Phase 2.

Where the pieces are:

- `lib/statifier/parser/handler.ex:162-175` - `build_attributes/2` copies
  Saxy's value straight through. It has no `source` in reach; it is called at
  `handler.ex:87` from `handle_event(:start_element, ...)`, where `state`
  (and therefore `state.source`) is available.
- `lib/statifier/parser/markup.ex:207-220` - the scanner produces
  `%{name, location, value_location}` per attribute; `value_location` spans the
  text inside the quotes. `handler.ex:172` already tolerates a missing scanner
  record (`scanned && scanned.value_location`), and
  `lib/statifier/lowering/attributes.ex:92` and
  `lib/statifier/validator/checks/default_transition.ex:25` both document that
  `nil` path as real.
- `lib/statifier/parser/location.ex:201-236` - `next_unit/2` and
  `next_unit_plain/2`, the four-case unit rule (reference / identical / raw
  TAB-LF-CR versus expanded space / desync) plus `match_reference/1` and
  `decode_reference/1`. Case 3 exists but is unreachable through a real parse
  today.
- `lib/statifier/parser/location.ex:279-297` - `raw_advance_string/2` and
  `expanded_advance/2`, which already handle a multi-codepoint raw token
  (that is how a `&lt;` token advances) and hold the expanded cursor still on
  `\r` to mirror predicator's lexer.
- `lib/statifier/parser.ex:11-17,64-68` - the "Nothing is validated,
  normalized, or resolved" claim and the "One consequence is worth stating"
  paragraph, both of which state the behavior this bead changes.
- `lib/statifier/parser/dom/attribute.ex:14-20` - "`value` is Saxy's
  entity-expanded text", same.
- `test/statifier/parser/location_test.exs:~318` - the synthetic TAB test whose
  "Passed by hand" note exists only because the clause is unreachable.
- `test/statifier/parser/location_test.exs:~188` - the literal-newline test,
  which asserts `{{2, 1}, {2, 7}}` over a value that will no longer have a
  second line.
- `test/statifier/parser_test.exs:133-178` - the `parse/1 - attributes`
  describe block, the natural home for `Attribute.value` assertions.
- `test/statifier/parser_test.exs:70-106` - the `parse/1 - locations` setup
  fixture carries a `label` attribute wrapped across two physical lines
  (`:77-78`). The test at `:93-106` asserts only raw-source coordinates for the
  element that follows it, so it stays green - but the fixture is the input to
  the every-attribute property below, which is where the interesting exposure is.
- `test/statifier/parser/location_accuracy_test.exs:89-127` -
  `assert_attribute_accurate/2` and `assert_whole_value_span_is_identity/2`,
  run over **every attribute of every fixture**. The first reconstructs
  `name="rawvalue"` from the two spans, raw against raw, so normalization
  cannot touch it. The second is the one to think about: it computes
  `whole_value_end(attribute.value)` in predicator's coordinate system and
  asserts `resolve_span/4` over `{{1, 1}, end}` returns `value_location`
  exactly. Traced by hand for the wrapped `label`: the value goes from
  `"a value\nthat wraps a line"` (end `{2, 19}`) to `"a value that wraps a
  line"` (end `{1, 26}`), while the walk pairs the raw `\n` against the
  expanded space through `next_unit_plain/2` case 3 and lands the raw cursor on
  `value_location`'s end either way. The property holds - and after this change
  it exercises the normalization clause across the whole fixture set, which is
  a strengthening rather than a risk. It must still be run and read, not
  assumed.
- `test/statifier/parser/location_span_resolution_test.exs` - all three tests
  use `&#10;` / `&lt;` references, never a literal line break, so none of them
  move.

A full sweep of the repo found exactly four literal-whitespace attribute values
and one literal TAB: `parser_test.exs:77-78` (`label`), `location_test.exs:191`
(`cond`), `location_test.exs:319` (`cond`, the deliberate TAB), and the two
SCION corpus `cond`s. There are no `.xml` or `.scxml` files anywhere under
`test/` or `tools/` - the corpus is generated Elixir modules with heredoc XML,
so the sweep is complete. `test/scion_tests/send_internal/test0_test.exs:59-62`
additionally has **trailing spaces before each line break**, so its normalized
`cond` contains runs of two or more spaces: correct under CDATA treatment,
which collapses nothing.

Nothing in `lib/` calls `resolve_span/4` yet, so the coordinate change lands
before any consumer depends on the unnormalized coordinates.

## Desired End State

`Statifier.Parser.parse/1` returns attributes whose `value` is what a
conforming XML processor would hand the application, and whose `value_location`
is unchanged raw source. Verified by:

- `Statifier.Parser.DOM.attribute(root, "cond").value == "a b"` for a `cond`
  written `a<LF>b`, `a<CR><LF>b`, `a<CR>b`, or `a<TAB>b`, and `== "a\nb"` for
  `a&#10;b`.
- `Location.resolve_span/4` still slices the exact raw subexpression for every
  one of those, including across a CRLF.
- `location_test.exs` has no "Passed by hand" note on the normalization clause.
- The conformance suites and the ratchet are green.

### Key Discoveries:

- **ADR-0043** (`docs/adr/0043-attribute-values-normalize-per-xml-3-3-3.md`) is
  the decision; it is currently uncommitted in this worktree along with an edit
  to `docs/adr/README.md`. Phase 1 commits both.
- **Saxy does no 2.11 either** (probe above). The ADR assumed a raw `\r\n`
  reached the walk as one `#xA`; it does not. This changes nothing about the
  decision - a raw `\r\n` still yields exactly one space - but it fixes where
  the fold has to be implemented (over units, in the normalization pass) and it
  confirms the ADR's decision item 3 is genuinely required: after
  normalization, `resolve_span/4` walks raw `"\r\n"` (two codepoints) against a
  normalized `" "` (one), which `next_unit_plain/2` desyncs on today.
- **`next_unit_plain/2`'s ordering is load-bearing.** `raw_cp == value_cp` must
  keep being checked before any CRLF clause, or the pre-normalization walk
  (raw `"\r\n"` against Saxy's `"\r\n"`) would take the wrong branch.
- **Predicator is whitespace-insensitive across all four characters**
  (`deps/predicator/lib/predicator/lexer.ex:215-226`), so no compiled
  instruction or evaluation result changes - only span tables. No corpus
  assertion reads a span (ADR-0043 Context).
- **The corpus holds exactly two multi-line attribute values**, both `cond`s:
  `test/scion_tests/send_data/send1_test.exs` and
  `test/scion_tests/send_internal/test0_test.exs`.
- **`resolve_span/4`'s anchor contract holds unchanged**: CDATA treatment means
  no trim, so `value`'s `{1, 1}` is still `value_location`'s start
  (`location.ex:94-97`).

## What We're NOT Doing

- **Not touching text content.** XML 2.11 line-break normalization of character
  data is ADR-0043 decision item 4: out of scope, its own bead if pursued. The
  ADR's recorded open question on this stays open and stays out of this plan.
- **Not trimming or collapsing whitespace runs.** CDATA treatment only
  (ADR-0043 decision item 2). Two literal newlines in a row become two spaces.
  `Statifier.Compiler.Expressions` keeps not trimming.
- **Not changing `value_location`, `location`, or the `Markup` scanner.**
  Normalization changes the string, never the span.
- **Not making the desync fallback impossible.** ADR-0043's Consequences invite
  that if it turns out cheap; it is not, because the `nil` `value_location` path
  is a real documented state elsewhere in `lib/`. The fallback (keep Saxy's
  value unnormalized) is implemented and tested as the chosen behavior.
- **Not adding a `Statifier.Parser.Attributes` module.** The reference-decode
  logic lives in `Location` and stays there; a second module would either
  duplicate the regex (which ADR-0043 forbids) or force `next_unit/2` public.
- **Not re-running the corpus generator.** `mise run corpus` regenerates
  fixtures; this change does not alter what should be generated, only how the
  parser reads it.

## Implementation Approach

Two phases, split at the module boundary between `Location` (the walk
primitives) and `Handler` (the parser's output).

Phase 1 adds the `\r\n`-pair unit to `resolve_span/4`'s walk. It is a pure
addition to a branch that is unreachable through a real parse today, so it
changes no observable behavior and is gate-green on its own. It has to land
first: without it, the moment Phase 2 normalizes a CRLF-wrapped attribute,
`resolve_span/4` desyncs to the whole-value fallback.

Phase 2 adds the normalization walk, rewires the handler, updates the four
moduledocs that state the old behavior, converts the synthetic tests to real
parses, and re-runs conformance.

On the extension file's Appendix D rule: this is parser work, and Appendix D
has no pseudocode for XML parsing - the interpreter is untouched, so there is
no deviation to declare. The equivalent spec-conformance judgment for this
layer is XML 1.0 3.3.3 and 2.11 plus SCXML Appendix A.2, and that is what both
phases' manual criteria are written against, read from the local spec cache
rather than from memory.

Phase 1's new test is necessarily synthetic (it hand-feeds a normalized
`" "` value, exactly as the existing TAB test at `location_test.exs:~318`
does), because nothing produces a normalized value until Phase 2. Phase 2
converts it, along with the pre-existing TAB test, to a real parse. That churn
is deliberate and is the price of keeping Phase 1 independently committable;
it is a two-line edit each.

### Judgment calls made while authoring

This plan was written without a human available to consult, so four calls were
made from the evidence rather than asked. Each is settled for implementation
purposes; each is flagged here so a reviewer can overrule it cheaply.

1. **A changelog fragment is written.** `changelog.d/README.md`'s rewrite-era
   rule is "write a fragment when v2 differs from v1", and v1 also parsed with
   Saxy and also passed literal newlines through, so this is behavior v2 has
   and v1 did not. It is also a change in observable behavior of a public API's
   output, which the general list names outright. The argument the other way -
   that predicator is whitespace-insensitive, so no evaluation result changes -
   is real but narrower than the rule as written. Drop the fragment if a
   reviewer disagrees; nothing else in the plan depends on it.
2. **`normalize_attribute_value/3` lives in `Location`, not a new module.**
   See "What We're NOT Doing".
3. **Its signature is `(value_location, value, source)`**, mirroring
   `resolve_span/4`'s trailing three arguments, rather than the simpler
   `(raw, value)`. The reason is that the two functions then read as one
   family and the handler passes the same three things to both. `(raw, value)`
   would be marginally easier to unit-test; the desync test in Phase 2 works
   either way.
4. **Two phases, not one.** One phase would avoid Phase 2's re-editing of
   Phase 1's synthetic test. Two was chosen because ADR-0043 itemizes them
   separately, because the `\r\n` unit is a strict prerequisite whose absence
   would silently degrade CRLF attributes to the whole-value fallback rather
   than fail loudly, and because this repo's authority table gates on
   per-phase gate-green commits.

---

## Phase 1: The `\r\n` pair unit in `resolve_span/4`

### Overview

Teach `next_unit_plain/2` to consume a raw `\r\n` pair against a single
expanded space, so a CRLF-wrapped attribute resolves instead of desyncing.
Commit ADR-0043 in the same commit, since it is the record this branch
implements.

### Changes Required:

#### 1. The unit rule

**File**: `lib/statifier/parser/location.ex`
**Changes**: Add a CRLF clause to `next_unit_plain/2`'s `cond`, **after** the
`raw_cp == value_cp` branch and before the single-codepoint normalization
branch. Ordering is the correctness point: the pre-normalization walk (Phase 2)
pairs raw `"\r\n"` against Saxy's `"\r\n"`, and that must keep taking the
identical-codepoint branch.

```elixir
defp next_unit_plain(raw, value) do
  with {raw_cp, raw_rest} <- String.next_codepoint(raw),
       {value_cp, value_rest} <- String.next_codepoint(value) do
    cond do
      raw_cp == value_cp ->
        {:ok, raw_cp, value_cp, raw_rest, value_rest}

      # 2.11 folds a literal CRLF to one #xA before 3.3.3 maps it to one
      # #x20, so two raw codepoints pair with a single expanded space. Must
      # follow the identical-codepoint branch: an unnormalized value still
      # spells "\r\n" and has to walk as two plain units.
      raw_cp == "\r" and value_cp == " " and String.starts_with?(raw_rest, "\n") ->
        {:ok, "\r\n", value_cp, binary_part(raw_rest, 1, byte_size(raw_rest) - 1), value_rest}

      raw_cp in ["\t", "\n", "\r"] and value_cp == " " ->
        {:ok, raw_cp, value_cp, raw_rest, value_rest}

      true ->
        :desync
    end
  else
    _empty -> :desync
  end
end
```

`raw_advance_string/2` already handles a two-codepoint token correctly - it
folds codepoint by codepoint, and its `"\n"` clause advances the line - so no
cursor change is needed. Update its comment at `location.ex:277-278`, which
currently asserts a raw token is "either a single plain codepoint or a whole
reference token"; a CRLF pair is now a third case.

#### 2. The four-case comment

**File**: `lib/statifier/parser/location.ex:195-200`
**Changes**: The unit-rule comment says "four-case"; it is five now. Name the
CRLF pair and cite XML 2.11.

#### 3. Test

**File**: `test/statifier/parser/location_test.exs`
**Changes**: One test in the `resolve_span/4` describe block, beside the
existing TAB test, with a sabotage line per `docs/testing.md`.

```elixir
# sabotage: the CRLF branch's `String.starts_with?(raw_rest, "\n")` guard
# dropped, so a lone raw "\r" consumes a following byte that is not a
# newline -> ... (author the real mutation and its observed failure)
test "a raw CRLF pair paired with one expanded space walks as a single unit" do
  source = "<edge cond=\"a\r\nb\"/>"
  attribute = root_attribute(source)

  # Passed by hand until st-6ans Phase 2 normalizes attribute values: Saxy
  # returns "a\r\nb" verbatim, so the pair-versus-space unit has no real
  # parse that produces it yet.
  value = "a b"

  resolved = Location.resolve_span(attribute.value_location, {{1, 3}, {1, 4}}, value, source)

  assert Location.slice(resolved, source) == "b"
end
```

Also assert the CRLF does not desync the whole walk (a `{{1, 1}, {1, 4}}` span
slices `"a\r\nb"` entire) in the same test, so a silent fallback to
`value_location` cannot pass.

#### 4. The ADR

**Files**: `docs/adr/0043-attribute-values-normalize-per-xml-3-3-3.md` (new,
untracked), `docs/adr/README.md` (modified)
**Changes**: None to the content. `git add` both so the record lands with the
first commit that implements it. If `mix quality`'s ADR-related stages object
to anything in the record, fix the record's form, not its decision.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` green while iterating (not a phase gate).
- [x] Full `mix quality` green.
- [x] `mix gate.verify` confirms the run was a full, unscoped, unskipped gate.
- [x] `mix test test/statifier/parser/location_test.exs` green, including the
      new CRLF test.
- [x] The sabotage mutation described in the new test's comment was applied,
      observed red, and reverted.

#### Manual Verification:
- [ ] The new clause's position in the `cond` is confirmed by reading: an
      identical-codepoint `"\r"` pair still takes branch 1.
- [ ] The quoted XML 2.11 and 3.3.3 clauses in the new comments match the local
      spec cache (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/`),
      not memory.
- [ ] `resolve_span/4`'s documented degrade-don't-raise posture is unchanged -
      the new branch can only turn a former `:desync` into a resolution, never
      the reverse.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: Normalize attribute values in the parser handler

### Overview

Derive `Attribute.value` by walking the raw slice against Saxy's expanded value,
rewire `Handler.build_attributes/2` to do it, update the four moduledocs that
state the old behavior, convert the synthetic tests to real parses, add the new
coverage, and re-run conformance.

### Changes Required:

#### 1. The normalization walk

**File**: `lib/statifier/parser/location.ex`
**Changes**: A new public `normalize_attribute_value/3`, placed beside
`resolve_span/4` and reusing `next_unit/2`, `match_reference/1`, and
`decode_reference/1` rather than re-deriving them. Signature mirrors
`resolve_span/4`'s trailing arguments so the two read as one family.

```elixir
@doc """
`value` with XML 1.0 3.3.3 attribute-value normalization applied.

`value_location` is the raw-source span of the attribute's value and `value`
is Saxy's entity-expanded string. Saxy applies neither 3.3.3 nor 2.11, so a
literal TAB/LF/CR survives into `value` verbatim - indistinguishable, in that
string alone, from an expanded `&#9;`/`&#10;`/`&#13;`, which 3.3.3 requires be
kept as-is. The raw slice is what draws the distinction, so the two are walked
in lockstep by the same unit rule `resolve_span/4` uses.

Literal `#x20`/`#x9`/`#xA`/`#xD` each append one space; a literal `\\r\\n` pair
appends one space between them (2.11 folds before 3.3.3 maps); a reference
appends its decoded character verbatim. CDATA treatment only - statifier reads
no attribute declarations, so nothing is trimmed or collapsed (ADR-0043).

Degrades rather than raising: if the raw slice and `value` desync, `value` is
returned unnormalized.
"""
@spec normalize_attribute_value(value_location :: t(), value :: binary(), source :: binary()) ::
        binary()
def normalize_attribute_value(%__MODULE__{} = value_location, value, source)
    when is_binary(value) and is_binary(source) do
  case walk_units(slice(value_location, source), value, []) do
    :desync -> value
    {:ok, units} -> units |> Enum.reverse() |> normalize_units([])
  end
end
```

One signature change and two private helpers:

- **`next_unit/2` gains a `kind` element**, returning
  `{:ok, kind, raw_token, expanded_codepoint, raw_rest, value_rest}` where
  `kind` is `:reference` or `:literal`. This is required: the fold has to know
  whether a `"\n"` came from a literal newline or from `&#10;`, and that is
  exactly what the output tuple currently throws away - it cannot be
  re-derived, since both cases yield the same expanded codepoint. `walk_spans/7`
  is the only other caller (`location.ex:169-183`); it ignores the new element
  with `_kind`. Add the element rather than writing a second classifier, so
  there stays one unit rule.

  `next_unit_plain/2` keeps its five-element return - it only ever produces
  literals, so tagging happens once, in `next_unit/2`, rather than in three
  `cond` branches:

  ```elixir
  defp next_unit(raw, value) do
    case match_reference(raw) do
      {token, decoded} ->
        if String.starts_with?(value, decoded) do
          raw_rest = binary_part(raw, byte_size(token), byte_size(raw) - byte_size(token))

          value_rest =
            binary_part(value, byte_size(decoded), byte_size(value) - byte_size(decoded))

          {:ok, :reference, token, decoded, raw_rest, value_rest}
        else
          tag_literal(next_unit_plain(raw, value))
        end

      nil ->
        tag_literal(next_unit_plain(raw, value))
    end
  end

  # `next_unit_plain/2` never produces a reference, so the tag is a constant
  # here. The kind is what lets the normalization fold apply 3.3.3's
  # whitespace rule to a literal `\n` while exempting an expanded `&#10;` -
  # the expanded codepoint is identical in both cases, so the distinction
  # cannot be recovered downstream.
  defp tag_literal(:desync), do: :desync

  defp tag_literal({:ok, raw_token, expanded_codepoint, raw_rest, value_rest}),
    do: {:ok, :literal, raw_token, expanded_codepoint, raw_rest, value_rest}
  ```

  And the one existing call site, `location.ex:169-183`, takes a single new
  `_kind`:

  ```elixir
        case next_unit(raw, value) do
          :desync ->
            :desync

          {:ok, _kind, raw_token, expanded_codepoint, raw_rest, value_rest} ->
            walk_spans(
  ```

  Nothing else in `walk_spans/7` changes. Note this edits a function Phase 1
  also touched, in a different way and for a different reason - Phase 1
  changes `next_unit_plain/2`'s `cond`, Phase 2 changes `next_unit/2`'s return
  shape - so the two phases do not conflict textually.
- `walk_units/3` - the same recursion shape as `walk_spans/7`, but carrying no
  cursors: it calls `next_unit/2` and accumulates
  `{:reference, decoded} | {:literal, raw_token}` until both sides are empty,
  returning `:desync` on desync. Which element it keeps depends on the kind,
  which is the one subtlety: a reference contributes its *expanded* text
  (`&#10;` -> `"\n"`), a literal contributes its *raw* text (`"\r\n"`, which is
  also the expanded text for a literal).

  ```elixir
  defp walk_units("", "", units), do: {:ok, units}

  defp walk_units(raw, value, units) do
    case next_unit(raw, value) do
      :desync ->
        :desync

      {:ok, :reference, _raw_token, decoded, raw_rest, value_rest} ->
        walk_units(raw_rest, value_rest, [{:reference, decoded} | units])

      {:ok, :literal, raw_token, _expanded, raw_rest, value_rest} ->
        walk_units(raw_rest, value_rest, [{:literal, raw_token} | units])
    end
  end
  ```

  The `("", "", units)` base clause must come first: a `raw` and `value` that
  empty together are done, and one that empties alone falls through to
  `next_unit/2`, which desyncs on it - the same rule `walk_spans/7` applies.
  Units accumulate reversed, which is why `normalize_attribute_value/3`
  reverses before folding.
- `normalize_units/2` - the fold. This is where the CRLF rule lives, and it has
  to be here rather than inside `next_unit/2`: **Saxy does not apply 2.11
  either**, so on this pass raw `"\r\n"` pairs against value `"\r\n"` and
  `next_unit/2` yields two identical-codepoint units, not one pair. Phase 1's
  pair unit is for the *post*-normalization walk and does not fire here.

```elixir
defp normalize_units([], acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

# 2.11: a literal CRLF is one line break, so one space - never two. Two
# clauses because the pair can arrive either way: as two units, which is what
# happens on this pass (Saxy applies no 2.11, so raw "\r\n" pairs against a
# value that also spells "\r\n" and walks as two identical-codepoint units),
# or as Phase 1's single pair token, which cannot fire against an
# unnormalized value but is matched so the fold does not depend on that
# staying true.
defp normalize_units([{:literal, "\r"}, {:literal, "\n"} | rest], acc),
  do: normalize_units(rest, [" " | acc])

defp normalize_units([{:literal, "\r\n"} | rest], acc), do: normalize_units(rest, [" " | acc])

# 3.3.3: "For a white space character (#x20, #xD, #xA, #x9), append a space
# character (#x20) to the normalized value."
defp normalize_units([{:literal, ws} | rest], acc) when ws in [" ", "\t", "\n", "\r"],
  do: normalize_units(rest, [" " | acc])

defp normalize_units([{:literal, other} | rest], acc), do: normalize_units(rest, [other | acc])

# 3.3.3: "For a character reference, append the referenced character to the
# normalized value." A reference is exempt from the whitespace rule - that is
# the whole distinction this walk exists to preserve.
defp normalize_units([{:reference, decoded} | rest], acc),
  do: normalize_units(rest, [decoded | acc])
```

Note `{:literal, " "}` mapping to `" "` is a no-op in effect; it is written
explicitly because 3.3.3 lists `#x20` among the four, and a reader checking the
code against the clause should find all four.

**This design was prototyped and run before the plan was written**, as a
standalone module reproducing `next_unit/2`, `match_reference/1`,
`decode_reference/1`, Phase 1's CRLF clause, and `normalize_units/2` verbatim.
All fifteen cases produced the expected string, including the four that decide
whether the design is right:

| raw | Saxy value | normalized |
|---|---|---|
| `a&#13;&#10;b` | `"a\r\nb"` | `"a\r\nb"` - references never fold |
| `a&#13;<LF>b` | `"a\r\nb"` | `"a\r b"` - reference CR kept, literal LF spaced |
| `a<CR>&#10;b` | `"a\r\nb"` | `"a \nb"` - the mirror image |
| `a&#10;b<LF>c` | `"a\nb\nc"` | `"a\nb c"` - both rules in one value |

Plus: all four literals to one space, `a<CR><LF>b` to exactly one space,
`a<LF><LF>b` to two spaces and `"  a  b  "` unchanged (no collapse, no trim),
`&lt;` and an undeclared `&foo;` unaffected, and a contradicting value returned
verbatim through the desync path. Reproduce it before trusting it; do not treat
this table as a substitute for the tests.

#### 2. The handler

**File**: `lib/statifier/parser/handler.ex`
**Changes**: `build_attributes/2` becomes `build_attributes/3`, taking the
handler state first per this repo's first-argument convention, and normalizing
when a scanner record with a `value_location` is present.

```elixir
# handler.ex:87
attributes: build_attributes(state, attributes, record.attributes),
```

```elixir
defp build_attributes(state, event_attributes, scanned_attributes) do
  event_attributes
  |> Enum.with_index()
  |> Enum.map(fn {{name, value}, index} ->
    scanned = Enum.at(scanned_attributes, index)

    %DOM.Attribute{
      name: name,
      value: normalized_value(state, scanned, value),
      location: scanned && scanned.location,
      value_location: scanned && scanned.value_location
    }
  end)
end

# No scanner record, or one without a value span, means no raw text to
# disambiguate a literal from a reference - so Saxy's value stands
# unnormalized rather than being guessed at (ADR-0043).
defp normalized_value(_state, nil, value), do: value
defp normalized_value(_state, %{value_location: nil}, value), do: value

defp normalized_value(state, %{value_location: value_location}, value),
  do: Location.normalize_attribute_value(value_location, value, state.source)
```

`Location` is already aliased at `handler.ex:36`.

#### 3. Moduledocs

**File**: `lib/statifier/parser.ex`
**Changes**: Two edits.
- The "What it does not do" opener (`parser.ex:11-17`): "Nothing is validated,
  normalized, or resolved" gains the 3.3.3 carve-out - vocabulary-level
  normalization is still not done, but the XML-processor-level obligations
  (entity expansion, attribute-value normalization) are, per SCXML Appendix A.2
  and ADR-0043.
- The "One consequence is worth stating" paragraph (`parser.ex:64-68`): an
  attribute's `value` is 3.3.3-normalized and entity-expanded while
  `value_location` covers raw source, so a literal newline in the source is a
  space in the value and offsets inside the value do not map 1:1 onto the
  document.

**File**: `lib/statifier/parser/dom/attribute.ex:14-20`
**Changes**: "`value` is Saxy's entity-expanded text" becomes the
3.3.3-normalized, entity-expanded text, with the literal-versus-reference
contrast stated in one sentence and ADR-0043 cited.

**File**: `lib/statifier/parser/handler.ex:2-31`
**Changes**: A short `## Attribute values` section: the handler normalizes per
3.3.3 by walking the raw slice against Saxy's value, because Saxy's value alone
cannot tell a literal newline from an expanded `&#10;`; the fallback when there
is no raw slice.

**File**: `lib/statifier/parser/location.ex`
**Changes**: `resolve_span/4`'s doc, and the unit-rule comment Phase 1 touched,
lose any implication that the normalization pairing is hypothetical.

#### 4. Test conversions

**File**: `test/statifier/parser/location_test.exs`
**Changes**:
- The TAB test (`~line 318`): parse `~s(<edge cond="a\tb"/>)` for real, drop
  `value = "a b"` and the "Passed by hand" note, use `attribute.value`, and add
  `assert attribute.value == "a b"` so the test states what it now proves. Keep
  the existing sabotage line - the mutation it describes still reddens it.
- Phase 1's CRLF test: same conversion, drop its "Passed by hand until st-6ans
  Phase 2" note.
- The literal-newline test (`~line 188`): the value is now `"first second"`,
  one expanded line, so the span becomes `{{1, 7}, {1, 13}}`. Keep the
  independent recomputation of the absolute document line
  (`Location.at_offset(source, resolved.start_offset).start_line == 3`) - that
  assertion is the point of the test and is exactly what proves the raw cursor
  still crosses the physical newline. Add `assert attribute.value ==
  "first second"`. Its sabotage line needs re-authoring: the old mutation
  (`raw_advance_codepoint/2`'s `"\n"` clause not advancing the line) still
  reddens the recomputed-line assertion, so re-verify rather than assume.
- The `\r` test (`~line 262`, "holds the expanded column still"): this one
  hand-feeds `value = "a\rb"`, which normalization now makes unreachable
  through a real parse for a *literal* `\r`. Re-anchor it on
  `~s(<edge cond="a&#13;b"/>)`, whose value legitimately is `"a\rb"` after
  normalization, so it keeps testing predicator's `\r` column rule against a
  real parse. Keep its sabotage line, re-verified.

**File**: `test/statifier/parser/location_span_resolution_test.exs`
**Changes**: None expected - all three tests use references, not literals.
Confirm by running it.

**File**: `test/statifier/parser/location_accuracy_test.exs`
**Changes**: None expected. `assert_whole_value_span_is_identity/2:113-127` is
the every-attribute property that now runs over normalized values, and the
wrapped `label` in `parser_test.exs`'s fixture is not its input - this file has
its own fixtures. Run it and read the result rather than assuming; if it
reddens, the walk is dropping or double-counting a unit and that is a Phase 2
bug, not a test to adjust. The `whole_value_end/1` comment at `:129-136` says
"No fixture contains a carriage return today" - re-check that claim holds after
this change, since the statement is about raw fixtures and stays true, but the
adjacent reasoning now also depends on `expanded_advance/2` seeing normalized
input.

#### 5. New tests

**File**: `test/statifier/parser_test.exs`, in the `parse/1 - attributes`
describe block. Each needs its own sabotage line.

- A literal LF, CR, CRLF, and TAB each normalize to one space, and
  `value_location` still slices the raw text unchanged. Assert the
  `value_location` slice as well as the value, so a change that "normalized"
  the span too would redden.
- The literal-versus-reference divergence in one document:
  `~s(<edge cond="a&#10;b\nc"/>)` yields `"a\nb c"` - the reference keeps its
  newline, the literal becomes a space. This is the single most important
  assertion in the bead.
- `&#13;&#10;` does **not** fold: `~s(<edge cond="a&#13;&#10;b"/>)` yields
  `"a\r\nb"`, two characters, because the fold is a 2.11 rule about literal
  line breaks and references are exempt.
- The two half-and-half mixes, which are what prove the fold is scoped to a
  literal *pair* rather than to any adjacent CR/LF: `a&#13;<LF>b` yields
  `"a\r b"` and `a<CR>&#10;b` yields `"a \nb"`. One test, both assertions.
- No trim, no collapse: `~s(<edge cond="  a  b  "/>)` and a two-literal-newline
  value each keep every space one-for-one (ADR-0043 decision item 2).

**File**: `test/statifier/parser/location_test.exs`, a describe block for
`normalize_attribute_value/3`:

- The desync fallback: a `value` that does not describe the raw slice returns
  `value` unnormalized. This is the unit-level test for the behavior the
  handler's `nil` guards also protect; the handler's `nil` path is not
  independently reachable through `parse/1` (Saxy rejects the malformed input
  the scanner drops), so it is covered by reading plus this test rather than by
  a contrived parse.

#### 6. Changelog fragment

**File**: `changelog.d/st-6ans.md` (new)
**Changes**: Warranted. `changelog.d/README.md`'s narrower rewrite-era rule is
"write a fragment when v2 differs from v1", and this is behavior v1 never had -
v1 also parsed with Saxy and also passed literal newlines through. It is a
change in observable behavior of a public API's output, which the general list
names outright.

```markdown
### Fixed

- Attribute values are normalized per XML 1.0 3.3.3: a literal tab, newline, or
  carriage return inside an attribute value becomes a space, while a character
  reference such as `&#10;` keeps its character. A `cond` or `expr` wrapped
  across source lines now compiles from a single-line string.
```

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` green while iterating (not a phase gate).
- [x] Full `mix quality` green.
- [x] `mix gate.verify` confirms the run was a full, unscoped, unskipped gate.
- [x] `mix test --include scion --include scxml_w3` run in full; its result
      recorded in the commit body whether or not it moved.
- [x] `mix test.regression` green. If any test's status moved,
      `mix test.baseline add` runs and `test/passing_tests.json` is staged in
      **this same commit** - and a shrink additionally needs a
      `docs/quality-gate-changes.md` entry, which is a human's call, so stop and
      report instead of writing one.
- [x] `mix test test/scion_tests/send_data/send1_test.exs
      test/scion_tests/send_internal/test0_test.exs --include scion` green -
      the two known multi-line-attribute corpus members, named so their result
      is checked rather than inferred from the aggregate.
- [x] Every new test's sabotage mutation was applied, observed red, and
      reverted; each mutation is described in the line above its test.
- [x] `changelog.d/st-6ans.md` exists.
- [x] `mix test test/statifier/parser/location_accuracy_test.exs` green - the
      every-attribute whole-value-span identity property, which now runs over
      normalized values across every fixture.

#### Manual Verification:
- [ ] `normalize_units/2`'s clauses match XML 1.0 3.3.3's algorithm clause by
      clause, read from the local spec cache rather than memory, with the
      quoted text in the comments checked against it. All four whitespace
      characters `#x20`, `#xD`, `#xA`, `#x9` are present and the character-
      reference clause is exempt from them.
- [ ] The CRLF fold is checked against XML 1.0 2.11 as quoted, and confirmed
      not to apply to `&#13;&#10;`.
- [ ] The two corpus `cond`s are read by hand after the change and confirmed to
      be semantically identical strings (whitespace-only difference), not merely
      still-passing tests.
- [ ] The four moduledocs no longer state the old behavior anywhere - grep for
      "Saxy's entity-expanded" and for "normalized" across `lib/statifier/parser`
      and read each hit.
- [ ] Diagnostic rendering of a wrapped `cond` looks right by eye: the resolved
      span underlines the intended subexpression in the raw source across the
      physical line break.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Corpus/Ratchet Notes

No ratchet movement is expected, and the re-run confirms rather than decides.
The reasoning (ADR-0043 Context): the corpus holds exactly two multi-line
attribute values, both `cond`s in ratchet members
(`test/scion_tests/send_data/send1_test.exs`,
`test/scion_tests/send_internal/test0_test.exs`); predicator's lexer treats
`#x20`, `#x9`, `#xA`, and `#xD` identically as whitespace
(`deps/predicator/lib/predicator/lexer.ex:215-226`), so their compiled
instructions and evaluation results are unchanged; and no corpus assertion
reads a span.

If a test does move:

- A test that starts passing is ratcheted in with `mix test.baseline add`, in
  Phase 2's commit.
- A test that starts failing is a real regression in this change, not a ratchet
  edit. Do not shrink `test/passing_tests.json` - that is a `Gate guard` trip
  needing a `docs/quality-gate-changes.md` entry, which per this repo's
  CLAUDE.md is a human's call on the record. Stop and report.

No corpus regeneration (`mise run corpus`) is involved; this changes how the
parser reads fixtures, not what is generated.

## Testing Strategy

### Unit Tests:

- `test/statifier/parser_test.exs`, `parse/1 - attributes` - the observable
  contract: what `Attribute.value` is for each of literal LF / CR / CRLF / TAB /
  space, for `&#10;` / `&#13;` / `&#9;`, for `&#13;&#10;`, and the no-trim /
  no-collapse cases. Paired with a `value_location` slice assertion so the span
  is proven untouched.
- `test/statifier/parser/location_test.exs` - the walk primitives: the CRLF
  pair unit (Phase 1), `normalize_attribute_value/3`'s desync fallback, and the
  converted TAB / literal-newline / `\r` tests.
- `test/statifier/parser/location_span_resolution_test.exs` - unchanged, run as
  a regression check that the compile-and-evaluate path still resolves.
- Edge cases worth naming: a value that is entirely whitespace; a literal
  newline immediately before the closing quote; `&#13;` followed by a literal
  `\n` (reference CR, then literal LF - one `\r`, then one space, no fold); a
  multi-byte codepoint adjacent to a normalized character, which
  `location_test.exs` already guards for the raw cursor.
- Every new test asserting `lib/` behavior carries its sabotage line, mutation
  applied and observed red before the line is written (`docs/testing.md`).

### Manual Testing Steps:

1. In `iex -S mix`, parse `"<edge cond=\"a&#10;b\nc\"/>"` and confirm the value
   is `"a\nb c"` - the reference kept, the literal normalized. This is the
   distinction the whole bead turns on.
2. Parse `"<edge cond=\"a\r\nb\"/>"` and confirm the value is `"a b"` (one
   space, three characters), not `"a  b"`.
3. For each, confirm `Location.slice(attribute.value_location, source)` returns
   the raw text unchanged, newline and all.
4. For the CRLF case, call `Location.resolve_span/4` with `{{1, 3}, {1, 4}}` and
   confirm it slices `"b"` rather than the whole value - a whole-value result
   means the walk fell back and Phase 1's unit is not firing.
5. Read the two corpus `cond`s and confirm their normalized forms are the same
   expressions.

## References

- Decision record: `docs/adr/0043-attribute-values-normalize-per-xml-3-3-3.md`
- Related ADRs: `docs/adr/0014-*` (expression spans),
  `docs/adr/0011-*` (gate guard ledger), `docs/adr/0002-*` (Appendix D fidelity)
- Spec: XML 1.0 3.3.3 (attribute-value normalization) and 2.11 (end-of-line
  handling), read from the local cache at
  `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/`;
  SCXML Appendix A.2 (XML processor obligation)
- Similar implementation: `lib/statifier/parser/location.ex:160-236` -
  `walk_spans/7` and `next_unit/2`, the lockstep walk this reuses
- Corpus members affected: `test/scion_tests/send_data/send1_test.exs:1`,
  `test/scion_tests/send_internal/test0_test.exs:1`
- Bead: st-6ans

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The new clause's position in the `cond` is confirmed by reading: an
      identical-codepoint `"\r"` pair still takes branch 1.
- [ ] The quoted XML 2.11 and 3.3.3 clauses in the new comments match the local
      spec cache (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/`),
      not memory.
- [ ] `resolve_span/4`'s documented degrade-don't-raise posture is unchanged -
      the new branch can only turn a former `:desync` into a resolution, never
      the reverse.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

### Phase 2

- [ ] `normalize_units/2`'s clauses match XML 1.0 3.3.3's algorithm clause by
      clause, read from the local spec cache rather than memory, with the
      quoted text in the comments checked against it. All four whitespace
      characters `#x20`, `#xD`, `#xA`, `#x9` are present and the character-
      reference clause is exempt from them.
- [ ] The CRLF fold is checked against XML 1.0 2.11 as quoted, and confirmed
      not to apply to `&#13;&#10;`.
- [ ] The two corpus `cond`s are read by hand after the change and confirmed to
      be semantically identical strings (whitespace-only difference), not merely
      still-passing tests.
- [ ] The four moduledocs no longer state the old behavior anywhere - grep for
      "Saxy's entity-expanded" and for "normalized" across `lib/statifier/parser`
      and read each hit.
- [ ] Diagnostic rendering of a wrapped `cond` looks right by eye: the resolved
      span underlines the intended subexpression in the raw source across the
      physical line break.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
