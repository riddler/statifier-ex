defmodule Statifier.Lowering.TransitionTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.{State, Transition}
  alias Statifier.{Lowering, Parser}
  alias Statifier.Parser.Location

  defp parse!(xml) do
    {:ok, root} = Parser.parse(xml)
    root
  end

  defp lower!(xml) do
    {:ok, document} = xml |> parse!() |> Lowering.lower(xml)
    document
  end

  defp only_transition(document) do
    assert [%State{transitions: [transition]}] = document.states
    transition
  end

  describe "lower/1 - <transition>, happy path" do
    # sabotage: `build_transition/2` sets `event: [Attributes.value(element,
    # "cond")]` instead of `Attributes.list(element, "event")` -> the split
    # assertion below reddens
    test "event and target both whitespace-split into lists" do
      xml = ~s(<scxml><state id="s"><transition event="e1 e2" target="a b"/></state></scxml>)

      document = lower!(xml)
      transition = only_transition(document)

      assert transition.event == ["e1", "e2"]
      assert transition.target == ["a", "b"]
    end

    # sabotage: `build_transition/2` drops the
    # `Attributes.put_location(:event, element, "event")` call from the
    # `attribute_locations` pipeline -> the key-present assertion below
    # reddens even though `event=""` was written
    test "event=\"\" yields [] with the attribute_locations key present" do
      xml = ~s(<scxml><state id="s"><transition event=""/></state></scxml>)

      document = lower!(xml)
      transition = only_transition(document)

      assert transition.event == []
      assert Map.has_key?(transition.attribute_locations, :event)
    end

    # sabotage: `build_transition/2` reads `cond` with `Attributes.list/2`
    # (and takes the first token) instead of `Attributes.value/2` -> the raw
    # string assertion below reddens (`"x"` instead of `"x > 1"`)
    test "cond is stored as the raw source string, uncompiled" do
      xml = ~s(<scxml><state id="s"><transition cond="x &gt; 1"/></state></scxml>)

      document = lower!(xml)
      transition = only_transition(document)

      assert transition.cond == "x > 1"
      assert %Location{} = location = Map.fetch!(transition.attribute_locations, :cond)
      assert Location.slice(location, xml) == "x &gt; 1"
    end
  end

  describe "lower/1 - <transition> type" do
    # sabotage: `build_transition/2` replaces
    # `Attributes.put_location(:type, element, "type")` with an
    # unconditional `Map.put/3` that ignores whether `type` was actually
    # written -> the "no key when absent" assertion below reddens
    test "no type attribute defaults to :external, with no attribute_locations key" do
      xml = ~s(<scxml><state id="s"><transition target="s"/></state></scxml>)

      document = lower!(xml)
      transition = only_transition(document)

      assert transition.type == :external
      refute Map.has_key?(transition.attribute_locations, :type)
    end

    # sabotage: `build_transition/2`'s `attribute_locations` update for
    # `:type` is made conditional on `type != :external` (a naive "only
    # record when non-default" reading) -> both this test and the
    # "sideways" test below redden, since `type="external"` written
    # explicitly and an out-of-range value both resolve to the default
    # `:external` and would then wrongly lose their span
    test "type=\"external\" written explicitly still records its span, unlike an absent type" do
      xml = ~s(<scxml><state id="s"><transition target="s" type="external"/></state></scxml>)

      document = lower!(xml)
      transition = only_transition(document)

      assert transition.type == :external
      assert %Location{} = location = Map.fetch!(transition.attribute_locations, :type)
      assert Location.slice(location, xml) == "external"
    end

    # sabotage: `@transition_type_values` is given `"external" => :internal`
    # (swapped) -> this test reddens because `type="internal"` would no
    # longer lower to `:internal`
    test "type=\"internal\" lowers to :internal" do
      xml = ~s(<scxml><state id="s"><transition target="s" type="internal"/></state></scxml>)

      document = lower!(xml)
      transition = only_transition(document)

      assert transition.type == :internal
    end

    # sabotage: see the mutation above (`build_transition/2`'s
    # conditional-on-default `attribute_locations` update for `:type`) ->
    # this test reddens alongside the explicit-"external" one, since an
    # out-of-range `type="sideways"` also resolves to the `:external`
    # default
    test "an unknown type value lowers to the default and keeps its attribute_locations entry" do
      xml = ~s(<scxml><state id="s"><transition target="s" type="sideways"/></state></scxml>)

      document = lower!(xml)
      transition = only_transition(document)

      assert transition.type == :external
      assert Map.has_key?(transition.attribute_locations, :type)
    end
  end

  describe "lower/1 - location" do
    # sabotage: `build_transition/2` sets `location` to a span one byte
    # short of the element's own `end_offset` -> the slice-equality
    # assertion below reddens
    test "a <transition>'s own location covers its whole element" do
      xml = ~s(<scxml><state id="s"><transition target="s"/></state></scxml>)

      document = lower!(xml)
      transition = only_transition(document)

      assert %Transition{} = transition
      assert Location.slice(transition.location, xml) == ~s(<transition target="s"/>)
    end
  end
end
