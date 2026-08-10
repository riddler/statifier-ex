defmodule Statifier.Validator.Checks.IdsTest do
  use ExUnit.Case, async: true

  alias Statifier.Document
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

  describe "check/2 - duplicate ids" do
    # sabotage: check_ids/2 groups states by the state struct itself instead
    # of by `state.id` -> two distinct state structs sharing one id are
    # never grouped together, so the duplicate goes unreported and this
    # reddens
    test "the second occurrence of a repeated id is reported at its own line" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a"/>
          <state id="a"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:duplicate_id, "a"}} = error]} = validate!(xml)
      assert error.location.start_line == 3
    end

    # sabotage: check_ids/2's `duplicate_errors/2` reports the first
    # occurrence (`[first | _rest]` mapped instead of dropped) rather than
    # each later one -> the assertion that exactly two errors are reported,
    # both distinct from the first line, reddens
    test "three occurrences of one id report two errors, not the first" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a"/>
          <state id="a"/>
          <state id="a"/>
      </scxml>
      """

      assert {:error, errors} = validate!(xml)
      assert length(errors) == 2

      lines = Enum.map(errors, & &1.location.start_line)
      assert lines == [3, 4]

      assert Enum.all?(errors, fn error ->
               match?(%Error{reason: {:duplicate_id, "a"}}, error)
             end)
    end

    # sabotage: check_ids/2 drops the `state.id != nil` filter before
    # grouping -> both anonymous states group under the key `nil` and are
    # reported as duplicates of each other, so this reddens
    test "nil ids never collide with each other" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state/>
          <state/>
      </scxml>
      """

      assert {:ok, %Document{}} = validate!(xml)
    end
  end

  describe "check/2 - empty ids" do
    # sabotage: empty_id_errors/1 filters on `state.id == nil` instead of
    # `""` (an earlier reading, where an empty id was just another
    # absent one) -> the state below reports nothing and this reddens
    test "a state written id=\"\" is reported at the attribute's own span" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id=""/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:empty_id}} = error]} = validate!(xml)
      assert error.location.start_line == 2
      assert error.message =~ "empty"
    end

    # sabotage: duplicate_id_errors/1's filter drops `""` from its
    # exclusion list (`state.id != nil`) -> the two empty ids group together
    # as a duplicate pair, adding a third error for one collision that is
    # not one, and the two-element list match reddens
    test "two empty ids are two empty ids, not a duplicate pair" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id=""/>
          <state id=""/>
      </scxml>
      """

      assert {:error, [first, second]} = validate!(xml)
      assert %Error{reason: {:empty_id}} = first
      assert %Error{reason: {:empty_id}} = second
      assert first.location.start_line == 2
      assert second.location.start_line == 3
    end

    # sabotage: empty_id_errors/1 widens its filter to `state.id in [nil,
    # ""]` -> the anonymous state below is reported as an empty id, and the
    # {:ok, _} assertion reddens on the empty-vs-absent distinction this
    # check draws
    test "an absent id is still not an empty one" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state/>
          <state id=""/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:empty_id}} = error]} = validate!(xml)
      assert error.location.start_line == 3
    end
  end

  describe "validate/2 - document-order sort" do
    # sabotage: validate/2 concatenates check results without
    # `Enum.sort_by(&1.location.start_offset)` -> reddens when a nested
    # duplicate is accumulated after a top-level one but sorts earlier
    test "duplicate-id errors across nesting depths come back sorted by offset" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a">
              <state id="b"/>
          </state>
          <state id="b"/>
          <state id="a"/>
      </scxml>
      """

      assert {:error, errors} = validate!(xml)
      assert length(errors) == 2

      offsets = Enum.map(errors, & &1.location.start_offset)
      assert offsets == Enum.sort(offsets)
    end
  end

  describe "validate/2 - a valid document" do
    # sabotage: validate/2's empty-error branch returns
    # `{:ok, %{document | states: []}}` instead of the caller's own
    # `document` -> the identity assertion below reddens
    test "unique ids return {:ok, document}, identical to the input" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a"/>
          <state id="b"/>
      </scxml>
      """

      document = lower!(xml)

      assert {:ok, ^document} = Validator.validate(document, xml)
    end
  end
end
