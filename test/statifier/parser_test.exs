defmodule Statifier.ParserTest do
  use ExUnit.Case, async: true

  alias Statifier.Parser
  alias Statifier.Parser.DOM
  alias Statifier.Parser.Location
  alias Statifier.Parser.ParseError

  defp parse!(xml) do
    {:ok, root} = Parser.parse(xml)
    root
  end

  # The element skeleton of a tree: attribute counts and nesting, with every
  # name erased. Two documents with the same skeleton parsed into the same
  # shape regardless of what their elements were called.
  defp skeleton(%DOM.Element{} = element) do
    {length(element.attributes), Enum.map(DOM.elements(element), &skeleton/1)}
  end

  describe "parse/1 - structure" do
    # sabotage: the :end_element clause skips `Enum.reverse(frame.children)`
    # -> the children come back in reverse document order, reddening the
    # ordered name assertion
    test "nested and sibling elements keep document order" do
      xml = """
      <root>
          <alpha>
              <gamma/>
          </alpha>
          <beta/>
      </root>
      """

      root = parse!(xml)

      assert [%DOM.Element{name: "alpha"} = alpha, %DOM.Element{name: "beta"}] =
               DOM.elements(root)

      assert [%DOM.Element{name: "gamma"}] = DOM.elements(alpha)
    end

    # sabotage: build_attributes/2 destructures the event's attribute tuple
    # backwards (`{{value, name}, index}`) -> the unknown vocabulary's
    # attribute reports its value as its name, reddening the "baz" match
    # below
    test "an unknown vocabulary parses into the same shape as a statechart document" do
      unknown = """
      <foo qux="1.0">
          <bar baz="1"/>
      </foo>
      """

      statechart = """
      <scxml version="1.0">
          <state id="s1"/>
      </scxml>
      """

      unknown_root = parse!(unknown)

      assert skeleton(unknown_root) == skeleton(parse!(statechart))
      assert %DOM.Element{name: "foo"} = unknown_root

      assert [%DOM.Element{name: "bar", attributes: [%DOM.Attribute{name: "baz"}]}] =
               DOM.elements(unknown_root)
    end
  end

  describe "parse/1 - locations" do
    setup do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!-- opening
           comment -->
      <root xmlns="urn:example"
            label="a value
      that wraps a line">
          <alpha id="a1"/>
          <!-- an inner comment: 1 > 2,
               and <gamma id="ignored"/> -->
          <beta/>
      </root>
      """

      %{xml: xml, root: parse!(xml)}
    end

    # sabotage: Markup.scan/1's classify_markup/2 drops its `<?` clause, so
    # the XML declaration is scanned as an element -> the root pops that
    # record instead of its own and desyncs, reddening the literal
    # line/column assertion
    test "the root after an XML declaration and a multi-line comment", %{xml: xml, root: root} do
      assert %Location{start_line: 4, start_column: 1} = root.location
      assert Location.slice(root.location, xml) =~ ~r/\A<root /
    end

    # sabotage: Markup.scan/1's scan_quoted_value/3 advances with
    # `advance_ascii/2` instead of `advance/2`, so a newline inside an
    # attribute value stops counting as one -> every element after the
    # wrapped value reports a line too low, reddening the literal
    # line/column assertion
    test "an element following a multi-line attribute value", %{xml: xml, root: root} do
      assert [%DOM.Element{name: "alpha"} = alpha, _beta] = DOM.elements(root)

      assert %Location{start_line: 7, start_column: 5} = alpha.location
      assert Location.slice(alpha.location, xml) == ~s(<alpha id="a1"/>)
    end

    # sabotage: Markup.scan/1's comment skip uses the delimiter `">"` rather
    # than `"-->"`, so the inner comment leaks records into the queue -> the
    # element after it desyncs, reddening the literal line/column assertion
    test "an element following a multi-line comment", %{xml: xml, root: root} do
      assert [_alpha, %DOM.Element{name: "beta"} = beta] = DOM.elements(root)

      assert %Location{start_line: 10, start_column: 5} = beta.location
      assert Location.slice(beta.location, xml) == "<beta/>"
    end

    # sabotage: the handler's span/2 takes `end_location.start_offset` for
    # the element's end -> the root's span stops at the `<` of its end tag,
    # reddening the slice assertion
    test "an element's span runs from its start tag to past its end tag", %{xml: xml, root: root} do
      assert %Location{end_line: 11, end_column: 8} = root.location

      slice = Location.slice(root.location, xml)

      assert String.starts_with?(slice, "<root ")
      assert String.ends_with?(slice, "</root>")
    end
  end

  describe "parse/1 - attributes" do
    # sabotage: build_attributes/2 drops the `Enum.with_index()` step and
    # pairs every attribute with `Enum.at(scanned, 0)` -> the second and
    # third attributes get the first one's span, reddening the slice
    # assertions
    test "attribute order and duplicates are preserved with their own spans" do
      xml = ~s(<root b="2" a="1" b="3"/>)

      root = parse!(xml)

      assert [
               %DOM.Attribute{name: "b", value: "2"} = first,
               %DOM.Attribute{name: "a", value: "1"} = second,
               %DOM.Attribute{name: "b", value: "3"} = third
             ] = root.attributes

      assert Location.slice(first.location, xml) == ~s(b="2")
      assert Location.slice(second.location, xml) == ~s(a="1")
      assert Location.slice(third.location, xml) == ~s(b="3")
    end

    # sabotage: build_attributes/2 sets `value_location: scanned.location`
    # -> the value span covers the whole `name="value"` text including the
    # quotes, reddening the raw-text assertion
    test "the value is entity-expanded while its span covers the raw quoted text" do
      xml = ~s(<root guard="x &lt; 1"/>)

      assert %DOM.Attribute{value: "x < 1", value_location: value_location} =
               DOM.attribute(parse!(xml), "guard")

      assert Location.slice(value_location, xml) == "x &lt; 1"
    end

    # sabotage: Markup.scan/1's parse_quoted_value/5 guard narrows to
    # `quote in [?"]` -> the single-quoted attribute is never located, so
    # its spans arrive nil and the slice call raises, reddening this test
    test "single-quoted values are located like double-quoted ones" do
      xml = ~s(<root id='r1'/>)

      assert %DOM.Attribute{value: "r1"} = attribute = DOM.attribute(parse!(xml), "id")

      assert Location.slice(attribute.location, xml) == "id='r1'"
      assert Location.slice(attribute.value_location, xml) == "r1"
    end
  end

  describe "parse/1 - text" do
    # sabotage: the :characters clause of handle_event/3 returns
    # `{:ok, state}` without calling add_text/2 -> the text runs vanish and
    # only the element child remains, reddening the interleaved match below
    test "mixed content interleaves text and elements in document order" do
      xml = "<root>before<alpha/>after</root>"

      assert %DOM.Element{
               children: [
                 %DOM.Text{value: "before"},
                 %DOM.Element{name: "alpha"},
                 %DOM.Text{value: "after"}
               ]
             } = parse!(xml)
    end

    # A text run that follows a *closing* tag is the only thing that pins the
    # cursor advance in the :end_element clause. The interleaving test above
    # cannot: its sibling is self-closing, so the start and end records share
    # a span and skipping the advance is a no-op.
    #
    # sabotage: the :end_element clause of handle_event/3 keeps the old cursor
    # (`cursor: state.cursor`) instead of advancing past the end tag -> the
    # trailing run's span starts back inside the sibling and slices to
    # "x</alpha>after", reddening the slice assertion below
    test "a text run after a closing tag starts past it, not inside the sibling" do
      xml = "<root>before<alpha>x</alpha>after</root>"

      assert %DOM.Element{
               children: [
                 %DOM.Text{value: "before", location: before_loc},
                 %DOM.Element{name: "alpha"},
                 %DOM.Text{value: "after", location: after_loc}
               ]
             } = parse!(xml)

      assert Location.slice(before_loc, xml) == "before"
      assert Location.slice(after_loc, xml) == "after"
    end

    # sabotage: add_text/2 replaces the open text node's value with the new
    # characters instead of appending (`value: characters`) -> only the last
    # of the three events survives, reddening the coalesced value assertion
    test "an entity reference and a CDATA section in one run coalesce into one node" do
      xml = "<root>t1 &amp; t2<![CDATA[cd]]>t3</root>"

      assert %DOM.Element{children: [%DOM.Text{value: value, location: location}]} = parse!(xml)

      assert value == "t1 & t2cdt3"
      assert Location.slice(location, xml) == "t1 &amp; t2<![CDATA[cd]]>t3"
    end

    # sabotage: add_text/2 skips runs that are entirely whitespace
    # (`if String.trim(characters) == ""`, returning state unchanged) -> the
    # whitespace-only child disappears, reddening the three-child match
    test "whitespace-only text is a node, and DOM.elements/1 is what drops it" do
      xml = """
      <root>
          <alpha/>
      </root>
      """

      root = parse!(xml)

      assert [%DOM.Text{value: "\n    "}, %DOM.Element{name: "alpha"}, %DOM.Text{value: "\n"}] =
               root.children

      assert [%DOM.Element{name: "alpha"}] = DOM.elements(root)
    end
  end

  describe "parse/1 - namespaces" do
    # sabotage: the :end_element clause builds the element from the name
    # with any `prefix:` stripped off -> the qualified name is lost,
    # reddening the literal name assertion
    test "a prefixed name is kept verbatim and its declaration is an ordinary attribute" do
      xml = ~s(<pre:root xmlns:pre="urn:example"/>)

      root = parse!(xml)

      assert %DOM.Element{name: "pre:root"} = root
      assert %DOM.Attribute{value: "urn:example"} = DOM.attribute(root, "xmlns:pre")
    end
  end

  describe "parse/1 - errors" do
    # sabotage: parse/1's `{:error, %Saxy.ParseError{}}` branch returns the
    # Saxy struct unconverted -> the %ParseError{} match reddens
    test "malformed XML returns a converted error with a location, and never raises" do
      xml = "<a><b></c></a>"

      assert {:error, %ParseError{reason: {:wrong_closing_tag, "b", "c"}} = error} =
               Parser.parse(xml)

      assert %Location{start_line: 1} = error.location
      assert error.byte_offset > 0
    end
  end
end
