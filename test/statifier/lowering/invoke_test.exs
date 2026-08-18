defmodule Statifier.Lowering.InvokeTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.{Block, Content, Invoke, Param, State}
  alias Statifier.{Lowering, Parser}

  defp parse!(xml) do
    {:ok, root} = Parser.parse(xml)
    root
  end

  defp lower!(xml) do
    {:ok, document} = xml |> parse!() |> Lowering.lower(xml)
    document
  end

  defp only_state(document) do
    assert [%State{} = state] = document.states
    state
  end

  defp only_invoke(document) do
    assert %State{invoke: [%Invoke{} = invoke]} = only_state(document)
    invoke
  end

  describe "lower/1 - <invoke> attributes" do
    # sabotage: `build_invoke/2`'s `typeexpr:` field reads
    # `Attributes.value(element, "type")` instead of `"typeexpr"` -> this
    # assertion's `typeexpr: "TypeVar"` reddens
    test "every 6.4.1 attribute lowers with its own value and span" do
      xml = """
      <scxml>
          <state id="s">
              <invoke type="http://www.w3.org/TR/scxml/" typeexpr="TypeVar"
                      src="http://example.com" srcexpr="SrcVar"
                      id="myid" idlocation="IdVar"
                      namelist="a b" autoforward="true"/>
          </state>
      </scxml>
      """

      invoke = lower!(xml) |> only_invoke()

      assert %Invoke{
               type: "http://www.w3.org/TR/scxml/",
               typeexpr: "TypeVar",
               src: "http://example.com",
               srcexpr: "SrcVar",
               id: "myid",
               idlocation: "IdVar",
               namelist: ["a", "b"],
               autoforward: true
             } = invoke

      for key <- [:type, :typeexpr, :src, :srcexpr, :id, :idlocation, :namelist, :autoforward] do
        assert Map.has_key?(invoke.attribute_locations, key),
               "attribute_locations is missing #{inspect(key)}"
      end
    end

    # sabotage: `build_invoke/2`'s struct literal drops `namelist:
    # Attributes.list(element, "namelist")`, falling back to the struct's
    # own `[]` default -> this test's non-empty `namelist` assertion
    # reddens
    test "namelist splits on whitespace into a list, in written order" do
      xml = """
      <scxml>
          <state id="s">
              <invoke type="t" namelist="foo   bar baz"/>
          </state>
      </scxml>
      """

      assert %Invoke{namelist: ["foo", "bar", "baz"]} = lower!(xml) |> only_invoke()
    end

    # sabotage: `build_invoke/2`'s `autoforward:` field defaults to `true`
    # instead of `false` (`Attributes.atom(element, "autoforward",
    # @autoforward_values, true)`) -> the absent-attribute assertion below
    # reddens
    test "autoforward defaults to false when the attribute is absent" do
      xml = """
      <scxml>
          <state id="s">
              <invoke type="t"/>
          </state>
      </scxml>
      """

      assert %Invoke{autoforward: false} = lower!(xml) |> only_invoke()
    end
  end

  describe "lower/1 - <param> inside <invoke>" do
    # sabotage: `build_invoke/2` drops its `reverse_lists/1` call ->
    # `place/3`'s `{:param, param}` clause on `%Invoke{}` builds `params`
    # newest-first (prepending), so without the reversal the two params
    # below come back as `[b, a]` instead of `[a, b]`, reddening this
    # document-order assertion
    test "<param> children accumulate into invoke.params in document order" do
      xml = """
      <scxml>
          <state id="s">
              <invoke type="t">
                  <param name="a" expr="1"/>
                  <param name="b" expr="2"/>
              </invoke>
          </state>
      </scxml>
      """

      assert %Invoke{
               params: [
                 %Param{name: "a", expr: "1"},
                 %Param{name: "b", expr: "2"}
               ]
             } = lower!(xml) |> only_invoke()
    end
  end

  describe "lower/1 - <content> inside <invoke>" do
    # sabotage: `place/3`'s `{:content, content}, %Invoke{}` clause is
    # dropped, leaving only the pre-existing `%Donedata{}` clause -> an
    # `<invoke>`'s `<content>` child falls through to the generic catch-all
    # and is reported `{:misplaced_element, "content", "invoke"}` instead of
    # being placed, reddening the `{:ok, _}`-shaped assertion below
    test "<content> child sets invoke.content" do
      xml = """
      <scxml>
          <state id="s">
              <invoke type="t">
                  <content>payload</content>
              </invoke>
          </state>
      </scxml>
      """

      assert %Invoke{content: %Content{text: "payload", expr: nil}} = lower!(xml) |> only_invoke()
    end
  end

  describe "lower/1 - <finalize> inside <invoke>" do
    # sabotage: `build_invoke/2`'s struct literal seeds `finalize:
    # %Block{location: element.location}` instead of leaving the struct's
    # own `nil` default -> this test's `finalize: nil` assertion reddens
    # even though no `<finalize>` child was written
    test "an <invoke> with no <finalize> child leaves finalize nil" do
      xml = """
      <scxml>
          <state id="s">
              <invoke type="t"/>
          </state>
      </scxml>
      """

      assert %Invoke{finalize: nil} = lower!(xml) |> only_invoke()
    end

    # sabotage: `"finalize" => &Builders.build_finalize/2` is dropped from
    # `Lowering`'s dispatch map -> `<finalize/>` is no longer dispatched at
    # all and lowering reports `{:unsupported_element, "finalize"}` instead
    # of building, reddening this `{:ok, _}`-shaped assertion
    test "a written but childless <finalize/> builds finalize: %Block{content: []}, distinct from absent" do
      xml = """
      <scxml>
          <state id="s">
              <invoke type="t">
                  <finalize/>
              </invoke>
          </state>
      </scxml>
      """

      assert %Invoke{finalize: %Block{content: []}} = lower!(xml) |> only_invoke()
    end

    # sabotage: `build_finalize/2` replaces `place_children(results, block,
    # element.name)` with `{block, []}`, discarding every walked child ->
    # this test's non-empty `content` assertion reddens
    test "<finalize> with executable content lowers into finalize.content" do
      xml = """
      <scxml>
          <state id="s">
              <invoke type="t">
                  <finalize>
                      <log label="done"/>
                  </finalize>
              </invoke>
          </state>
      </scxml>
      """

      assert %Invoke{finalize: %Block{content: [%Statifier.Document.Log{label: "done"}]}} =
               lower!(xml) |> only_invoke()
    end
  end
end
