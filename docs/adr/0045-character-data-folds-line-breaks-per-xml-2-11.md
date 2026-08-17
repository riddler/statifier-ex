# ADR-0045: Character data folds line breaks per XML 1.0 2.11, guided by the raw source

Status: accepted (2026-08-17)

## Context

ADR-0043 normalized attribute values per XML 1.0 3.3.3 and put character
data explicitly out of scope (its decision item 4), recording as its open
question whether text nodes deserve the 2.11 line-break fold too and filing
st-5x0b to own the call. This record resolves that question. It extends
ADR-0043 rather than amending it: nothing in ADR-0043's decision changes,
and its item 4 anticipated exactly this follow-on record.

XML 1.0 2.11 (quoted from https://www.w3.org/TR/xml/#sec-line-ends, fetched
2026-08-17):

> To simplify the tasks of applications, the XML processor MUST behave as
> if it normalized all line breaks in external parsed entities (including
> the document entity) on input, before parsing, by translating both the
> two-character sequence #xD #xA and any #xD that is not followed by #xA
> to a single #xA character.

"On input, before parsing" makes the fold unconditional over the entity
text - character data, CDATA sections, comments, everything. The spec's own
note under 2.3 says so in as many words:

> As explained in 2.11 End-of-Line Handling, all #xD characters literally
> present in an XML document are either removed or replaced by #xA
> characters before any other processing is done. The only way to get a
> #xD character to match this production is to use a character reference
> [...]

Two consequences of that phrasing matter here. First, CDATA is not exempt:
`<![CDATA[` is recognized during parsing, and the fold happens before
parsing, so a literal CRLF inside a CDATA section folds like any other.
Second, a `&#xD;` character reference must survive as a real #xD - the
reference is five CR-free ASCII characters, so the pre-parse fold never
touches it. That is the same literal-versus-reference distinction ADR-0043
preserved for attributes, now on the text side.

SCXML binds this to us the same way ADR-0043 argued: Appendix A.2 makes
[XML] conformance a processor MUST, and `Statifier.Parser`'s moduledoc
claims "this layer knows XML".

What the investigation found, concretely (probed 2026-08-17 on this
branch):

- **The deviation is live.** `<r><t>a\r\nb</t></r>` parses to
  `DOM.Text.value == "a\r\nb"` where 2.11 requires `"a\nb"`; a lone CR
  (`"c\rd"`) and a CDATA-wrapped CRLF (`"g\r\nh"`) survive the same way.
  `&#xD;` correctly yields `"\r"` today and must keep doing so.
- **Saxy folds nothing.** No normalization code or option exists anywhere
  under `deps/saxy/lib/`; the only CR mention is the `is_whitespace`
  guard (`deps/saxy/lib/saxy/guards.ex:6`). Same finding as ADR-0043;
  waiting on upstream is not a plan.
- **Saxy's event granularity cannot disambiguate.** Its `chardata` loop
  decodes references inline into the same accumulator
  (`deps/saxy/lib/saxy/parser/builder.ex`, `element_entity_ref` appending
  into `acc`), so one `:characters` event carries literal text and decoded
  references mixed together. A `"\r"` in the event string is ambiguous -
  literal CR (must fold) or expanded `&#xD;` (must not) - exactly the trap
  ADR-0043 identified for attribute values. Only the raw source
  disambiguates, and the handler already holds it: `text_span/1` computes
  each run's raw span.
- **A value-only fold is wrong even ignoring references.** The scanner
  skips comments, CDATA delimiters, and PIs without producing records
  (`lib/statifier/parser/markup.ex:81-83`), so a text run's raw span can
  straddle all three while `value` contains none of them. Probed:
  `<x>i\r<!--c-->\nj</x>` coalesces to `value == "i\r\nj"`, but in the raw
  entity text that CR is *not* followed by #xA (a comment intervenes), so
  2.11 folds it alone: the correct value is `"i\n\nj"`, not the `"i\nj"` a
  blind `String.replace` on the value would produce. The raw text is not
  merely a disambiguator here; it is the only place the fold's
  followed-by rule can be read off.
- **No fixture or corpus document carries a literal CR.** A byte-level
  sweep (`grep -rlP '\r'`) over `test/` and `tools/` finds none; the only
  `\r` occurrences are escaped strings in four parser test files, all from
  st-6ans's attribute-side work. No ratchet movement is expected - the
  re-run confirms rather than decides.
- **No consumer does offset arithmetic over `DOM.Text.value`.** The four
  `DOM.text/1` call sites (`lib/statifier/lowering/builders.ex`) feed
  `Content.text`, `Data.text`, `Assign.text`, and `Script.text`, all
  compiled or stored whole; diagnostic spans for text-sourced expressions
  are whole-node locations by design (`lib/statifier/compiler.ex:1658`:
  "`Content.text` has no span of its own"). Nothing in `lib/` calls
  `Location.resolve_span/4` (grep confirms; ADR-0043 recorded the same),
  and text nodes have no `value_location` to anchor one. `DOM.Text`'s own
  moduledoc already disclaims 1:1 offset mapping between `value` and
  `location` whenever a reference or CDATA delimiter is present, so the
  fold adds one more case to a divergence that is already the documented
  contract. `slice_markup/2` (`Content.markup`, ADR-0041) slices raw
  source by locations and never reads `value`, so it is untouched.

One alternative was seriously considered and rejected: folding the whole
source binary before `Markup.scan/1` and Saxy, which is literally what 2.11
describes and gets every case above right for free. It loses to the span
contract: `Statifier.Parser.parse/1` promises that every span slices out of
the caller's own binary (its "Relaxed input" section), ADR-0014's
attribute-relative arithmetic, ADR-0041's markup slices, observability
constraint 3, and the location-accuracy sweep all lean on that promise, and
a pre-fold moves every byte offset after the first CRLF - a visualizer
holding the user's actual file would highlight the wrong bytes on every
CRLF checkout. ADR-0043 chose per-value normalization over raw spans for
the same reason; character data takes the symmetric choice.

## Decision

**Statifier folds line breaks in character data per XML 1.0 2.11, in the
parser, guided by the raw source.** Documenting the deviation is rejected
on ADR-0043's own reasoning, which applies verbatim: A.2 makes 2.11 a
processor obligation, every other SCXML toolchain's parser hands its engine
the folded text, and a deviation would mean a `<script>` body or
`<content>` payload differs by stray #xD characters from what any
conforming processor produces from the same document. This record extends
ADR-0043 and resolves its open question; it amends nothing.

Concretely:

1. **`DOM.Text.value` is the 2.11-folded, entity-expanded text.** A
   literal `\r\n` pair and a literal lone `\r` in the raw run each become
   one `\n`; a `\r` decoded from `&#xD;` stays `\r`; everything else
   passes through. Only the 2.11 fold applies - 3.3.3's
   whitespace-to-space mapping is attribute-specific and never touches
   character data (the bead's own contrast), so TABs and folded newlines
   are kept.
2. **The fold is a `Location` helper mirroring
   `normalize_attribute_value/3`, called from the handler.**
   `Statifier.Parser.Location` gains a character-data sibling (working
   name `normalize_character_data/3`) that walks the run's raw slice
   against the expanded value with the same tagged-unit machinery
   (`walk_units`/`next_unit`), folds literal `\r\n` and lone `\r` units to
   `"\n"`, and keeps reference units verbatim. The walk needs one
   extension over the attribute version: raw-only skip units for the three
   constructs the scanner leaves inside a text span - `<!--` through
   `-->`, `<![CDATA[` through `]]>`, and `<?` through `?>` - each
   consuming raw text and contributing nothing to the expanded side. A raw
   `<` inside a well-formed text run can only open one of those three (a
   real tag would have ended the run), so the skip rule is deterministic.
   The reference regex misfiring inside CDATA is already impossible for
   the reason ADR-0043's walk is safe everywhere: every decode is
   validated against the expanded value before it is believed, and
   `&#xD;` inside CDATA pairs against a value that spells `&#xD;`
   literally, so it walks as plain characters.
   `Statifier.Parser.Handler.add_text/2` applies the fold with the run's
   raw span (`text_span/1`), recomputing over the accumulated value as
   events coalesce exactly as the span itself is recomputed today; the
   final event of a run sees the complete value against the complete
   span, so the finished node is folded whole. Whether intermediate
   recomputes walk a value prefix or the fold is deferred to run
   completion is the implementation's call.
3. **Desync degrades to Saxy's value unfolded.** Same posture as
   `normalize_attribute_value/3` and `resolve_span/4`: a raw slice that
   cannot be walked against the value keeps Saxy's value rather than
   guessing (ADR-0043's fallback, applied here).
4. **`DOM.Text.location` keeps covering raw source, untouched.** The fold
   changes the string, never the span - the same split ADR-0043's item 3
   made for attributes, and the split `DOM.Text`'s moduledoc already
   documents for references and CDATA delimiters. No lockstep span
   machinery is stood up for text nodes now: nothing calls
   `resolve_span/4` at all yet, text has no `value_location`, and every
   text-sourced diagnostic uses a whole-node location today (the evidence
   above), so there is no consumer whose coordinates the fold can move.
5. **`Content.markup` stays a raw slice, CR included.** ADR-0041's markup
   arm is opaque source bytes sliced by location; the child document
   compiled from it at invoke time is parsed by this same parser, whose
   own character-data fold then applies. Folding the slice itself would
   change bytes this layer promised to pass through verbatim.

## Consequences

- `Content.text`, `Data.text`, `Assign.text`, and `Script.text` receive
  the line structure a conforming processor produces: a `<script>` body or
  `<content>` payload authored on a CRLF checkout evaluates the same text
  everywhere. Attribute values are unchanged -
  `normalize_attribute_value/3` already folds a raw CRLF inside a value to
  one space and keeps assuming unfolded input, which item 2's
  no-pre-fold design preserves.
- Follow-on work, sized for the implementation stage (the bead's remaining
  acceptance criteria):
  - The `Location` character-data fold helper (decision items 1-3),
    sharing `walk_units`/`next_unit` rather than duplicating them, plus
    the three raw-only skip units; the handler call site in `add_text/2`.
  - Tests, each with its sabotage line per `docs/testing.md`: CRLF folds
    to one `\n`; lone CR folds; `&#xD;` survives as `\r` (the
    literal-versus-reference divergence); CR inside CDATA folds; the
    comment-straddle case (`i\r<!--c-->\nj` folds to `"i\n\nj"`, the case
    that proves the raw walk); a desync-fallback case if one is
    constructible; `DOM.Text.location` still slicing the raw run.
  - `test/statifier/parser/location_accuracy_test.exs`: the
    `assert_text_accurate/2` split treats a raw slice containing `\r` as
    decode-changed (like `&` and `<![CDATA[` today), since slice and
    value stop agreeing byte-for-byte; its shortens-or-holds-steady
    invariant already covers the fold.
  - Doc updates where the old behavior is stated: `Statifier.Parser`'s
    "not normalized" list and its "one consequence worth stating"
    paragraph gain the 2.11 text carve-out; `DOM.Text`'s moduledoc
    defines `value` as folded; the "verbatim, untrimmed" wording in
    `lowering/builders.ex` and the `Statifier.Document`
    `Content`/`Data`/`Assign`/`Script` moduledocs is qualified where it
    implies raw line endings survive.
  - ADR-0043's open-question bullet is marked resolved by this record
    (done alongside this record).
  - Full conformance re-run (`mix test --include scion --include
    scxml_w3`); any ratchet movement rides in the same commit. Expected
    movement: none - no corpus file carries a literal CR byte.
  - Full `mix quality` green.
- Open question, recorded and deliberately not blocking: sub-text span
  resolution. If the evaluation-error wiring ever wants to point inside a
  `<script>` or `<content>` body the way `resolve_span/4` points inside an
  attribute value, it needs a raw-versus-expanded lockstep walk for text -
  and would have needed one before this record too, since references and
  CDATA delimiters already desync the coordinates; the fold adds only the
  CR units, and the skip units built here are the bulk of that future
  walk. Nothing calls for it today, so it stays a known seam rather than
  scope.
- Open question, second and equally not blocking: lone-CR line counting.
  `Location`'s line accounting counts only `\n`
  (`line_and_column/1`, `raw_advance_codepoint/2`), so a document using
  bare-CR line endings gets line numbers that differ from an editor
  treating CR as a line break. That is pre-existing, untouched by this
  decision (spans stay raw), and bare-CR files are effectively extinct;
  it is named here so the next person tracing a lone-CR span knows the
  behavior is known rather than newly broken.
