defmodule Statifier.Validator.Checks.IdsTest do
  use ExUnit.Case, async: true

  alias Statifier.Document
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

      assert {:error, [%Error{reason: {:duplicate_id, "a"}} = error], _warnings} = validate!(xml)
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

      assert {:error, errors, _warnings} = validate!(xml)
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

      assert {:ok, %Document{}, _warnings} = validate!(xml)
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

      assert {:error, [%Error{reason: {:empty_id}} = error], _warnings} = validate!(xml)
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

      assert {:error, [first, second], _warnings} = validate!(xml)
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

      assert {:error, [%Error{reason: {:empty_id}} = error], _warnings} = validate!(xml)
      assert error.location.start_line == 3
    end
  end

  describe "check/2 - <data> ids share the state id namespace" do
    # sabotage: state_entries/1 drops the `datamodel_entries(state.datamodel_element)`
    # collection from its list, so a <data> id never joins the uniqueness
    # set at all -> the colliding <data id="a"> below goes unreported,
    # reddening this assertion
    test "a <data id> colliding with an earlier <state id> is reported at the <data>" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="a"/>
          <datamodel>
              <data id="a" expr="1"/>
          </datamodel>
      </scxml>
      """

      assert {:error, [%Error{reason: {:duplicate_id, "a"}} = error], _warnings} = validate!(xml)
      assert error.location.start_line == 4
    end

    # sabotage: datamodel_entries/1's `Datamodel{data: data}` clause maps
    # each entry to `{nil, id_location(data)}` instead of `{data.id, ...}`
    # -> two distinct <data> ids never collide with each other, and this
    # assertion (which expects exactly that collision) reddens
    test "two <data> ids in different <datamodel>s collide with each other" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <datamodel>
                  <data id="x" expr="1"/>
              </datamodel>
          </state>
          <datamodel>
              <data id="x" expr="2"/>
          </datamodel>
      </scxml>
      """

      assert {:error, [%Error{reason: {:duplicate_id, "x"}} = error], _warnings} = validate!(xml)
      assert error.location.start_line == 8
    end

    # sabotage: entries/2 drops the `datamodel_entries(root_datamodel)` half
    # of its collection -> a root-level <data id=""> never reaches
    # empty_id_errors/1, reddening this assertion
    test "a <data id=\"\"> is reported as empty, like a state's" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <datamodel>
              <data id=""/>
          </datamodel>
          <state id="a"/>
      </scxml>
      """

      assert {:error, [%Error{reason: {:empty_id}} = error], _warnings} = validate!(xml)
      assert error.location.start_line == 3
    end

    # sabotage: entries/2's `Enum.sort_by(fn {_id, location} ->
    # location.start_offset end)` call is dropped -> the collection stays in
    # `datamodel_entries(root_datamodel) ++ state_entries(states)` order,
    # which puts the root's own, source-*later* <data id="x"> ahead of the
    # state-scoped, source-*earlier* one. The root one is then wrongly
    # canonicalized as "first", so the *state-scoped* <data> (offset-wise
    # the true first) is the one reported instead of the root one - and
    # this assertion, which expects the root <data>'s line, reddens
    test "the state-scoped <data> is canonical when it comes first by source offset" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
          <state id="s">
              <datamodel>
                  <data id="x" expr="1"/>
              </datamodel>
          </state>
          <datamodel>
              <data id="x" expr="2"/>
          </datamodel>
      </scxml>
      """

      assert {:error, [%Error{reason: {:duplicate_id, "x"}} = error], _warnings} = validate!(xml)
      assert error.location.start_line == 8
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

      assert {:error, errors, _warnings} = validate!(xml)
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

      assert {:ok, ^document, _warnings} = Validator.validate(document, xml)
    end
  end
end
