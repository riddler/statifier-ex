defmodule Statifier.Parser.MarkupTest do
  use ExUnit.Case, async: true

  alias Statifier.Parser.Location
  alias Statifier.Parser.Markup

  describe "scan/1 - elements" do
    # sabotage: walk/3 prepends a self-closing tag's records unreversed
    # (`records ++ acc` instead of `Enum.reverse(records) ++ acc`) -> the
    # self-closed transition's end record surfaces before its start record,
    # reddening the name/kind ordering assertion
    test "scans nested elements, including a self-closing child, in document order" do
      xml = """
      <scxml>
          <state id="s1">
              <transition target="s2"/>
          </state>
      </scxml>
      """

      records = Markup.scan(xml)

      assert Enum.map(records, & &1.kind) ==
               [:start, :start, :start, :end, :end, :end]

      assert Enum.map(records, & &1.name) ==
               ["scxml", "state", "transition", "transition", "state", "scxml"]

      [scxml_start, state_start, transition_start, transition_end, state_end, scxml_end] =
        records

      assert Location.slice(scxml_start.location, xml) == "<scxml>"
      assert Location.slice(state_start.location, xml) == ~s(<state id="s1">)
      assert Location.slice(transition_start.location, xml) == ~s(<transition target="s2"/>)
      assert Location.slice(transition_end.location, xml) == ~s(<transition target="s2"/>)
      assert transition_start.location == transition_end.location
      assert Location.slice(state_end.location, xml) == "</state>"
      assert Location.slice(scxml_end.location, xml) == "</scxml>"
    end

    # sabotage: scan_start_tag/2's self-closing branch is replaced with the
    # non-self-closing branch unconditionally (`{[start_record], rest,
    # tag_end}` always) -> only one record comes back, reddening the
    # two-record assertion below
    test "a self-closing tag emits a start and an end record with identical spans" do
      xml = "<b/>"

      assert [
               %Markup{kind: :start, name: "b", location: start_location},
               %Markup{kind: :end, name: "b", location: end_location}
             ] = Markup.scan(xml)

      assert start_location == end_location
      assert Location.slice(start_location, xml) == "<b/>"
    end
  end

  describe "scan/1 - attributes" do
    # sabotage: parse_quoted_value/5's guard narrows to `quote in [?"]`
    # (double quotes only) -> the single-quoted attribute is dropped,
    # reddening the two-attribute match below
    test "reads single- and double-quoted attribute values" do
      xml = ~s(<a x='1' y="2"/>)

      [start, _end] = Markup.scan(xml)

      assert [
               %{name: "x", location: x_location, value_location: x_value_location},
               %{name: "y", location: y_location, value_location: y_value_location}
             ] = start.attributes

      assert Location.slice(x_location, xml) == "x='1'"
      assert Location.slice(x_value_location, xml) == "1"
      assert Location.slice(y_location, xml) == ~s(y="2")
      assert Location.slice(y_value_location, xml) == "2"
    end

    # sabotage: scan_quoted_value/3 gains a clause that also stops at a bare
    # `>` (`literal?(bin, ">") -> {pos, pos, bin}`) -> the value is cut short
    # at the `>` inside it, reddening the slice assertion
    test "a `>` inside an attribute value does not end the tag" do
      xml = ~s(<a x="1 > 2"/>)

      [start, _end] = Markup.scan(xml)

      assert [%{name: "x", value_location: value_location}] = start.attributes
      assert Location.slice(value_location, xml) == "1 > 2"
      assert Location.slice(start.location, xml) == ~s(<a x="1 > 2"/>)
    end

    # sabotage: advance/2's "\n" clause drops the line increment / column
    # reset (`{offset + 1, line, column + 1}`) -> the attribute on line 3
    # reports the wrong start_line, reddening this assertion
    test "attributes spread across multiple lines" do
      xml = """
      <state
          id="s1"
          initial="s2">
      </state>
      """

      [start, end_record] = Markup.scan(xml)

      assert [
               %{name: "id", value_location: id_value_location},
               %{name: "initial", value_location: initial_value_location}
             ] = start.attributes

      assert Location.slice(id_value_location, xml) == "s1"
      assert Location.slice(initial_value_location, xml) == "s2"
      assert initial_value_location.start_line == 3

      assert Location.slice(start.location, xml) ==
               ~s(<state\n    id="s1"\n    initial="s2">)

      assert Location.slice(end_record.location, xml) == "</state>"
    end
  end

  describe "scan/1 - comments" do
    # sabotage: classify_markup/2's `literal?(bin, "<!--") -> skip(...)`
    # clause is removed, so a comment falls through to scan_start_tag/2 and
    # is read as an element -> spurious records appear before scxml,
    # reddening the two-record match below
    test "skips a multi-line XML comment" do
      xml = """
      <!-- This is
      a multi-line
      comment -->
      <scxml/>
      """

      assert [
               %Markup{kind: :start, name: "scxml", location: start_location},
               %Markup{kind: :end, name: "scxml"}
             ] = Markup.scan(xml)

      assert start_location.start_line == 4
      assert Location.slice(start_location, xml) == "<scxml/>"
    end

    # sabotage: skip/4's comment call passes delimiter `">"` instead of
    # `"-->"` -> the skip stops at the first bare `>` inside the comment's
    # own markup-shaped text, leaking the rest as a real element and
    # reddening the two-record match below
    test "a comment containing markup text does not desync the scan" do
      xml = """
      <!-- <state id="ignored"><state id="also-ignored"/></state> -->
      <scxml/>
      """

      assert [
               %Markup{kind: :start, name: "scxml"},
               %Markup{kind: :end, name: "scxml"}
             ] = Markup.scan(xml)
    end
  end

  describe "scan/1 - processing instructions and the XML declaration" do
    # sabotage: classify_markup/2's `literal?(bin, "<?") -> skip(...)`
    # clause is removed, so the declaration and the PI are each read as
    # elements named "?xml" / "?some-pi" -> spurious records appear,
    # reddening the two-record match below
    test "skips the XML declaration and a processing instruction" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <?some-pi data?>
      <scxml/>
      """

      assert [
               %Markup{kind: :start, name: "scxml", location: start_location},
               %Markup{kind: :end, name: "scxml"}
             ] = Markup.scan(xml)

      assert start_location.start_line == 3
      assert Location.slice(start_location, xml) == "<scxml/>"
    end
  end

  describe "scan/1 - DOCTYPE" do
    # sabotage: `advance_ascii(pos, 9)` after the "<!DOCTYPE" literal is
    # changed to `advance_ascii(pos, 0)` -> the returned cursor undercounts
    # by 9 bytes, so the following element's location is 9 bytes early and
    # slices the wrong text, reddening the slice assertion
    test "skips a DOCTYPE with no internal subset" do
      xml = """
      <!DOCTYPE scxml PUBLIC "-//W3C//DTD SCXML 1.0//EN" "scxml.dtd">
      <scxml/>
      """

      assert [
               %Markup{kind: :start, name: "scxml", location: start_location},
               %Markup{kind: :end, name: "scxml"}
             ] = Markup.scan(xml)

      assert start_location.start_line == 2
      assert Location.slice(start_location, xml) == "<scxml/>"
    end

    # sabotage: skip_doctype/3's `{">", rest} when depth == 0` clause drops
    # the `when depth == 0` guard, so it stops at the internal subset's own
    # `>` instead of the DOCTYPE's closing one -> the leftover `<bogus/>`
    # is scanned as a real element, reddening the two-record match below
    test "skips a DOCTYPE with an internal subset, including its own `>` characters" do
      xml = """
      <!DOCTYPE scxml [
      <!ENTITY x "y"><bogus/>
      ]>
      <scxml/>
      """

      assert [
               %Markup{kind: :start, name: "scxml", location: start_location},
               %Markup{kind: :end, name: "scxml"}
             ] = Markup.scan(xml)

      assert Location.slice(start_location, xml) == "<scxml/>"
    end
  end

  describe "scan/1 - CDATA" do
    # sabotage: skip/4's CDATA call passes delimiter `">"` instead of
    # `"]]>"` -> the skip stops at the first bare `>` inside the CDATA
    # text, leaking the rest as a real element and reddening the two-record
    # match below
    test "CDATA containing `<` and `>` does not desync the scan" do
      xml = """
      <data><![CDATA[a > b <ignored/> c]]></data>
      """

      assert [
               %Markup{kind: :start, name: "data", location: start_location},
               %Markup{kind: :end, name: "data", location: end_location}
             ] = Markup.scan(xml)

      assert Location.slice(start_location, xml) == "<data>"
      assert Location.slice(end_location, xml) == "</data>"
    end
  end

  describe "scan/1 - positions" do
    # sabotage: advance/2's non-newline clause counts bytes instead of
    # codepoints (`column + byte_size(codepoint)`) -> the two-byte "é"
    # advances the column by 2, reddening the column assertion
    test "counts columns in codepoints, not bytes, ahead of a tag" do
      xml = "café <scxml/>"

      [start, _end] = Markup.scan(xml)

      assert start.location.start_line == 1
      assert start.location.start_column == 6
      assert Location.slice(start.location, xml) == "<scxml/>"
    end

    # sabotage: advance/2's newline trigger is changed from `"\n"` to
    # `"\r"` -> the "\n" of a CRLF pair is then treated as an ordinary
    # character, shifting the following line's column right by one and
    # reddening the column assertion
    test "CRLF line endings advance the line counter" do
      xml = "<scxml>\r\n  <state id=\"s1\"/>\r\n</scxml>"

      [_scxml_start, state_start, _state_end, scxml_end] = Markup.scan(xml)

      assert state_start.location.start_line == 2
      assert state_start.location.start_column == 3
      assert Location.slice(state_start.location, xml) == ~s(<state id="s1"/>)

      assert scxml_end.location.start_line == 3
    end
  end

  describe "scan/1 - totality" do
    # sabotage: consume_until/3's `consume_until(<<>>, pos, _delim), do:
    # {<<>>, pos}` base clause is deleted -> an unterminated comment/CDATA
    # runs `String.next_codepoint(<<>>)` -> `nil`, and the subsequent
    # `{codepoint, rest} = nil` match raises, reddening this test
    test "never raises, for a set of malformed or truncated binaries" do
      hostile_inputs = [
        "",
        "   ",
        "<",
        ~s(<a x="unterminated),
        "]]>",
        "<!-- unterminated comment",
        "<![CDATA[unterminated",
        "<!DOCTYPE unterminated",
        "<a><b></c>"
      ]

      for input <- hostile_inputs do
        assert is_list(Markup.scan(input))
      end
    end
  end
end
