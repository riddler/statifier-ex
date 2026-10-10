defmodule Statifier.Validator.Checks.HistoryTest do
  use ExUnit.Case, async: true

  alias Statifier.Document.State
  alias Statifier.{Lowering, Parser, Validator}
  alias Statifier.Parser.Location
  alias Statifier.Validator.Checks.History
  alias Statifier.Validator.{Context, Error}

  defp lower!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    document
  end

  defp validate!(xml) do
    Validator.validate(lower!(xml), xml)
  end

  describe "Context.compound?/1" do
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

    # sabotage: compound?/1 drops :state from its kind list (keeping only
    # :parallel) -> a childful :state is wrongly treated as not compound,
    # reddening the :state assertion below
    test "a :state or :parallel with children is compound" do
      location = Location.at_offset("", 0)
      child = %State{kind: :state, location: location, id: "child"}

      assert Context.compound?(%State{kind: :state, location: location, states: [child]})
      assert Context.compound?(%State{kind: :parallel, location: location, states: [child]})
    end

    # sabotage: compound?/1 adds :final to its kind list -> a childful
    # :final is wrongly treated as compound, reddening the :final refute
    test "a :final or :history is never compound, regardless of children" do
      location = Location.at_offset("", 0)
      child = %State{kind: :state, location: location, id: "child"}

      refute Context.compound?(%State{kind: :final, location: location, states: [child]})
      refute Context.compound?(%State{kind: :history, location: location, states: [child]})
    end
  end

  describe "check/2 - history_bad_parent" do
    # sabotage: compound_parent?/1's %Document{} clause flips false to
    # true -> the document root is wrongly treated as a compound parent,
    # reddening this assertion
    test "a history at the document root is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <history id="h">
              <transition target="a"/>
          </history>
          <state id="a"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:history_bad_parent, "h", :scxml}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 2
    end

    # sabotage: compound?/1 adds :final to its kind list -> a <final> with
    # a history child is wrongly treated as a compound parent, reddening
    # this assertion (same mutation as the Context.compound?/1 :final test).
    # A <final> with any state child - including a <history> - also trips
    # check 6 (Statifier.Validator.Checks.Final), so this fixture reports
    # two errors; `find/2` isolates the one this describe block is about.
    test "a history under a <final> is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a"/>
          <final id="f">
              <history id="h">
                  <transition target="a"/>
              </history>
          </final>
      </scxml>
      """

      assert {:error, errors, _warnings} = validate!(xml)
      assert %Error{reason: {:history_bad_parent, "h", :final}} = error = find(errors, "h")
      assert error.location.start_line == 4
    end

    # sabotage: compound_parent?/1 gains a %State{kind: :history} clause
    # returning true -> a history-under-history is wrongly treated as a
    # compound parent, reddening this assertion
    test "a history under another history is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
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

      assert {:error, errors, _warnings} = validate!(xml)
      assert %Error{reason: {:history_bad_parent, "inner", :history}} = find(errors, "inner")
    end

    # sabotage: compound?/1 drops :state from its kind list -> a compound
    # <state> parent is wrongly treated as not compound, and the history
    # gets an unwanted :history_bad_parent, reddening this assertion (same
    # mutation as the "a :state ... is compound" test above)
    test "a history under a compound <state> reports nothing from this check" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b"/>
              <history id="h">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: compound_parent?/1 gains a %State{kind: :parallel} clause
    # returning false -> a <parallel> parent is wrongly treated as not
    # compound, reddening this assertion
    test "a history under a <parallel> reports nothing from this check" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <parallel id="p">
              <state id="a"/>
              <state id="b"/>
              <history id="h">
                  <transition target="a"/>
              </history>
          </parallel>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - transition_count (shared sub-check)" do
    # sabotage: DefaultTransition.count_errors/3 matches `0 -> []` instead
    # of `1 -> []` -> a history with zero transitions is (wrongly) treated
    # as fine, reddening this assertion (spec 3.10 requires the default
    # transition unconditionally)
    test "a history with zero transitions is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b"/>
              <history id="h"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:transition_count, {:history, "h"}, 0}} = error],
              _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
    end
  end

  describe "check/2 - message naming" do
    # sabotage: compound?/1 drops :state from its kind list -> the fixture's
    # compound-<state> parent is wrongly treated as not compound, adding
    # an unwanted second error and reddening the single-error match below
    # (same underlying mutation as the "a :state ... is compound" test)
    test "the shared sub-check's message names <history>, not <initial>" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b"/>
              <history id="h"/>
          </state>
      </scxml>
      """

      assert {:error, [error], _warnings} = validate!(xml)
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
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b"/>
              <history id="h">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: target_descendancy_errors/3's Enum.reject(&Context.descendant?/3)
    # becomes Enum.filter (keeps descendants instead of dropping them) ->
    # the non-descendant target below is silently dropped, reddening this
    test "a default target outside the history's parent is reported against the parent" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b"/>
              <history id="h">
                  <transition target="outside"/>
              </history>
          </state>
          <state id="outside"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_not_descendant, "outside", "a"}} = error],
              _warnings} =
               validate!(xml)

      assert error.location.start_line == 5
    end

    # sabotage: compound?/1 drops :state from its kind list -> the
    # fixture's compound-<state> parent is wrongly treated as not
    # compound, adding an unwanted :history_bad_parent alongside
    # :unresolved_target and reddening the single-error match below (same
    # underlying mutation as the "a :state ... is compound" test)
    test "an unresolved default target is reported only by check 2, not descendancy" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b"/>
              <history id="h">
                  <transition target="missing"/>
              </history>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:unresolved_target, "missing"}}], _warnings} =
               validate!(xml)
    end

    # Two states share the parent's id. The target sits under the OTHER
    # "on_loan", outside the history's own parent, so it is reported in
    # either document order (the duplicate itself is check 1's to report,
    # so the check runs alone here; the validate!/1 test below shows both).
    #
    # sabotage: resolved_outside?/3 tests an id-ful parent by id again
    # (`Context.descendant?(context, parent.id, target)`) -> the target under
    # the other "on_loan" is accepted, reddening the error match below
    test "a parent with an id is placed by structure when another state shares that id" do
      for {first, second} <- [{:history, :target}, {:target, :history}] do
        states = %{
          history: """
              <state id="on_loan">
                  <state id="due"/>
                  <history id="loan_history">
                      <transition target="overdue"/>
                  </history>
              </state>
          """,
          target: """
              <state id="on_loan">
                  <state id="overdue"/>
              </state>
          """
        }

        xml = """
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        #{states[first]}#{states[second]}</scxml>
        """

        document = lower!(xml)

        assert [%Error{reason: {:initial_not_descendant, "overdue", "on_loan"}}] =
                 History.check(document, Context.build(document, xml))
      end
    end

    # The whole validator on the same document: the duplicate id was already
    # refused, and the misplaced default target now adds its own entry.
    #
    # sabotage: resolved_outside?/3 tests an id-ful parent by id again
    # (`Context.descendant?(context, parent.id, target)`) -> only the
    # :duplicate_id entry is left, reddening the two-reason match below
    test "a document whose history target sits under a shared id reports both errors" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="on_loan">
              <state id="due"/>
              <history id="loan_history">
                  <transition target="overdue"/>
              </history>
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

      assert %Error{location: %Location{start_line: 5}} =
               Enum.find(
                 errors,
                 &match?(%Error{reason: {:initial_not_descendant, "overdue", "on_loan"}}, &1)
               )
    end

    # The same shape with the shared id written empty: each `id=""` was
    # already refused as empty, and the misplaced default target adds its
    # own entry, naming the parent by its empty id.
    #
    # sabotage: resolved_outside?/3 tests an id-ful parent by id again
    # (`Context.descendant?(context, parent.id, target)`) -> only the two
    # :empty_id entries are left, reddening the three-reason match below
    test "a document whose history target sits under a shared empty id reports both errors" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="">
              <state id="due"/>
              <history id="loan_history">
                  <transition target="overdue"/>
              </history>
          </state>
          <state id="">
              <state id="overdue"/>
          </state>
      </scxml>
      """

      assert {:error, errors, _warnings} = validate!(xml)

      assert [
               {:empty_id},
               {:empty_id},
               {:initial_not_descendant, "overdue", ""}
             ] == errors |> Enum.map(& &1.reason) |> Enum.sort()

      assert %Error{location: %Location{start_line: 5}} =
               Enum.find(
                 errors,
                 &match?(%Error{reason: {:initial_not_descendant, "overdue", ""}}, &1)
               )
    end

    # sabotage: Context.inside?/3's `^ancestor -> true` clause answers false
    # (every parent chain climbs to the document) -> the grandchild target under
    # the id-less parent is reported as outside it, reddening the {:ok, _}
    # assertion below
    test "a default target inside a parent with no id is accepted" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state>
              <state id="on_loan">
                  <state id="due"/>
              </state>
              <history id="loan_history">
                  <transition target="due"/>
              </history>
          </state>
          <state id="returned"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: Context.inside?/3's `%Document{} -> false` clause answers true
    # (the document counts as the parent) -> the target outside the id-less
    # parent is accepted, reddening the error match below; and
    # describe_parent(nil) in Error renders `inspect(nil)` -> the message
    # reads "a descendant of nil", reddening the message assertion
    test "a default target outside a parent with no id is reported with a nil parent id" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state>
              <state id="on_loan"/>
              <history id="loan_history">
                  <transition target="returned"/>
              </history>
          </state>
          <state>
              <state id="returned"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:initial_not_descendant, "returned", nil}} = error],
              _warnings} =
               validate!(xml)

      assert error.location.start_line == 5
      assert error.message =~ "which has no id"
    end
  end

  describe "check/2 - history_bad_type" do
    # sabotage: type_errors/2 compares `history_type` (the already-lowered
    # atom, which silently defaults to :shallow for any out-of-range value)
    # instead of slicing the raw attribute span -> type="sideways" no
    # longer trips the check, reddening this assertion
    test "type=\"sideways\" is reported with the raw source text" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b"/>
              <history id="h" type="sideways">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:history_bad_type, "sideways"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
    end

    # sabotage: compound?/1 drops :state from its kind list -> the
    # fixture's compound-<state> parent is wrongly treated as not
    # compound, adding an unwanted :history_bad_parent and reddening this
    # {:ok, _} assertion (same underlying mutation as the "a :state ...
    # is compound" test)
    test "type=\"deep\" reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b"/>
              <history id="h" type="deep">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: compound?/1 drops :state from its kind list -> the
    # fixture's compound-<state> parent is wrongly treated as not
    # compound, adding an unwanted :history_bad_parent and reddening this
    # {:ok, _} assertion (same underlying mutation as the "a :state ...
    # is compound" test)
    test "type=\"shallow\" reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b"/>
              <history id="h" type="shallow">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: compound?/1 drops :state from its kind list -> the
    # fixture's compound-<state> parent is wrongly treated as not
    # compound, adding an unwanted :history_bad_parent and reddening this
    # {:ok, _} assertion (same underlying mutation as the "a :state ...
    # is compound" test)
    test "an absent type attribute reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b"/>
              <history id="h">
                  <transition target="b"/>
              </history>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  defp find(errors, id) do
    Enum.find(errors, fn %Error{reason: reason} -> elem(reason, 1) == id end)
  end
end
