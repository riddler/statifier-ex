defmodule Statifier.Validator.Checks.FinalTest do
  use ExUnit.Case, async: true

  alias Statifier.{Lowering, Parser, Validator}
  alias Statifier.Validator.Error

  defp lower!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    document
  end

  defp validate!(xml) do
    Validator.validate(lower!(xml), xml)
  end

  describe "check/2 - final_has_states" do
    # sabotage: check_final/1 reports the parent <final>'s own id and
    # location instead of the child's (`Error.final_has_states(final.id,
    # final.location)`) -> both the reason's id ("f" instead of "s") and
    # the start_line assertion below redden
    test "a <final> with a <state> child is reported at the child's location" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="f">
              <state id="s"/>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:final_has_states, "s"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
      assert error.message =~ "final"
    end

    # sabotage: check/2's filter widens from `kind == :final` to
    # `kind in [:final, :parallel]` -> a <parallel> (which is a legal
    # compound parent, not a <final>) starts getting scanned, and since it
    # has a <state> child unconditionally, a spurious error appears -
    # reddening this "reports nothing" assertion by adding an unwanted one
    test "a <parallel> with state children reports nothing from this check" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <parallel id="p">
              <state id="a"/>
              <state id="b"/>
          </parallel>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: check_final/1 reports the parent <final>'s own id instead
    # of each child's -> both errors' reasons carry "f" instead of "a" and
    # "b", so `find(errors, "a")` and `find(errors, "b")` both return nil,
    # reddening this assertion (same mutation as the id/location swap
    # above, exercised against two children instead of one)
    test "a <final> with multiple state children is reported once per child" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="f">
              <state id="a"/>
              <state id="b"/>
          </final>
      </scxml>
      """

      assert {:error, errors, _warnings} = validate!(xml)
      assert length(errors) == 2
      assert %Error{reason: {:final_has_states, "a"}} = find(errors, "a")
      assert %Error{reason: {:final_has_states, "b"}} = find(errors, "b")
    end

    # sabotage: check_final/1 reports the parent <final>'s own id instead
    # of the nested <final> child's -> the reason carries "f" instead of
    # "inner", reddening this assertion (same id/location-swap mutation as
    # above, exercised against a <final>-kind child instead of a <state>)
    test "a <final> with a <final> child is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="f">
              <final id="inner"/>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:final_has_states, "inner"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
    end

    # sabotage: check_final/1 reports the parent <final>'s own id (`nil`
    # here) instead of the child's -> the reason carries `nil` instead of
    # "s", reddening this assertion (same id/location-swap mutation as
    # above, exercised against a nil-id <final>)
    test "a <final> with no id and a state child is still reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final>
              <state id="s"/>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:final_has_states, "s"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
    end
  end

  describe "check/2 - final_has_transitions" do
    # sabotage: check_final/1 drops its `transitions` arm, reporting only
    # state children as it originally did -> the <final> below
    # produces no error at all and validate!/1 returns {:ok, _}, reddening
    # this assertion
    test "a <transition> on a <final> is reported at the transition's own span" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a"/>
          <final id="done">
              <transition event="e" target="a"/>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:final_has_transitions, "done"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
    end

    # sabotage: check_final/1's transitions arm reports `transition.location`
    # once for the whole state (`Enum.map` replaced with a single
    # `List.first` lookup) -> only one error comes back instead of two,
    # reddening the two-element list match
    test "each transition on a <final> is reported separately" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a"/>
          <final id="done">
              <transition event="e" target="a"/>
              <transition event="f" target="a"/>
          </final>
      </scxml>
      """

      assert {:error, [first, second], _warnings} = validate!(xml)
      assert %Error{reason: {:final_has_transitions, "done"}} = first
      assert %Error{reason: {:final_has_transitions, "done"}} = second
      assert first.location.start_line == 4
      assert second.location.start_line == 5
    end

    # sabotage: check_final/1's transitions arm passes a literal `nil`
    # instead of `state.id` -> the reason no longer names the <final> the
    # transition sits on, reddening this assertion
    test "the reported id names the <final>, not the transition" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a"/>
          <final id="the_end">
              <transition target="a"/>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:final_has_transitions, "the_end"}}], _warnings} =
               validate!(xml)
    end

    # sabotage: check_final/1 grows an `initial` arm of its own (reporting
    # whenever `state.initial != []`), the duplication this module's
    # moduledoc says it deliberately avoids -> the <final> below reports
    # both check 3's error and this module's, so the single-element list
    # match goes red on two errors for one mistake
    test "an initial attribute on a <final> stays check 3's error, not this one" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="done" initial="a"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_on_atomic_state, "done"}}], _warnings} =
               validate!(xml)
    end

    # sabotage: check_final/1's transitions arm drops its `Enum.map` guard on
    # the empty list and reports one error unconditionally (`[Error.
    # final_has_transitions(state.id, state.location)]`) -> this legal
    # <final> gains a spurious error, reddening the {:ok, _} assertion
    test "a <final> with only onentry, onexit, and donedata reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="done">
              <onentry><log label="x"/></onentry>
              <onexit><log label="y"/></onexit>
              <donedata><content>bye</content></donedata>
          </final>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  defp find(errors, id) do
    Enum.find(errors, fn %Error{reason: reason} -> elem(reason, 1) == id end)
  end
end
