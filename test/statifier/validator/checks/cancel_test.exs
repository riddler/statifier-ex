defmodule Statifier.Validator.Checks.CancelTest do
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

  describe "check/2 - cancel_sendid_and_sendidexpr" do
    # sabotage: `check_cancel/1`'s both-present clause's guard drops `not
    # is_nil(sendidexpr)`, leaving only `not is_nil(sendid)` -> `sendid`
    # alone (no `sendidexpr`) is wrongly reported too, reddening the
    # "sendid alone" branch below
    test "sendid and sendidexpr together are reported; sendid alone is not" do
      both = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <cancel sendid="send_1" sendidexpr="SendIdVar"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:cancel_sendid_and_sendidexpr}} = error], _warnings} =
               validate!(both)

      assert error.location.start_line == 4

      alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <cancel sendid="send_1"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(alone)
    end
  end

  describe "check/2 - cancel_no_sendid" do
    # sabotage: `check_cancel/1`'s neither-present clause is dropped
    # (falling through to the catch-all `check_cancel(%DCancel{}), do: []`)
    # -> a `<cancel>` with neither `sendid` nor `sendidexpr` is silently
    # accepted, reddening this assertion
    test "a <cancel> with neither sendid nor sendidexpr is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <cancel/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:cancel_no_sendid}} = error], _warnings} = validate!(xml)

      assert error.location.start_line == 4
    end

    # sabotage: `check_cancel/1`'s `sendidexpr` alone case is left unmatched
    # by the catch-all reordering (the neither-present clause's guard is
    # loosened to `sendid: nil` alone, dropping `sendidexpr: nil`) -> a
    # `<cancel sendidexpr="...">` with no `sendid` is wrongly reported,
    # reddening this assertion
    test "sendidexpr alone is not reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <cancel sendidexpr="SendIdVar"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - reach" do
    # sabotage: `cancels_of/1` drops its `transition_cancels(state.transitions)`
    # clause -> a `<cancel>` inside a `<transition>` is invisible, reddening
    # this assertion
    test "a <cancel> inside a <transition> is reached" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <transition event="go" target="s">
                  <cancel/>
              </transition>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:cancel_no_sendid}}], _warnings} = validate!(xml)
    end

    # sabotage: `descend/1`'s `%DIf{branches: branches}` clause is dropped
    # (only the `%DForeach{}` clause and the `other` fallback survive) -> a
    # `<cancel>` nested inside an `<if>` branch is invisible, reddening this
    # assertion
    test "a <cancel> nested inside an <if> branch is reached" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <if cond="a">
                      <cancel/>
                  </if>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:cancel_no_sendid}}], _warnings} = validate!(xml)
    end

    # sabotage: `cancels_of/1` drops its `invoke_finalize_cancels(state.invoke)`
    # clause -> a `<cancel>` inside an `<invoke>`'s `<finalize>` block is
    # invisible, reddening this assertion
    test "a <cancel> inside an <invoke>'s <finalize> is reached" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t">
                  <finalize>
                      <cancel/>
                  </finalize>
              </invoke>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:cancel_no_sendid}}], _warnings} = validate!(xml)
    end
  end

  describe "check/2 - collect-all" do
    # sabotage: `check/2` gains an `Enum.take(1)` between `flatten/1` and
    # `Enum.flat_map(&cancels_of/1)`, walking only the first flattened state
    # -> a document with two offending `<cancel>` elements on two different
    # states reports fewer than two errors, reddening this assertion
    test "two <cancel> elements on different states each report their own error" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <onentry>
                  <cancel/>
              </onentry>
          </state>
          <state id="b">
              <onentry>
                  <cancel/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, errors, _warnings} = validate!(xml)

      assert Enum.count(errors, &match?(%Error{reason: {:cancel_no_sendid}}, &1)) == 2
    end
  end
end
