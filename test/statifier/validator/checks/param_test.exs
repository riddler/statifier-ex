defmodule Statifier.Validator.Checks.ParamTest do
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

  describe "check/2 - param_expr_and_location" do
    # sabotage: `check_param/1`'s expr-and-location clause drops its `when
    # not is_nil(expr) and not is_nil(param_location)` guard, matching every
    # `%DParam{}` and always reporting -> the expr-only, location-only, and
    # empty <param> tests below all gain an error and their {:ok, _}
    # assertions redden
    test "a <param> with both expr and location is reported at the element's own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="done">
              <donedata>
                  <param name="x" expr="1" location="foo.bar"/>
              </donedata>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:param_expr_and_location, "x"}} = error]} = validate!(xml)
      assert error.location.start_line == 4
      assert error.message =~ "x"
    end
  end

  describe "check/2 - param_no_value" do
    # sabotage: `check_param/1`'s no-value clause is dropped, leaving no
    # arm that matches `%DParam{expr: nil, param_location: nil}` -> it falls
    # through to the passing `%DParam{}` catch-all and reports nothing,
    # reddening this assertion
    test "a <param> with neither expr nor location is reported at the element's own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="done">
              <donedata>
                  <param name="x"/>
              </donedata>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:param_no_value, "x"}} = error]} = validate!(xml)
      assert error.location.start_line == 4
      assert error.message =~ "x"
    end
  end

  describe "check/2 - passing shapes" do
    test "a <param> with only expr reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="done">
              <donedata>
                  <param name="x" expr="1"/>
              </donedata>
          </final>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    test "a <param> with only location reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="done">
              <donedata>
                  <param name="x" location="foo.bar"/>
              </donedata>
          </final>
      </scxml>
      """

      assert {:ok, _document} = validate!(xml)
    end

    # sabotage: `params/1`'s `%State{donedata: %Donedata{params: params}}`
    # clause is dropped, leaving only the `%State{}` catch-all returning `[]`
    # -> every <param> in the document goes unwalked, and this multi-error
    # assertion reddens because neither offending <param> is reported
    test "each offending <param> in the document is reported separately" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="first">
              <donedata>
                  <param name="a" expr="1" location="foo"/>
              </donedata>
          </final>
          <final id="second">
              <donedata>
                  <param name="b"/>
              </donedata>
          </final>
      </scxml>
      """

      assert {:error, [first, second]} = validate!(xml)
      assert %Error{reason: {:param_expr_and_location, "a"}} = first
      assert %Error{reason: {:param_no_value, "b"}} = second
      assert first.location.start_line == 4
      assert second.location.start_line == 9
    end

    # sabotage: `flatten/1` stops at the document's top-level states instead
    # of walking nested ones -> the nested <final>'s offending <param> below
    # goes unreported and this assertion reddens
    test "a nested <final>'s params are walked too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="outer">
              <final id="inner">
                  <donedata>
                      <param name="x"/>
                  </donedata>
              </final>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:param_no_value, "x"}} = error]} = validate!(xml)
      assert error.location.start_line == 5
    end
  end
end
