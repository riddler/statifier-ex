defmodule Statifier.Validator.Checks.ParamTest do
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

      assert {:error, [%Error{reason: {:param_expr_and_location, "x"}} = error], _warnings} =
               validate!(xml)

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

      assert {:error, [%Error{reason: {:param_no_value, "x"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
      assert error.message =~ "x"
    end
  end

  describe "check/2 - passing shapes" do
    # sabotage: `check_param/1`'s final `%DParam{}) -> []` catch-all is
    # changed to always report `param_no_value` -> this and the
    # location-only test below both redden, since a passing single-attribute
    # `<param>` now gets an error where `{:ok, _}` was expected
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

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: same mutation as the expr-only test above, reddening this
    # test in the same way for the location-only shape
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

      assert {:ok, _document, _warnings} = validate!(xml)
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

      assert {:error, [first, second], _warnings} = validate!(xml)
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

      assert {:error, [%Error{reason: {:param_no_value, "x"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 5
    end

    # sabotage: `params/1`'s new `Enum.flat_map(invokes, & &1.params)` half
    # is dropped, leaving only `donedata_params(donedata)` -> an offending
    # `<param>` under `<invoke>` goes unwalked, reddening this assertion
    test "an offending <param> under <invoke> is reported too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t">
                  <param name="x"/>
              </invoke>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:param_no_value, "x"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
    end
  end

  describe "check/2 - <param> under <send>" do
    # sabotage: `check/2`'s `++ send_params(document)` arm is dropped, so
    # only donedata and invoke params are walked -> the `<send>`'s
    # attribute-less `<param>` goes unreported and the {:error, _} match
    # reddens
    test "a <send> <param> with neither expr nor location is reported at the element's own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="lending">
              <onentry>
                  <send event="loan.requested">
                      <param name="copies"/>
                  </send>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:param_no_value, "copies"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 5
    end

    # sabotage: the same dropped `++ send_params(document)` arm -> the
    # transition's `<send>` `<param>` carrying both attributes goes
    # unreported and the {:error, _} match reddens
    test "a <send> <param> with both expr and location is reported at the element's own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id="copies" expr="2"/>
          </datamodel>
          <state id="lending">
              <transition event="return">
                  <send event="loan.returned">
                      <param name="copies" expr="1" location="copies"/>
                  </send>
              </transition>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:param_expr_and_location, "copies"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 8
    end

    # sabotage: `Checks.Send.sends/1`'s `descend/1` stops at the top of a
    # block (its `%DIf{}` clause returns `[]`) -> the `<send>` nested in the
    # `<if>` is never reached and the {:error, _} match reddens
    test "a <send> nested in an <if> inside <onexit> has its <param> walked too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="lending">
              <onexit>
                  <if cond="true">
                      <send event="loan.closed">
                          <param name="copies"/>
                      </send>
                  </if>
              </onexit>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:param_no_value, "copies"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 6
    end

    # sabotage: `send_params/1` maps every `<send>` `<param>` to a
    # `param_no_value` error instead of passing it to `check_param/1` ->
    # both well-formed params below are reported and the {:ok, _} match
    # reddens
    test "a <send> <param> with only expr or only location reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id="stock" expr="3"/>
          </datamodel>
          <state id="lending">
              <onentry>
                  <send event="loan.requested">
                      <param name="copies" expr="2"/>
                      <param name="stock" location="stock"/>
                  </send>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: `Checks.Send.descend/1`'s `%DForeach{}` clause is dropped,
    # so a `<foreach>` falls to the catch-all and is filtered out as a
    # non-`<send>` -> the `<send>` in its body is never reached and the
    # {:error, _} match reddens
    test "a <send> inside a <foreach> body has its <param> walked too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id="shelf" expr="[1, 2]"/>
              <data id="book"/>
          </datamodel>
          <state id="lending">
              <onentry>
                  <foreach array="shelf" item="book">
                      <send event="loan.requested">
                          <param name="copies"/>
                      </send>
                  </foreach>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:param_no_value, "copies"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 10
    end

    # sabotage: `Checks.Send.sends_of/1`'s `invoke_finalize_sends(state.invoke)`
    # arm is dropped -> the `<send>` inside the `<invoke>`'s `<finalize>` is
    # never reached and the {:error, _} match reddens
    test "a <send> inside an <invoke>'s <finalize> has its <param> walked too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="lending">
              <invoke type="loan.check">
                  <finalize>
                      <send event="loan.checked">
                          <param name="copies"/>
                      </send>
                  </finalize>
              </invoke>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:param_no_value, "copies"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 6
    end

    # sabotage: `Checks.Send.sends_of/1`'s `initial_sends(state.initial_element)`
    # arm is dropped -> the `<send>` on the `<initial>` element's transition
    # is never reached and the {:error, _} match reddens
    test "a <send> on an <initial> element's transition has its <param> walked too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="lending">
              <initial>
                  <transition target="open">
                      <send event="loan.opened">
                          <param name="copies"/>
                      </send>
                  </transition>
              </initial>
              <state id="open"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:param_no_value, "copies"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 6
    end

    # sabotage: a `defp sends_of(%State{kind: :history}), do: []` clause is
    # added ahead of `Checks.Send.sends_of/1`'s own, so the walk skips a
    # `<history>` state -> the `<send>` on its default transition is never
    # reached and the {:error, _} match reddens
    test "a <send> on a <history> default transition has its <param> walked too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="lending">
              <state id="open"/>
              <history id="resume">
                  <transition target="open">
                      <send event="loan.resumed">
                          <param name="copies"/>
                      </send>
                  </transition>
              </history>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:param_no_value, "copies"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 7
    end
  end
end
