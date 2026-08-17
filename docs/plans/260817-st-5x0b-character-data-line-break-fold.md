---
date: 2026-08-17
planner: Claude
git_commit: 2c26fe087109d74cb9939081c060b39a5d5af694
branch: st-5x0b-cdata-line-break-fold
repository: statifier-ex
beads_issue: st-5x0b
topic: "XML 1.0 2.11 character-data line-break folding in the parser, guided by the raw source"
tags: [plan, parser, xml-conformance, locations]
status: ready
last_updated: 2026-08-17
last_updated_by: Claude
---

# Character-Data Line-Break Fold Implementation Plan

## Overview

Character data in `Statifier.Parser.DOM.Text.value` does not have XML 1.0 2.11
end-of-line handling applied: a literal `\r\n` pair and a literal lone `\r`
survive verbatim where a conforming XML processor owes the application a single
`\n`. ADR-0045 decided to fold, in the parser, guided by the raw source, by
adding a character-data sibling to `Location.normalize_attribute_value/3` and
calling it from `Handler.add_text/2`. This plan implements that record. Bead:
st-5x0b.

## Current State Analysis

**The deviation is live and unmitigated.** Saxy applies no 2.11 anywhere
(`deps/saxy/lib/` has no normalization code or option; the only CR mention is
the `is_whitespace` guard at `deps/saxy/lib/saxy/guards.ex:6`), so
`<r><t>a\r\nb</t></r>` parses to `value == "a\r\nb"`. The same is true of a lone
CR and of a CRLF inside a CDATA section. A `&#xD;` correctly yields `"\r"` today
and must keep doing so — that is the literal-versus-reference distinction 2.11
draws, and it is the reason a blind `String.replace/3` over `value` is wrong.

**The machinery to do it right already exists, one layer over.** ADR-0043's
attribute work (st-6ans, landed) built a lockstep raw-versus-expanded walk in
`lib/statifier/parser/location.ex`:

- `normalize_attribute_value/3` (`location.ex:170-176`) — slices the raw span,
  runs `walk_units/3`, folds the resulting units into a string.
- `walk_units/3` (`location.ex:191-204`) — accumulates
  `{:reference, decoded} | {:literal, raw_token}` units until both sides empty
  together; anything else is `:desync`.
- `next_unit/2` (`location.ex:301-318`) — the five-case unit rule, tagging
  reference versus literal, validating every decode against the expanded value
  with `String.starts_with?/2` before believing it.
- `next_unit_plain/2` (`location.ex:330-353`) — identical codepoints, the raw
  CRLF-versus-single-space pair, the TAB/LF/CR-versus-space pair, or desync.
- `normalize_units/2` (`location.ex:206-231`) — the 3.3.3 fold over the units.
- `resolve_span/4` (`location.ex:120-147`) — the span composition, sharing
  `next_unit/2` through `walk_spans/7`.

**The call site.** `Handler.add_text/2` (`handler.ex:139-153`) coalesces a run's
events into one `DOM.Text`: it appends `characters` to the head child's `value`
when that child is already a `DOM.Text`, and recomputes `text_span/1`
(`handler.ex:159-167`) every event. The span always covers the *whole* raw run
(the cursor has not moved and the head of the markup queue is the next
construct), so the final event of a run sees the complete value against the
complete span.

**What the raw span contains that the value does not.** `Markup.scan/1` skips
comments, CDATA delimiters, DOCTYPE, and PIs without emitting a record
(`markup.ex:78-84`), so a text run's raw slice can straddle `<!--`…`-->`,
`<![CDATA[`…`]]>`, and `<?`…`?>` while `value` contains none of the delimiters.
This is what makes the raw walk load-bearing rather than merely
disambiguating: in `<x>i\r<!--c-->\nj</x>` the value coalesces to `"i\r\nj"`,
but in the raw entity text that CR is *not* followed by `#xA`, so 2.11 folds it
alone and the correct value is `"i\n\nj"`.

**Nothing consumes text offsets.** `Nothing in lib/` calls `resolve_span/4`;
text nodes have no `value_location`; the four `DOM.text/1` call sites
(`lib/statifier/lowering/builders.ex`) feed `Content.text`, `Data.text`,
`Assign.text`, and `Script.text`, all compiled or stored whole; text-sourced
diagnostics use whole-node locations by design
(`lib/statifier/compiler.ex:1658`). So no coordinate consumer exists for the
fold to disturb.

**Docs that state the old behavior.** `Statifier.Parser`'s "What it does not do"
list and its "One consequence worth stating" paragraph (`parser.ex:11-21`,
`parser.ex:71-77`); `DOM.Text`'s moduledoc (`lib/statifier/parser/dom/text.ex:2-17`);
`Handler`'s "## Attribute values" section (`handler.ex:32-40`); and the
"verbatim, untrimmed" wording at `lib/statifier/lowering/builders.ex:436,495,751`
and in `lib/statifier/document/{assign,data,script}.ex`.

## Desired End State

`DOM.Text.value` is the 2.11-folded, entity-expanded text of its run:

- a literal `\r\n` pair in the raw run is one `\n`;
- a literal lone `\r` is one `\n`;
- a `\r` decoded from `&#xD;` is still `\r`;
- a literal CR inside a CDATA section folds like any other;
- a CR whose following `\n` is separated from it by a comment, CDATA
  delimiter, or PI folds *alone* (`i\r<!--c-->\nj` → `"i\n\nj"`);
- TABs and folded newlines are kept — 3.3.3's whitespace-to-space mapping is
  attribute-specific and never touches character data;
- `DOM.Text.location` still spans the raw run, byte-for-byte unchanged;
- `Content.markup` is still a raw slice, CR included (ADR-0041, ADR-0045 item 5);
- attribute values are unchanged.

Verified by: the new unit tests over `Location.normalize_character_data/3`, the
parser-level tests over `DOM.Text.value` and `.location`, the location-accuracy
sweep, and a full conformance run showing no ratchet movement.

### Key Discoveries:

- ADR-0045 is the authority for this plan; it extends ADR-0043 and amends
  nothing. ADR-0043's open-question bullet is already marked resolved on this
  branch (`docs/adr/0043-attribute-values-normalize-per-xml-3-3-3.md:171-172`).
- `Location.normalize_attribute_value/3` (`location.ex:170`) is the shape to
  mirror; `walk_units/3` and `next_unit/2` are the parts to share rather than
  duplicate.
- `Handler.add_text/2` (`handler.ex:139`) already recomputes the whole-run span
  on every event, so recomputing the fold there costs the same kind of work and
  needs no new event bookkeeping — except that the *unfolded* accumulation must
  be kept somewhere, because re-walking an already-folded value against the raw
  slice desyncs (raw `\r` against a folded `\n` matches no `next_unit_plain/2`
  branch).
- `Markup.scan/1`'s skip list (`markup.ex:78-84`) is where the constructs the
  text walk must skip come from: comments, CDATA delimiters, and PIs. DOCTYPE is
  on the scanner's list but not the walk's — it can only appear in the prolog,
  never inside character data.
- ADR-0043's degrade-don't-raise fallback (`location.ex:172-175`,
  `handler.ex:190-194`) is the posture for any desync here too.
- The corpus carries no literal CR byte anywhere (`grep -rlP '\r'` over `test/`
  and `tools/` finds none), so no ratchet movement is expected.
- `changelog.d/st-6ans.md` is the precedent for a fragment on this class of
  change: it is user-observable behavior in `Script.text` / `Content.text`, so
  this bead gets one too.

## What We're NOT Doing

- **Not pre-folding the source binary before `Markup.scan/1` and Saxy.**
  ADR-0045 rejected it explicitly: it would move every byte offset after the
  first CRLF and break `Statifier.Parser.parse/1`'s promise that every span
  slices out of the caller's own binary (ADR-0014, ADR-0041, observability
  constraint 3, the location-accuracy sweep).
- **Not standing up lockstep span machinery for text nodes.** No
  `value_location` on `DOM.Text`, no text arm of `resolve_span/4`. ADR-0045
  item 4: nothing calls `resolve_span/4` at all yet and every text-sourced
  diagnostic uses a whole-node location, so there is no consumer whose
  coordinates the fold can move. The seam is recorded in ADR-0045's first open
  question and stays out of scope here.
- **Not folding `Content.markup`.** ADR-0045 item 5: it is opaque source bytes
  sliced by location, and the child document compiled from it is parsed by this
  same parser, whose fold then applies.
- **Not touching attribute normalization.** `normalize_attribute_value/3` keeps
  assuming unfolded input, which the no-pre-fold design preserves.
- **Not fixing lone-CR line counting.** `line_and_column/1` and
  `raw_advance_codepoint/2` count only `\n`, so a bare-CR document gets line
  numbers an editor would disagree with. Pre-existing, untouched by this change
  (spans stay raw), and recorded as ADR-0045's second open question.
- **Not regenerating the corpus.** This changes how the parser reads fixtures,
  not what is generated.

## Implementation Approach

Three phases, split along the module boundary ADR-0045 draws: the `Location`
primitive, the `Handler` call site, and the downstream documentation.

Phase 1 stands up `Location.normalize_character_data/3` with no call site. That
is deliberate and it is still gate-verifiable: the function is public and its
unit tests drive it directly with hand-built locations, exactly as
`location_test.exs`'s `normalize_attribute_value/3` block does today
(`location_test.exs:484-504`). Committing the primitive alone keeps the walk's
unit rule — the subtle part — reviewable on its own.

Phase 2 wires it into `Handler.add_text/2` and is where behavior changes, so it
carries the parser-level tests, the location-accuracy adjustment, the
parser/DOM/handler moduledoc updates, the changelog fragment, and the
conformance re-run.

Phase 3 is documentation-only: the "verbatim, untrimmed" wording in the
lowering builders and the `Statifier.Document` moduledocs, which implies raw
line endings survive.

**The unfolded-accumulation rule** shapes Phase 2 and is worth stating once.
`walk_units/3` requires the raw and expanded sides to empty together. Saxy's
value for a run is unfolded, so a raw `\r\n` pairs against a value `\r\n` as two
identical-codepoint units and the fold happens in the units-to-string step —
the same design `normalize_attribute_value/3` uses. Feeding an already-folded
value back into the walk would desync on the first CR. So the handler keeps
Saxy's unfolded accumulation for the open run and derives `value` from it on
every event. Intermediate events of a split run walk a value *prefix* against
the whole-run raw slice and therefore desync to the unfolded prefix; the final
event of the run sees the complete value against the complete span and
overwrites it with the folded whole. That is ADR-0045 item 2's "recomputing
over the accumulated value as events coalesce", and it is self-correcting by
construction.

The alternative — appending unfolded into `DOM.Text.value` and folding once when
the run closes — was considered and rejected for this plan: run-close is three
event clauses (`:start_element`, `:end_element`, `:end_document`) instead of
one, and it would leave a temporarily-wrong `value` on the node between events.
See Performance Considerations for the cost side of that trade.

## Phase 1: The character-data fold in `Location`

### Overview

Add `Statifier.Parser.Location.normalize_character_data/3`, sharing
`walk_units`/`next_unit` with the attribute path and extending the unit rule
with the raw-only constructs a text span can straddle. No call site yet.

### Changes Required:

#### 1. Parameterize the unit walk

**File**: `lib/statifier/parser/location.ex`
**Changes**: `walk_units/3` gains two arguments — a **mode** and the unit
function — so the attribute path and the text path share one recursion. The mode
is threaded explicitly through both the call and the return, because the text
walk needs to know whether it is currently inside an unclosed `<![CDATA[` and
neither `raw` nor `value` carries that. The existing arity-3 clause delegates
through a thin adapter, leaving `normalize_attribute_value/3` byte-identical in
behavior.

```elixir
defp walk_units(raw, value, units),
  do: walk_units(raw, value, :none, units, &attribute_unit/3)

# The attribute path has no modes; the adapter exists only to give
# `next_unit/2` the arity the shared recursion calls with.
defp attribute_unit(raw, value, mode) do
  case next_unit(raw, value) do
    :desync -> :desync
    {:ok, kind, raw_token, expanded, raw_rest, value_rest} ->
      {:ok, kind, raw_token, expanded, raw_rest, value_rest, mode}
  end
end

defp walk_units("", "", _mode, units, _next), do: {:ok, units}

defp walk_units(raw, value, mode, units, next) do
  case next.(raw, value, mode) do
    :desync ->
      :desync

    # A raw-only construct contributes no unit; only the mode may move.
    {:ok, :skip, _raw_token, _expanded, raw_rest, value_rest, mode} ->
      walk_units(raw_rest, value_rest, mode, units, next)

    {:ok, :reference, _raw_token, decoded, raw_rest, value_rest, mode} ->
      walk_units(raw_rest, value_rest, mode, [{:reference, decoded} | units], next)

    {:ok, :literal, raw_token, _expanded, raw_rest, value_rest, mode} ->
      walk_units(raw_rest, value_rest, mode, [{:literal, raw_token} | units], next)
  end
end
```

#### 2. The text unit rule

**File**: `lib/statifier/parser/location.ex`
**Changes**: a private `next_text_unit/3` — `(raw, value, mode)` where `mode` is
`:text` or `:cdata` — that recognizes the raw-only constructs first and
otherwise delegates to `next_unit/2`. Ordering and validation matter:

- A construct is only taken as raw-only when the **expanded value does not
  start with the same literal** (`skip?/3` in the sketch below). This mirrors
  `next_unit/2`'s validate-before-believing rule (`location.ex:304`) and keeps a
  literal `<!--` *inside* a CDATA section — which does appear in `value` — from
  being mistaken for a comment.
- `<!--` … `-->` and `<?` … `?>`: consume the whole construct from the raw side,
  contribute nothing to the expanded side.
- `<![CDATA[` and `]]>`: consume the **delimiter only** from the raw side,
  contribute nothing. The section's *interior* is part of `value` and must keep
  walking.
- **CDATA interior is walked verbatim, not through `next_unit/2`.** Inside a
  CDATA section, no reference is expanded: `&amp;` is five literal characters on
  both sides. Routing it through `next_unit/2` would decode raw `&amp;` to `"&"`,
  find that `value` (spelling `&amp;`) does start with `"&"`, and consume five
  raw bytes against one value byte — a mispairing that only recovers by
  desyncing to the fallback. So the mode threaded by change 1 is the mechanism:

  ```elixir
  # :text -> :cdata on the opening delimiter, :cdata -> :text on the closing
  # one; both delimiters are raw-only, so they contribute no unit.
  defp next_text_unit(raw, value, :text) do
    cond do
      skip?(raw, value, "<![CDATA[") -> {:ok, :skip, "<![CDATA[", "", after_it, value, :cdata}
      skip?(raw, value, "<!--")      -> # consume through "-->", mode stays :text
      skip?(raw, value, "<?")        -> # consume through "?>",  mode stays :text
      true                           -> tag_mode(next_unit(raw, value), :text)
    end
  end

  # Inside the section: identical codepoints only, no reference decoding.
  defp next_text_unit(raw, value, :cdata) do
    if skip?(raw, value, "]]>") do
      {:ok, :skip, "]]>", "", after_it, value, :text}
    else
      # one codepoint from each side, must be identical, else :desync
    end
  end
  ```

  A literal `\r` inside the section therefore arrives as a `{:literal, "\r"}`
  unit and folds exactly as one outside does, which is what ADR-0045's decision
  item 1 and its test list require. This **refines** ADR-0045 item 2's
  wording rather than contradicting it: the record's "`<![CDATA[` through `]]>`
  … contributing nothing to the expanded side" cannot be read literally, since
  the same record's decision item 1 and its test list both require a CR *inside*
  CDATA to fold, which is impossible if the interior contributes nothing. The
  raw-only part is the delimiters; the interior is verbatim.

#### 3. The public helper and its fold

**File**: `lib/statifier/parser/location.ex`
**Changes**: `normalize_character_data/3` mirroring
`normalize_attribute_value/3` (`location.ex:149-176`) — `@doc` quoting XML 1.0
2.11 from the local spec cache, `@spec`, the desync fallback returning `value`
unfolded, and a `fold_units/2` that is deliberately *not* `normalize_units/2`:

```elixir
def normalize_character_data(%__MODULE__{} = location, value, source) do
  case walk_units(slice(location, source), value, :text, [], &next_text_unit/3) do
    :desync -> value
    {:ok, units} -> units |> Enum.reverse() |> fold_units([])
  end
end
```

```elixir
# 2.11 folds a literal CRLF and a lone literal CR to one #xA. Nothing else
# is touched - 3.3.3's whitespace-to-space mapping is attribute-specific,
# so TABs and folded newlines are kept (ADR-0045 item 1).
defp fold_units([{:literal, "\r"}, {:literal, "\n"} | rest], acc), do: ...
defp fold_units([{:literal, "\r\n"} | rest], acc), do: ...
defp fold_units([{:literal, "\r"} | rest], acc), do: ...   # lone CR
defp fold_units([{:literal, other} | rest], acc), do: ...
defp fold_units([{:reference, decoded} | rest], acc), do: ...  # verbatim
```

The two-unit `[{:literal, "\r"}, {:literal, "\n"}]` clause is the one that fires
on a real parse (Saxy's value is unfolded, so the pair walks as two identical
units); the single `"\r\n"` token clause is matched for the same reason
`normalize_units/2` matches it — so the fold does not depend on that staying
true.

#### 4. Unit tests

**File**: `test/statifier/parser/location_test.exs`
**Changes**: a new `describe "normalize_character_data/3"` block beside the
existing `normalize_attribute_value/3` block (`location_test.exs:484`), driving
the helper directly with a hand-built `%Location{}` over a synthetic source:
CRLF folds to one `\n`; lone CR folds; `&#xD;` survives; a CDATA-wrapped CR
folds; `&amp;` inside CDATA survives intact; the comment-straddle case folds to
`"i\n\nj"`; a PI-straddle case; a TAB is preserved (the 3.3.3 contrast); a
desynced value returns unfolded. Each test carries its sabotage line per
`docs/testing.md`, mutation applied and observed red before the line is written.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality` (full, unprofiled, unscoped) is green.
- [x] `mix gate.verify` exits zero, proving the run above was a full gate.
- [x] `mix quality --profile loop` used between edits (never as the phase gate).
- [x] The new `describe "normalize_character_data/3"` tests pass, and
      `mix test test/statifier/parser/location_test.exs` is green as a whole —
      the attribute block unchanged proves the `walk_units` parameterization was
      behavior-preserving.
- [x] `mix test test/statifier/parser_test.exs` is green **and unchanged** —
      no call site exists yet, so parser behavior must not have moved.
- [x] Doctor reports no missing `@doc`/`@spec` for the new public function
      (`.doctor.exs` holds 100% thresholds).
- [x] Every new test carries a `# sabotage:` line (the gate's sabotage scan
      checks presence).

#### Manual Verification:

- [ ] The XML 1.0 2.11 text quoted in the new `@doc` and comments is read from
      the local spec cache
      (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/`),
      not from memory, and matches byte for byte.
- [ ] The CDATA-interior refinement in change 2 is confirmed as a refinement of
      ADR-0045 item 2 and not a contradiction of it: a CR inside CDATA folds,
      which is what the record's decision item 1 and its test list require.
- [ ] Each sabotage mutation was actually applied and observed red, and none of
      them is a truthy-sentinel no-op (`docs/testing.md`).
- [ ] The raw-only skip is confirmed by reading to be unreachable for attribute
      values: `next_unit/2`'s behavior is untouched and `<` cannot occur
      literally in a well-formed attribute value anyway.
- [ ] Read against the W3C Appendix D pseudocode rule: this phase touches the
      parser, not the interpreter, so no Appendix D procedure is involved and no
      deviation is claimed (ADR-0002 does not apply to `lib/statifier/parser/`).

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

**Commit contents**: this phase's commit also carries the three
already-uncommitted direction-stage files on this branch —
`docs/adr/0045-character-data-folds-line-breaks-per-xml-2-11.md`,
`docs/adr/0043-attribute-values-normalize-per-xml-3-3-3.md` (its open-question
bullet marked resolved), and `docs/adr/README.md` (the index row). They are this
bead's own work and belong with its first commit.

---

## Phase 2: Wire the fold into the handler

### Overview

Call `normalize_character_data/3` from `Handler.add_text/2`, keeping the
unfolded accumulation so repeated recomputation over a coalescing run stays
correct. Behavior changes here, so this phase carries the observable-contract
tests, the accuracy-sweep adjustment, the moduledoc corrections, the changelog
fragment, and the conformance re-run.

### Changes Required:

#### 1. The call site

**File**: `lib/statifier/parser/handler.ex`
**Changes**: `add_text/2` (`handler.ex:139-153`) derives `value` from an
unfolded accumulation carried in handler state. The coalescing condition is
already computed in the `case frame.children` head, so the accumulator reuses
it — a head child that is a `DOM.Text` means the same run continues.

```elixir
defp add_text(state, characters) do
  [frame | ancestors] = state.stack
  location = text_span(state)

  {unfolded, children} =
    case frame.children do
      [%DOM.Text{} = text | rest] ->
        unfolded = state.text <> characters
        {unfolded, [%DOM.Text{text | value: folded(state, location, unfolded), location: location} | rest]}

      children ->
        {characters, [%DOM.Text{value: folded(state, location, characters), location: location} | children]}
    end

  %{state | text: unfolded, stack: [%{frame | children: children} | ancestors]}
end

defp folded(state, location, unfolded),
  do: Location.normalize_character_data(location, unfolded, state.source)
```

`init/2` gains `text: ""` and the `t()` type gains the field. No reset is
needed on element events: the accumulator is only ever read when the head child
is a `DOM.Text`, which can only be the run it belongs to (an element event
pushes or appends a non-text child, and a comment or PI produces no event, which
is exactly the straddle case that must keep coalescing).

#### 2. Moduledocs stating the old behavior

**File**: `lib/statifier/parser.ex`
**Changes**: the "What it does not do" carve-out (`parser.ex:16-21`) names the
2.11 character-data fold alongside 3.3.3 attribute normalization; the "One
consequence worth stating" paragraph (`parser.ex:71-77`) gains the text half —
`DOM.Text.value` is folded while `DOM.Text.location` covers raw source, so
offsets inside a folded value do not map 1:1 onto the document. The "Whitespace
is preserved verbatim" bullet is qualified: whitespace-only runs are still
preserved as runs, but their line breaks are folded.

**File**: `lib/statifier/parser/dom/text.ex`
**Changes**: the moduledoc defines `value` as the 2.11-folded, entity-expanded
text and names the CR cases; the existing "offsets inside `value` do not map
onto the source one for one" sentence gains the fold as one more cause, which is
the divergence it already documents.

**File**: `lib/statifier/parser/handler.ex`
**Changes**: the "## Attribute values" section (`handler.ex:32-40`) gains a
"## Character data" sibling covering the fold, the unfolded accumulation, and
the desync fallback.

#### 3. Observable-contract tests

**File**: `test/statifier/parser_test.exs`
**Changes**: tests over a real `Statifier.Parser.parse/1` for each case in
Desired End State — literal CRLF, lone CR, `&#xD;`, CR inside CDATA, the
comment-straddle `<x>i\r<!--c-->\nj</x>` → `"i\n\nj"`, a TAB preserved, and a
run split by an entity reference so the coalescing recomputation is exercised.
Each paired with a `Location.slice(text.location, source)` assertion proving the
span still covers raw source, CR included. Sabotage line on each.

#### 4. The accuracy sweep

**File**: `test/statifier/parser/location_accuracy_test.exs`
**Changes**: `entity_or_cdata_free?/1` (`location_accuracy_test.exs:80-82`)
treats a slice containing `"\r"` as decode-changed, like `"&"` and
`"<![CDATA["` today, since slice and value stop agreeing byte for byte once the
fold fires. The comment above `assert_text_accurate/2` gains the reason. The
shortens-or-holds-steady branch already covers the fold (folding only ever
removes a byte).

#### 5. Changelog fragment

**File**: `changelog.d/st-5x0b.md` (new)
**Changes**: a `### Fixed` entry in the shape of `changelog.d/st-6ans.md` —
user-observable behavior in `Script.text`, `Content.text`, `Data.text`, and
`Assign.text`.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality` (full, unprofiled, unscoped) is green.
- [x] `mix gate.verify` exits zero.
- [x] `mix test --include scion --include scxml_w3` — the full conformance run.
- [x] `mix test.regression` — the ratchet's registry tests still pass.
- [x] `test/passing_tests.json` is unchanged, or grew via `mix test.baseline add`
      in this same commit. It must never shrink (see Corpus/Ratchet Notes).
- [x] `mix quality --format json --report -` if a later agent routes on results.
- [x] Every new test carries a `# sabotage:` line.

#### Manual Verification:

- [ ] In `iex -S mix`, `Statifier.Parser.parse("<r><t>a\\r\\nb</t></r>")` yields
      `"a\nb"` and `Location.slice/2` over the same node still yields `"a\r\nb"`.
      This is the bead's own reproduction, inverted.
- [ ] `<x>i\r<!--c-->\nj</x>` yields `"i\n\nj"` — the case that proves the walk
      reads the fold's followed-by rule off the raw text rather than the value.
      A `"i\nj"` result means a value-only fold slipped in.
- [ ] `<t>a&#xD;b</t>` still yields `"a\rb"` — the literal-versus-reference
      distinction, the thing a `String.replace/3` would destroy.
- [ ] An attribute value containing a literal newline still normalizes to a
      single space, unchanged by this phase.
- [ ] The moduledoc edits leave no stale statement of the old behavior: grep
      `lib/statifier/parser` for "verbatim", "not normalized", and "Saxy
      reported" and read every hit.
- [ ] Read against the W3C Appendix D pseudocode rule: parser work only, no
      Appendix D procedure touched, no deviation claimed (ADR-0002).
- [ ] The conformance run's result set is compared to the pre-change run by eye,
      not just by exit code — no member flipped in either direction.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 3: Downstream documentation

### Overview

Documentation-only. The lowering builders and the `Statifier.Document` structs
describe their text as "verbatim, untrimmed", which now implies more than it
should: the concatenation is still untrimmed and still verbatim with respect to
whitespace, but its line breaks are folded. Separate from Phase 2 because it
touches no behavior and no test, and gates on its own.

### Changes Required:

#### 1. The lowering builders

**File**: `lib/statifier/lowering/builders.ex`
**Changes**: the three "verbatim, untrimmed" statements (`builders.ex:436`,
`:495`, `:751`) are qualified — verbatim except for the parser's XML 1.0 2.11
line-break fold (ADR-0045). The `<content>` text paragraph (`builders.ex:345`)
gets the same qualification; the `markup` slice paragraph (`builders.ex:352`,
`:376`) explicitly does **not** — it is a raw source slice, CR included
(ADR-0045 item 5), and saying so is the point.

#### 2. The document structs

**File**: `lib/statifier/document/assign.ex`, `data.ex`, `script.ex`,
`content.ex`
**Changes**: the same qualification on each `text` field's moduledoc
(`assign.ex:25`, `data.ex:9`, `script.ex:12`); `content.ex:9`'s `markup`
sentence gains the ADR-0045 item 5 note that the slice keeps its raw line
endings and the child document folds when it is parsed.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality` (full, unprofiled, unscoped) is green — this phase's edits
      are moduledoc text, so Doctor, Credo's doc checks, and the compiler's
      doc-attribute handling are what it exercises.
- [x] `mix gate.verify` exits zero.
- [x] `git diff --stat` for this phase names only files under
      `lib/statifier/lowering/` and `lib/statifier/document/`.

#### Manual Verification:

- [ ] Reading `Statifier.Document.Script`'s and `Statifier.Document.Content`'s
      docs end to end, a caller can tell which of `text` and `markup` folds and
      which does not, without opening an ADR.
- [ ] No remaining hit for "verbatim, untrimmed" states the unqualified claim.
- [ ] `git diff` is read in full and every changed line sits inside a
      `@moduledoc` or `@doc` string — `--stat` reports counts, not what kind of
      line moved, so this half of the path check is a human's read.
- [ ] Read against the W3C Appendix D pseudocode rule: documentation only, no
      Appendix D procedure touched (ADR-0002).

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Corpus/Ratchet Notes

No ratchet movement is expected, and the conformance re-run confirms rather than
decides. The reasoning (ADR-0045 Context): a byte-level sweep (`grep -rlP '\r'`)
over `test/` and `tools/` finds no fixture or corpus document carrying a literal
CR; the only `\r` occurrences anywhere are escaped strings in four parser test
files, all from st-6ans's attribute-side work. A document with no literal CR
folds to itself.

If a test does move:

- A test that starts passing is ratcheted in with `mix test.baseline add`, in
  Phase 2's commit.
- A test that starts failing is a real regression in this change, not a ratchet
  edit. Do not shrink `test/passing_tests.json` — that is a `Gate guard` trip
  needing a `docs/quality-gate-changes.md` entry, which per this repo's
  CLAUDE.md is a human's call on the record. Stop and report.

No corpus regeneration (`mise run corpus`) is involved.

## Performance Considerations

`add_text/2` already recomputes `text_span/1` on every event of a coalescing
run; this adds a full raw-versus-value walk on the same schedule, making a run
split into *k* events cost O(k · n) in the run's length rather than O(n). The
split factor is the number of entity references and CDATA sections in the run,
so the worst realistic case is a large `<script>` body dense with `&lt;`.

This is accepted rather than optimized, for two reasons. First, the alternative
(fold once at run close) costs three event clauses and a temporarily-wrong
`value` on the node, for a constant factor on an input shape nobody has. Second,
if it ever does matter, the fix is local to `add_text/2` and needs no change to
`Location` — the helper is already whole-run pure. Do not pre-optimize it in
this bead; measure first if a real document ever shows it.

## Testing Strategy

### Unit Tests:

- `test/statifier/parser/location_test.exs`, new
  `describe "normalize_character_data/3"` (Phase 1) — the walk primitive driven
  directly: CRLF, lone CR, `&#xD;`, CDATA-wrapped CR, `&amp;` inside CDATA,
  comment straddle, PI straddle, TAB preserved, desync fallback. The existing
  `normalize_attribute_value/3` and `resolve_span/4` blocks are the regression
  check on the `walk_units` parameterization.
- `test/statifier/parser_test.exs` (Phase 2) — the observable contract through
  a real parse, each case paired with a raw-slice assertion on
  `DOM.Text.location`.
- `test/statifier/parser/location_accuracy_test.exs` (Phase 2) — the sweep's
  `\r` split, which keeps every existing fixture asserting the strongest
  available invariant.
- Edge cases worth naming: an empty run; a run that is a lone `\r`; `\r\r\n`
  (a lone CR then a CRLF → `"\n\n"`); `&#xD;&#xA;` (two references, neither
  folded, and not a pair); a literal `\r` immediately before the closing tag; a
  CDATA section whose interior spells `<!--`, which must not be taken as a
  comment skip; a multi-byte codepoint adjacent to a folded CR.
- Every new test asserting `lib/` behavior carries its sabotage line, mutation
  applied and observed red before the line is written (`docs/testing.md`).

### Manual Testing Steps:

1. In `iex -S mix`, parse `"<r><t>a\r\nb</t></r>"` and confirm the text value is
   `"a\nb"` while `Location.slice(text.location, source)` is still `"a\r\nb"`.
2. Parse `"<r><t>c\rd</t></r>"` and confirm `"c\nd"` — the lone-CR half of the
   clause.
3. Parse `"<t>a&#xD;b</t>"` and confirm `"a\rb"` — the reference survives.
4. Parse `"<x>i\r<!--c-->\nj</x>"` and confirm `"i\n\nj"`, not `"i\nj"`.
5. Parse `"<t><![CDATA[g\r\nh]]></t>"` and confirm `"g\nh"`.
6. Parse an SCXML fragment with a `<script>` body written with CRLF line
   endings and confirm the compiled script text has no `\r` in it, while
   `<content>`'s `markup` slice for the same document still does.
7. Re-run the two multi-line-`cond` corpus members from ADR-0043
   (`test/scion_tests/send_data/send1_test.exs`,
   `test/scion_tests/send_internal/test0_test.exs`) and confirm they are
   untouched by this change.

## References

- Decision record: `docs/adr/0045-character-data-folds-line-breaks-per-xml-2-11.md`
  (this plan implements its Decision and Consequences; it is not re-litigated
  here)
- Extends: `docs/adr/0043-attribute-values-normalize-per-xml-3-3-3.md` (whose
  open question ADR-0045 resolves)
- Related ADRs: `docs/adr/0041-*` (`Content.markup` raw slices),
  `docs/adr/0014-*` (expression spans), `docs/adr/0012-*` (observability),
  `docs/adr/0011-*` (gate guard ledger), `docs/adr/0002-*` (Appendix D fidelity)
- Spec: XML 1.0 2.11 (end-of-line handling) and 2.3's note, plus 3.3.3 for the
  contrast, read from the local cache at
  `$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/`;
  SCXML Appendix A.2 (XML processor obligation)
- Similar implementation: `lib/statifier/parser/location.ex:149-231` —
  `normalize_attribute_value/3`, `walk_units/3`, `normalize_units/2`, the shape
  this mirrors; `location.ex:301-353` — `next_unit/2` and `next_unit_plain/2`,
  the unit rule it shares
- Prior plan for the attribute half:
  `docs/plans/260817-st-6ans-attribute-value-normalization.md`
- Call site: `lib/statifier/parser/handler.ex:139-167`
- Scanner skip list: `lib/statifier/parser/markup.ex:78-84`
- Bead: st-5x0b

## Deferred Manual Verification

Manual verification items are deferred during looped (`--loop`) execution and
surfaced here once, rather than blocking after each phase. Confirm every Manual
Verification item from Phases 1, 2, and 3 before considering the plan fully
landed.

**Verification pass run 2026-08-17**, by a session other than the one that
implemented the phases. Every item below is marked; each carries what was
actually checked. Two carry a caveat worth reading rather than a plain tick:
the spec-cache item, which was unsatisfiable as phrased and was verified
against the live W3C source instead, and the sabotage item, which was checked
structurally rather than by re-running all 17 mutations and so still rests on
the implementing session's attestation. One question is deliberately left open
for a human: whether ADR-0045 item 2 gets a clarifying sentence — a call on the
record, not on the code, which nothing here blocks on.

The three that most deserve a human's eye:

- [x] The CDATA-interior refinement (Phase 1, change 2) is the right reading of
      ADR-0045 item 2. This plan decided it rather than asking, on the grounds
      that the record's own decision item 1 and test list require a CR inside
      CDATA to fold; if a human disagrees, the record needs a sentence, not the
      code. **Confirmed by parse** (2026-08-17): `<r><t><![CDATA[a\r\nb]]></t></r>`
      yields `"a\nb"`, and `<r><t><![CDATA[&amp;]]></t></r>` yields `"&amp;"` —
      the interior walks verbatim while only the delimiters are raw-only, which
      is the reading that keeps both of the record's requirements true at once.
      **Still open for a human**: whether ADR-0045 item 2's wording gets the
      clarifying sentence, which is a call on the record, not on the code.
- [x] `<x>i\r<!--c-->\nj</x>` folds to `"i\n\nj"` on a real parse. **Confirmed**
      (2026-08-17): value is `"i\n\nj"`, raw slice is `"i\r<!--c-->\nj"`. Saxy
      coalesces the comment-straddled run into one text node, so a value-only
      fold would have produced `"i\nj"`; it did not.
- [x] The conformance re-run moved nothing in either direction. **Confirmed by
      re-run** (2026-08-17, independent of the implementing session):
      `mix test --include scion --include scxml_w3` → 2,175 tests, 15 failures,
      the same pre-existing set; `test/passing_tests.json` is absent from
      `git diff --name-only origin/main...HEAD`, so the ratchet never moved.

### Phase 1

- [x] The XML 1.0 2.11 text quoted in the new `@doc` and comments is read from
      the local spec cache
      (`$(git rev-parse --path-format=absolute --git-common-dir)/spec-cache/`),
      not from memory, and matches byte for byte. **Resolved differently than
      written** (2026-08-17): no local cache holds the XML 1.0 REC —
      `mise run spec:fetch` populates only the SCXML REC and its Appendix D
      extract — so this item was unsatisfiable as phrased. Verified instead by
      fetching https://www.w3.org/TR/xml/#sec-line-ends directly: the quoted
      sentence matches character for character. The `@doc` already discloses
      its provenance rather than claiming a cache read.
- [x] The CDATA-interior refinement in change 2 is confirmed as a refinement of
      ADR-0045 item 2 and not a contradiction of it: a CR inside CDATA folds,
      which is what the record's decision item 1 and its test list require.
      Confirmed by parse, as recorded above.
- [~] Each sabotage mutation was actually applied and observed red, and none of
      them is a truthy-sentinel no-op (`docs/testing.md`). **Structurally
      checked, not reproduced**: 17 new `test "` lines and 17 added
      `# sabotage:` lines across the three changed test files, so none is
      missing. Whether each mutation was genuinely run and observed red is the
      implementing session's attestation; re-running all 17 was not done here.
      This is the one item still resting on a self-report.
- [x] The raw-only skip is confirmed by reading to be unreachable for attribute
      values: `next_unit/2`'s behavior is untouched and `<` cannot occur
      literally in a well-formed attribute value anyway. Corroborated by parse:
      an attribute value with a literal newline still normalizes to `"a b"`.
- [x] Read against the W3C Appendix D pseudocode rule: this phase touches the
      parser, not the interpreter, so no Appendix D procedure is involved and no
      deviation is claimed (ADR-0002 does not apply to `lib/statifier/parser/`).
      Confirmed: the branch changes no file under `lib/statifier/interpreter`.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

**Commit contents**: this phase's commit also carries the three
already-uncommitted direction-stage files on this branch —
`docs/adr/0045-character-data-folds-line-breaks-per-xml-2-11.md`,
`docs/adr/0043-attribute-values-normalize-per-xml-3-3-3.md` (its open-question
bullet marked resolved), and `docs/adr/README.md` (the index row). They are this
bead's own work and belong with its first commit.

---

### Phase 2

- [x] In `iex -S mix`, `Statifier.Parser.parse("<r><t>a\\r\\nb</t></r>")` yields
      `"a\nb"` and `Location.slice/2` over the same node still yields `"a\r\nb"`.
      This is the bead's own reproduction, inverted. **Confirmed** (2026-08-17),
      both halves, plus the lone-CR case `<r><t>a\rb</t></r>` -> `"a\nb"` with
      raw slice `"a\rb"`.
- [x] `<x>i\r<!--c-->\nj</x>` yields `"i\n\nj"` — the case that proves the walk
      reads the fold's followed-by rule off the raw text rather than the value.
      A `"i\nj"` result means a value-only fold slipped in. **Confirmed**
      (2026-08-17): `"i\n\nj"`.
- [x] `<t>a&#xD;b</t>` still yields `"a\rb"` — the literal-versus-reference
      distinction, the thing a `String.replace/3` would destroy. **Confirmed**
      (2026-08-17): value `"a\rb"`, raw slice `"a&#xD;b"`.
- [x] An attribute value containing a literal newline still normalizes to a
      single space, unchanged by this phase. **Confirmed** (2026-08-17):
      `<r><t c="a\nb"/></r>` gives `c == "a b"`.
- [x] The moduledoc edits leave no stale statement of the old behavior: grep
      `lib/statifier/parser` for "verbatim", "not normalized", and "Saxy
      reported" and read every hit. **Confirmed** (2026-08-17): 6 hits, each
      either describing the raw slice (correctly still verbatim) or carrying
      the 2.11 carve-out.
- [x] Read against the W3C Appendix D pseudocode rule: parser work only, no
      Appendix D procedure touched, no deviation claimed (ADR-0002). Confirmed
      against `git diff --name-only origin/main...HEAD`.
- [x] The conformance run's result set is compared to the pre-change run by eye,
      not just by exit code — no member flipped in either direction. **Confirmed
      by independent re-run** (2026-08-17): 15 failures, the known pre-existing
      set; `test/passing_tests.json` untouched across all three commits, so the
      ratchet stage would have caught any member that flipped to failing.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

### Phase 3

- [x] Reading `Statifier.Document.Script`'s and `Statifier.Document.Content`'s
      docs end to end, a caller can tell which of `text` and `markup` folds and
      which does not, without opening an ADR. **Confirmed** (2026-08-17):
      `content.ex:14-21` states outright that `markup` keeps raw line endings,
      CR included, and folds only when the child document it names is itself
      parsed; `text` carries the 2.11 carve-out.
- [x] No remaining hit for "verbatim, untrimmed" states the unqualified claim.
      **Confirmed** (2026-08-17): the phrase survives at five sites, each now
      immediately followed by the "verbatim except for the parser's XML 1.0
      2.11 line-break fold - ADR-0045" qualification. The phrase remaining is
      correct; the unqualified claim is gone.
- [x] `git diff` is read in full and every changed line sits inside a
      `@moduledoc` or `@doc` string — `--stat` reports counts, not what kind of
      line moved, so this half of the path check is a human's read. **Confirmed**
      (2026-08-17): every `lib/` line in `0dd5f97` is doc-string prose; the only
      non-`lib/` change is this plan file.
- [x] Read against the W3C Appendix D pseudocode rule: documentation only, no
      Appendix D procedure touched (ADR-0002). Confirmed: `0dd5f97` changes only
      moduledoc/doc strings.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
