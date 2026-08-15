defmodule Statifier.Validator.Checks.InvokeTest do
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

  describe "check/2 - invoke_type_and_typeexpr" do
    # sabotage: `type_and_typeexpr/2`'s guard drops `not is_nil(typeexpr)`,
    # leaving only `not is_nil(type)` -> `type` alone (no `typeexpr`) is
    # wrongly reported too, reddening the "type alone" branch below
    test "type and typeexpr together are reported; type alone is not" do
      both = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t" typeexpr="TypeVar"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:invoke_type_and_typeexpr}} = error]} = validate!(both)
      assert error.location.start_line == 3

      alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t"/>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(alone)
    end
  end

  describe "check/2 - invoke_src_and_srcexpr" do
    # sabotage: `src_and_srcexpr/2`'s guard drops `not is_nil(src)`,
    # leaving only `not is_nil(srcexpr)` -> `srcexpr` alone (no `src`) is
    # wrongly reported too, reddening the "srcexpr alone" branch below
    test "src and srcexpr together are reported; srcexpr alone is not" do
      both = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t" src="http://example.com" srcexpr="SrcVar"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:invoke_src_and_srcexpr}} = error]} = validate!(both)
      assert error.location.start_line == 3

      alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t" srcexpr="SrcVar"/>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(alone)
    end
  end

  describe "check/2 - invoke_src_and_content" do
    # sabotage: `src_and_content/2`'s guard drops the `not is_nil(src)`
    # disjunct, leaving only `not is_nil(srcexpr)` -> `src` (without
    # `srcexpr`) alongside a `<content>` child is no longer reported,
    # reddening the "src alongside content" branch below
    test "src or srcexpr alongside a <content> child is reported; <content> alone is not" do
      with_src = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t" src="http://example.com">
                  <content>payload</content>
              </invoke>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:invoke_src_and_content}} = error]} = validate!(with_src)
      assert error.location.start_line == 3

      with_srcexpr = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t" srcexpr="SrcVar">
                  <content>payload</content>
              </invoke>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:invoke_src_and_content}}]} = validate!(with_srcexpr)

      content_alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t">
                  <content>payload</content>
              </invoke>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(content_alone)
    end
  end

  describe "check/2 - invoke_id_and_idlocation" do
    # sabotage: `id_and_idlocation/2`'s guard drops `not is_nil(id)`,
    # leaving only `not is_nil(idlocation)` -> `idlocation` alone (no `id`)
    # is wrongly reported too, reddening the "idlocation alone" branch below
    test "id and idlocation together are reported; idlocation alone is not" do
      both = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t" id="myid" idlocation="IdVar"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:invoke_id_and_idlocation}} = error]} = validate!(both)
      assert error.location.start_line == 3

      alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t" idlocation="IdVar"/>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(alone)
    end
  end

  describe "check/2 - invoke_namelist_and_param" do
    # sabotage: `namelist_and_param/2`'s guard drops `params != []`,
    # leaving only `namelist != []` -> `namelist` alone (no `<param>` child)
    # is wrongly reported too, reddening the "namelist alone" branch below
    test "namelist alongside a <param> child is reported; namelist alone is not" do
      both = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t" namelist="a b">
                  <param name="x" expr="1"/>
              </invoke>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:invoke_namelist_and_param}} = error]} = validate!(both)
      assert error.location.start_line == 3

      alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t" namelist="a b"/>
          </state>
      </scxml>
      """

      assert {:ok, _document} = validate!(alone)
    end
  end

  describe "check/2 - collect-all" do
    # sabotage: `check_invoke/1` stops at the first violation
    # (`type_and_typeexpr/2` alone, dropping the other four `++` clauses)
    # -> only one error comes back for an `<invoke>` that trips several,
    # reddening the count assertion below
    test "an <invoke> tripping several constraints reports one error per constraint" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t" typeexpr="TypeVar" id="myid" idlocation="IdVar"
                      namelist="a b">
                  <param name="x" expr="1"/>
              </invoke>
          </state>
      </scxml>
      """

      assert {:error, errors} = validate!(xml)

      reasons = Enum.map(errors, & &1.reason)

      assert {:invoke_type_and_typeexpr} in reasons
      assert {:invoke_id_and_idlocation} in reasons
      assert {:invoke_namelist_and_param} in reasons
      assert length(errors) == 3
    end

    # sabotage: `check/2` drops its `Enum.flat_map(& &1.invoke)` step,
    # walking only `state.donedata`-shaped nodes the way `Checks.Donedata`
    # does -> a document with two offending `<invoke>` elements on two
    # different states reports nothing, reddening this assertion
    test "two <invoke> elements on different states each report their own error" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <invoke type="t" typeexpr="TypeVar"/>
          </state>
          <state id="b">
              <invoke type="t" typeexpr="TypeVar"/>
          </state>
      </scxml>
      """

      assert {:error, errors} = validate!(xml)

      assert Enum.count(errors, &match?(%Error{reason: {:invoke_type_and_typeexpr}}, &1)) == 2
    end
  end
end
