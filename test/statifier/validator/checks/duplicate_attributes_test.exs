defmodule Statifier.Validator.Checks.DuplicateAttributesTest do
  use ExUnit.Case, async: true

  alias Statifier.{Document, Lowering, Parser, Validator}
  alias Statifier.Parser.Location
  alias Statifier.Validator.Error

  defp lower!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    document
  end

  defp validate!(xml) do
    Validator.validate(lower!(xml), xml)
  end

  describe "check/2 - duplicate_attribute" do
    # sabotage: `tag_errors/1` never reports (the `MapSet.member?/2` branch
    # returns `{errors, seen}` unchanged) -> the repeated `event` validates
    # and this reddens
    test "a repeated attribute is refused at its second occurrence; the same tag without it is not" do
      repeated = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="loaned">
          <state id="loaned">
              <transition event="renew" event="return" target="returned"/>
          </state>
          <final id="returned"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:duplicate_attribute, "transition", "event"}} = error],
              _warnings} = validate!(repeated)

      assert Error.code(error.reason) == :duplicate_attribute
      assert error.message == ~s(duplicate attribute "event" on <transition>)
      assert Location.slice(error.location, repeated) == ~s(event="return")
      assert error.location.start_line == 3
      assert error.location.start_column == 35

      single = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="loaned">
          <state id="loaned">
              <transition event="return" target="returned"/>
          </state>
          <final id="returned"/>
      </scxml>
      """

      assert {:ok, %Document{}, _warnings} = validate!(single)
    end

    # sabotage: `tag_errors/1` adds every name to `seen` before testing it
    # (`MapSet.put/2` ahead of `MapSet.member?/2`) -> the first occurrence
    # is reported too, so three errors arrive and this reddens
    test "three occurrences of one attribute report two errors, never the first" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="on_hold" id="loaned" id="returned"/>
      </scxml>
      """

      assert {:error, errors, _warnings} = validate!(xml)

      assert [
               %Error{reason: {:duplicate_attribute, "state", "id"}} = second,
               %Error{reason: {:duplicate_attribute, "state", "id"}} = third
             ] = errors

      assert Location.slice(second.location, xml) == ~s(id="loaned")
      assert Location.slice(third.location, xml) == ~s(id="returned")
    end

    # sabotage: `check/2` pools every tag's attributes into one list before
    # `tag_errors/1` -> the `<final>`'s `id` reads as a repeat of the
    # `<state>`'s and this reddens
    test "one name on two different tags, and two names on one tag, are not repeats" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="loaned">
          <state id="loaned">
              <transition event="return" cond="true" target="returned"/>
          </state>
          <final id="returned"/>
      </scxml>
      """

      assert {:ok, %Document{}, _warnings} = validate!(xml)
    end

    # sabotage: `check/2` scans only the first start tag (`Enum.take(1)`
    # after the filter) -> the repeat inside `<content>` validates and this
    # reddens
    test "a repeat inside inline content markup is refused too" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="loaned">
              <onentry>
                  <send event="checked_out">
                      <content><copy id="c-1" id="c-2"/></content>
                  </send>
              </onentry>
          </state>
      </scxml>
      """

      assert {:error, [%Error{reason: {:duplicate_attribute, "copy", "id"}} = error], _warnings} =
               validate!(xml)

      assert Location.slice(error.location, xml) == ~s(id="c-2")
    end

    # sabotage: `Statifier.Validator`'s `@checks` list drops
    # `&DuplicateAttributes.check/2` -> `compile/2` answers `{:ok, machine}`
    # and this reddens
    test "Statifier.compile/2 refuses the document" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="loaned" initial="returned">
          <state id="loaned"/>
          <final id="returned"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:duplicate_attribute, "scxml", "initial"}}]} =
               Statifier.compile(xml)
    end
  end
end
