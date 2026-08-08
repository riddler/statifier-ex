defmodule Statifier.Validator.Checks.DonedataTest do
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

  describe "check/2 - donedata_not_on_final" do
    # sabotage: offending?/1's `%State{kind: :final}` clause is dropped ->
    # a <final> with <donedata> is now wrongly reported (falls through to
    # the catch-all `true` clause), reddening this "reports nothing"
    # assertion
    test "<donedata> on a <final> reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="f">
              <donedata/>
          </final>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    # sabotage: offending?/1 gains an erroneous `%State{kind: :state}, do:
    # false` clause alongside the legitimate `:final` exclusion -> a
    # <state> carrying <donedata> is wrongly treated as legal, and this
    # assertion, which expects it to be reported, reddens
    test "<donedata> on a <state> is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <donedata/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:donedata_not_on_final, "s"}} = error]} = validate!(xml)
      assert error.location.start_line == 3
      assert error.message =~ "donedata"
    end

    # sabotage: offending?/1 gains an erroneous `%State{kind: :parallel},
    # do: false` clause alongside the legitimate `:final` exclusion -> a
    # <parallel> carrying <donedata> is wrongly treated as legal, reddening
    # this assertion
    test "<donedata> on a <parallel> is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <parallel id="p">
              <state id="a"/>
              <state id="b"/>
              <donedata/>
          </parallel>
      </scxml>
      """

      assert {:error, [%Error{reason: {:donedata_not_on_final, "p"}} = error]} = validate!(xml)
      assert error.location.start_line == 5
    end

    # sabotage: check/2's `Error.donedata_not_on_final(&1.id, &1.donedata.location)`
    # swaps the location argument to `&1.location` (the state's own span)
    # instead of `&1.donedata.location` -> the reported line moves off the
    # <donedata> element (line 6) onto the <parallel>'s own opening tag
    # (line 2), reddening this assertion
    test "the reported location is the <donedata> element's own span, not the state's" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <parallel id="p">
              <state id="a"/>
              <state id="b"/>

              <donedata/>
          </parallel>
      </scxml>
      """

      assert {:error, [%Error{reason: {:donedata_not_on_final, "p"}} = error]} = validate!(xml)
      assert error.location.start_line == 6
    end
  end
end
