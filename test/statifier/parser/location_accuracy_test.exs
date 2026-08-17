defmodule Statifier.Parser.LocationAccuracyTest do
  use ExUnit.Case, async: true

  alias Statifier.Parser
  alias Statifier.Parser.DOM
  alias Statifier.Parser.Location

  # The property, applied to every element and every attribute of a parsed
  # document rather than to hand-picked nodes: slice each span back out of
  # the source and check it against what the node says it is. No line number
  # is written down anywhere, so this catches an off-by-one introduced
  # anywhere in the scanner, on any fixture, without being rewritten.
  defp assert_locations_accurate(source) do
    assert {:ok, root} = Parser.parse(source)

    elements = descendants(root)

    for element <- elements do
      slice = Location.slice(element.location, source)

      assert slice =~ ~r/\A<#{Regex.escape(element.name)}[\s\/>]/,
             "#{element.name}'s span does not start at its start tag: #{inspect(slice)}"

      assert String.ends_with?(slice, "</#{element.name}>") or String.ends_with?(slice, "/>"),
             "#{element.name}'s span does not end at its end tag: #{inspect(slice)}"

      assert_line_column_agrees_with_offset(element.location, source)

      for attribute <- element.attributes do
        assert_attribute_accurate(attribute, source)
        assert_line_column_agrees_with_offset(attribute.location, source)
        assert_line_column_agrees_with_offset(attribute.value_location, source)
      end
    end

    for text <- text_nodes(elements) do
      assert_text_accurate(text, source)
      assert_line_column_agrees_with_offset(text.location, source)
    end

    elements
  end

  # Every `DOM.Text{}` child of every element in the tree, in the order the
  # elements themselves were visited. `location` is the raw span (entities
  # unexpanded, CDATA delimiters intact); `value` is what Saxy decoded, so
  # the two only need to agree byte-for-byte when the run contains neither -
  # `assert_text_accurate/2` is where that split is handled.
  defp text_nodes(elements) do
    Enum.flat_map(elements, fn element ->
      Enum.filter(element.children, &match?(%DOM.Text{}, &1))
    end)
  end

  # A literal "&" cannot occur in well-formed XML character data outside an
  # entity reference, so its presence in the raw slice is exactly the signal
  # that `value` decoded something the slice did not spell out the same way.
  # Likewise a raw "<![CDATA[" only ever opens a CDATA section, which `value`
  # reports unwrapped. Runs with neither decode to themselves.
  defp assert_text_accurate(%DOM.Text{} = text, source) do
    slice = Location.slice(text.location, source)

    if entity_or_cdata_free?(slice) do
      assert slice == text.value,
             "text run's span does not match its value: #{inspect(slice)} / #{inspect(text.value)}"
    else
      # Decoding only ever shortens or holds steady (an entity reference
      # collapses to one character, CDATA delimiters disappear), so the raw
      # slice can never be shorter than the value it decoded to, and a
      # non-empty value cannot come from an empty raw span.
      assert byte_size(slice) >= byte_size(text.value),
             "text run's raw span is shorter than its decoded value: " <>
               "#{inspect(slice)} / #{inspect(text.value)}"

      refute slice == "",
             "text run has an empty raw span despite a decoded value #{inspect(text.value)}"
    end
  end

  defp entity_or_cdata_free?(slice) do
    not (String.contains?(slice, "&") or String.contains?(slice, "<![CDATA["))
  end

  # `location` covers `name="value"` and `value_location` covers the text
  # between the quotes, so reconstructing the first from the second is a
  # single assertion that pins both spans against each other and against the
  # source. The raw value text appears on both sides, so it holds whether or
  # not entity expansion changed `value`.
  defp assert_attribute_accurate(attribute, source) do
    whole = Location.slice(attribute.location, source)
    raw_value = Location.slice(attribute.value_location, source)

    pattern =
      ~r/\A#{Regex.escape(attribute.name)}\s*=\s*(['"])#{Regex.escape(raw_value)}\1\z/

    assert whole =~ pattern,
           "#{attribute.name}'s spans do not reconstruct: #{inspect(whole)} / #{inspect(raw_value)}"

    assert_whole_value_span_is_identity(attribute, source)
  end

  # The strongest single statement of `resolve_span/4`'s contract: resolving
  # the span that covers `value` in its own entirety - `{1, 1}` through one
  # past its last codepoint - must return `value_location` exactly. Applied
  # to every attribute of every fixture this file already parses, with no
  # line number written down anywhere.
  #
  # sabotage: `maybe_capture/5`'s `expanded_pos >= target` comparison
  # narrowed to `expanded_pos > target` -> the start target `{1, 1}` is never
  # captured at the walk's initial position, so the resolved span's start
  # drifts one unit late -> this test reddens (the resolved location no
  # longer equals `attribute.value_location` exactly)
  defp assert_whole_value_span_is_identity(attribute, source) do
    {end_line, end_column} = whole_value_end(attribute.value)

    resolved =
      Location.resolve_span(
        attribute.value_location,
        {{1, 1}, {end_line, end_column}},
        attribute.value,
        source
      )

    assert resolved == attribute.value_location,
           "#{attribute.name}'s whole-value span is not the identity: " <>
             "#{inspect(resolved)} / #{inspect(attribute.value_location)}"
  end

  # One past the last codepoint of `value`, in predicator's coordinate
  # system: 1-based line/column, a line break resetting the column to 1 -
  # the same rule `expanded_advance/2` applies while walking, computed here
  # independently rather than reusing that private function.
  defp whole_value_end(value) do
    Enum.reduce(String.codepoints(value), {1, 1}, fn
      "\n", {line, _column} -> {line + 1, 1}
      _codepoint, {line, column} -> {line, column + 1}
    end)
  end

  # The scanner carries offset, line, and column in one cursor and advances
  # all three together, so the two halves can drift apart without either one
  # looking wrong on its own. `Location.at_offset/2` recomputes line and
  # column from the offset by a different route, which makes that drift an
  # assertion instead of a hope - and it needs no line number written down.
  defp assert_line_column_agrees_with_offset(%Location{} = location, source) do
    recomputed_start = Location.at_offset(source, location.start_offset)
    recomputed_end = Location.at_offset(source, location.end_offset)

    assert {location.start_line, location.start_column} ==
             {recomputed_start.start_line, recomputed_start.start_column}

    assert {location.end_line, location.end_column} ==
             {recomputed_end.start_line, recomputed_end.start_column}
  end

  defp descendants(%DOM.Element{} = element) do
    [element | element |> DOM.elements() |> Enum.flat_map(&descendants/1)]
  end

  describe "every span slices back out of the source" do
    # sabotage: Markup.scan/1's consume_until/3 advances with advance_ascii/2
    # instead of advance/2, so newlines inside a skipped comment stop
    # counting as newlines -> every line after the license comment is
    # reported five too low, reddening the line/column-versus-offset check
    test "a declaration, a license comment, a default xmlns, and multi-line start tags" do
      source = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!--
          Licensed to the Apache Software Foundation (ASF) under one or more
          contributor license agreements.  See the NOTICE file distributed
          with this work for additional information regarding copyright
          ownership.
      -->
      <chart xmlns="http://www.w3.org/2005/07/scxml"
             version="1.0"
             initial="alpha" >
          <node id="alpha" >
              <edge event="go"
                    target="beta"/>
          </node>
          <node id="beta"/>
      </chart>
      """

      assert [chart | _rest] = assert_locations_accurate(source)
      assert %Location{start_line: 8, start_column: 1} = chart.location
    end

    # sabotage: Markup.scan/1's advance/2 fallback adds 1 to the offset
    # instead of byte_size(codepoint) -> every span after the first non-ASCII
    # character slides left, reddening the sweep
    test "prefixed names, single quotes, entity references, CDATA, and non-ASCII text" do
      source = """
      <pre:root xmlns:pre="urn:example" note='café &amp; crème'>
          <pre:child>naïve text &lt; 1</pre:child>
          <pre:data><![CDATA[ if (x < 1) { } ]]></pre:data>
          <pre:leaf/>
      </pre:root>
      """

      assert [root | _rest] = assert_locations_accurate(source)
      assert %DOM.Element{name: "pre:root"} = root
    end

    # sabotage: Markup.scan/1's skip_doctype/3 ignores its bracket depth and
    # ends at the first ">" -> the internal subset's second declaration is
    # scanned as a start tag named "!ELEMENT", desyncing the zip and
    # reddening the sweep's parse
    test "a DOCTYPE with an internal subset, a processing instruction, and mixed content" do
      source = """
      <!DOCTYPE doc [
          <!ENTITY who "world">
          <!ELEMENT doc (#PCDATA)>
      ]>
      <?target an instruction?>
      <doc kind="mixed">before<em level="1"/>after</doc>
      """

      assert [doc, em] = assert_locations_accurate(source)
      assert %Location{start_line: 6, start_column: 1} = doc.location
      assert Location.slice(em.location, source) == ~s(<em level="1"/>)
    end

    # sabotage: Markup.scan/1's scan_start_tag/2 spans the start record from
    # `name_start` rather than `pos` -> every element slice loses its "<",
    # reddening the start-tag assertion
    test "a tag whose attribute value contains a > and a run of trailing whitespace" do
      source = """
      <chart>
          <edge cond="a > b &amp;&amp; c &lt; d"
                target="x"
                	>
              <node/>
          </edge>
      </chart>
      """

      assert [_chart, edge | _rest] = assert_locations_accurate(source)
      assert %DOM.Attribute{value: "a > b && c < d"} = DOM.attribute(edge, "cond")
    end

    # A self-closing sibling shares one span between its start and end
    # records, so the cursor Handler.add_text/2 reads from is already
    # correct even without advancing it - see the "mixed content" fixture
    # above, whose "after" run follows the self-closing <em/>. Only a
    # sibling with a real end tag, like <edge>...</edge> here, moves the
    # cursor past content the stale-cursor bug would otherwise re-swallow
    # into the following text run.
    #
    # sabotage: Handler.handle_event/3's :end_element clause sets
    # `cursor: state.cursor` instead of `cursor: cursor_after(record)` ->
    # the cursor never advances past a real end tag, so the "after" run's
    # span grows backward to swallow "before</edge>" instead of starting
    # after "</edge>", reddening the text sweep
    test "a text run following an element with a real end tag" do
      source = """
      <chart>
          <node id="alpha"><edge event="go">before</edge>after</node>
      </chart>
      """

      assert_locations_accurate(source)
    end
  end
end
