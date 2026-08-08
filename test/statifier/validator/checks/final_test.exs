defmodule Statifier.Validator.Checks.FinalTest do
  use ExUnit.Case, async: true

  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Validator
  alias Statifier.Validator.Error

  defp lower!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
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

      assert {:error, [%Error{reason: {:final_has_states, "s"}} = error]} = validate!(xml)
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

      assert {:ok, _document} = validate!(xml)
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

      assert {:error, errors} = validate!(xml)
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

      assert {:error, [%Error{reason: {:final_has_states, "inner"}} = error]} = validate!(xml)
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

      assert {:error, [%Error{reason: {:final_has_states, "s"}} = error]} = validate!(xml)
      assert error.location.start_line == 3
    end
  end

  defp find(errors, id) do
    Enum.find(errors, fn %Error{reason: reason} -> elem(reason, 1) == id end)
  end
end
