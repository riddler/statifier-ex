defmodule Statifier.Validator.Checks.SendTest do
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

  describe "check/2 - send_event_and_eventexpr" do
    # sabotage: `event_and_eventexpr/2`'s guard drops `not is_nil(eventexpr)`,
    # leaving only `not is_nil(event)` -> `event` alone (no `eventexpr`) is
    # wrongly reported too, reddening the "event alone" branch below
    test "event and eventexpr together are reported; event alone is not" do
      both = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" eventexpr="EventVar"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:send_event_and_eventexpr}} = error], _warnings} =
               validate!(both)

      assert error.location.start_line == 4

      alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(alone)
    end
  end

  describe "check/2 - send_target_and_targetexpr" do
    # sabotage: `target_and_targetexpr/2`'s guard drops `not is_nil(targetexpr)`,
    # leaving only `not is_nil(target)` -> `target` alone (no `targetexpr`)
    # is wrongly reported too, reddening the "target alone" branch below
    test "target and targetexpr together are reported; target alone is not" do
      both = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" target="#_internal" targetexpr="TargetVar"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:send_target_and_targetexpr}} = error], _warnings} =
               validate!(both)

      assert error.location.start_line == 4

      alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" target="#_internal"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(alone)
    end
  end

  describe "check/2 - send_type_and_typeexpr" do
    # sabotage: `type_and_typeexpr/2`'s guard drops `not is_nil(typeexpr)`,
    # leaving only `not is_nil(type)` -> `type` alone (no `typeexpr`) is
    # wrongly reported too, reddening the "type alone" branch below
    test "type and typeexpr together are reported; type alone is not" do
      both = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" type="t" typeexpr="TypeVar"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:send_type_and_typeexpr}} = error], _warnings} =
               validate!(both)

      assert error.location.start_line == 4

      alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" type="t"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(alone)
    end
  end

  describe "check/2 - send_id_and_idlocation" do
    # sabotage: `id_and_idlocation/2`'s guard drops `not is_nil(id)`,
    # leaving only `not is_nil(idlocation)` -> `idlocation` alone (no `id`)
    # is wrongly reported too, reddening the "idlocation alone" branch below
    test "id and idlocation together are reported; idlocation alone is not" do
      both = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" id="myid" idlocation="IdVar"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:send_id_and_idlocation}} = error], _warnings} =
               validate!(both)

      assert error.location.start_line == 4

      alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" idlocation="IdVar"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(alone)
    end
  end

  describe "check/2 - send_delay_and_delayexpr" do
    # sabotage: `delay_and_delayexpr/2`'s guard drops `not is_nil(delayexpr)`,
    # leaving only `not is_nil(delay)` -> `delay` alone (no `delayexpr`) is
    # wrongly reported too, reddening the "delay alone" branch below
    test "delay and delayexpr together are reported; delay alone is not" do
      both = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" delay="1s" delayexpr="DelayVar"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:send_delay_and_delayexpr}} = error], _warnings} =
               validate!(both)

      assert error.location.start_line == 4

      alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" delay="1s"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(alone)
    end
  end

  describe "check/2 - send_delay_and_internal_target" do
    # sabotage: `delay_and_internal_target/2`'s guard is changed from `when
    # not is_nil(delay) or not is_nil(delayexpr)` to `when not is_nil(delay)
    # and not is_nil(delayexpr)` -> a lone `delay` with a literal
    # `target="_internal"` (no `delayexpr`) is no longer reported, reddening
    # the "delay alone" branch below
    test "delay with a literal target=\"_internal\" is reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" delay="1s" target="_internal"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:send_delay_and_internal_target}} = error], _warnings} =
               validate!(xml)

      assert error.location.start_line == 4
    end

    # sabotage: the clause's `target: "_internal"` literal match is
    # loosened to bind `target` instead (`target: target`) with no further
    # guard -> a `delay` alongside any other literal `target` value is
    # wrongly reported, reddening this assertion
    test "delay with a literal target other than \"_internal\" is not reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" delay="1s" target="#other"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end

    # sabotage: `delay_and_internal_target/2`'s head is changed to match on
    # `targetexpr: "_internal"` in addition to `target: "_internal"` -> a
    # `delay` alongside a dynamic `targetexpr` is wrongly reported, even
    # though the value cannot be known until execute time, reddening this
    # assertion
    test "delay with a targetexpr (not a literal target) is not reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" delay="1s" targetexpr="TargetVar"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - send_namelist_and_content" do
    # sabotage: `namelist_and_content/2`'s guard drops `not is_nil(content)`,
    # leaving only `namelist != []` -> a `namelist` with no `<content>`
    # child is wrongly reported too, reddening the "namelist alone" branch
    # below
    test "namelist alongside a <content> child is reported; namelist alone is not" do
      both = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" namelist="a b">
                      <content>payload</content>
                  </send>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:send_namelist_and_content}} = error], _warnings} =
               validate!(both)

      assert error.location.start_line == 4

      alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" namelist="a b"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(alone)
    end
  end

  describe "check/2 - send_param_and_content" do
    # sabotage: `param_and_content/2`'s guard drops `not is_nil(content)`,
    # leaving only `params != []` -> a `<param>` child with no `<content>`
    # child is wrongly reported too, reddening the "param alone" branch
    # below
    test "a <param> child alongside a <content> child is reported; <param> alone is not" do
      both = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e">
                      <param name="x" expr="1"/>
                      <content>payload</content>
                  </send>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:send_param_and_content}} = error], _warnings} =
               validate!(both)

      assert error.location.start_line == 4

      alone = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e">
                      <param name="x" expr="1"/>
                  </send>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(alone)
    end
  end

  describe "check/2 - deliberately not enforced" do
    # sabotage: n/a - this test only pins the documented omission (no
    # three-way event/eventexpr/<content> constraint); it is not exercising
    # a mutation of lib/ code, it is exercising the *absence* of a check
    # this bead deliberately does not add
    test "event alongside a <content> child (the message payload) is not reported" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e">
                      <content>payload</content>
                  </send>
              </onentry>
          </state>
      </scxml>
      """

      assert {:ok, _document, _warnings} = validate!(xml)
    end
  end

  describe "check/2 - collect-all" do
    # sabotage: `check_send/1` stops at the first violation
    # (`event_and_eventexpr/2` alone, dropping the other seven `++`
    # clauses) -> only one error comes back for a `<send>` that trips
    # several, reddening the count assertion below
    test "a <send> tripping several constraints reports one error per constraint" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" eventexpr="EventVar" id="myid" idlocation="IdVar"
                        delay="1s" delayexpr="DelayVar"/>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, errors, _warnings} = validate!(xml)

      reasons = Enum.map(errors, & &1.reason)

      assert {:send_event_and_eventexpr} in reasons
      assert {:send_id_and_idlocation} in reasons
      assert {:send_delay_and_delayexpr} in reasons
      assert length(errors) == 3
    end

    # sabotage: `sends_of/1` drops its `transition_sends(state.transitions)`
    # clause -> a `<send>` inside a `<transition>` is invisible, reddening
    # this assertion
    test "two <send> elements in different blocks each report their own error" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <send event="e" eventexpr="EventVar"/>
              </onentry>
              <transition event="go" target="s">
                  <send event="e" eventexpr="EventVar"/>
              </transition>
          </state>
      </scxml>
      """

      assert {:error, errors, _warnings} = validate!(xml)

      assert Enum.count(errors, &match?(%Error{reason: {:send_event_and_eventexpr}}, &1)) == 2
    end
  end

  describe "check/2 - reach" do
    # sabotage: `sends_of/1` drops its `initial_sends(state.initial_element)`
    # clause -> a `<send>` inside an `<initial>` element's own transition is
    # invisible, reddening this assertion
    test "a <send> inside an <initial> element's transition is reached" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <initial>
                  <transition target="t">
                      <send event="e" eventexpr="EventVar"/>
                  </transition>
              </initial>
              <state id="t"/>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:send_event_and_eventexpr}}], _warnings} = validate!(xml)
    end

    # sabotage: `descend/1`'s `%DForeach{content: content}` clause is
    # dropped (only `%DIf{}` and the `other` fallback survive) -> a `<send>`
    # nested inside a `<foreach>` body is invisible, reddening this
    # assertion
    test "a <send> nested inside a <foreach> body is reached" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <onentry>
                  <foreach array="[1, 2]" item="x">
                      <send event="e" eventexpr="EventVar"/>
                  </foreach>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:send_event_and_eventexpr}}], _warnings} = validate!(xml)
    end

    # sabotage: `sends_of/1` drops its `invoke_finalize_sends(state.invoke)`
    # clause -> a `<send>` nested inside an `<if>` branch inside
    # `<finalize>` is invisible, reddening this assertion
    test "a <send> nested inside an <if> branch inside <finalize> is reached" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <invoke type="t">
                  <finalize>
                      <if cond="a">
                          <send event="e" eventexpr="EventVar"/>
                      </if>
                  </finalize>
              </invoke>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:send_event_and_eventexpr}}], [warning]} = validate!(xml)
      assert warning.reason == {:finalize_forbidden_content, "send"}
    end
  end
end
