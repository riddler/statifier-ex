defmodule Statifier.Parser.LocationTest do
  use ExUnit.Case, async: true

  alias Statifier.Parser
  alias Statifier.Parser.{DOM, Location}

  describe "at_offset/2" do
    # sabotage: line_and_column/1 seeds column with `String.length(last_line)`
    # instead of `+ 1` -> the offset-0 case reddens (column 0 instead of 1)
    test "offset 0 is line 1, column 1" do
      assert Location.at_offset("<scxml/>", 0) == %Location{
               start_line: 1,
               start_column: 1,
               start_offset: 0,
               end_line: 1,
               end_column: 1,
               end_offset: 0
             }
    end

    # sabotage: line_and_column/1 splits on "\r\n" instead of "\n" -> this
    # test reddens (line stays 1 instead of advancing to 2)
    test "counts a newline crossed by the prefix" do
      source = "line one\nline two"
      offset = byte_size("line one\nli")

      assert Location.at_offset(source, offset) == %Location{
               start_line: 2,
               start_column: 3,
               start_offset: offset,
               end_line: 2,
               end_column: 3,
               end_offset: offset
             }
    end

    # sabotage: line_and_column/1 counts `byte_size(last_line)` instead of
    # `String.length(last_line)` -> this reddens (column overshoots since
    # each of the two non-ASCII codepoints is more than one byte)
    test "counts codepoints, not bytes, for non-ASCII text on the line" do
      source = "café <scxml/>"
      offset = byte_size("café ")

      location = Location.at_offset(source, offset)

      assert location.start_line == 1
      # "café " is 5 codepoints (c, a, f, é, space), so column 6 - byte
      # offset would put this at column 7 since "é" is 2 bytes in UTF-8.
      assert location.start_column == 6
      assert location.start_offset == offset
    end

    # sabotage: n/a - pins that at_offset/2 accepts the full source length
    # (one past the last valid index), a boundary case/1 above does not
    # exercise; asserts a documented input shape, not a computed behavior
    test "accepts an offset at the end of the source" do
      source = "<a/>"

      location = Location.at_offset(source, byte_size(source))

      assert location.start_offset == byte_size(source)
      assert location.start_line == 1
      assert location.start_column == byte_size(source) + 1
    end
  end

  describe "slice/2" do
    # sabotage: slice/2 uses `end_offset` instead of `end_offset - start_offset`
    # as the length argument -> this reddens (raises ArgumentError from
    # binary_part/3 on an out-of-range length, or returns the wrong text)
    test "returns the exact bytes a span covers" do
      source = "<state id=\"s1\"/>"

      location = %Location{
        start_line: 1,
        start_column: 2,
        start_offset: 1,
        end_line: 1,
        end_column: 7,
        end_offset: 6
      }

      assert Location.slice(location, source) == "state"
    end

    # sabotage: n/a - a zero-width span is an at_offset/2 output shape, and
    # this pins slice/2's behavior on it rather than computing anything new
    test "returns an empty string for a zero-width span" do
      source = "<scxml/>"
      location = Location.at_offset(source, 3)

      assert Location.slice(location, source) == ""
    end
  end

  describe "resolve_span/4" do
    # `cond`'s `value_location` (the raw source between the quotes) and
    # `source` come from a real parsed document in every case below; `value`
    # is the entity-expanded string `resolve_span/4` documents as its third
    # argument - taken from the real `attribute.value` where the case is
    # about what Saxy actually produces (undeclared entities), and built by
    # hand where the case targets a code path Saxy's output can never reach
    # (the `\r` and TAB-normalization clauses) - `resolve_span/4` takes
    # `value` as a parameter precisely so a caller can supply either.
    defp root_attribute(source, name \\ "cond") do
      assert {:ok, root} = Parser.parse(source)
      DOM.attribute(root, name)
    end

    # sabotage: next_unit_plain/2's `raw_cp == value_cp` guard inverted to
    # `raw_cp != value_cp` -> the plain-text case never matches, so the walk
    # desyncs immediately and resolve_span/4 falls back to the whole
    # attribute value -> this test reddens (slice returns "score > 5")
    test "plain ASCII with no references resolves a subexpression" do
      source = ~s(<edge cond="score > 5"/>)
      attribute = root_attribute(source)

      resolved =
        Location.resolve_span(attribute.value_location, {{1, 1}, {1, 6}}, attribute.value, source)

      assert Location.slice(resolved, source) == "score"
    end

    # sabotage: the reference-consuming branch of next_unit/2 slices the raw
    # rest by `byte_size(decoded)` instead of `byte_size(token)` -> only part
    # of `&lt;` is consumed from the raw side, so every raw column after it
    # is off by the difference and the walk desyncs -> this test reddens
    # (slice returns the whole attribute value instead of "score")
    test "a reference before the span shifts the raw columns" do
      source = ~s(<edge cond="1 &lt; score"/>)
      attribute = root_attribute(source)

      # value expands to "1 < score"; "score" is expanded columns 5-9.
      resolved =
        Location.resolve_span(
          attribute.value_location,
          {{1, 5}, {1, 10}},
          attribute.value,
          source
        )

      assert Location.slice(resolved, source) == "score"
    end

    # sabotage: expanded_advance/2's `"\n"` clause returns `{line + 1,
    # column}` instead of `{line + 1, 1}` -> the expanded cursor's column
    # never resets after the character-reference line break -> this test
    # reddens (the target position is never reached, so the span clamps to
    # the whole value instead of "after")
    test "&#10; inside the value shifts an expanded line the raw source does not have" do
      source = ~s(<edge cond="before&#10;after"/>)
      attribute = root_attribute(source)

      # value expands to "before\nafter"; "after" starts expanded line 2.
      resolved =
        Location.resolve_span(attribute.value_location, {{2, 1}, {2, 6}}, attribute.value, source)

      assert Location.slice(resolved, source) == "after"
    end

    # sabotage: raw_advance_codepoint/2's non-newline clause advances the
    # offset by `1` instead of `byte_size(codepoint)` -> the raw cursor
    # undercounts every byte "é" costs beyond its first, so every column
    # after it lands one byte short -> this test reddens (slice returns
    # "core" instead of "score", off by the byte "é" was undercounted)
    test "multi-byte text before the span keeps codepoint columns and byte offsets aligned" do
      source = ~s(<edge cond="café score"/>)
      attribute = root_attribute(source)

      # value is "café score"; "score" is codepoint columns 6-10.
      resolved =
        Location.resolve_span(
          attribute.value_location,
          {{1, 6}, {1, 11}},
          attribute.value,
          source
        )

      assert Location.slice(resolved, source) == "score"
    end

    # sabotage: raw_advance_codepoint/2's `"\n"` clause returns `{offset + 1,
    # line, 1}` instead of `{offset + 1, line + 1, 1}` -> the raw cursor's
    # line never advances past the literal newline inside the attribute
    # value -> this test reddens (the resolved location's byte offset points
    # at the wrong text, so the slice no longer reads "second")
    test "a literal newline inside the raw attribute value resolves to the document's absolute line" do
      source = """
      <chart>
          <edge cond="first
      second" />
      </chart>
      """

      assert {:ok, root} = Parser.parse(source)
      [edge] = DOM.elements(root)
      attribute = DOM.attribute(edge, "cond")

      # The literal newline normalizes to a space (XML 1.0 3.3.3, ADR-0043),
      # so the value is one expanded line: "first second".
      assert attribute.value == "first second"

      # "second" is expanded columns 7-13 of the single-line value.
      resolved =
        Location.resolve_span(
          attribute.value_location,
          {{1, 7}, {1, 13}},
          attribute.value,
          source
        )

      assert Location.slice(resolved, source) == "second"

      # The absolute line is the document's third line, even though the
      # normalized value has only one line - recomputed independently from
      # the resolved byte offset rather than hardcoded, the way
      # location_accuracy_test.exs does. This is exactly what proves the raw
      # cursor still crosses the physical newline.
      recomputed = Location.at_offset(source, resolved.start_offset)
      assert recomputed.start_line == 3
      assert resolved.start_line == recomputed.start_line
    end

    # sabotage: resolve_span/4's `{start_target, end_target} = span` swapped
    # to `{end_target, start_target} = span` -> the walk captures the start
    # and end raw positions in the wrong order -> this test reddens (the
    # five-byte span's length assertion computes -5 instead of 5)
    test "the exclusive end is preserved, including for a zero-width span" do
      source = ~s(<edge cond="score > 5"/>)
      attribute = root_attribute(source)

      resolved =
        Location.resolve_span(attribute.value_location, {{1, 1}, {1, 6}}, attribute.value, source)

      assert resolved.end_offset - resolved.start_offset == byte_size("score")

      zero_width =
        Location.resolve_span(attribute.value_location, {{1, 3}, {1, 3}}, attribute.value, source)

      assert zero_width.start_offset == zero_width.end_offset
      assert Location.slice(zero_width, source) == ""
    end

    # sabotage: @reference_regex's named alternation gains a bare `foo` (as
    # if it were a sixth predefined entity) with no matching
    # `named_codepoint/1` clause -> match_reference/1 recognizes "&foo;" as
    # a reference and crashes decoding it -> this test reddens with a
    # FunctionClauseError instead of resolving "foo"
    test "an undeclared entity kept verbatim is carried by the plain-match case" do
      source = ~s(<edge cond="a &foo; b"/>)
      attribute = root_attribute(source)

      # Saxy keeps an undeclared entity verbatim rather than expanding it.
      assert attribute.value == "a &foo; b"

      resolved =
        Location.resolve_span(attribute.value_location, {{1, 4}, {1, 7}}, attribute.value, source)

      assert Location.slice(resolved, source) == "foo"
    end

    # sabotage: expanded_advance/2's `"\r"` clause returns `{line, column +
    # 1}` instead of holding `{line, column}` -> the expanded cursor advances
    # past the `\r`, so the span's end target is reached one raw character
    # early -> this test reddens (slice returns "a\r" instead of "a\rb")
    test "a \\r in the value holds the expanded column still, mirroring predicator's lexer" do
      # A literal `\r` normalizes to a space (XML 1.0 3.3.3, ADR-0043), so a
      # literal `\r` alone is no longer reachable through a real parse for
      # this case; `&#13;` is a character reference, exempt from
      # normalization, so it is the real way to get a `\r` into `value`.
      source = ~s(<edge cond="a&#13;b"/>)
      attribute = root_attribute(source)

      assert attribute.value == "a\rb"

      # The raw text is 8 bytes ("a", "&#13;", "b") but only 2 expanded
      # columns ("\r" does not advance the expanded cursor), so the span
      # covering both expanded columns must still resolve the full raw text.
      resolved =
        Location.resolve_span(
          attribute.value_location,
          {{1, 1}, {1, 3}},
          attribute.value,
          source
        )

      assert Location.slice(resolved, source) == "a&#13;b"
    end

    # sabotage: maybe_capture/5's `is_nil(Map.fetch!(captured, key))` guard
    # replaced with `true`, so every step overwrites the capture instead of
    # only the first -> this test reddens (the in-range start target no
    # longer resolves to its own position, so the slice is wrong)
    test "a target past the end of value clamps to value_location's end" do
      source = ~s(<edge cond="score"/>)
      attribute = root_attribute(source)

      resolved =
        Location.resolve_span(
          attribute.value_location,
          {{1, 3}, {1, 100}},
          attribute.value,
          source
        )

      assert resolved.end_offset == attribute.value_location.end_offset
      assert resolved.end_line == attribute.value_location.end_line
      assert resolved.end_column == attribute.value_location.end_column
      assert Location.slice(resolved, source) == "ore"
    end

    # sabotage: the `:desync` branch of resolve_span/4 returns
    # `%{value_location | end_offset: value_location.end_offset - 1}`
    # instead of `value_location` unchanged -> this test reddens (the
    # resolved location no longer equals value_location exactly)
    test "a value that does not describe the raw slice returns value_location whole" do
      source = ~s(<edge cond="score"/>)
      attribute = root_attribute(source)

      resolved =
        Location.resolve_span(
          attribute.value_location,
          {{1, 1}, {1, 3}},
          "totally different",
          source
        )

      assert resolved == attribute.value_location
    end

    # sabotage: next_unit_plain/2's TAB/LF/CR-vs-space guard narrowed from
    # `raw_cp in ["\t", "\n", "\r"]` to `raw_cp in ["\n"]` -> a raw TAB no
    # longer normalizes against an expanded space, so the walk desyncs at
    # the TAB -> this test reddens (slice returns the whole attribute value
    # instead of "b")
    test "a raw TAB paired with an expanded space exercises the normalization clause" do
      source = ~s(<edge cond="a\tb"/>)
      attribute = root_attribute(source)

      assert attribute.value == "a b"

      resolved =
        Location.resolve_span(
          attribute.value_location,
          {{1, 3}, {1, 4}},
          attribute.value,
          source
        )

      assert Location.slice(resolved, source) == "b"
    end

    # sabotage: next_unit_plain/2's CRLF clause returns `raw_rest` unchanged
    # instead of `binary_part(raw_rest, 1, byte_size(raw_rest) - 1)` -> the
    # leading "\n" is never skipped, so it is walked again as its own raw
    # unit and the raw cursor never reaches "b" -> this test reddens (slice
    # returns "a\r\nb" instead of "b")
    test "a raw CRLF pair paired with one expanded space walks as a single unit" do
      source = ~s(<edge cond="a\r\nb"/>)
      attribute = root_attribute(source)

      assert attribute.value == "a b"

      resolved =
        Location.resolve_span(
          attribute.value_location,
          {{1, 3}, {1, 4}},
          attribute.value,
          source
        )

      assert Location.slice(resolved, source) == "b"

      whole =
        Location.resolve_span(
          attribute.value_location,
          {{1, 1}, {1, 4}},
          attribute.value,
          source
        )

      assert Location.slice(whole, source) == "a\r\nb"
    end

    # sabotage: next_unit/2 believes every decode unconditionally, dropping
    # the `String.starts_with?(value, decoded)` check and its else branch ->
    # `&lt;` is consumed from the raw side against a value that still spells
    # it out, so the walk desyncs -> this test reddens (slice returns the
    # whole attribute value instead of "score")
    test "a decode the value contradicts falls through to the plain case" do
      source = ~s(<edge cond="1 &lt; score"/>)
      attribute = root_attribute(source)

      # Passed by hand: an unexpanded value, which Saxy never produces. It is
      # what makes the reference check observable - `&lt;` decodes to "<" but
      # the value's next codepoint is "&", so the decode is rejected and the
      # token walks as four plain characters instead. This is the validation
      # next_unit/2 documents: an unexpected decode degrades to the plain
      # case rather than producing a wrong answer.
      value = "1 &lt; score"

      # "score" is columns 8-12 of the unexpanded value.
      resolved = Location.resolve_span(attribute.value_location, {{1, 8}, {1, 13}}, value, source)

      assert Location.slice(resolved, source) == "score"
    end

    # sabotage: decode_reference/1's `"#x" <> hex` clause parses the digits
    # base 10 instead of base 16 -> String.to_integer("A", 10) raises ->
    # this test reddens with an ArgumentError instead of resolving "after"
    test "a hex character reference resolves like its decimal spelling" do
      source = ~s(<edge cond="before&#xA;after"/>)
      attribute = root_attribute(source)

      assert attribute.value == "before\nafter"

      resolved =
        Location.resolve_span(attribute.value_location, {{2, 1}, {2, 6}}, attribute.value, source)

      assert Location.slice(resolved, source) == "after"
    end

    # sabotage: named_codepoint/1's `"gt"` clause returns ">>" instead of
    # ">" -> the two-codepoint decode no longer matches the expanded value,
    # so the reference is rejected and the walk desyncs at the "&" -> this
    # test reddens (slice returns the whole attribute value instead of
    # "score")
    test "gt, quot and apos decode like lt and amp" do
      source = ~s(<edge cond="&gt;&quot;&apos; score"/>)
      attribute = root_attribute(source)

      assert attribute.value == ">\"' score"

      # Each reference is one expanded column, so "score" is expanded
      # columns 5-9 while its raw text starts 15 columns further along.
      resolved =
        Location.resolve_span(
          attribute.value_location,
          {{1, 5}, {1, 10}},
          attribute.value,
          source
        )

      assert Location.slice(resolved, source) == "score"
    end

    # sabotage: codepoint_string/1 drops its range guard and builds
    # `<<codepoint::utf8>>` for any integer -> the surrogate crashes the
    # construction the same way it crashes Saxy -> this test reddens with an
    # ArgumentError instead of resolving "x"
    test "an out-of-range character reference degrades instead of crashing" do
      source = ~s(<edge cond="&#55296;x"/>)
      raw_value = "&#55296;x"

      # Built rather than parsed: Saxy cannot parse this document at all. It
      # constructs a character reference with `<<codepoint::utf8>>` and no
      # range check, so `&#55296;` - a surrogate, excluded from Char by XML
      # 1.0 4.1 - crashes it. That crash is what codepoint_string/1's guard
      # exists to keep out of a diagnostic path, and the only way to reach
      # the guard is a location this parser could not have handed us.
      # Column and offset coincide here because every byte before the value
      # is single-byte ASCII on line 1.
      {start_offset, _length} = :binary.match(source, raw_value)

      value_location = %Location{
        start_line: 1,
        start_column: start_offset + 1,
        start_offset: start_offset,
        end_line: 1,
        end_column: start_offset + String.length(raw_value) + 1,
        end_offset: start_offset + byte_size(raw_value)
      }

      # The decode returns nil, so the reference is never recognized and the
      # nine raw characters walk 1:1 against a value that repeats them - "x"
      # is expanded column 9.
      resolved = Location.resolve_span(value_location, {{1, 9}, {1, 10}}, raw_value, source)

      assert Location.slice(resolved, source) == "x"
    end
  end

  describe "normalize_attribute_value/3" do
    # sabotage: normalize_attribute_value/3's `:desync -> value` branch
    # replaced with `:desync -> String.upcase(value)` -> the fallback no
    # longer returns Saxy's value unchanged -> this test reddens (the
    # returned string is upcased instead of equal to the contradicting value)
    test "a value that does not describe the raw slice returns value unnormalized" do
      source = ~s(<edge cond="score"/>)
      assert {:ok, root} = Parser.parse(source)
      attribute = DOM.attribute(root, "cond")

      # "totally different" does not describe the raw slice "score" at all,
      # so the walk desyncs on the very first unit and the fallback returns
      # it verbatim - not normalized, not truncated, not raised on.
      assert Location.normalize_attribute_value(
               attribute.value_location,
               "totally different",
               source
             ) == "totally different"
    end
  end

  describe "normalize_character_data/3" do
    # Each case hand-builds a `%Location{}` spanning the whole synthetic
    # `source` string, mirroring how `Handler.add_text/2` calls this with a
    # run's whole-run span (`text_span/1`) rather than through a real parse -
    # `normalize_character_data/3` has no call site yet (Phase 1), so there is
    # no `Handler`/`Parser` path to drive it through. `value` stands in for
    # Saxy's unfolded, entity-expanded accumulation for the run.
    defp whole_span(source) do
      %Location{
        start_line: 1,
        start_column: 1,
        start_offset: 0,
        end_line: 1,
        end_column: String.length(source) + 1,
        end_offset: byte_size(source)
      }
    end

    # sabotage: fold_units/2's two-unit CRLF clause
    # (`[{:literal, "\r"}, {:literal, "\n"} | rest]`) deleted, leaving only
    # the lone-CR clause to fire on each half separately -> this test
    # reddens ("a\n\nb" instead of "a\nb")
    test "a literal CRLF folds to one \\n" do
      source = "a\r\nb"

      assert Location.normalize_character_data(whole_span(source), source, source) == "a\nb"
    end

    # sabotage: fold_units/2's lone-CR clause (`[{:literal, "\r"} | rest]`)
    # changed to pass the CR through unfolded (`[other | acc]` instead of
    # `["\n" | acc]`) -> this test reddens ("a\rb" instead of "a\nb")
    test "a literal lone CR folds to one \\n" do
      source = "a\rb"

      assert Location.normalize_character_data(whole_span(source), source, source) == "a\nb"
    end

    # sabotage: fold_units/2's reference clause changed to fold a decoded
    # "\r" the same as a literal one (`"\n"` instead of `decoded`) -> this
    # test reddens ("a\nb" instead of "a\rb") - the literal-versus-reference
    # distinction 2.11 draws, the reason a blind `String.replace/3` is wrong
    test "a \\r decoded from &#xD; is not folded" do
      raw = "a&#xD;b"
      value = "a\rb"

      assert Location.normalize_character_data(whole_span(raw), value, raw) == "a\rb"
    end

    # sabotage: next_text_unit/3's `<![CDATA[` branch passes `:text` instead
    # of `:cdata` as the mode it switches to -> the walk never actually
    # enters CDATA mode, so the section is walked as ordinary text; the "]]>"
    # closing delimiter then has no correspondent in the (unfolded) value and
    # the walk desyncs -> this test reddens (falls back to the unfolded value
    # "a\r\nb" instead of the folded "a\nb")
    test "a CR inside a CDATA section folds" do
      raw = "<![CDATA[a\r\nb]]>"
      value = "a\r\nb"

      assert Location.normalize_character_data(whole_span(raw), value, raw) == "a\nb"
    end

    # sabotage: next_text_unit/3's :cdata clause changed to delegate to
    # `next_unit/2` (via `tag_mode/2`) instead of `cdata_literal/2` -> a plain
    # `"a&amp;b"` case does NOT redden under this mutation: raw "&amp;"
    # decodes to "&", which does start the value, so it wrongly consumes five
    # raw bytes against one value byte, desyncs shortly after, and the
    # desync fallback happens to return the untouched `value` argument
    # unchanged - which for a CR-free case is indistinguishable from the
    # correct answer (a truthy-sentinel no-op the first attempt at this test
    # missed). Pairing the entity with a lone CR that must still fold makes
    # the two paths diverge: the mutant's desync fallback returns the whole
    # run *unfolded* ("&amp;\rb"), while the correct CDATA-verbatim walk
    # still applies 2.11 to the CR it never mistook for part of the entity
    # ("&amp;\nb") -> this test reddens on the mutant (asserts the folded
    # form, gets the unfolded one)
    test "&amp; inside a CDATA section survives intact, not decoded" do
      raw = "<![CDATA[&amp;\rb]]>"
      value = "&amp;\rb"

      assert Location.normalize_character_data(whole_span(raw), value, raw) == "&amp;\nb"
    end

    # sabotage: walk_units/5's :skip clause pushes `units` unchanged instead
    # of `[:boundary | units]` -> the raw-only comment no longer breaks
    # adjacency between the CR before it and the LF after it, so fold_units/2
    # mispairs them as one CRLF -> this test reddens ("i\nj" instead of
    # "i\n\nj") - the case ADR-0045's investigation used to show a
    # value-only fold is wrong: the raw text is not merely a disambiguator,
    # it is the only place the fold's followed-by rule can be read off
    test "a comment straddling a CR and its LF folds each alone" do
      raw = "i\r<!--c-->\nj"
      value = "i\r\nj"

      assert Location.normalize_character_data(whole_span(raw), value, raw) == "i\n\nj"
    end

    # sabotage: walk_units/5's :skip clause pushes `units` unchanged instead
    # of `[:boundary | units]` -> same defect as the comment-straddle test
    # above, exercised through the PI branch instead -> this test reddens
    # ("i\nj" instead of "i\n\nj")
    test "a PI straddling a CR and its LF folds each alone" do
      raw = "i\r<?pi?>\nj"
      value = "i\r\nj"

      assert Location.normalize_character_data(whole_span(raw), value, raw) == "i\n\nj"
    end

    # sabotage: fold_units/2's plain-literal clause narrowed with a guard
    # that maps "\t" to " " (3.3.3's attribute mapping, wrongly applied to
    # character data) -> this test reddens ("a b" instead of "a\tb") - 3.3.3
    # is attribute-specific and never touches character data (ADR-0045
    # item 1, the contrast with normalize_attribute_value/3)
    test "a TAB is preserved, unlike in attribute normalization" do
      source = "a\tb"

      assert Location.normalize_character_data(whole_span(source), source, source) == "a\tb"
    end

    # sabotage: normalize_character_data/3's `:desync -> value` branch
    # changed to `:desync -> String.upcase(value)` -> this test reddens (the
    # returned string is upcased instead of equal to the contradicting value)
    test "a value that does not describe the raw slice returns value unfolded" do
      raw = "abc"
      value = "totally different"

      assert Location.normalize_character_data(whole_span(raw), value, raw) ==
               "totally different"
    end
  end
end
