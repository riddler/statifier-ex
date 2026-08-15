defmodule Statifier.Validator.Checks.TargetsTest do
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

  describe "check/2 - unresolved targets" do
    # sabotage: unresolved_errors/2 uses Enum.filter instead of
    # Enum.reject when testing Context.states membership (inverts the
    # resolved test) -> an unresolved target reports nothing, reddening
    # this assertion
    test "a plain transition's unresolved target is reported at its own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <transition target="missing"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:unresolved_target, "missing"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
    end

    # sabotage: same Enum.filter/Enum.reject inversion as the test above ->
    # a resolved target is reported unresolved, reddening this assertion
    # too (one mutation, two doors)
    test "a resolved plain transition target reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <transition target="b"/>
          </state>
          <state id="b"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: Context.own_transitions/1 (Context.build/2) drops the
    # `initial_element` arm of the transition walk -> Context.transitions
    # never includes the <initial> transition below, so this reddens
    test "an <initial> element's unresolved target is reported at its own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <initial>
                  <transition target="missing"/>
              </initial>
              <state id="b"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:unresolved_target, "missing"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
    end

    # sabotage: check/2 skips the {:history, _} owner arm of the transition
    # walk entirely -> the history state's unresolved target goes
    # unreported, reddening this assertion
    test "a history state's unresolved default target is reported at its own line" do
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

      assert {:error, [%Error{reason: {:unresolved_target, "missing"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 5
    end

    # sabotage: unresolved_errors/2 rejects the whole transition when any
    # id is unresolved instead of mapping each unresolved id on its own ->
    # only one of the two unresolved ids below is reported, reddening the
    # two-error assertion
    test "reports one error per unresolved id when target lists several" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <transition target="missing1 missing2"/>
          </state>
      </scxml>
      """

      assert {:error, errors, _warnings} = validate!(xml)
      assert length(errors) == 2

      reasons = Enum.map(errors, & &1.reason)
      assert {:unresolved_target, "missing1"} in reasons
      assert {:unresolved_target, "missing2"} in reasons
    end
  end
end
