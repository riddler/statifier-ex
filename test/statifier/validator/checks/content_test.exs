defmodule Statifier.Validator.Checks.ContentTest do
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

  describe "check/2 - content_expr_and_text" do
    # sabotage: check_content/1 drops its `%Content{expr: nil}` head and
    # reports whenever `text` is non-blank -> every static <content> in the
    # suite gains an error, and here the reason's quoted expr goes wrong
    # first: this assertion reddens on the <content> below being reported
    # only because of the expr it actually carries
    test "a <content> with both expr and text is reported at the element's own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="done">
              <donedata>
                  <content expr="payload">literal</content>
              </donedata>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:content_expr_and_text, "payload"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
      assert error.message =~ "expr"
    end

    # sabotage: check_content/1 reports whenever `expr` is non-nil,
    # regardless of `text` -> this expr-only <content> gains an error and
    # the {:ok, _} assertion reddens
    test "a <content> with only an expr reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="done">
              <donedata>
                  <content expr="payload"/>
              </donedata>
          </final>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: check_content/1 reports whenever `text` is non-blank,
    # regardless of `expr` -> this text-only <content> gains an error and
    # the {:ok, _} assertion reddens
    test "a <content> with only text reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="done">
              <donedata>
                  <content>literal</content>
              </donedata>
          </final>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: blank?/1 tests `text == ""` instead of trimming ->
    # DOM.text/1's verbatim, untrimmed concatenation of the newline and
    # indentation below counts as a payload, so this pretty-printed but
    # legal <content> gains an error and the {:ok, _} assertion reddens
    test "whitespace-only text alongside an expr reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="done">
              <donedata>
                  <content expr="payload">
                  </content>
              </donedata>
          </final>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: contents/1 returns only the first offending state's content
    # (`List.first` over the flat_map) -> the second <final> below goes
    # unreported and the two-element list match reddens
    test "each offending <content> in the document is reported separately" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <final id="first">
              <donedata>
                  <content expr="a">one</content>
              </donedata>
          </final>
          <final id="second">
              <donedata>
                  <content expr="b">two</content>
              </donedata>
          </final>
      </scxml>
      """

      assert {:error, [first, second], _warnings} = validate!(xml)
      assert %Error{reason: {:content_expr_and_text, "a"}} = first
      assert %Error{reason: {:content_expr_and_text, "b"}} = second
      assert first.location.start_line == 4
      assert second.location.start_line == 9
    end

    # sabotage: contents/1 stops at the document's top-level states instead
    # of walking `flatten/1`'s nested ones -> the nested <final> below goes
    # unreported and this assertion reddens
    test "a nested <final>'s content is walked too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="outer">
              <final id="inner">
                  <donedata>
                      <content expr="payload">literal</content>
                  </donedata>
              </final>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:content_expr_and_text, "payload"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 5
    end

    # sabotage: `contents/1`'s new `invoke_content(invokes)` half is
    # dropped, leaving only `donedata_content(donedata)` -> an offending
    # `<content>` under `<invoke>` goes unwalked, reddening this assertion
    test "an offending <content> under <invoke> is reported too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t">
                  <content expr="payload">literal</content>
              </invoke>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:content_expr_and_text, "payload"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
    end

    # sabotage: check_content/1 drops the `is_nil(markup)` half of the guard
    # and keeps only `blank?(text)` -> the markup below carries no direct
    # text child, so `blank?(text)` reads true and the
    # {:content_expr_and_text, _} match reddens to {:ok, _}
    test "a <content> with both expr and markup is reported at the element's own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t">
                  <content expr="payload"><scxml version="1.0"/></content>
              </invoke>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:content_expr_and_text, "payload"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
      assert error.message =~ "expr"
    end

    # sabotage: check_content/1 drops its `%Content{expr: nil}` head clause,
    # so every call (nil expr included) falls into the two-arg clause ->
    # this markup-only, expr-nil <content> now reports
    # {:content_expr_and_text, nil} and the {:ok, _} match reddens
    test "a <content> with only markup reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t">
                  <content><scxml version="1.0"/></content>
              </invoke>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: check_content/1's guard uses `or` instead of `and`
    # (`if is_nil(markup) or blank?(text)`) -> markup is non-nil but the
    # whitespace-only text below is blank, so the `or` reads true and the
    # {:content_expr_and_text, _} match reddens to {:ok, _}
    test "whitespace around markup with an expr present still reports" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t">
                  <content expr="payload">
                      <scxml version="1.0"/>
                  </content>
              </invoke>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:content_expr_and_text, "payload"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
    end
  end
end
