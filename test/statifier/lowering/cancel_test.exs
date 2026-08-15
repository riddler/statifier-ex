defmodule Statifier.Lowering.CancelTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.Block
  alias Statifier.Document.Cancel
  alias Statifier.Document.State
  alias Statifier.Lowering
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

  defp only_onexit_cancel(document) do
    assert %State{onexit: [%Block{content: [%Cancel{} = cancel]}]} = only_state(document)
    cancel
  end

  describe "lower/1 - <cancel> attributes" do
    # sabotage: `build_cancel/2`'s `sendid:` field reads
    # `Attributes.value(element, "sendidexpr")` instead of `"sendid"` ->
    # this assertion's `sendid: "s1"` reddens
    test "sendid lowers with its own value and span" do
      xml = """
      <scxml>
          <state id="s">
              <onexit>
                  <cancel sendid="s1"/>
              </onexit>
          </state>
      </scxml>
      """

      cancel = lower!(xml) |> only_onexit_cancel()

      assert %Cancel{sendid: "s1", sendidexpr: nil} = cancel
      assert Map.has_key?(cancel.attribute_locations, :sendid)
      refute Map.has_key?(cancel.attribute_locations, :sendidexpr)
    end

    # sabotage: `build_cancel/2`'s `sendidexpr:` field reads
    # `Attributes.value(element, "sendid")` instead of `"sendidexpr"` ->
    # this assertion's `sendidexpr: "SendIdVar"` reddens
    test "sendidexpr lowers with its own value and span" do
      xml = """
      <scxml>
          <state id="s">
              <onexit>
                  <cancel sendidexpr="SendIdVar"/>
              </onexit>
          </state>
      </scxml>
      """

      cancel = lower!(xml) |> only_onexit_cancel()

      assert %Cancel{sendid: nil, sendidexpr: "SendIdVar"} = cancel
      assert Map.has_key?(cancel.attribute_locations, :sendidexpr)
      refute Map.has_key?(cancel.attribute_locations, :sendid)
    end

    # sabotage: `build_cancel/2`'s `sendid:` field is hardcoded to
    # `"unwanted"` instead of `Attributes.value(element, "sendid")` -> this
    # test reddens because a `<cancel/>` with no `sendid` attribute would
    # still lower with a non-nil `sendid`
    test "both attributes default to nil when absent" do
      xml = ~s(<scxml><state id="s"><onexit><cancel/></onexit></state></scxml>)

      assert %Cancel{sendid: nil, sendidexpr: nil} = lower!(xml) |> only_onexit_cancel()
    end
  end
end
