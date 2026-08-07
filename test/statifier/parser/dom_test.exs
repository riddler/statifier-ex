defmodule Statifier.Parser.DOMTest do
  use ExUnit.Case, async: true

  alias Statifier.Parser.DOM

  defp parse!(xml) do
    {:ok, root} = Statifier.Parser.parse(xml)
    root
  end

  describe "elements/1" do
    # sabotage: elements/1 returns `children` unfiltered -> the whitespace
    # text runs between the children come back too, reddening the
    # two-element match below
    test "returns element children only, dropping whitespace text runs" do
      xml = """
      <root>
          <alpha/>
          <beta/>
      </root>
      """

      root = parse!(xml)

      assert [%DOM.Element{name: "alpha"}, %DOM.Element{name: "beta"}] = DOM.elements(root)
      assert length(root.children) == 5
    end

    # sabotage: elements/1 filters with `match?(%DOM.Text{}, &1)` instead of
    # `match?(%DOM.Element{}, &1)` -> the element between the two text runs
    # is dropped and the runs are kept, reddening the match below
    test "keeps document order across mixed content" do
      xml = "<root>before<alpha/>after</root>"

      assert [%DOM.Element{name: "alpha"}] = DOM.elements(parse!(xml))
    end
  end

  describe "attribute/2" do
    # sabotage: attribute/2's finder compares `&1.value == name` instead of
    # `&1.name == name` -> the lookup misses, reddening the match below
    test "finds an attribute by name and reports nil for a missing one" do
      xml = ~s(<root id="r1" label="hello"/>)

      root = parse!(xml)

      assert %DOM.Attribute{name: "label", value: "hello"} = DOM.attribute(root, "label")
      assert DOM.attribute(root, "absent") == nil
    end

    # sabotage: attribute/2 uses `Enum.reverse(attributes) |> Enum.find(...)`
    # -> the last duplicate is returned instead of the first, reddening the
    # value assertion
    test "returns the first of a duplicated attribute, and the list keeps both" do
      xml = ~s(<root id="first" id="second"/>)

      root = parse!(xml)

      assert %DOM.Attribute{value: "first"} = DOM.attribute(root, "id")
      assert Enum.map(root.attributes, & &1.value) == ["first", "second"]
    end
  end

  describe "text/1" do
    # sabotage: text/1 concatenates every child's `value` without filtering
    # to %DOM.Text{} -> it raises on the %DOM.Element{} child, which has no
    # `value` field, reddening this test
    test "concatenates direct text children and ignores child elements" do
      xml = "<root>before<alpha>inner</alpha>after</root>"

      assert DOM.text(parse!(xml)) == "beforeafter"
    end

    # sabotage: text/1 recurses, concatenating each child element's text as
    # well as its own -> the descendant's text leaks into the result,
    # reddening the empty-binary assertion
    test "is the empty binary when only descendants carry text" do
      assert DOM.text(parse!("<root><alpha>inner</alpha></root>")) == ""
    end
  end
end
