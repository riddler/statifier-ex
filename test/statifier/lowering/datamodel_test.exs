defmodule Statifier.Lowering.DatamodelTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Data
  alias Statifier.Document.Datamodel
  alias Statifier.Document.State
  alias Statifier.Lowering
  alias Statifier.Lowering.Error

  defp parse!(xml) do
    {:ok, root} = Statifier.Parser.parse(xml)
    root
  end

  defp lower!(xml) do
    {:ok, document} = xml |> parse!() |> Lowering.lower()
    document
  end

  defp only_state(document) do
    assert [%State{} = state] = document.states
    state
  end

  describe "lower/1 - <datamodel> at the document root" do
    # sabotage: `place/3`'s `{:datamodel, datamodel}` clause for `%Document{}`
    # is dropped, falling through to the generic misplaced-element catch-all
    # -> this test reddens because `document.datamodel_element` would stay
    # `nil` and lowering would return `{:error, _}` instead
    test "a root <datamodel> lands on Document.datamodel_element" do
      xml = """
      <scxml>
          <datamodel>
              <data id="x" expr="1"/>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      document = lower!(xml)

      assert %Datamodel{data: [%Data{id: "x", expr: "1"}]} = document.datamodel_element
    end
  end

  describe "lower/1 - <datamodel> on a state" do
    # sabotage: `place/3`'s `{:datamodel, datamodel}` clause for `%State{}`
    # sets `initial_element` instead of `datamodel_element` -> this test
    # reddens because `state.datamodel_element` would stay `nil`
    test "a state-scoped <datamodel> lands on State.datamodel_element" do
      xml = """
      <scxml>
          <state id="s">
              <datamodel>
                  <data id="x" expr="1"/>
              </datamodel>
          </state>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert %Datamodel{data: [%Data{id: "x", expr: "1"}]} = state.datamodel_element
    end

    # sabotage: `Checks.Data`'s placement rule does not exist yet (that is
    # Phase 2's job), but lowering itself must not reject a <datamodel> under
    # <final> - break that by adding a `place/3` clause that returns a
    # misplaced-element error for `%State{kind: :final}` -> this test
    # reddens because lowering would return `{:error, _}` instead of
    # building the document
    test "a <datamodel> under <final> lowers without error (placement is Phase 2's job)" do
      xml = """
      <scxml>
          <final id="f">
              <datamodel>
                  <data id="x" expr="1"/>
              </datamodel>
          </final>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert %Datamodel{data: [%Data{id: "x"}]} = state.datamodel_element
    end
  end

  describe "lower/1 - <data>, the four shapes" do
    # sabotage: `build_data/2` reads `expr` with `Attributes.list/2` instead
    # of `Attributes.value/2` -> this test reddens because `expr` would
    # become a list, not the raw string
    test ~s(expr shape: <data id="x" expr="..."/> lowers expr as a raw string) do
      xml = """
      <scxml>
          <datamodel>
              <data id="x" expr="1 + 1"/>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      document = lower!(xml)

      assert %Datamodel{data: [%Data{id: "x", expr: "1 + 1", src: nil, text: ""}]} =
               document.datamodel_element
    end

    # sabotage: `build_data/2` swaps the `src` and `expr` reads -> this test
    # reddens since the value would land on the wrong field
    test ~s(src shape: <data id="x" src="..."/> lowers src as a raw string) do
      xml = """
      <scxml>
          <datamodel>
              <data id="x" src="file:x.txt"/>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      document = lower!(xml)

      assert %Datamodel{data: [%Data{id: "x", src: "file:x.txt", expr: nil, text: ""}]} =
               document.datamodel_element
    end

    # sabotage: `build_data/2` calls `walk_children/2` instead of reading
    # `element.children` directly -> red
    test "child content shape: <data id=\"x\">child text</data> keeps text verbatim" do
      xml = """
      <scxml>
          <datamodel>
              <data id="x"> [1,2,3] </data>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      document = lower!(xml)

      assert %Datamodel{data: [%Data{id: "x", text: " [1,2,3] ", expr: nil, src: nil}]} =
               document.datamodel_element
    end

    # sabotage: `build_data/2` defaults `expr`/`src` to `""` instead of the
    # raw `Attributes.value/2` result when the attribute is absent -> this
    # test reddens because `expr`/`src` would come back `""`, not `nil`
    test "bare shape: <data id=\"x\"/> lowers with expr and src nil, text empty" do
      xml = """
      <scxml>
          <datamodel>
              <data id="x"/>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      document = lower!(xml)

      assert %Datamodel{data: [%Data{id: "x", expr: nil, src: nil, text: ""}]} =
               document.datamodel_element
    end

    # sabotage: `build_data/2` sets `src: nil` whenever `expr` is present,
    # enforcing mutual exclusion at lowering time instead of leaving it to
    # `Statifier.Validator.Checks.Data` -> this test reddens because `src`
    # would come back `nil` instead of `"file:x.txt"`
    test "expr, src, and text are all representable on the same <data> at once" do
      xml = """
      <scxml>
          <datamodel>
              <data id="x" expr="1" src="file:x.txt">hi</data>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      document = lower!(xml)

      assert %Datamodel{data: [%Data{id: "x", expr: "1", src: "file:x.txt", text: "hi"}]} =
               document.datamodel_element
    end

    # sabotage: `build_data/2`'s `attribute_locations` pipeline drops the
    # `:expr`/`:src` `put_location` calls -> the `Map.has_key?/2` assertions
    # below reddens
    test "attribute_locations records id, expr, and src only when written" do
      xml = """
      <scxml>
          <datamodel>
              <data id="x" expr="1"/>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      document = lower!(xml)

      assert %Datamodel{data: [%Data{attribute_locations: locations}]} =
               document.datamodel_element

      assert Map.has_key?(locations, :id)
      assert Map.has_key?(locations, :expr)
      refute Map.has_key?(locations, :src)
    end
  end

  describe "lower/1 - <data>, missing id" do
    # sabotage: `build_data/2` defaults a missing id to nil instead of
    # erroring -> red
    test "a <data> with no id attribute produces a missing_attribute error" do
      xml = """
      <scxml>
          <datamodel>
              <data expr="1"/>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:missing_attribute, "data", "id"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert error.location != nil
    end
  end

  describe "lower/1 - <data>, an element child is misplaced" do
    # sabotage: `build_data/2` silently drops an element child instead of
    # reporting it via `Error.misplaced/3` -> this test reddens because no
    # `{:misplaced_element, ...}` error would be produced; lowering would
    # return `{:ok, _}` instead
    test "an element child inside <data> is misplaced, not silently dropped" do
      xml = """
      <scxml>
          <datamodel>
              <data id="x"><state id="nope"/></data>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:misplaced_element, "state", "data"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert error.location != nil
    end
  end

  describe "lower/1 - no <datamodel> at all" do
    # sabotage: `build_scxml/2` unconditionally sets
    # `datamodel_element: %Datamodel{location: element.location}` instead of
    # leaving the struct default -> this test reddens because
    # `document.datamodel_element` would no longer be `nil`
    test "a document with no <datamodel> lowers with datamodel_element: nil" do
      xml = ~s(<scxml><state id="s"/></scxml>)

      document = lower!(xml)

      assert document.datamodel_element == nil
      assert only_state(document).datamodel_element == nil
    end
  end
end
