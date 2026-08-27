defmodule Statifier.ReadmeTest do
  @moduledoc """
  Pins the runnable example in the root `README.md` - the card authorization
  quick start - and the conformance-corpus counts its "Why a rewrite" section
  quotes. The chart here is the document printed in that README: if one
  changes, change both.

  The counts test is the root README's half of what
  `Corpus.ReadmeCountsTest` already does for `tools/corpus/README.md`. A
  number quoted in prose goes stale silently; a number quoted in prose and
  asserted against disk goes stale loudly.
  """

  use Statifier.Testing.Case, async: true

  alias Statifier.Effect.Invoke

  # The example chart from README.md's "Quick start", verbatim.
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
         datamodel="predicator" initial="authorizing">
    <datamodel>
      <data id="amount" expr="4200"/>
      <data id="budget_remaining" expr="10000"/>
    </datamodel>

    <state id="authorizing">
      <transition event="card.approved" cond="amount &lt;= budget_remaining"
                  target="capturing"/>
      <transition event="card.approved" target="over_budget"/>
      <transition event="card.declined" target="declined"/>
    </state>

    <state id="capturing">
      <invoke type="myapp:capture" id="capture">
        <param name="amount" expr="amount"/>
      </invoke>
      <transition event="done.invoke.capture" target="settled"/>
      <transition event="error.communication" target="needs_attention"/>
    </state>

    <state id="over_budget"/>
    <state id="declined"/>
    <state id="needs_attention"/>
    <final id="settled"/>
  </scxml>
  """

  describe "the README.md quick start chart" do
    # sabotage: `Statifier.Interpreter.Selection.select_transitions/2` returns
    # `{machine_state, []}` instead of its enabled set -> `card.approved`
    # drives no transition, the chart stays in "authorizing" instead of
    # reaching "capturing" -> red. Reverted and confirmed green.
    test "an in-budget approval walks the states the README prints" do
      test_scxml(@chart, "in-budget approval captures", ["authorizing"], [
        {%{"name" => "card.approved"}, ["capturing"]}
      ])
    end

    # sabotage: `Statifier.Interpreter.Selection.select_transitions/2` returns
    # `{machine_state, []}` instead of its enabled set -> `card.declined`
    # drives no transition, the chart stays in "authorizing" instead of
    # reaching "declined" -> red. Reverted and confirmed green.
    test "a declined authorization takes the declined arrow" do
      test_scxml(@chart, "declined authorization", ["authorizing"], [
        {%{"name" => "card.declined"}, ["declined"]}
      ])
    end

    # sabotage: `Statifier.Effect.Invoke`'s `params` field is built from `%{}`
    # instead of the evaluated `<param>` map -> the asserted
    # `%{"amount" => 4200}` payload the README prints comes back empty -> red.
    # Reverted and confirmed green.
    test "entering capturing yields the invoke effect the README prints" do
      {:ok, machine} = Statifier.compile(@chart)
      {machine_state, _effects} = Statifier.initialize(machine)

      assert Statifier.active_leaf_states(machine_state) == MapSet.new(["authorizing"])

      {:ok, machine_state, effects} = Statifier.send_event(machine_state, "card.approved")

      assert Statifier.active_leaf_states(machine_state) == MapSet.new(["capturing"])

      assert [invoke: %Invoke{invoke_id: "capture", type: "myapp:capture", params: params}] =
               effects

      assert params == %{"amount" => 4200}
    end
  end

  describe "README.md conformance-corpus counts" do
    # sabotage: n/a - pins the README's corpus-count sentence against a fresh
    # count of the emitted corpus trees, no lib/ behavior.
    test "the corpus-first bullet's counts match disk" do
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
