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
    # sabotage: `Lowering`'s dispatch map grows a stray
    # `"script" => &Builders.build_state/2` entry -> this test reddens
    # because the document lowers successfully instead of reporting
    # `{:unsupported_element, "script"}`
    test "<script> under <scxml>" do
      xml = ~s(<scxml><script>1;</script></scxml>)
      assert_unsupported(xml, "script")
    end

    # sabotage: same dispatch-map addition as above, checked from a
    # different legal position - confirms the rejection is not
    # scxml-root-specific
    test "<script> under <state>" do
      xml = ~s(<scxml><state id="s"><script>1;</script></state></scxml>)
      assert_unsupported(xml, "script")
    end

    # sabotage: `Lowering.walk_child/4`'s unsupported-element branch reports
    # the enclosing element's `location` instead of the child's own -> the
    # location-regex assertion inside `assert_unsupported/2` reddens, since
    # the slice would start at "<donedata", not "<param"
    test "<param> under <donedata>" do
      xml = """
      <scxml>
          <final id="f">
              <donedata><param name="x" expr="1"/></donedata>
          </final>
      </scxml>
      """

      assert_unsupported(xml, "param")
    end

    # sabotage: `Lowering`'s dispatch map grows a stray "if" entry
    # dispatching to `build_block/3` (an accidental structural-content
    # builder) -> this test reddens because `<if>` builds a `Block` instead
    # of being reported unsupported
    test "<if> under <onentry>" do
      xml = ~s(<scxml><state id="s"><onentry><if cond="true"/></onentry></state></scxml>)
      assert_unsupported(xml, "if")
    end

    # sabotage: same class of mutation as `<if>`'s, applied to "elseif"
    test "<elseif> under <onentry>" do
      xml = ~s(<scxml><state id="s"><onentry><elseif cond="true"/></onentry></state></scxml>)
      assert_unsupported(xml, "elseif")
    end

    # sabotage: same class of mutation as `<if>`'s, applied to "else"
    test "<else> under <onentry>" do
      xml = ~s(<scxml><state id="s"><onentry><else/></onentry></state></scxml>)
      assert_unsupported(xml, "else")
    end

    # sabotage: `Lowering`'s dispatch map grows a stray "assign" entry
    # dispatching to `build_log/2` (an accidental content-node builder) ->
    # this test reddens because `<assign>` builds a `Log` and lands in
    # `Transition.content` instead of being reported unsupported
    test "<assign> under a <transition>" do
      xml =
        ~s(<scxml><state id="s"><transition><assign location="x" expr="1"/></transition></state></scxml>)

      assert_unsupported(xml, "assign")
    end

    # `<datamodel>` and `<data>` moved from this deferred set to the
    # supported set in st-af3.3 Phase 1 - see
    # `test/statifier/lowering/datamodel_test.exs` for their own coverage.

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

    # sabotage: `Lowering`'s dispatch map grows a stray "foreach" entry
    # dispatching to `build_block/3` -> this test reddens because
    # `<foreach>` builds a `Block` instead of being reported unsupported
    test "<foreach> under <onentry>" do
      xml = ~s(<scxml><state id="s"><onentry><foreach item="x"/></onentry></state></scxml>)
      assert_unsupported(xml, "foreach")
    end
  end
end
