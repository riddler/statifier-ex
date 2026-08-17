# ADR-0043: Attribute values normalize per XML 1.0 3.3.3, guided by the raw source

Status: accepted (2026-08-17)

## Context

st-nhpk's verification pass found that Saxy 1.6.1 does not apply XML 1.0
3.3.3 attribute-value normalization: a literal TAB, LF, or CR inside an
attribute value survives verbatim into `Statifier.Parser.DOM.Attribute`'s
`value`, where the spec requires a space. XML 1.0 3.3.3 (quoted from
https://www.w3.org/TR/xml/#AVNormalize, fetched 2026-08-17):

> Before the value of an attribute is passed to the application or checked
> for validity, the XML processor MUST normalize the attribute value by
> applying the algorithm below, or by using some other method such that the
> value passed to the application is the same as that produced by the
> algorithm.

The algorithm's per-item rules draw the distinction statifier already gets
half right:

> For a character reference, append the referenced character to the
> normalized value. [...] For a white space character (#x20, #xD, #xA,
> #x9), append a space character (#x20) to the normalized value.

So `&#10;` must stay a newline while a literal newline must become a
space - and today the literal half is wrong. Two more clauses bound the
obligation. First, the algorithm operates on text whose line breaks 2.11
already normalized, so a raw `\r\n` pair inside a value is one `#xA` before
3.3.3 sees it - one space out, not two. Second, the further
collapse-and-trim step applies only to attributes declared other than
CDATA, and:

> All attributes for which no declaration has been read SHOULD be treated
> by a non-validating processor as if declared CDATA.

Statifier reads no DTD, so the CDATA treatment applies: whitespace maps to
`#x20` one-for-one (after 2.11), and nothing is trimmed or collapsed.

SCXML binds this to us through Appendix A.2: "In a Conforming SCXML 1.0
Processor, the XML parser MUST be able to parse and process all well-formed
XML constructs defined within [XML] and [XMLNames]." `Statifier.Parser`'s
own moduledoc says "this layer knows XML" - and it already honors the other
processor-level obligation of the same class, entity expansion. The
"nothing is validated, normalized, or resolved" rule in that moduledoc is
about vocabulary (namespaces, unknown names, whitespace-only *text* runs),
not about what an XML processor must do before the value exists at all.

Why the call is not a cleanup: predicator counts lines and columns in
`Attribute.value` (ADR-0014), so a `cond` or `expr` written across two
physical source lines stops being two logical lines once the newline
becomes a space, and every span in its table moves. What the investigation
found, concretely:

- **The corpus contains exactly two multi-line attribute values**, both
  `cond`s in ratchet members: `test/scion_tests/send_data/send1_test.exs`
  and `test/scion_tests/send_internal/test0_test.exs`. Predicator's lexer
  treats `#x20`, `#x9`, `#xA`, and `#xD` identically as whitespace
  (`deps/predicator/lib/predicator/lexer.ex:215-226`), so their compiled
  instructions and evaluation results are unchanged by normalization; only
  their span tables shift. No corpus assertion reads a span, so no ratchet
  movement is expected - the re-run confirms rather than decides.
- **No fixture or W3C corpus document carries a literal TAB/LF/CR in any
  attribute value** beyond those two conds (swept every `.xml`, `.scxml`,
  and embedded-heredoc `.exs` under `test/` and `tools/`).
- **`Statifier.Parser.Location.resolve_span/4` was built for the
  normalized world already**: its `next_unit_plain/2` clause pairing a raw
  TAB/LF/CR against an expanded space exists today and is unreachable
  through a real parse - `location_test.exs`'s synthetic test (~line 318)
  says so explicitly. The lockstep walk keeps spans exact under either
  behavior, because it walks whatever the parser actually produced.
- **Nothing in `lib/` calls `resolve_span/4` yet** - the evaluation-error
  wiring that will is still ahead - so the coordinate change lands before
  any consumer depends on the unnormalized coordinates.
- **Saxy offers no option**: no normalization code or setting exists
  anywhere under `deps/saxy/lib/`, and Saxy passes handlers no positions
  either (the same gap the Markup scanner already fills). Waiting on
  upstream is not a plan.

One trap shapes the implementation. Saxy hands the handler an
entity-*expanded* value, so a `\n` in that string is ambiguous: a literal
newline (must normalize) or an expanded `&#10;` (must not). Normalizing
Saxy's output blindly would erase exactly the distinction 3.3.3 draws.
The raw source disambiguates, and the handler already holds it:
`value_location` slices the raw value text, and `resolve_span/4`'s
four-case unit rule already classifies reference-versus-literal against
that slice.

## Decision

**Statifier normalizes attribute values per XML 1.0 3.3.3, in the parser,
guided by the raw source.** Option (b) - documenting non-normalization as a
deviation - is rejected: A.2 makes 3.3.3 a processor obligation, every
other SCXML toolchain's parser (libxml2 under SCION, the Java parsers under
the W3C tests) hands its engine the normalized string, and a deviation here
would mean statifier evaluates a different `cond` text than any conforming
processor given the same wrapped attribute, forever, to save a contained
one-time change.

Concretely:

1. **`Attribute.value` is the 3.3.3-normalized, entity-expanded value.**
   The handler (`Statifier.Parser.Handler.build_attributes/2` or a helper
   it calls) derives it by walking the raw slice
   (`Location.slice(value_location, source)`) against Saxy's expanded
   value in lockstep, the same unit rule `resolve_span/4` uses: a
   reference token keeps its decoded character verbatim; a literal `#x20`
   / `#x9` / `#xA` / `#xD` appends `#x20`; a literal `\r\n` pair is
   consumed as one unit and appends a single `#x20` (2.11 folded in);
   everything else passes through. Saxy stays authoritative for
   expansion - the walk validates each decode against Saxy's value exactly
   as `next_unit/2` does, and a desync between the two passes falls back
   to Saxy's value unnormalized rather than guessing.
2. **CDATA treatment only.** No leading/trailing trim, no collapsing of
   space runs - statifier reads no attribute declarations, so the SHOULD
   above is the whole obligation. `Statifier.Compiler.Expressions` keeps
   not trimming, and `resolve_span/4`'s anchor contract ("`value`'s
   position `{1, 1}` is `value_location`'s start") holds unchanged.
3. **`value_location` still covers raw source, untouched.** Normalization
   changes the string, never the span. `resolve_span/4`'s
   TAB/LF/CR-versus-space clause becomes reachable through a real parse,
   which is the world it was written for; its one extension is a unit
   pairing a raw `\r\n` (two codepoints) against a single expanded space,
   without which a CRLF-wrapped attribute desyncs to the whole-value
   fallback.
4. **Text content is out of scope.** 2.11 line-break normalization of
   character data (a literal `\r\n` in a text node) is a separate gap with
   its own blast radius (`<script>` bodies, `<content>` slices) and gets
   its own bead if pursued; this record neither fixes nor blesses it.

## Consequences

- A `cond` wrapped across physical lines compiles from a one-line string
  with the line structure a conforming parser produces; predicator spans
  for it are single-line, and `resolve_span/4` maps them back across the
  raw newline exactly - the composition ADR-0014 committed to, now over
  spec-correct input.
- Follow-on work, sized for the implementation stage (the bead's remaining
  acceptance criteria):
  - The normalization walk in the parser handler (decision items 1-2),
    sharing or mirroring `Location`'s reference-decode logic rather than
    duplicating its regex ad hoc.
  - The `\r\n`-pair unit in `resolve_span/4`'s walk (decision item 3).
  - Test updates: `location_test.exs`'s synthetic TAB test (~line 318)
    becomes reachable through a real parse and its "Passed by hand" note
    goes; the literal-newline test (~line 188) re-anchors on the
    normalized value ("first second", one expanded line) while still
    asserting the resolved absolute document line; new coverage for
    literal-versus-`&#10;` divergence and for CRLF. Each carries its
    sabotage line per `docs/testing.md`.
  - Doc updates where the old behavior is stated: `Statifier.Parser`'s
    "one consequence worth stating" paragraph, `DOM.Attribute`'s
    moduledoc, and the parser moduledoc's "not normalized" list gains the
    3.3.3 carve-out.
  - Full conformance re-run (`mix test --include scion --include
    scxml_w3`); any ratchet movement rides in the same commit. Expected
    movement: none, per the corpus findings above.
  - Full `mix quality` green.
- The desync fallback in decision item 1 (scanner record missing or raw
  walk failing: keep Saxy's value unnormalized) mirrors `resolve_span/4`'s
  degrade-don't-raise posture. It is recorded here as the chosen behavior;
  if the implementation finds a cheap way to make the case impossible
  instead, better.
- Open question, recorded and deliberately not blocking: whether character
  data deserves 2.11 treatment too (decision item 4). No corpus document
  is known to depend on it either way. This branch's verification pass
  confirmed the deviation is live rather than hypothetical - `<r><t>a\r\nb
  </t></r>` parses to `"a\r\nb"` where 2.11 requires `"a\nb"` - and filed
  **st-5x0b** to own the call, so the question is tracked rather than
  waiting on whoever hits a CRLF-sensitive `<script>` body first.
  *Resolved by ADR-0045 (st-5x0b's outcome): character data folds line
  breaks per 2.11, guided by the raw source, extending this record.*
