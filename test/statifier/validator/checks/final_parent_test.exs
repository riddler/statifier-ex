defmodule Statifier.Validator.Checks.FinalParentTest do
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

  # sabotage: offending?/1's child predicate inverted from `&(&1.kind ==
  # :final)` to `&(&1.kind != :final)` -> the parent below stops being
  # reported (its only child is now excluded rather than counted), reddening
  # this assertion with {:ok, _} instead of the expected error
  test "an id-less state wrapping a <final> is rejected" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state>
            <final id="done"/>
        </state>
    </scxml>
    """

    assert {:error, [%Error{reason: {:final_parent_missing_id, "done"}} = error], _warnings} =
             validate!(xml)

    assert error.location.start_line == 2
  end

  # sabotage: offending?/1's `&(&1.kind == :final)` predicate dropped so any
  # child counts as offending -> this id-less state with only a non-final
  # child is wrongly rejected, reddening the {:ok, _} assertion
  test "an id-less state with no final child validates" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state>
            <state id="a"/>
        </state>
    </scxml>
    """

    assert {:ok, _document, _warnings} = validate!(xml)
  end

  # sabotage: offending?/1 recurses into descendants (`Enum.any?(children,
  # &(&1.kind == :final or offending_states?(&1.states)))`) instead of only
  # direct children -> the id-less outer state below is wrongly rejected
  # because its grandchild is a <final>, reddening the {:ok, _} assertion
  test "a <final> nested as a grandchild does not trigger the rule" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state>
            <state id="mid">
                <final id="deep"/>
            </state>
        </state>
    </scxml>
    """

    assert {:ok, _document, _warnings} = validate!(xml)
  end

  # sabotage: offending?/1's `id: nil` head dropped so every parent matches
  # regardless of id -> the named parent below is wrongly rejected, reddening
  # the {:ok, _} assertion
  test "a named parent of a <final> validates" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state id="p">
            <final id="done"/>
        </state>
    </scxml>
    """

    assert {:ok, _document, _warnings} = validate!(xml)
  end

  # sabotage: check/2's flatten call replaced with
  # `flatten(states) ++ states` fed straight from `Document.states` as if it
  # were itself a parent's child list, i.e. the top-level <final> below gets
  # treated as a direct child of a synthetic id-less parent -> the document
  # is wrongly rejected, reddening the {:ok, _} assertion
  test "a top-level <final> validates" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <final id="done"/>
    </scxml>
    """

    assert {:ok, _document, _warnings} = validate!(xml)
  end

  # sabotage: check/2's filter narrowed to `&(&1.kind == :state)` (mirroring
  # Checks.DefaultEntry's narrowing) -> the id-less <parallel> below stops
  # being reported, reddening this assertion
  test "an id-less parallel wrapping a <final> is rejected" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <parallel>
            <final id="done"/>
        </parallel>
    </scxml>
    """

    assert {:error, [%Error{reason: {:final_parent_missing_id, "done"}}], _warnings} =
             validate!(xml)
  end

  # sabotage: n/a - asserts that Checks.Ids' own {:empty_id} guarantee holds
  # for an id="" parent of a <final> (Open Question 1's resolution: this
  # check fires on id: nil only), not this module's own lib/ behavior
  test "an id=\"\" parent of a <final> is refused, listing the reasons present" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state id="">
            <final id="done"/>
        </state>
    </scxml>
    """

    assert {:error, errors, _warnings} = validate!(xml)
    reasons = Enum.map(errors, & &1.reason)
    assert {:empty_id} in reasons
  end

  # sabotage: check/2's `Enum.map` over offending parents replaced with a
  # nested `Enum.flat_map` over each parent's final children, reporting once
  # per child instead of once per parent -> the parent below (two final
  # children) produces two errors instead of one, reddening the
  # single-element list match
  test "a parent with two final children reports exactly one error" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state>
            <final id="a"/>
            <final id="b"/>
        </state>
    </scxml>
    """

    assert {:error, [%Error{reason: {:final_parent_missing_id, "a"}}], _warnings} = validate!(xml)
  end
end
