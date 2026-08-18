defmodule Statifier.LoweringTest do
  use ExUnit.Case, async: true

  alias Statifier.{Document, Lowering, Parser}
  alias Statifier.Lowering.Error
  alias Statifier.Parser.Location

  defp parse!(xml) do
    {:ok, root} = Parser.parse(xml)
    root
  end

  defp lower!(xml) do
    {:ok, document} = xml |> parse!() |> Lowering.lower(xml)
    document
  end

  describe "lower/1 - the <scxml> root, happy path" do
    # sabotage: build_scxml/2 assigns `version: Attributes.value(element, "datamodel")`
    # (swaps the two field reads) -> the version/datamodel assertions below
    # reddens
    test "all six root attributes lower onto the Document, with their spans recorded" do
      xml =
        ~s(<scxml initial="a b" name="my-chart" datamodel="null" binding="late" version="1.0" xmlns="http://www.w3.org/2005/07/scxml"/>)

      document = lower!(xml)

      assert %Document{
               initial: ["a", "b"],
               name: "my-chart",
               datamodel: "null",
               binding: :late,
               version: "1.0",
               xmlns: "http://www.w3.org/2005/07/scxml",
               states: []
             } = document

      for key <- [:initial, :name, :datamodel, :binding, :version, :xmlns] do
        assert %Location{} = location = Map.fetch!(document.attribute_locations, key)
        assert Location.slice(location, xml) != ""
      end
    end

    # sabotage: `build_scxml/2` passes `:late` as `Attributes.atom/4`'s
    # default instead of `:early` -> the binding assertion below reddens
    test "no attributes lowers to defaults, with an empty attribute_locations" do
      xml = ~s(<scxml/>)

      document = lower!(xml)

      assert %Document{
               initial: [],
               name: nil,
               datamodel: nil,
               binding: :early,
               version: nil,
               xmlns: nil,
               states: [],
               attribute_locations: %{}
             } = document
    end

    # sabotage: `build_scxml/2`'s `Attributes.put_location(:binding, element,
    # "binding")` call has its attribute-name argument swapped for the raw
    # string `"early"` -> it looks up a nonexistent `"early"` attribute
    # instead of the written `"binding"` one, and the key assertion below
    # reddens
    test "binding=\"late\" records its span in attribute_locations" do
      xml = ~s(<scxml binding="late"/>)

      document = lower!(xml)

      assert document.binding == :late
      assert %Location{} = location = Map.fetch!(document.attribute_locations, :binding)
      assert Location.slice(location, xml) == "late"
    end

    # sabotage: `Attributes.put_location/4` is called with `"binding"` swapped
    # for a raw string constant `"early"` as the attribute name, so it always
    # looks up a nonexistent `"early"` attribute -> the key assertion below
    # reddens even though `binding="early"` was written explicitly
    test "binding=\"early\" written explicitly still records its span, unlike an absent binding" do
      xml = ~s(<scxml binding="early"/>)

      document = lower!(xml)

      assert document.binding == :early
      assert %Location{} = location = Map.fetch!(document.attribute_locations, :binding)
      assert Location.slice(location, xml) == "early"
    end
  end

  describe "lower/1 - unsupported children of <scxml>" do
    # sabotage: `finalize/2` drops `Enum.sort_by(errors, ...)` and returns the
    # accumulated list unsorted -> the ordered names assertion below reddens
    test "three unknown children report three errors in document order" do
      xml = """
      <scxml>
          <foo/>
          <bar/>
          <baz/>
      </scxml>
      """

      assert {:error, errors} = xml |> parse!() |> Lowering.lower(xml)

      assert [
               %Error{reason: {:unsupported_element, "foo"}},
               %Error{reason: {:unsupported_element, "bar"}},
               %Error{reason: {:unsupported_element, "baz"}}
             ] = errors

      offsets = Enum.map(errors, & &1.location.start_offset)
      assert offsets == Enum.sort(offsets)
    end
  end

  describe "lower/1 - stray text" do
    # sabotage: `walk_child/4`'s text clause reports `location` from the
    # enclosing element instead of the text node's own `location` -> the
    # slice assertion below reddens
    test "non-whitespace text inside <scxml> is an error naming its own location" do
      xml = "<scxml>hello</scxml>"

      assert {:error, [%Error{reason: {:stray_text, "hello"}} = error]} =
               xml |> parse!() |> Lowering.lower(xml)

      assert Location.slice(error.location, xml) == "hello"
    end

    # sabotage: `walk_child/4`'s text clause drops the `String.trim/1` guard
    # and reports every text run, whitespace-only or not -> this test
    # reddens because the whitespace-only run now produces an error
    test "a whitespace-only run produces no error" do
      xml = "<scxml>\n    \n</scxml>"

      assert {:ok, %Document{}} = xml |> parse!() |> Lowering.lower(xml)
    end
  end

  describe "lower/1 - a non-scxml root" do
    # sabotage: `lower/1` looks the builder up with the literal `"scxml"`
    # instead of the root's own `name`, so any root name dispatches -> this
    # test reddens because no {:unexpected_root, _} error is produced
    test "a root element other than <scxml> is rejected" do
      xml = ~s(<foo/>)

      assert {:error, [%Error{reason: {:unexpected_root, "foo"}} = error]} =
               xml |> parse!() |> Lowering.lower(xml)

      assert Location.slice(error.location, xml) == "<foo/>"
    end
  end
end
