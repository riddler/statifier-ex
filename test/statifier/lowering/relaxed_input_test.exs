defmodule Statifier.Lowering.RelaxedInputTest do
  use ExUnit.Case, async: true

  alias Statifier.{Document, Lowering, Parser}
  alias Statifier.Document.{State, Transition}
  alias Statifier.Parser.{DOM, Location}

  defp parse!(xml) do
    {:ok, root} = Parser.parse(xml)
    root
  end

  defp lower!(xml) do
    {:ok, document} = xml |> parse!() |> Lowering.lower(xml)
    document
  end

  # sabotage: `Namespace.scxml_vocabulary?/1` is narrowed from
  # `uri in [nil, @scxml_namespace]` to `uri == @scxml_namespace`, rejecting
  # the unprefixed-and-undeclared root -> `boilerplate_free` fails to lower
  # with `{:foreign_element, "scxml", nil}` instead of matching
  # `full_boilerplate`'s stripped tree
  test "a boilerplate-free fragment lowers to the same tree as its fully-declared twin" do
    boilerplate_free = """
    <scxml initial="a">
      <state id="a">
        <transition event="go" target="b"/>
      </state>
      <state id="b"/>
    </scxml>
    """

    full_boilerplate = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
        <transition event="go" target="b"/>
      </state>
      <state id="b"/>
    </scxml>
    """

    assert strip(lower!(boilerplate_free)) == strip(lower!(full_boilerplate))
  end

  # sabotage: `Parser.parse/1` scans `"<?xml version=\"1.0\"?>\n" <> source`
  # while still building the DOM against the caller's original `source` (v1's
  # rewrite-then-parse, reintroduced) -> the scanner's markup records are
  # offset by the length of the inserted declaration, so every slice below
  # returns the wrong bytes and the start-tag/end-tag assertions redden
  test "every span from a boilerplate-free parse slices out of the ORIGINAL binary" do
    source = """
    <scxml initial="a">
      <state id="a">
        <transition event="go" target="b" cond="x &gt; 1"/>
      </state>
      <state id="b"/>
    </scxml>
    """

    assert {:ok, root} = Parser.parse(source)

    for element <- descendants(root) do
      slice = Location.slice(element.location, source)

      assert slice =~ ~r/\A<#{Regex.escape(element.name)}[\s\/>]/,
             "#{element.name}'s span does not start at its start tag: #{inspect(slice)}"

      assert String.ends_with?(slice, "</#{element.name}>") or String.ends_with?(slice, "/>"),
             "#{element.name}'s span does not end at its end tag: #{inspect(slice)}"

      for attribute <- element.attributes do
        whole = Location.slice(attribute.location, source)
        raw_value = Location.slice(attribute.value_location, source)

        pattern =
          ~r/\A#{Regex.escape(attribute.name)}\s*=\s*(['"])#{Regex.escape(raw_value)}\1\z/

        assert whole =~ pattern,
               "#{attribute.name}'s spans do not reconstruct: #{inspect(whole)} / #{inspect(raw_value)}"
      end
    end
  end

  # sabotage: `Parser.parse/1` prepends
  # `"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" <> source` before scanning
  # (v1's `:xml_declaration` option, reintroduced) -> the inserted line shifts
  # every reported line number down by one, and this test reddens expecting
  # `start_line: 3` but observing `4`
  test "line and column numbers are the caller's own, with no declaration line shift" do
    source = """
    <scxml initial="a">
      <state id="a">
        <state id="A"/>
      </state>
    </scxml>
    """

    assert {:ok, root} = Parser.parse(source)

    [state_a] =
      root
      |> DOM.elements()
      |> Enum.flat_map(&DOM.elements/1)

    assert %DOM.Element{name: "state", location: %Location{start_line: 3, start_column: 5}} =
             state_a
  end

  # sabotage: `Attributes.put_location/4` stores `attribute.location` (the
  # whole `name="value"` span) instead of `attribute.value_location` ->
  # slicing `attribute_locations[:cond]` returns `cond="x &gt; 1"` instead of
  # the bare expression, and this test reddens on the raw-value assertion
  test "a cond span from a boilerplate-free parse still lands on the expression" do
    source = """
    <scxml initial="a">
      <state id="a">
        <transition event="go" target="b" cond="x &gt; 1"/>
      </state>
      <state id="b"/>
    </scxml>
    """

    %Document{states: [%State{transitions: [%Transition{} = transition]} | _rest]} =
      lower!(source)

    cond_location = transition.attribute_locations[:cond]

    assert Location.slice(cond_location, source) == "x &gt; 1"
  end

  # sabotage: `Attributes.put_location/4`'s `nil` clause (attribute not
  # written) is changed to `Map.put(locations, key, nil)` instead of
  # returning `locations` unchanged -> `attribute_locations` gains `:xmlns`
  # and `:version` keys with `nil` values, and this test reddens on the
  # `has_key?` refutations
  test "absent boilerplate is observable, with a place to report from" do
    source = """
    <scxml initial="a">
      <state id="a"/>
    </scxml>
    """

    document = lower!(source)

    assert %Document{xmlns: nil, version: nil} = document
    refute Map.has_key?(document.attribute_locations, :xmlns)
    refute Map.has_key?(document.attribute_locations, :version)

    assert Location.slice(document.location, source) =~ ~r/\A<scxml[\s>]/
  end

  # sabotage: `build_scxml/2` drops the `Attributes.put_location(:xmlns,
  # element, "xmlns")` call from its `attribute_locations` pipeline -> the
  # `xmlns` value still lowers (unaffected) but its `attribute_locations`
  # entry disappears, and this test reddens on the `has_key?(:xmlns)`
  # assertion
  test "written boilerplate is still captured, with an accurate span" do
    source = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a"/>
    </scxml>
    """

    document = lower!(source)

    assert %Document{
             xmlns: "http://www.w3.org/2005/07/scxml",
             version: "1.0"
           } = document

    assert Map.has_key?(document.attribute_locations, :xmlns)
    assert Map.has_key?(document.attribute_locations, :version)

    assert Location.slice(document.attribute_locations[:xmlns], source) ==
             "http://www.w3.org/2005/07/scxml"

    assert Location.slice(document.attribute_locations[:version], source) == "1.0"
  end

  defp descendants(%DOM.Element{} = element) do
    [element | element |> DOM.elements() |> Enum.flat_map(&descendants/1)]
  end

  defp strip(%Document{} = document) do
    %{
      initial: document.initial,
      name: document.name,
      datamodel: document.datamodel,
      binding: document.binding,
      states: Enum.map(document.states, &strip/1)
    }
  end

  defp strip(%State{} = state) do
    %{
      kind: state.kind,
      id: state.id,
      initial: state.initial,
      states: Enum.map(state.states, &strip/1),
      transitions: Enum.map(state.transitions, &strip/1),
      onentry: Enum.map(state.onentry, &strip/1),
      onexit: Enum.map(state.onexit, &strip/1)
    }
  end

  defp strip(%Transition{} = transition) do
    %{
      event: transition.event,
      target: transition.target,
      cond: transition.cond,
      type: transition.type,
      content: Enum.map(transition.content, &strip/1)
    }
  end
end
