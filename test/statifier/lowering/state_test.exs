defmodule Statifier.Lowering.StateTest do
  use ExUnit.Case, async: true

  alias Statifier.Document
  alias Statifier.Document.Initial
  alias Statifier.Document.State
  alias Statifier.Lowering
  alias Statifier.Lowering.Error
  alias Statifier.Parser

  defp parse!(xml) do
    {:ok, root} = Parser.parse(xml)
    root
  end

  defp lower!(xml) do
    {:ok, document} = xml |> parse!() |> Lowering.lower(xml)
    document
  end

  describe "lower/1 - the state family, happy path" do
    # sabotage: `state_like/3` hardcodes `kind: :state` instead of using its
    # own `kind` argument -> the parallel/final-kind assertions below redden
    test "<state>, <parallel>, and <final> each build a State with the matching kind" do
      xml = """
      <scxml>
          <state id="a"/>
          <parallel id="b"/>
          <final id="c"/>
      </scxml>
      """

      document = lower!(xml)

      assert [
               %State{kind: :state, id: "a"},
               %State{kind: :parallel, id: "b"},
               %State{kind: :final, id: "c"}
             ] = document.states
    end

    # sabotage: `build_history/2` reads `Attributes.value(element, "type")`
    # directly instead of mapping it through `@history_type_values` with
    # `Attributes.atom/4` -> the `:shallow` default assertion below reddens
    # since the raw string `"deep"` (not the atom) would be stored
    test "<history> builds a State with kind: :history and history_type mapped from type" do
      xml = """
      <scxml>
          <state id="a">
              <history id="h" type="deep"/>
          </state>
      </scxml>
      """

      document = lower!(xml)

      assert [%State{states: [%State{kind: :history, id: "h", history_type: :deep}]}] =
               document.states
    end

    # sabotage: `build_history/2`'s `attribute_locations` update replaces
    # `Attributes.put_location/4` with an unconditional `Map.put/3` that
    # ignores whether `type` was actually written -> the "no key when
    # absent" assertion below reddens
    test "<history> with no type defaults to :shallow, with no attribute_locations key" do
      xml = """
      <scxml>
          <history id="h"/>
      </scxml>
      """

      document = lower!(xml)

      assert [%State{kind: :history, history_type: :shallow} = history] = document.states
      refute Map.has_key?(history.attribute_locations, :type)
    end

    # sabotage: `build_history/2`'s `attribute_locations` update is made
    # conditional on `history_type != :shallow` (a naive "only record when
    # non-default" reading) -> both this test and the one below redden,
    # since `type="shallow"` written explicitly and `type="sideways"` both
    # resolve to the default `:shallow` and would then wrongly lose their
    # span
    test "type=\"shallow\" written explicitly still records its span" do
      xml = ~s(<scxml><history id="h" type="shallow"/></scxml>)

      document = lower!(xml)

      assert [%State{history_type: :shallow} = history] = document.states
      assert Map.has_key?(history.attribute_locations, :type)
    end

    # sabotage: see the mutation above (`build_history/2`'s conditional-on-
    # default `attribute_locations` update) -> this test reddens alongside
    # the explicit-"shallow" one, since an out-of-range `type="sideways"`
    # also resolves to the `:shallow` default
    test "an unknown type value lowers to the default and keeps its attribute_locations entry" do
      xml = ~s(<scxml><history id="h" type="sideways"/></scxml>)

      document = lower!(xml)

      assert [%State{history_type: :shallow} = history] = document.states
      assert Map.has_key?(history.attribute_locations, :type)
    end
  end

  describe "lower/1 - nesting" do
    # sabotage: `place/3`'s `{:state, state}, %State{}` clause drops the
    # child instead of prepending it to `parent.states` -> the nested-chain
    # assertion below reddens since every level's `states` comes back empty
    test "a <state> nested three deep builds the full chain" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b">
                  <state id="c"/>
              </state>
          </state>
      </scxml>
      """

      document = lower!(xml)

      assert [
               %State{
                 id: "a",
                 states: [
                   %State{
                     id: "b",
                     states: [
                       %State{id: "c", states: []}
                     ]
                   }
                 ]
               }
             ] = document.states
    end
  end

  describe "lower/1 - initial attribute splitting" do
    # sabotage: `state_like/3` reads `Attributes.value(element, "initial")`
    # instead of `Attributes.list/2` for the `initial` field -> the split
    # assertion below reddens (a raw string instead of a three-element list)
    test "initial=\"a b c\" splits into a three-element list" do
      xml = ~s(<scxml><state id="s" initial="a b c"/></scxml>)

      document = lower!(xml)

      assert [%State{initial: ["a", "b", "c"]}] = document.states
    end

    # sabotage: `place/3`'s `{:initial, initial}, %State{}` clause drops the
    # child instead of setting `parent.initial_element` -> the
    # `initial_element` assertion below reddens (it comes back `nil`)
    test "a <state> with both an initial attribute and an <initial> element is built as written" do
      xml = """
      <scxml>
          <state id="s" initial="a">
              <initial>
                  <transition target="b"/>
              </initial>
              <state id="a"/>
              <state id="b"/>
          </state>
      </scxml>
      """

      document = lower!(xml)

      assert [
               %State{
                 initial: ["a"],
                 initial_element: %Initial{transitions: [%Document.Transition{target: ["b"]}]}
               }
             ] = document.states
    end
  end

  describe "lower/1 - <initial>" do
    # sabotage: `build_initial/2` seeds the accumulator with
    # `transitions: [%Transition{location: element.location}]` instead of
    # the struct's own `[]` default -> the empty-list assertion below
    # reddens even though `<initial/>` has no children at all
    test "an <initial> with zero transitions builds an empty list" do
      xml = """
      <scxml>
          <state id="s">
              <initial/>
              <state id="a"/>
          </state>
      </scxml>
      """

      document = lower!(xml)

      assert [%State{initial_element: %Initial{transitions: []}}] = document.states
    end

    # sabotage: `place/3`'s `{:transition, transition}, %Initial{}` clause
    # drops the child instead of prepending it -> the two-transition
    # assertion below reddens (the list comes back empty) while the
    # zero-transition test above stays green, since it has no children to
    # drop
    test "an <initial> with two transitions builds both, in document order" do
      xml = """
      <scxml>
          <state id="s">
              <initial>
                  <transition target="a"/>
                  <transition target="b"/>
              </initial>
              <state id="a"/>
              <state id="b"/>
          </state>
      </scxml>
      """

      document = lower!(xml)

      assert [
               %State{
                 initial_element: %Initial{
                   transitions: [
                     %Document.Transition{target: ["a"]},
                     %Document.Transition{target: ["b"]}
                   ]
                 }
               }
             ] = document.states
    end
  end

  describe "lower/1 - order preservation" do
    # sabotage: `state_like/3` skips the `Enum.reverse/1` call in
    # `reverse_lists/1` for the `states` and `transitions` slots -> both
    # lists come back reversed, and the interleave-by-offset assertion below
    # reddens
    test "interleaved <transition>/<state>/<transition>/<state> children preserve document order in both slots" do
      xml = """
      <scxml>
          <state id="s">
              <transition event="e1" target="a"/>
              <state id="a"/>
              <transition event="e2" target="b"/>
              <state id="b"/>
          </state>
      </scxml>
      """

      document = lower!(xml)

      assert [%State{states: states, transitions: transitions}] = document.states

      assert [%State{id: "a"}, %State{id: "b"}] = states

      assert [%Document.Transition{event: ["e1"]}, %Document.Transition{event: ["e2"]}] =
               transitions

      state_offsets = Enum.map(states, & &1.location.start_offset)
      transition_offsets = Enum.map(transitions, & &1.location.start_offset)

      assert state_offsets == Enum.sort(state_offsets)
      assert transition_offsets == Enum.sort(transition_offsets)

      # The two lists interleave correctly: each transition precedes the
      # state written right after it in the source.
      assert Enum.at(transition_offsets, 0) < Enum.at(state_offsets, 0)
      assert Enum.at(state_offsets, 0) < Enum.at(transition_offsets, 1)
      assert Enum.at(transition_offsets, 1) < Enum.at(state_offsets, 1)
    end
  end

  describe "lower/1 - misplacement" do
    # sabotage: `place/3`'s catch-all clause is dropped, replaced with a
    # clause that silently ignores unmatched tags (`{parent, nil}`) -> this
    # test reddens because the document lowers successfully instead of
    # reporting an error
    test "a <transition> directly under <scxml> is misplaced" do
      xml = "<scxml><transition target=\"a\"/></scxml>"

      assert {:error, [%Error{reason: {:misplaced_element, "transition", "scxml"}} = error]} =
               xml |> parse!() |> Lowering.lower(xml)

      assert error.location != nil
    end
  end
end
