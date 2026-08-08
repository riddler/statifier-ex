defmodule Statifier.Validator.Checks.HistoryTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.State
  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Parser.Location
  alias Statifier.Validator
  alias Statifier.Validator.Context
  alias Statifier.Validator.Error

  defp lower!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    document
  end

  defp validate!(xml) do
    Validator.validate(lower!(xml), xml)
  end

  describe "Context.compound?/1 (Decision 6)" do
    # A <state> whose only child is a <history> cannot be represented as
    # "atomic" through an XML fixture: the history itself is a member of
    # its parent's `states` list, so `states != []` is trivially satisfied
    # by construction the moment a history has any parent at all - there is
    # no reachable document where a real history's parent has `states ==
    # []`. compound?/1's `states != []` conjunct is exercised directly here
    # instead.
    #
    # sabotage: compound?/1 drops the `states != []` conjunct, leaving only
    # `kind in [:state, :parallel]` -> a childless :state is wrongly
    # treated as compound, reddening this assertion
    test "a :state or :parallel with no children is not compound" do
      location = Location.at_offset("", 0)

      refute Context.compound?(%State{kind: :state, location: location, states: []})
      refute Context.compound?(%State{kind: :parallel, location: location, states: []})
    end

    test "a :state or :parallel with children is compound" do
      location = Location.at_offset("", 0)
      child = %State{kind: :state, location: location, id: "child"}

      assert Context.compound?(%State{kind: :state, location: location, states: [child]})
      assert Context.compound?(%State{kind: :parallel, location: location, states: [child]})
    end

    test "a :final or :history is never compound, regardless of children" do
      location = Location.at_offset("", 0)
      child = %State{kind: :state, location: location, id: "child"}

      refute Context.compound?(%State{kind: :final, location: location, states: [child]})
      refute Context.compound?(%State{kind: :history, location: location, states: [child]})
    end
  end

  describe "check/2 - history_bad_parent" do
    test "a history at the document root is reported" do
      xml = """
      <scxml>
          <history id="h">
              <transition target="a"/>
          </history>
          <state id="a"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:history_bad_parent, "h", :scxml}} = error]} =
               validate!(xml)

      assert error.location.start_line == 2
    end

    test "a history under a <final> is reported" do
      xml = """
      <scxml>
          <state id="a"/>
          <final id="f">
              <history id="h">
                  <transition target="a"/>
              </history>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:history_bad_parent, "h", :final}} = error]} =
               validate!(xml)

      assert error.location.start_line == 4
    end

    test "a history under another history is reported" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
              <history id="outer">
                  <transition target="b"/>
                  <history id="inner">
                      <transition target="b"/>
                  </history>
              </history>
          </state>
      </scxml>
      """

      assert {:error, errors} = validate!(xml)
      assert %Error{reason: {:history_bad_parent, "inner", :history}} = find(errors, "inner")
    end

    test "a history under a compound <state> reports nothing from this check" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
              <history id="h">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    test "a history under a <parallel> reports nothing from this check" do
      xml = """
      <scxml>
          <parallel id="p">
              <state id="a"/>
              <state id="b"/>
              <history id="h">
                  <transition target="a"/>
              </history>
          </parallel>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end
  end

  describe "check/2 - transition_count (shared sub-check)" do
    # sabotage: DefaultTransition.count_errors/3 matches `0 -> []` instead
    # of `1 -> []` -> a history with zero transitions is (wrongly) treated
    # as fine, reddening this assertion (Decision 8's spec-over-bead call)
    test "a history with zero transitions is reported" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
              <history id="h"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:transition_count, {:history, "h"}, 0}} = error]} =
               validate!(xml)

      assert error.location.start_line == 4
    end
  end

  describe "check/2 - message naming" do
    test "the shared sub-check's message names <history>, not <initial>" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
              <history id="h"/>
          </state>
      </scxml>
      """

      assert {:error, [error]} = validate!(xml)
      assert error.message =~ "<history>"
      refute error.message =~ "<initial>"
    end
  end

  describe "check/2 - initial_not_descendant (default-target descendancy)" do
    # sabotage: target_descendancy_errors/3 tests descendancy against the
    # history state's own id ("h") instead of its parent's ("a") -> "b" is
    # a descendant of "a" but not of "h" (which has no children at all), so
    # this wrongly reports :initial_not_descendant, reddening the
    # "reports nothing" assertion below
    test "a default target that is a sibling of the history under its parent reports nothing" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
              <history id="h">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    # sabotage: target_descendancy_errors/3's Enum.reject(&Context.descendant?/3)
    # becomes Enum.filter (keeps descendants instead of dropping them) ->
    # the non-descendant target below is silently dropped, reddening this
    test "a default target outside the history's parent is reported against the parent" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
              <history id="h">
                  <transition target="outside"/>
              </history>
          </state>
          <state id="outside"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_not_descendant, "outside", "a"}} = error]} =
               validate!(xml)

      assert error.location.start_line == 5
    end

    test "an unresolved default target is reported only by check 2, not descendancy" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
              <history id="h">
                  <transition target="missing"/>
              </history>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:unresolved_target, "missing"}}]} = validate!(xml)
    end
  end

  describe "check/2 - history_bad_type" do
    # sabotage: type_errors/2 compares `history_type` (the already-lowered
    # atom, which silently defaults to :shallow for any out-of-range value)
    # instead of slicing the raw attribute span -> type="sideways" no
    # longer trips the check, reddening this assertion
    test "type=\"sideways\" is reported with the raw source text" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
              <history id="h" type="sideways">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:history_bad_type, "sideways"}} = error]} = validate!(xml)
      assert error.location.start_line == 4
    end

    test "type=\"deep\" reports nothing" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
              <history id="h" type="deep">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    test "type=\"shallow\" reports nothing" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
              <history id="h" type="shallow">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    test "an absent type attribute reports nothing" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
              <history id="h">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end
  end

  defp find(errors, id) do
    Enum.find(errors, fn %Error{reason: reason} -> elem(reason, 1) == id end)
  end
end
