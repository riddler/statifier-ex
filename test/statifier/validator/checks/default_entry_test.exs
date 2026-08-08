defmodule Statifier.Validator.Checks.DefaultEntryTest do
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

  describe "check/2 - default_entry_not_enterable" do
    # sabotage: check_state/1 drops its `id:` binding and reports `nil`
    # unconditionally (`Error.default_entry_not_enterable(nil, :history,
    # first.location)`) -> the reason's id no longer matches "a", reddening
    # this assertion
    test "a compound state whose only child is a <history> is reported" do
      xml = """
      <scxml>
          <state id="a">
              <history id="h">
                  <transition target="b"/>
              </history>
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:error, errors} = validate!(xml)

      assert %Error{reason: {:default_entry_not_enterable, "a", :history}} =
               error =
               find(errors, "a")

      assert error.location.start_line == 3
    end

    # sabotage: candidate?/1 drops the `initial_element: nil` conjunct ->
    # a state with an explicit <initial> element is wrongly treated as a
    # default-entry candidate even though it has one, and since its own
    # `states` first child is a <history>, this fixture wrongly gains a
    # :default_entry_not_enterable error, reddening this "reports nothing"
    # assertion
    test "an explicit <initial> element pointing past a first-child history reports nothing" do
      xml = """
      <scxml>
          <state id="a">
              <initial>
                  <transition target="b"/>
              </initial>
              <history id="h">
                  <transition target="b"/>
              </history>
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    # sabotage: candidate?/1's `states: [_first | _rest]` non-empty guard is
    # dropped (matches any `states`, including `[]`), and check_state/1's
    # fallback `%State{}, do: []` clause is removed, leaving only the
    # history-first clause -> an atomic state's `states: []` now reaches
    # check_state/1 with no matching clause, raising FunctionClauseError
    # instead of quietly reporting nothing, reddening this assertion
    test "an atomic state (empty states, no initial) reports nothing from check 7" do
      xml = """
      <scxml>
          <state id="a"/>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    # sabotage: check_state/1's `[%State{kind: :history} = first | _rest]`
    # head-only match is replaced with `Enum.find(states, &(&1.kind ==
    # :history))`, scanning the whole list instead of only the first
    # element -> a compound state whose *second* child is a <history>
    # (first child a real <state>) wrongly reports
    # :default_entry_not_enterable, reddening this "reports nothing"
    # assertion
    test "a compound state whose first child is a <state> and second a <history> reports nothing" do
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
