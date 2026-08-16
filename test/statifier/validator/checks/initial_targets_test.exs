defmodule Statifier.Validator.Checks.InitialTargetsTest do
  use ExUnit.Case, async: true

  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Validator
  alias Statifier.Validator.Error

  defp lower!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    document
  end

  defp validate!(xml) do
    Validator.validate(lower!(xml), xml)
  end

  describe "check/2 - unresolved_initial" do
    # sabotage: check_initial_attribute/2's cond inverts
    # `not Map.has_key?(context.states, id)` to `Map.has_key?(...)` -> an
    # unresolved id falls through to the descendancy branch instead,
    # reddening this test, "an unresolved initial reports only
    # unresolved_initial..." below, and "a sibling initial target is
    # reported..." further down (one mutation, three doors)
    test "a state's initial attribute naming a nonexistent state is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a" initial="missing">
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:unresolved_initial, "missing"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 2
    end

    # sabotage: check_document_initial/2's `if` inverts
    # `Map.has_key?(context.states, id)` -> a nonexistent id is (wrongly)
    # treated as resolved and reports nothing, reddening this
    test "the document's own initial naming a nonexistent state is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="missing">
          <state id="a"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:unresolved_initial, "missing"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 1
    end

    # manual verification: one mistake produces one error - an unresolved
    # initial reports :unresolved_initial and never :initial_not_descendant
    # for the same id
    # sabotage: check_initial_attribute/2 tests descendancy before
    # resolution -> an unresolved id reports :initial_not_descendant instead
    # of :unresolved_initial, reddening this assertion
    test "an unresolved initial reports only unresolved_initial, not descendancy" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a" initial="missing">
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:error, [error], _warnings} = validate!(xml)
      assert error.reason == {:unresolved_initial, "missing"}
    end
  end

  describe "check/2 - initial_not_descendant" do
    # sabotage: descendant?/3 (Context) tests direct-child membership
    # instead of ancestry -> a grandchild target is (wrongly) treated as
    # non-descendant, reddening the grandchild assertion below
    test "a sibling initial target is reported, a grandchild target is not" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a" initial="sibling">
              <state id="child">
                  <state id="grandchild"/>
              </state>
          </state>
          <state id="sibling"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_not_descendant, "sibling", "a"}} = error],
              _warnings} =
               validate!(xml)

      assert error.location.start_line == 2

      xml_grandchild = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a" initial="grandchild">
              <state id="child">
                  <state id="grandchild"/>
              </state>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml_grandchild)
    end

    # sabotage: check_initial_element/2's Enum.reject(&Context.descendant?/3)
    # becomes Enum.filter (keeps descendants instead of dropping them) ->
    # the non-descendant target is silently dropped, reddening this
    test "an <initial> element's non-descendant transition target is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <initial>
                  <transition target="sibling"/>
              </initial>
              <state id="child"/>
          </state>
          <state id="sibling"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_not_descendant, "sibling", "a"}} = error],
              _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
    end
  end

  describe "check/2 - a document initial naming a descendant" do
    # spec 3.11's "additional requirement" restricting an `initial` target to
    # descendants of the *containing* state is written for a <state>'s
    # `initial`/<initial> only, never for <scxml>'s - <scxml> has no
    # containing state to be a descendant of, so a document-level `initial`
    # naming a state several levels deep is a legal state specification
    # (spec 3.2.1, 3.11) and reports nothing.
    # sabotage: check_document_initial/2's `if` inverts
    # `Map.has_key?(context.states, id)` -> a resolved-but-nested id is
    # (wrongly) treated as unresolved and reports :unresolved_initial,
    # reddening this assertion
    test "a document initial resolving to a nested state reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="nested">
          <state id="a">
              <state id="nested"/>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    test "a document initial resolving to a top-level state reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - initial_on_atomic_state" do
    # sabotage: check_state/2 concatenates the atomic-state error onto the
    # attribute/element checks unconditionally instead of a cond that stops
    # once the state is atomic -> the atomic state's own initial="b" (which
    # does not resolve either) also reports :unresolved_initial, reddening
    # this test's single-error assertion, "an <initial> element on a
    # :final state is reported" below, and "an atomic state's initial
    # reports only initial_on_atomic_state" further down (one mutation,
    # three doors)
    test "an initial attribute on a state with no children is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a" initial="b"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_on_atomic_state, "a"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 2
    end

    # sabotage: atomic_for_initial?/1 tests `states == []` only, dropping
    # the `kind in [:parallel, :final, :history]` clause -> a non-empty
    # :parallel carrying an initial attribute is no longer treated as
    # atomic, reddening this assertion
    test "an initial attribute on a non-empty :parallel is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <parallel id="a" initial="b">
              <state id="b"/>
              <state id="c"/>
          </parallel>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_on_atomic_state, "a"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 2
    end

    # sabotage: same check_state/2 unconditional-concatenation mutation as
    # above -> the <initial> transition's own target ("a", not a
    # descendant of itself) also reports :initial_not_descendant,
    # reddening this single-error assertion too (one mutation, three doors)
    test "an <initial> element on a :final state is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="a">
              <initial>
                  <transition target="a"/>
              </initial>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_on_atomic_state, "a"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
    end

    # manual verification: an initial on an atomic state reports
    # initial_on_atomic_state only - not unresolved_initial, even though
    # "missing" does not resolve either
    # sabotage: check_state/2's atomic_for_initial? clause appends the
    # normal initial-attribute/element checks instead of suppressing them
    # -> a second error (unresolved_initial or initial_not_descendant)
    # appears alongside initial_on_atomic_state, reddening this assertion
    test "an atomic state's initial reports only initial_on_atomic_state" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a" initial="missing"/>
      </scxml>
      """

      assert {:error, [error], _warnings} = validate!(xml)
      assert error.reason == {:initial_on_atomic_state, "a"}
    end
  end

  describe "check/2 - a valid document" do
    # sabotage: same Enum.filter/Enum.reject inversion in
    # check_initial_element/2 as the non-descendant test above -> the
    # resolved, descendant <initial> target ("d" under "c") is wrongly
    # reported non-descendant, reddening this too (one mutation, two doors)
    test "resolved, descendant initial references report nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a" initial="b">
              <state id="b"/>
              <state id="c">
                  <initial>
                      <transition target="d"/>
                  </initial>
                  <state id="d"/>
              </state>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end
end
