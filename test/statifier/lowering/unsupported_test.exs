defmodule Statifier.Lowering.UnsupportedTest do
  use ExUnit.Case, async: true

  alias Statifier.Lowering
  alias Statifier.Lowering.Error
  alias Statifier.Parser
  alias Statifier.Parser.Location

  defp parse!(xml) do
    {:ok, root} = Parser.parse(xml)
    root
  end

  # Exactly one error, naming `name`, whose own location slices back to
  # `name`'s own start tag - not its parent's.
  defp assert_unsupported(xml, name) do
    assert {:error, [%Error{reason: {:unsupported_element, ^name}} = error]} =
             xml |> parse!() |> Lowering.lower()

    slice = Location.slice(error.location, xml)

    assert slice =~ ~r/\A<#{Regex.escape(name)}[\s\/>]/,
           "#{name}'s reported location is not its own: #{inspect(slice)}"

    error
  end

  describe "elements outside the supported set are rejected by name, at their own location" do
    # `<datamodel>` and `<data>` moved from this deferred set to the
    # supported set in st-af3.3 Phase 1 - see
    # `test/statifier/lowering/datamodel_test.exs` for their own coverage.
    # `<assign>` moved the same way in st-af3.4 Phase 1 - see
    # `test/statifier/lowering/content_test.exs` for its own coverage.
    # `<if>`/`<elseif>`/`<else>` moved the same way in st-af3.5 Phase 2 - see
    # `test/statifier/lowering/content_test.exs` for their own coverage.
    # `<script>` moved the same way - see
    # `test/statifier/lowering/content_test.exs` for its own coverage.

    # sabotage: `Lowering`'s dispatch map grows a stray "invoke" entry
    # dispatching to `state_like/3` with `kind: :invoke` (an invented state
    # kind) -> this test reddens because `<invoke>` builds instead of being
    # reported unsupported
    test "<invoke> under a <state>" do
      xml = ~s(<scxml><state id="s"><invoke type="t"/></state></scxml>)
      assert_unsupported(xml, "invoke")
    end

    # sabotage: `Lowering`'s dispatch map grows a stray "cancel" entry
    # dispatching to `build_raise/2` (an accidental content-node builder) ->
    # this test reddens because `<cancel>` builds a `Raise` instead of being
    # reported unsupported
    test "<cancel> under <onexit>" do
      xml = ~s(<scxml><state id="s"><onexit><cancel sendid="s1"/></onexit></state></scxml>)
      assert_unsupported(xml, "cancel")
    end

    # sabotage: `Lowering`'s dispatch map grows a stray "send" entry
    # dispatching to `build_log/2` -> this test reddens because `<send>`
    # builds a `Log` and lands in `Block.content` instead of being reported
    # unsupported
    test "<send> under <onentry>" do
      xml = ~s(<scxml><state id="s"><onentry><send event="e"/></onentry></state></scxml>)
      assert_unsupported(xml, "send")
    end

    # sabotage: same dispatch-map addition as above, checked from a
    # transition's own content instead of a block's
    test "<send> under a <transition>" do
      xml = ~s(<scxml><state id="s"><transition><send event="e"/></transition></state></scxml>)
      assert_unsupported(xml, "send")
    end

    # `<foreach>` moved from this deferred set to the supported set in
    # st-af3.6 Phase 1 - see `test/statifier/lowering/content_test.exs` for
    # its own coverage. `<param>` moved the same way in st-af3.7 Phase 3 -
    # see `test/statifier/lowering/donedata_test.exs` for its own coverage.
  end
end
