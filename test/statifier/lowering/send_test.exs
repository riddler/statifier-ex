defmodule Statifier.Lowering.SendTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Block
  alias Statifier.Document.Content
  alias Statifier.Document.Param
  alias Statifier.Document.Send
  alias Statifier.Document.State
  alias Statifier.Lowering
  alias Statifier.Parser

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

  defp only_onentry_send(document) do
    assert %State{onentry: [%Block{content: [%Send{} = send]}]} = only_state(document)
    send
  end

  describe "lower/1 - <send> attributes" do
    # sabotage: `build_send/2`'s `eventexpr:` field reads
    # `Attributes.value(element, "event")` instead of `"eventexpr"` -> this
    # assertion's `eventexpr: "EventVar"` reddens
    test "every 6.2.1 attribute lowers with its own value and span" do
      xml = """
      <scxml>
          <state id="s">
              <onentry>
                  <send event="go" eventexpr="EventVar"
                        target="t" targetexpr="TargetVar"
                        type="http://www.w3.org/TR/scxml/" typeexpr="TypeVar"
                        id="myid" idlocation="IdVar"
                        delay="1s" delayexpr="DelayVar"
                        namelist="a b"/>
              </onentry>
          </state>
      </scxml>
      """

      send = lower!(xml) |> only_onentry_send()

      assert %Send{
               event: "go",
               eventexpr: "EventVar",
               target: "t",
               targetexpr: "TargetVar",
               type: "http://www.w3.org/TR/scxml/",
               typeexpr: "TypeVar",
               id: "myid",
               idlocation: "IdVar",
               delay: "1s",
               delayexpr: "DelayVar",
               namelist: ["a", "b"]
             } = send

      for key <- [
            :event,
            :eventexpr,
            :target,
            :targetexpr,
            :type,
            :typeexpr,
            :id,
            :idlocation,
            :delay,
            :delayexpr,
            :namelist
          ] do
        assert Map.has_key?(send.attribute_locations, key),
               "attribute_locations is missing #{inspect(key)}"
      end
    end

    # sabotage: `build_send/2`'s `namelist:` field reads
    # `Attributes.value(element, "namelist")` instead of
    # `Attributes.list(element, "namelist")` -> this test crashes/reddens
    # because `namelist` would be a raw string, not a list
    test "namelist splits on whitespace into a list, in written order" do
      xml = """
      <scxml>
          <state id="s">
              <onentry>
                  <send event="e" namelist="foo   bar baz"/>
              </onentry>
          </state>
      </scxml>
      """

      assert %Send{namelist: ["foo", "bar", "baz"]} = lower!(xml) |> only_onentry_send()
    end

    # sabotage: `build_send/2`'s `event:` field is hardcoded to
    # `"unwanted"` instead of `Attributes.value(element, "event")` -> this
    # test reddens because a `<send/>` with no `event` attribute would still
    # lower with a non-nil `event`
    test "event defaults to nil when the attribute is absent" do
      xml = ~s(<scxml><state id="s"><onentry><send/></onentry></state></scxml>)

      assert %Send{event: nil} = lower!(xml) |> only_onentry_send()
    end
  end

  describe "lower/1 - <param> inside <send>" do
    # sabotage: `build_send/2` drops its `reverse_lists/1` call ->
    # `place/3`'s `{:param, param}` clause on `%Send{}` builds `params`
    # newest-first (prepending), so without the reversal the two params
    # below come back as `[b, a]` instead of `[a, b]`, reddening this
    # document-order assertion
    test "<param> children accumulate into send.params in document order" do
      xml = """
      <scxml>
          <state id="s">
              <onentry>
                  <send event="e">
                      <param name="a" expr="1"/>
                      <param name="b" expr="2"/>
                  </send>
              </onentry>
          </state>
      </scxml>
      """

      assert %Send{
               params: [
                 %Param{name: "a", expr: "1"},
                 %Param{name: "b", expr: "2"}
               ]
             } = lower!(xml) |> only_onentry_send()
    end
  end

  describe "lower/1 - <content> inside <send>" do
    # sabotage: `place/3`'s `{:content, content}, %Send{}` clause is dropped
    # -> a `<send>`'s `<content>` child falls through to the generic
    # catch-all and is reported `{:misplaced_element, "content", "send"}`
    # instead of being placed, reddening the `{:ok, _}`-shaped assertion
    # below
    test "<content> child sets send.content" do
      xml = """
      <scxml>
          <state id="s">
              <onentry>
                  <send event="e">
                      <content>payload</content>
                  </send>
              </onentry>
          </state>
      </scxml>
      """

      assert %Send{content: %Content{text: "payload", expr: nil}} =
               lower!(xml) |> only_onentry_send()
    end
  end
end
