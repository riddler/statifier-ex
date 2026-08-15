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

      assert {:ok, _document, _warnings} = validate!(xml)
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

      assert {:error, [%Error{reason: {:donedata_not_on_final, "s"}} = error], _warnings} =
               validate!(xml)

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

      assert {:error, [%Error{reason: {:donedata_not_on_final, "p"}} = error], _warnings} =
               validate!(xml)

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

      assert {:error, [%Error{reason: {:donedata_not_on_final, "p"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 6
    end
  end

  describe "check/2 - donedata_content_and_params" do
    # sabotage: `content_and_params?/1`'s `%Donedata{content: nil}` clause
    # is dropped, leaving only the `%Donedata{params: []}` clause and the
    # catch-all `true` -> a <donedata> with only <param> children (no
    # <content>) is wrongly reported, reddening this "reports nothing"
    # assertion
    test "<donedata> with only <param> children reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="f">
              <donedata>
                  <param name="x" expr="1"/>
              </donedata>
          </final>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: `content_and_params?/1`'s `%Donedata{params: []}` clause is
    # dropped, leaving only the `%Donedata{content: nil}` clause and the
    # catch-all `true` -> a <donedata> with only <content> (no <param>) is
    # wrongly reported, reddening this "reports nothing" assertion
    test "<donedata> with only <content> reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="f">
              <donedata>
                  <content expr="1"/>
              </donedata>
          </final>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: `content_and_params?/1`'s catch-all `%Donedata{}, do: true`
    # clause is changed to `false` -> a <donedata> carrying both <content>
    # and <param> is wrongly treated as legal, reddening this assertion
    test "<donedata> with both <content> and <param> is reported at the donedata's own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="f">
              <donedata>
                  <content expr="1"/>
                  <param name="x" expr="2"/>
              </donedata>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:donedata_content_and_params, "f"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
      assert error.message =~ "donedata"
    end

    # sabotage: `donedatas/1`'s `%State{donedata: nil}` clause is dropped,
    # crashing the `%DDonedata{}` clause's pattern match against `nil`
    # instead of returning `[]` -> a document with a `<final>` carrying no
    # `<donedata>` at all would raise instead of validating cleanly,
    # reddening this assertion
    test "a <final> with no <donedata> reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="f"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end
end
