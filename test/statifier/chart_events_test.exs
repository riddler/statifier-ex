defmodule Statifier.ChartEventsTest do
  @moduledoc """
  `Statifier.Chart.events/1`: the event vocabulary computed from a compiled
  chart (ADR-0071 decisions 1 and 2). The library charts are read from
  `conformance/cases/library/`, never edited; the inline charts below are in
  the same world (patron, copy, loan, hold) and each isolates one clause of
  the reachability rule, so the clause is the only thing that can put a
  descriptor in or keep it out.
  """

  use ExUnit.Case, async: true

  alias Statifier.{Chart, Compiler, Lowering, Parser}

  @library Path.expand("../../conformance/cases/library", __DIR__)

  defp library_chart(name) do
    {:ok, machine} =
      @library |> Path.join(name <> ".scxml") |> File.read!() |> Statifier.compile()

    machine
  end

  defp chart(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  describe "the library charts" do
    # sabotage: `events/1` drops its `Enum.uniq()` -> red (idle's and
    # awaiting_pickup's repeated descriptors come back twice)
    test "a flat chart answers its descriptors in t_index order, each once" do
      assert Chart.events(library_chart("hold_queue_available_with_no_holds")) ==
               ["hold.placed", "copy.available", "pickup.expired", "copy.collected"]
    end

    # sabotage: `events/1`'s `Enum.sort()` over the t_indexes becomes
    # `Enum.sort(:desc)` -> red
    test "the loan chart answers the record's worked example, ancestors' own transitions first" do
      assert Chart.events(library_chart("loan_dispute_returns_to_history")) ==
               [
                 "copy.returned",
                 "copy.disputed",
                 "loan.renew",
                 "loan.due_soon",
                 "loan.due",
                 "loan.lost",
                 "dispute.resolved"
               ]
    end

    # sabotage: `default_entry/2`'s `:parallel` clause returns `[]` -> red
    # (no region below the parallel root is entered)
    test "every region of a reachable parallel state contributes" do
      assert Chart.events(library_chart("patron_initial_both_regions")) ==
               [
                 "patron.blocked",
                 "patron.reinstated",
                 "fine.assessed",
                 "fine.paid",
                 "loan.requested"
               ]
    end
  end

  describe "the reachability rule" do
    # `lending` is never entered by any default: only as the proper ancestor
    # of the transition target `on_loan`.
    @ancestor_only """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="checkout">
        <state id="checkout">
            <transition event="loan.issued" target="on_loan"/>
        </state>
        <state id="lending">
            <transition event="copy.returned" target="returned"/>
            <state id="on_loan">
                <transition event="loan.renew" target="on_loan"/>
            </state>
        </state>
        <final id="returned"/>
    </scxml>
    """

    # sabotage: `walk_entry/4`'s `{:targets, _}` clause stops marking the
    # targets' proper ancestors (`ancestor_work` built over `[]`) -> red
    test "a transition on an ancestor of an entered state is in the vocabulary" do
      assert Chart.events(chart(@ancestor_only)) ==
               ["loan.issued", "copy.returned", "loan.renew"]
    end

    # `archived` is neither a default nor any transition's target, so it and
    # `purged` (reached only from `archived`) are never entered. The
    # `cond="false"` transition still enters `renewed`: a condition is not read.
    @unreachable """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
        <state id="on_loan">
            <transition event="loan.renew" cond="false" target="renewed"/>
            <transition event="copy.returned" target="returned"/>
        </state>
        <state id="renewed">
            <transition event="loan.due" target="returned"/>
        </state>
        <state id="archived">
            <transition event="loan.archived" target="purged"/>
        </state>
        <state id="purged">
            <transition event="loan.purged" target="returned"/>
        </state>
        <final id="returned"/>
    </scxml>
    """

    # sabotage: `events/1` collects transitions from every state in the
    # machine instead of from `entered_states/1` -> red (`loan.archived` and
    # `loan.purged` appear)
    test "a descriptor on a state no path enters is not in the vocabulary" do
      assert Chart.events(chart(@unreachable)) == ["loan.renew", "copy.returned", "loan.due"]
    end

    # `blocked` is entered as a target inside the parallel `patron`, which no
    # default enters. The `fines` region holds no target, so it is entered by
    # its default; the `standing` region holds the target, so its default
    # (`registered`) is not entered, and `registered` is no other
    # transition's target. `fines` targets nothing: the rule reads no
    # transition domain, so a transition targeting inside `fines` would
    # re-enter `standing` by its default (an over-count the rule allows) and
    # hide the clause under test.
    @parallel_by_target """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="desk">
        <state id="desk">
            <transition event="patron.blocked" target="blocked"/>
        </state>
        <parallel id="patron">
            <state id="standing" initial="registered">
                <state id="registered">
                    <transition event="patron.welcomed" target="blocked"/>
                </state>
                <state id="blocked">
                    <transition event="patron.reinstated" target="desk"/>
                </state>
            </state>
            <state id="fines">
                <transition event="fine.assessed"/>
            </state>
        </parallel>
    </scxml>
    """

    # sabotage: `untargeted_regions/3` enters every region, ignoring
    # `targets` -> red (`patron.welcomed` appears); and, separately,
    # `untargeted_regions/3` returns `[]` -> red (`fine.assessed` vanishes)
    test "entering a target inside a parallel state enters every region that holds no target" do
      assert Chart.events(chart(@parallel_by_target)) ==
               ["patron.blocked", "patron.reinstated", "fine.assessed"]
    end

    # `overdue` is entered only through the history's default transition;
    # `lending` only as the history's ancestor, so its own `initial`
    # (`on_loan`) is never entered.
    @history_default """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="held_for_review">
        <state id="held_for_review">
            <transition event="dispute.resolved" target="h"/>
        </state>
        <state id="lending" initial="on_loan">
            <transition event="copy.returned" target="returned"/>
            <history id="h" type="shallow">
                <transition target="overdue"/>
            </history>
            <state id="on_loan">
                <transition event="loan.due" target="overdue"/>
            </state>
            <state id="overdue">
                <transition event="loan.lost" target="returned"/>
            </state>
        </state>
        <final id="returned"/>
    </scxml>
    """

    # sabotage: `default_entry/2`'s `history_default: t_index` clause returns
    # `[]` -> red (`loan.lost` vanishes)
    test "a history pseudo-state's default target counts as entered" do
      assert Chart.events(chart(@history_default)) ==
               ["dispute.resolved", "copy.returned", "loan.lost"]
    end
  end

  describe "the descriptors" do
    @eventless """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="checked_out">
        <state id="checked_out">
            <transition cond="true" target="on_loan"/>
        </state>
        <state id="on_loan">
            <transition event="loan.renew" target="on_loan"/>
        </state>
    </scxml>
    """

    # sabotage: `mark_entered/3` skips transitions whose events are `[]` when
    # collecting targets -> red (`on_loan` is never entered, `loan.renew`
    # vanishes)
    test "an eventless transition contributes no descriptor but still enters its target" do
      assert Chart.events(chart(@eventless)) == ["loan.renew"]
    end

    # sabotage: `events/1` maps each transition to `[""]` when its events are
    # `[]` (joining an empty token list) -> red
    test "a chart with no transition carrying an event answers []" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
          <state id="on_loan">
              <transition target="returned"/>
          </state>
          <final id="returned"/>
      </scxml>
      """

      assert Chart.events(chart(xml)) == []
    end

    @patterns """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
        <state id="on_loan">
            <transition event="loan.* loan. *" target="on_loan"/>
            <transition event="loan.renew" target="on_loan"/>
        </state>
    </scxml>
    """

    # sabotage: `events/1` joins with `Enum.join(&1, "")` -> red; and,
    # separately, `events/1` normalizes each token list through
    # `NameMatch`'s rule (drop a trailing `*` or `""`) before joining -> red
    test "a pattern is reported as written, never expanded" do
      assert Chart.events(chart(@patterns)) == ["loan.*", "loan.", "*", "loan.renew"]
    end

    @platform """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="lending">
        <state id="lending" initial="on_loan">
            <transition event="done.state.lending" target="returned"/>
            <transition event="error.execution error." target="returned"/>
            <state id="on_loan">
                <onentry>
                    <raise event="loan.checked"/>
                </onentry>
                <transition event="loan.checked" target="closed"/>
            </state>
            <final id="closed"/>
        </state>
        <final id="returned"/>
    </scxml>
    """

    # sabotage: `events/1` rejects descriptors whose first token is `done` or
    # `error` -> red
    test "platform and internally raised descriptors are kept" do
      assert Chart.events(chart(@platform)) ==
               ["done.state.lending", "error.execution", "error.", "loan.checked"]
    end
  end

  describe "purity" do
    # sabotage: n/a - `events/1` reads neither field; this pins that a
    # machine with neither answers the same list, which a mutation that
    # started reading them would break by raising or diverging.
    test "needs no source, identity or compile options on the machine" do
      xml = File.read!(Path.join(@library, "loan_dispute_returns_to_history.scxml"))
      {:ok, root} = Parser.parse(xml)
      {:ok, document} = Lowering.lower(root, xml)
      {:ok, bare} = Compiler.compile(document)

      assert bare.identity == nil and bare.source == nil
      assert Chart.events(bare) == Chart.events(library_chart("loan_dispute_returns_to_history"))
    end
  end
end
