defmodule Statifier.Validator.Checks.InitialTargetsTest do
  use ExUnit.Case, async: true

  alias Statifier.{Lowering, Parser, Validator}
  alias Statifier.Parser.Location
  alias Statifier.Validator.Checks.InitialTargets
  alias Statifier.Validator.{Context, Error}

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
    # sabotage: Context.inside?/3's `%State{} = parent ->` clause answers
    # false instead of climbing (direct-child membership instead of
    # ancestry) -> a grandchild target is (wrongly) treated as
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

    # sabotage: check_initial_element/2's Enum.filter keeps targets that
    # are not outside?/3 instead of those that are -> the non-descendant
    # target is silently dropped, reddening this
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

  describe "check/2 - a containing state that shares its id" do
    # Two states share the containing state's id. The initial target sits
    # under the OTHER "on_loan", outside the containing state, so it is
    # reported in either document order, from an initial attribute and from
    # an <initial> element (the duplicate itself is check 1's to report, so
    # the check runs alone here; the validate!/1 test below shows both).
    #
    # sabotage: outside?/3 tests a state with an id by id again
    # (`not Context.descendant?(context, state.id, target)` for a non-nil
    # id) -> the target under the other "on_loan" is accepted, reddening the
    # error match below
    test "a containing state with an id is placed by structure when another state shares that id" do
      containing = %{
        attribute: """
            <state id="on_loan" initial="overdue">
                <state id="due"/>
            </state>
        """,
        element: """
            <state id="on_loan">
                <initial>
                    <transition target="overdue"/>
                </initial>
                <state id="due"/>
            </state>
        """
      }

      target = """
          <state id="on_loan">
              <state id="overdue"/>
          </state>
      """

      for shape <- [:attribute, :element], target_first? <- [false, true] do
        body =
          if target_first?, do: target <> containing[shape], else: containing[shape] <> target

        xml = """
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        #{body}</scxml>
        """

        document = lower!(xml)

        assert [%Error{reason: {:initial_not_descendant, "overdue", "on_loan"}}] =
                 InitialTargets.check(document, Context.build(document, xml))
      end
    end

    # The whole validator on the same document: the duplicate id was already
    # refused, and the misplaced initial target now adds its own entry.
    #
    # sabotage: outside?/3 tests a state with an id by id again
    # (`not Context.descendant?(context, state.id, target)` for a non-nil
    # id) -> only the :duplicate_id entry is left, reddening the two-reason
    # match below
    test "a document whose initial target sits under a shared id reports both errors" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="on_loan" initial="overdue">
              <state id="due"/>
          </state>
          <state id="on_loan">
              <state id="overdue"/>
          </state>
      </scxml>
      """

      assert {:error, errors, _warnings} = validate!(xml)

      assert [
               {:duplicate_id, "on_loan"},
               {:initial_not_descendant, "overdue", "on_loan"}
             ] == errors |> Enum.map(& &1.reason) |> Enum.sort()

      assert %Error{location: %Location{start_line: 2}} =
               Enum.find(
                 errors,
                 &match?(%Error{reason: {:initial_not_descendant, "overdue", "on_loan"}}, &1)
               )
    end
  end

  describe "check/2 - a containing state with no id" do
    # sabotage: check/2 keeps `Enum.filter(&(&1.id != nil))` ahead of
    # check_state/2 -> the id-less state is never checked and both
    # documents validate, reddening both error matches below
    # sabotage: outside?/3 answers false -> the
    # target outside the id-less state is accepted, reddening the same
    # matches; and Context.inside?/3's `%Document{} -> false` clause answers
    # true -> the same, reddening the same matches
    test "an initial target outside the state is reported with a nil parent id" do
      attribute_xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state initial="returned">
              <state id="on_loan"/>
          </state>
          <state id="returned"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_not_descendant, "returned", nil}} = error],
              _warnings} = validate!(attribute_xml)

      assert error.location.start_line == 2
      assert error.message =~ "which has no id"

      element_xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state>
              <initial>
                  <transition target="returned"/>
              </initial>
              <state id="on_loan"/>
          </state>
          <state id="returned"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_not_descendant, "returned", nil}} = error],
              _warnings} = validate!(element_xml)

      assert error.location.start_line == 4
    end

    # sabotage: Context.inside?/3's `^ancestor -> true` clause answers false
    # (every chain climbs to the document) -> the grandchild targets under
    # the id-less state are reported as outside it, reddening both {:ok, _}
    # matches below
    test "an initial target inside the state is accepted" do
      attribute_xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state initial="overdue">
              <state id="on_loan">
                  <state id="overdue"/>
              </state>
          </state>
          <state id="returned"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(attribute_xml)

      element_xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state>
              <initial>
                  <transition target="overdue"/>
              </initial>
              <state id="on_loan">
                  <state id="overdue"/>
              </state>
          </state>
          <state id="returned"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(element_xml)
    end

    # sabotage: check_initial_attribute/2 answers [] for an unresolved id on
    # a state with no id (the skip this check used to carry) -> the
    # document validates and compile/2 raises KeyError, reddening the
    # validate match below
    test "an unresolved initial on a state with no id is reported by the missing id" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <state initial="missing">
                  <state id="c"/>
              </state>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:unresolved_initial, "missing"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
      assert {:error, [%Error{reason: {:unresolved_initial, "missing"}}]} = Statifier.compile(xml)
    end

    # sabotage: check_state/2 answers [] for an atomic state with no id (the
    # skip this check used to carry) -> the document validates and
    # compile/2 raises KeyError, reddening the validate match below; and
    # Error's describe_state/1 nil arm answers `state nil` -> the message
    # match reddens
    test "an initial on an atomic state with no id is reported with a nil id" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
          <state id="a">
              <state initial="a"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_on_atomic_state, nil}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
      assert error.message == "a state with no id has no child states to default into"
      assert {:error, [%Error{reason: {:initial_on_atomic_state, nil}}]} = Statifier.compile(xml)
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
    # sabotage: same Enum.filter inversion in
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
