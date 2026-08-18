defmodule Statifier.ValidatorTest do
  use ExUnit.Case, async: true

  alias Statifier.{Lowering, Parser, Validator}
  alias Statifier.Validator.{Error, Warning}

  defp lower!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    document
  end

  defp find(errors, code) do
    Enum.find(errors, fn error -> Error.code(error.reason) == code end)
  end

  # Corpus-shaped: compound states with both `initial` forms (on different
  # states, since one state may not carry both `initial` forms), a <parallel>
  # with two regions *led by a <history>* (SCION's history3/4/4b/5 all open a
  # <parallel> that way, and check 7 must not read that child order as a
  # default-entry mistake), both shallow and deep <history> each with a legal
  # default transition, a <final> with <donedata><content>, onentry/onexit
  # blocks, and full xmlns/version boilerplate.
  @valid_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="compound_attr">
      <state id="compound_attr" initial="child_a">
          <onentry>
              <log label="enter compound_attr"/>
          </onentry>
          <onexit>
              <log label="exit compound_attr"/>
          </onexit>
          <state id="child_a">
              <transition event="go" target="child_b"/>
          </state>
          <state id="child_b"/>
      </state>
      <state id="compound_element">
          <initial>
              <transition target="child_c"/>
          </initial>
          <state id="child_c"/>
          <state id="child_d"/>
      </state>
      <parallel id="par">
          <history id="par_hist" type="deep">
              <transition target="region_a_1"/>
          </history>
          <state id="region_a">
              <state id="region_a_1"/>
          </state>
          <state id="region_b">
              <state id="region_b_1"/>
          </state>
      </parallel>
      <state id="history_holder">
          <state id="h_child_1"/>
          <state id="h_child_2">
              <state id="h_child_2_a"/>
          </state>
          <history id="shallow_hist" type="shallow">
              <transition target="h_child_1"/>
          </history>
          <history id="deep_hist" type="deep">
              <transition target="h_child_2_a"/>
          </history>
      </state>
      <final id="done">
          <donedata>
              <content>all done</content>
          </donedata>
      </final>
  </scxml>
  """

  # Same shape, the root spelled with an explicit prefix bound to the SCXML
  # namespace - proves check 9 tests the resolved namespace,
  # not the literal `xmlns` attribute, end to end, not just at the root.
  @valid_prefixed_document """
  <s:scxml xmlns:s="http://www.w3.org/2005/07/scxml" version="1.0" initial="compound_attr">
      <s:state id="compound_attr" initial="child_a">
          <s:onentry>
              <s:log label="enter compound_attr"/>
          </s:onentry>
          <s:onexit>
              <s:log label="exit compound_attr"/>
          </s:onexit>
          <s:state id="child_a">
              <s:transition event="go" target="child_b"/>
          </s:state>
          <s:state id="child_b"/>
      </s:state>
      <s:state id="compound_element">
          <s:initial>
              <s:transition target="child_c"/>
          </s:initial>
          <s:state id="child_c"/>
          <s:state id="child_d"/>
      </s:state>
      <s:parallel id="par">
          <s:history id="par_hist" type="deep">
              <s:transition target="region_a_1"/>
          </s:history>
          <s:state id="region_a">
              <s:state id="region_a_1"/>
          </s:state>
          <s:state id="region_b">
              <s:state id="region_b_1"/>
          </s:state>
      </s:parallel>
      <s:state id="history_holder">
          <s:state id="h_child_1"/>
          <s:state id="h_child_2">
              <s:state id="h_child_2_a"/>
          </s:state>
          <s:history id="shallow_hist" type="shallow">
              <s:transition target="h_child_1"/>
          </s:history>
          <s:history id="deep_hist" type="deep">
              <s:transition target="h_child_2_a"/>
          </s:history>
      </s:state>
      <s:final id="done">
          <s:donedata>
              <s:content>all done</s:content>
          </s:donedata>
      </s:final>
  </s:scxml>
  """

  describe "validate/2 - the corpus-shaped valid document" do
    # sabotage: `Statifier.Validator.Checks.Donedata.offending?/1` drops its
    # `%State{kind: :final}` exclusion clause, so the <final> "done" state's
    # own <donedata> is wrongly reported as :donedata_not_on_final -> this
    # "passes clean" assertion reddens with a spurious error
    test "passes clean and returns the input document unchanged" do
      document = lower!(@valid_document)

      assert {:ok, ^document, []} = Validator.validate(document, @valid_document)
    end

    # sabotage: `Statifier.Validator.Checks.History.compound_parent?/1`'s
    # `%State{} = parent -> Context.compound?(parent)` clause is replaced
    # with a bare `false` -> both real histories under "history_holder" (a
    # genuinely compound <state>) are wrongly reported as
    # :history_bad_parent, reddening this assertion
    test "the prefixed twin passes clean and returns the input document unchanged" do
      document = lower!(@valid_prefixed_document)

      assert {:ok, ^document, []} = Validator.validate(document, @valid_prefixed_document)
    end
  end

  describe "validate/2 - all violations at once" do
    @all_at_once """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state id="dup">
            <transition target="missing"/>
        </state>
        <state id="dup"/>
        <state id="bad_initial" initial="nowhere">
            <state id="child"/>
        </state>
        <history id="root_hist">
            <transition target="dup"/>
        </history>
        <final id="f">
            <state id="stray"/>
        </final>
        <state id="has_donedata">
            <donedata/>
        </state>
    </scxml>
    """

    # sabotage: `Statifier.Validator.validate/2` returns after the first
    # non-empty check list instead of concatenating all of them (e.g.
    # `Enum.find_value(@checks, [], fn check -> case check.(document,
    # context) do [] -> nil; errs -> errs end end)` in place of the
    # `Enum.flat_map` over every check) -> only one of the six distinct
    # codes below survives, reddening the six-distinct-codes assertion
    test "six distinct violations across six checks are all reported, once each, in document order" do
      assert {:error, errors, _warnings} = Validator.validate(lower!(@all_at_once), @all_at_once)

      assert length(errors) == 6

      assert %Error{reason: {:duplicate_id, "dup"}} = find(errors, :duplicate_id)
      assert %Error{reason: {:unresolved_target, "missing"}} = find(errors, :unresolved_target)
      assert %Error{reason: {:unresolved_initial, "nowhere"}} = find(errors, :unresolved_initial)

      assert %Error{reason: {:history_bad_parent, "root_hist", :scxml}} =
               find(errors, :history_bad_parent)

      assert %Error{reason: {:final_has_states, "stray"}} = find(errors, :final_has_states)

      assert %Error{reason: {:donedata_not_on_final, "has_donedata"}} =
               find(errors, :donedata_not_on_final)

      offsets = Enum.map(errors, & &1.location.start_offset)
      assert offsets == Enum.sort(offsets)
    end
  end

  describe "validate/2 - both channels" do
    @both_channels """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state id="dup">
            <invoke type="t">
                <finalize>
                    <raise event="x"/>
                </finalize>
            </invoke>
        </state>
        <state id="dup"/>
    </scxml>
    """

    # sabotage: `validate/2`'s `errors -> {:error, errors}` clause drops
    # `warnings` (reverting to the pre-tier two-element shape) -> this
    # three-element pattern match fails with a `MatchError`, reddening this
    # assertion
    test "a document that trips both an error and a warning returns both, populated" do
      assert {:error, [error], [warning]} =
               Validator.validate(lower!(@both_channels), @both_channels)

      assert %Error{reason: {:duplicate_id, "dup"}} = error
      assert %Warning{reason: {:finalize_forbidden_content, "raise"}} = warning
    end

    # sabotage: `run/3`'s `|> Enum.sort_by(fn finding -> ...)` step is
    # dropped, so `errors` and `warnings` are returned in `@checks`/
    # `@warning_checks` list order instead of document order -> the
    # errors-sorted assertion below reddens (the six checks that produce
    # `@all_at_once`-shaped violations run in a fixed pipeline order that
    # does not match the document's physical layout), demonstrating that
    # the same shared `run/3` sort also backs the warning channel
    test "warnings are sorted by start_offset, the same way errors are" do
      assert {:error, errors, warnings} = Validator.validate(lower!(@all_at_once), @all_at_once)

      error_offsets = Enum.map(errors, & &1.location.start_offset)
      assert error_offsets == Enum.sort(error_offsets)

      warning_offsets = Enum.map(warnings, & &1.location.start_offset)
      assert warning_offsets == Enum.sort(warning_offsets)
    end
  end
end
