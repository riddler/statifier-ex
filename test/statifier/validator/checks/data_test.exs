defmodule Statifier.Validator.Checks.DataTest do
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

  describe "check/2 - data_expr_and_src" do
    # sabotage: expr_and_src_errors/1's `%Data{src: nil}, do: []` clause is
    # dropped -> a <data> with both expr and src still falls through to the
    # `[]` clause via the first `%Data{expr: nil}` match failing and no
    # matching clause reporting it, so this reddens
    test "a <data> with both expr and src is reported at its own id span" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id="x" expr="1" src="foo.txt"/>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:data_expr_and_src, "x"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
      assert error.message =~ "x"
    end

    # sabotage: expr_and_src_errors/1's guard clauses are widened so a
    # <data> with only expr (no src) is treated the same as one with both
    # -> the {:ok, _} assertion below reddens
    test "a <data> with only expr reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id="x" expr="1"/>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: same as above, mirrored for src alone
    test "a <data> with only src reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id="x" src="foo.txt"/>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - data_value_and_children" do
    # sabotage: value_and_children_errors/1's `blank?(text)` call is
    # inverted to `not blank?(text)` -> non-blank child text alongside expr
    # is treated as blank and reports nothing, reddening this assertion
    test "a <data> with expr and non-blank child text is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id="x" expr="1">hello</data>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:data_value_and_children, "x"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
    end

    # sabotage: blank?/1's `String.trim(text) == ""` becomes
    # `text == ""` (no trim) -> whitespace-only child text alongside expr is
    # wrongly treated as non-blank, reddening this {:ok, _} assertion
    test "a <data> with expr and whitespace-only child text reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id="x" expr="1">
              </data>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: value_and_children_errors/1's `%Data{expr: nil, src: nil},
    # do: []` guard clause is dropped -> a <data> with neither expr nor src,
    # only child text, is wrongly reported, reddening this {:ok, _}
    # assertion
    test "a <data> with only child content (no expr or src) reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id="x">hello</data>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - data_reserved_id" do
    # sabotage: reserved_id_errors/1's `String.starts_with?(id, "_")` is
    # inverted to `not String.starts_with?(id, "_")` -> a reserved id
    # reports nothing, reddening this assertion
    test "a <data id> beginning with an underscore is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id="_reserved" expr="1"/>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:data_reserved_id, "_reserved"}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 3
      assert error.message =~ "_reserved"
    end

    # sabotage: same inversion as above - an ordinary id would be wrongly
    # reported too, reddening this {:ok, _} assertion
    test "a <data id> not beginning with an underscore reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id="ordinary" expr="1"/>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - datamodel_bad_parent" do
    # sabotage: bad_parent?/1's `kind in [:final, :history]` guard is
    # narrowed to `kind == :history` only -> a <datamodel> on a <final>
    # state is wrongly treated as legal, reddening this assertion
    test "a <datamodel> on a <final> state is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <transition event="e" target="f"/>
          </state>
          <final id="f">
              <datamodel>
                  <data id="x" expr="1"/>
              </datamodel>
          </final>
      </scxml>
      """

      assert {:error, [%Error{reason: {:datamodel_bad_parent, :final}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 6
    end

    # sabotage: same guard narrowing as above, mirrored for :history
    test "a <datamodel> on a <history> state is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <state id="a"/>
              <state id="b"/>
              <history id="h">
                  <datamodel>
                      <data id="x" expr="1"/>
                  </datamodel>
                  <transition target="a"/>
              </history>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:datamodel_bad_parent, :history}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 6
    end

    # sabotage: bad_parent?/1's `kind in [:final, :history]` guard is
    # widened to include `:state` -> a legal <datamodel> on a plain
    # <state> is wrongly reported, reddening this {:ok, _} assertion
    test "a <datamodel> on a <state> reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <datamodel>
                  <data id="x" expr="1"/>
              </datamodel>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: same widening as above, mirrored for :parallel
    test "a <datamodel> on a <parallel> reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <parallel id="p">
              <datamodel>
                  <data id="x" expr="1"/>
              </datamodel>
              <state id="a"/>
              <state id="b"/>
          </parallel>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: same widening as above, checking the document root
    test "a <datamodel> at the document root reports nothing" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id="x" expr="1"/>
          </datamodel>
          <state id="s"/>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end
end
