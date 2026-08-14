defmodule Statifier.Lowering.DonedataTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Content
  alias Statifier.Document.Donedata
  alias Statifier.Document.Param
  alias Statifier.Document.State
  alias Statifier.Lowering
  alias Statifier.Lowering.Error
  alias Statifier.Parser

  defp parse!(xml) do
    {:ok, root} = Parser.parse(xml)
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

  describe "lower/1 - <donedata>, happy path" do
    # sabotage: `build_donedata/2` seeds the accumulator with
    # `content: %Content{location: element.location}` instead of the
    # struct's own `nil` default -> the empty-donedata assertion below
    # reddens even though `<donedata/>` has no children at all
    test "an empty <donedata> builds with content: nil" do
      xml = """
      <scxml>
          <final id="f">
              <donedata/>
          </final>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert %Donedata{content: nil} = state.donedata
    end

    # sabotage: `build_content/2` uses `String.trim/1` on the concatenated
    # text instead of passing `DOM.text/1`'s result through untouched -> the
    # leading/trailing whitespace asserted below is stripped and this test
    # reddens
    test "<donedata> with static <content> text lowers text verbatim, untrimmed" do
      xml = """
      <scxml>
          <final id="f">
              <donedata>
                  <content> foo </content>
              </donedata>
          </final>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert %Donedata{content: %Content{text: " foo ", expr: nil}} = state.donedata
    end

    # sabotage: `build_content/2` skips `Attributes.put_location/4` for
    # `:expr` and returns an empty `attribute_locations` map instead -> the
    # `Map.has_key?/2` assertion below reddens
    test "<donedata> with <content expr=\"...\"/> lowers expr with its value span" do
      xml = """
      <scxml>
          <final id="f">
              <donedata>
                  <content expr="'foo'"/>
              </donedata>
          </final>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert %Donedata{content: %Content{expr: "'foo'", text: ""} = content} = state.donedata
      assert Map.has_key?(content.attribute_locations, :expr)
    end

    # sabotage: `build_content/2` blanks `text` to `""` whenever `expr` is
    # present instead of always using `DOM.text/1`'s result -> the `text:
    # "bar"` assertion below reddens
    test "<donedata> with <content> carrying both text and expr is representable" do
      xml = """
      <scxml>
          <final id="f">
              <donedata>
                  <content expr="'foo'">bar</content>
              </donedata>
          </final>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert %Donedata{content: %Content{expr: "'foo'", text: "bar"}} = state.donedata
    end
  end

  describe "lower/1 - <param> inside <donedata>" do
    # sabotage: `build_param/2`'s `name` case reads `Attributes.value(element,
    # "expr")` into the `name` field instead of the matched `name` variable
    # -> this assertion's `name: "x"` reddens
    test "a <param> child lowers into donedata.params with its name, expr and location attributes" do
      xml = """
      <scxml>
          <final id="f">
              <donedata>
                  <param name="x" expr="1"/>
              </donedata>
          </final>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert %Donedata{params: [%Param{name: "x", expr: "1", param_location: nil} = param]} =
               state.donedata

      assert Map.has_key?(param.attribute_locations, :name)
      assert Map.has_key?(param.attribute_locations, :expr)
      refute Map.has_key?(param.attribute_locations, :location)
    end

    # sabotage: `build_param/2` reads `Attributes.value(element, "expr")`
    # into `param_location` instead of `Attributes.value(element,
    # "location")` -> this assertion's `param_location: "foo.bar"` reddens
    test "a <param location> child lowers its location attribute into param_location" do
      xml = """
      <scxml>
          <final id="f">
              <donedata>
                  <param name="x" location="foo.bar"/>
              </donedata>
          </final>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert %Donedata{params: [%Param{name: "x", expr: nil, param_location: "foo.bar"}]} =
               state.donedata
    end

    # sabotage: `build_donedata/2` drops its `reverse_lists/1` call ->
    # `place/3`'s `{:param, param}` clause builds `params` newest-first
    # (prepending), so without the reversal the two params below come back
    # as `[b, a]` instead of `[a, b]`, reddening this document-order
    # assertion
    test "multiple <param> children land in donedata.params in document order" do
      xml = """
      <scxml>
          <final id="f">
              <donedata>
                  <param name="a" expr="1"/>
                  <param name="b" expr="2"/>
              </donedata>
          </final>
      </scxml>
      """

      state = lower!(xml) |> only_state()

      assert %Donedata{
               params: [
                 %Param{name: "a", expr: "1"},
                 %Param{name: "b", expr: "2"}
               ]
             } = state.donedata
    end

    # sabotage: `build_param/2`'s `nil` case is dropped, falling through to
    # the `name` case with `name` bound to `nil` -> this test reddens
    # because lowering would succeed (with `name: nil`) instead of reporting
    # a missing-attribute error
    test "a <param> with no name reports missing_attribute at its own location" do
      xml = """
      <scxml>
          <final id="f">
              <donedata>
                  <param expr="1"/>
              </donedata>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:missing_attribute, "param", "name"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert %Parser.Location{start_line: 4} = error.location
    end
  end

  describe "lower/1 - element child inside <content>" do
    # sabotage: `build_content/2` drops the `<content>`-exempt-from-stray-text
    # special case, calling `Lowering.walk_children/2` on the content element
    # instead of reading `element.children` directly -> the misplaced-element
    # assertion below reddens (the child element would attempt normal
    # dispatch, or the text run beside it would instead surface as
    # `{:stray_text, _}`)
    test "an element child inside <content> is misplaced, not silently dropped" do
      xml = """
      <scxml>
          <final id="f">
              <donedata>
                  <content><state id="s"/></content>
              </donedata>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:misplaced_element, "state", "content"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      assert error.location != nil
    end
  end

  describe "lower/1 - multi-error accumulation across a <donedata> and a sibling <state>" do
    # sabotage: `Lowering.walk_child/4`'s element clause drops the child's
    # own errors instead of prepending them (`{[result | results], errors}`
    # instead of `{[result | results], Enum.reverse(child_errors) ++
    # errors}`) -> this test reddens because only the top-level walk's own
    # errors would surface, losing both the <script> error nested inside
    # <donedata> and the <send> error nested inside the sibling <state>, so
    # the assertion's two-element list comes back empty
    test "a <script> in one <donedata> and a <send> in a sibling state report two errors, in document order" do
      xml = """
      <scxml>
          <final id="f">
              <donedata>
                  <script>1;</script>
              </donedata>
          </final>
          <state id="s">
              <send/>
          </state>
      </scxml>
      """

      assert {:error, errors} = xml |> parse!() |> Lowering.lower()

      assert [
               %Error{reason: {:unsupported_element, "script"}},
               %Error{reason: {:unsupported_element, "send"}}
             ] = errors

      assert Enum.map(errors, & &1.location.start_offset) ==
               Enum.sort(Enum.map(errors, & &1.location.start_offset))
    end
  end
end
