defmodule Statifier.ReadmeTest do
  @moduledoc """
  Pins the runnable example in the root `README.md` - the library loan in its
  "Basic usage" section - and the conformance-corpus counts its Why paragraph
  quotes. The chart here is the document printed in that README: if one
  changes, change both.

  The counts test is the root README's half of what
  `Corpus.ReadmeCountsTest` already does for `tools/corpus/README.md`. A
  number quoted in prose goes stale silently; a number quoted in prose and
  asserted against disk goes stale loudly.
  """

  use Statifier.Testing.Case, async: true

  # The example chart from README.md's "Basic usage", verbatim.
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
         datamodel="predicator" initial="on_loan">
    <datamodel>
      <data id="renewals" expr="0"/>
    </datamodel>

    <state id="on_loan">
      <transition event="loan.renew" cond="renewals &lt; 2" target="on_loan">
        <assign location="renewals" expr="renewals + 1"/>
      </transition>
      <transition event="loan.renew" target="due"/>
      <transition event="loan.returned" target="returned"/>
    </state>

    <state id="due">
      <transition event="loan.returned" target="returned"/>
      <transition event="loan.lost" target="lost"/>
    </state>

    <final id="returned"/>
    <final id="lost"/>
  </scxml>
  """

  describe "the README.md basic usage chart" do
    # sabotage: `Statifier.Interpreter.Selection.select_transitions/2` returns
    # `{machine_state, []}` instead of its enabled set -> `loan.renew` drives
    # no transition, so the third renewal leaves the loan in "on_loan"
    # instead of "due" -> red. Reverted and confirmed green.
    test "walks the configurations the README prints" do
      {:ok, chart} = Statifier.compile(@chart)
      {execution, _effects} = Statifier.initialize(chart)

      {:ok, execution, _effects} = Statifier.send_event(execution, "loan.renew")
      {:ok, execution, _effects} = Statifier.send_event(execution, "loan.renew")
      assert Statifier.active_leaf_states(execution) == MapSet.new(["on_loan"])

      {:ok, execution, _effects} = Statifier.send_event(execution, "loan.renew")
      assert Statifier.active_leaf_states(execution) == MapSet.new(["due"])
    end

    # sabotage: `Statifier.Machine.Content.Assign.execute/2` returns the
    # context it was given, so `renewals` stays 0 -> the guard holds on every
    # renewal and the third one keeps the loan in "on_loan" instead of "due"
    # -> red. Reverted and confirmed green.
    test "the guard counts renewals: two renew, the third makes the loan due" do
      test_scxml(@chart, "renewal limit", ["on_loan"], [
        {%{"name" => "loan.renew"}, ["on_loan"]},
        {%{"name" => "loan.renew"}, ["on_loan"]},
        {%{"name" => "loan.renew"}, ["due"]}
      ])
    end

    # sabotage: `Statifier.Interpreter.Selection.select_transitions/2` returns
    # `{machine_state, []}` instead of its enabled set -> no event drives a
    # transition, the loan never comes due and so is never returned or lost
    # -> red. Reverted and confirmed green.
    test "a due loan is returned or lost" do
      test_scxml(@chart, "due loan returned", ["on_loan"], [
        {%{"name" => "loan.renew"}, ["on_loan"]},
        {%{"name" => "loan.renew"}, ["on_loan"]},
        {%{"name" => "loan.renew"}, ["due"]},
        {%{"name" => "loan.returned"}, ["returned"]}
      ])

      test_scxml(@chart, "due loan lost", ["on_loan"], [
        {%{"name" => "loan.renew"}, ["on_loan"]},
        {%{"name" => "loan.renew"}, ["on_loan"]},
        {%{"name" => "loan.renew"}, ["due"]},
        {%{"name" => "loan.lost"}, ["lost"]}
      ])
    end
  end

  describe "README.md conformance-corpus counts" do
    # sabotage: n/a - pins the README's corpus-count sentence against a fresh
    # count of the emitted corpus trees, no lib/ behavior.
    test "the Why paragraph's counts match disk" do
      scion = emitted_count("test/scion_tests")
      w3c = emitted_count("test/scxml_tests")
      total = scion + w3c

      assert readme() =~
               "#{total} generated SCION/W3C conformance tests (#{scion} SCION + #{w3c} W3C)",
             "README's corpus-count sentence is stale (disk has #{scion} SCION + " <>
               "#{w3c} W3C = #{total})"
    end
  end

  defp emitted_count(root) do
    root
    |> Path.join("**/*_test.exs")
    |> Path.wildcard()
    |> length()
  end

  # Markdown line-wraps prose at ~80 columns, so a phrase this test looks for
  # can straddle a newline. Collapse all whitespace runs (including newlines)
  # to a single space before matching, so wrapping is invisible to the
  # assertion.
  defp readme do
    "README.md"
    |> File.read!()
    |> String.replace(~r/\s+/, " ")
  end
end
