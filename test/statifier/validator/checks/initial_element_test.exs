defmodule Statifier.Validator.Checks.InitialElementTest do
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

  describe "check/2 - initial_attribute_and_element" do
    # sabotage: both_forms_errors/1's second clause guard `initial != []`
    # inverts to `initial == []` -> a state carrying both forms no longer
    # matches, reddening this assertion
    test "a state carrying both an initial attribute and an <initial> element is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a" initial="b">
              <initial>
                  <transition target="b"/>
              </initial>
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_attribute_and_element, "a"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
    end

    # sabotage: check/2's filter widens from `initial_element != nil` to
    # also include `initial != []` -> a state with only the attribute is
    # now scanned, and both_forms_errors/1 crashes on its nil
    # initial_element (reddens for the right reason: the check should
    # never look at this state at all)
    test "a state carrying only an initial attribute reports nothing from this check" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a" initial="b">
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: both_forms_errors/1 drops its `%State{initial: []}` clause
    # -> a state carrying only the <initial> element is now unconditionally
    # reported as carrying both forms, reddening this assertion
    test "a state carrying only an <initial> element reports nothing from this check" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <initial>
                  <transition target="b"/>
              </initial>
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - transition_count (shared sub-check)" do
    # sabotage: count_errors/3 (DefaultTransition) matches `0 -> []` instead
    # of `1 -> []` -> a zero-transition <initial> is (wrongly) treated as
    # fine, reddening this assertion
    test "an <initial> element with no transition is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <initial/>
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:transition_count, {:initial, "a"}, 0}} = error],
              _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
    end

    # sabotage: both_forms_errors/1 drops its `%State{initial: []}` clause
    # -> the fixture's own state now also wrongly reports
    # :initial_attribute_and_element alongside :transition_count,
    # reddening the single-error match below (same underlying mutation as
    # the "only <initial> element" test)
    test "an <initial> element with two transitions is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <initial>
                  <transition target="b"/>
                  <transition target="c"/>
              </initial>
              <state id="b"/>
              <state id="c"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:transition_count, {:initial, "a"}, 2}} = error],
              _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
    end

    # sabotage: both_forms_errors/1 drops its `%State{initial: []}` clause
    # -> the fixture's state wrongly reports :initial_attribute_and_element,
    # reddening this {:ok, _} assertion (same underlying mutation as the
    # "only <initial> element" test)
    test "an <initial> element with exactly one transition reports nothing from this check" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <initial>
                  <transition target="b"/>
              </initial>
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - transition_missing_target (shared sub-check)" do
    # sabotage: missing_target_errors/2's first clause pattern
    # `%Transition{target: []}` widens to match any transition -> a
    # transition that does carry a target is also reported missing one,
    # reddening this test's single-error assertion (and would also redden
    # the valid-document tests above)
    test "an <initial> element's transition with no target is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <initial>
                  <transition/>
              </initial>
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:transition_missing_target, {:initial, "a"}}} = error],
              _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
    end
  end

  describe "check/2 - transition_forbidden_attribute (shared sub-check)" do
    # sabotage: forbidden?/2's :event clause tests
    # `transition.event != []` instead of
    # `Map.has_key?(attribute_locations, :event)` -> `event=""` no longer
    # trips the check (its event list is `[]` same as absent), reddening
    # this assertion
    test "an <initial> element's transition with event=\"\" is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <initial>
                  <transition event="" target="b"/>
              </initial>
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:error,
              [
                %Error{
                  reason: {:transition_forbidden_attribute, {:initial, "a"}, :event}
                } = error
              ], _warnings} = validate!(xml)

      assert error.location.start_line == 4
    end

    # sabotage: forbidden?/2's :cond clause inverts `cond != nil` to
    # `cond == nil` -> a written cond is no longer treated as forbidden,
    # reddening this assertion
    test "an <initial> element's transition with a cond is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <initial>
                  <transition cond="true" target="b"/>
              </initial>
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:error,
              [
                %Error{
                  reason: {:transition_forbidden_attribute, {:initial, "a"}, :cond}
                } = error
              ], _warnings} = validate!(xml)

      assert error.location.start_line == 4
    end

    # sabotage: both_forms_errors/1 drops its `%State{initial: []}` clause
    # -> the fixture's state wrongly reports :initial_attribute_and_element,
    # reddening this {:ok, _} assertion (same underlying mutation as the
    # "only <initial> element" test)
    test "an <initial> element's transition with neither event nor cond reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <initial>
                  <transition target="b"/>
              </initial>
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - message naming" do
    # sabotage: both_forms_errors/1 drops its `%State{initial: []}` clause
    # -> the fixture's state wrongly reports a second error alongside
    # :transition_count, reddening the single-error match below (same
    # underlying mutation as the "only <initial> element" test)
    test "the shared sub-check's message names <initial>, not <history>" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <initial/>
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:error, [error], _warnings} = validate!(xml)
      assert error.message =~ "<initial>"
      refute error.message =~ "<history>"
    end
  end
end
