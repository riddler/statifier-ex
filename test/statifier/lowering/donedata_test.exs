defmodule Statifier.Lowering.DonedataTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Content
  alias Statifier.Document.Donedata
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

  describe "lower/1 - <param> inside <donedata> is refused" do
    # sabotage: `Lowering`'s dispatch map grows a `"param" => &Builders.build_param/2`
    # entry (a stray hand-written builder) -> this test reddens because the
    # document lowers successfully instead of reporting an unsupported
    # element error
    test "a <param> child produces exactly one error naming param, at param's own location" do
      xml = """
      <scxml>
          <final id="f">
              <donedata>
                  <param name="x" expr="1"/>
              </donedata>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:unsupported_element, "param"}} = error]} =
               xml |> parse!() |> Lowering.lower()

      # sabotage confirms the location is param's own, not donedata's: swap
      # `walk_child/4`'s `Error.unsupported(name, location)` call to use the
      # parent element's location instead -> this assertion reddens because
      # the reported line would move from <param>'s line to <donedata>'s
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
    # errors would surface, losing both the <param> error nested inside
    # <donedata> and the <script> error nested inside the sibling <state>,
    # so the assertion's two-element list comes back empty
    test "a <param> in one <donedata> and a <script> in a sibling state report two errors, in document order" do
      xml = """
      <scxml>
          <final id="f">
              <donedata>
                  <param name="x" expr="1"/>
              </donedata>
          </final>
          <state id="s">
              <script>1;</script>
          </state>
      </scxml>
      """

      assert {:error, errors} = xml |> parse!() |> Lowering.lower()

      assert [
               %Error{reason: {:unsupported_element, "param"}},
               %Error{reason: {:unsupported_element, "script"}}
             ] = errors

      assert Enum.map(errors, & &1.location.start_offset) ==
               Enum.sort(Enum.map(errors, & &1.location.start_offset))
    end
  end
end
