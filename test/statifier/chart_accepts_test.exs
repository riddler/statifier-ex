defmodule Statifier.ChartAcceptsTest do
  @moduledoc """
  `Statifier.Chart.check_accepts/2`: a declaration of accepted event names
  compared with the chart's computed vocabulary (ADR-0071 decisions 3 and
  4). The loan chart is read from `conformance/cases/library/`, never
  edited; the inline charts are in the same world (patron, copy, loan, hold)
  and each isolates one clause, so the clause is the only thing that can
  move a name between the two lists.
  """

  use ExUnit.Case, async: true

  alias Statifier.{Chart, Compiler, Lowering, Parser}

  @loan Path.expand(
          "../../conformance/cases/library/loan_dispute_returns_to_history.scxml",
          __DIR__
        )

  defp loan_chart do
    {:ok, machine} = @loan |> File.read!() |> Statifier.compile()
    machine
  end

  defp chart(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  describe "the record's worked example" do
    # sabotage: `check_accepts/2`'s `undeclared` comprehension keeps the
    # descriptors that DO match a declared name (the `not` dropped) -> red
    test "the loan chart declaring loan.renew, copy.returned and loan.archived" do
      assert Chart.check_accepts(loan_chart(), ["loan.renew", "copy.returned", "loan.archived"]) ==
               %{
                 unreachable: ["loan.archived"],
                 undeclared: [
                   "copy.disputed",
                   "loan.due_soon",
                   "loan.due",
                   "loan.lost",
                   "dispute.resolved"
                 ]
               }
    end
  end

  describe "no declaration and the empty declaration" do
    # sabotage: the `nil` clause deleted, so `nil` falls to a clause that
    # does not match it -> FunctionClauseError -> red
    test "nil makes the computed vocabulary the contract: both lists are empty" do
      assert Chart.check_accepts(loan_chart(), nil) == %{unreachable: [], undeclared: []}
    end

    # sabotage: `check_accepts/2`'s list clause returning the `nil` answer
    # for `[]` (a `[] -> both empty` shortcut) -> red
    test "an empty list declares that the chart accepts nothing" do
      assert Chart.check_accepts(loan_chart(), []) == %{
               unreachable: [],
               undeclared: Chart.events(loan_chart())
             }
    end
  end

  describe "matching is the runtime's descriptor semantics, one relation both ways" do
    @patterns """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
        <state id="on_loan">
            <transition event="loan.* hold. patron" target="on_loan"/>
        </state>
    </scxml>
    """

    # sabotage: `check_accepts/2` compares each descriptor string to the
    # name with `==` instead of `NameMatch.name_match?/2` -> red (every
    # name is unreachable)
    test "a pattern, a trailing dot, a bare prefix and a bare * each match a declared name" do
      assert Chart.check_accepts(chart(@patterns), [
               "loan.renew",
               "hold.placed",
               "patron.blocked"
             ]) == %{unreachable: [], undeclared: []}

      any =
        chart("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
            <state id="on_loan">
                <transition event="*" target="on_loan"/>
            </state>
        </scxml>
        """)

      assert Chart.check_accepts(any, ["branch.closed"]) == %{unreachable: [], undeclared: []}
    end

    @exact """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
        <state id="on_loan">
            <transition event="loan.renew" target="on_loan"/>
            <transition event="loan.renewal" target="on_loan"/>
        </state>
    </scxml>
    """

    # sabotage: `check_accepts/2`'s `undeclared` comprehension passes the
    # name's tokens as the descriptor and the descriptor's as the name
    # (`name_match?/2`'s arguments swapped) -> red (`loan.renew` no longer
    # matches the longer `loan.renew.late`)
    test "a descriptor matches a longer name on token boundaries, never a shorter one" do
      assert Chart.check_accepts(chart(@exact), ["loan.renew.late", "loan"]) == %{
               unreachable: ["loan"],
               undeclared: ["loan.renewal"]
             }
    end

    # sabotage: `check_accepts/2`'s `undeclared` comprehension also counts a
    # match with the declared entry read as a descriptor
    # (`NameMatch.name_match?([name_tokens], tokens)` or'd in) -> red (the
    # declared `loan.*` then covers `loan.renew` and `loan.renewal`)
    test "a * in a declared entry is an ordinary token, never a pattern" do
      assert Chart.check_accepts(chart(@exact), ["loan.*"]) == %{
               unreachable: ["loan.*"],
               undeclared: ["loan.renew", "loan.renewal"]
             }
    end
  end

  describe "the order of each list" do
    # sabotage: `check_accepts/2` drops its `Enum.uniq()` over the declared
    # names -> red (`loan.archived` listed twice)
    test "unreachable follows the declaration's order, without duplicates" do
      assert Chart.check_accepts(loan_chart(), [
               "patron.blocked",
               "loan.archived",
               "loan.renew",
               "patron.blocked",
               "loan.archived"
             ]).unreachable == ["patron.blocked", "loan.archived"]
    end

    # sabotage: `check_accepts/2` builds `undeclared` from
    # `Enum.sort(events(machine))` -> red
    test "undeclared follows the vocabulary's order" do
      assert Chart.check_accepts(loan_chart(), ["loan.renew"]).undeclared == [
               "copy.returned",
               "copy.disputed",
               "loan.due_soon",
               "loan.due",
               "loan.lost",
               "dispute.resolved"
             ]
    end
  end

  describe "membership for a receiver that declares nothing" do
    # sabotage: `check_accepts/2` reads the machine's every transition
    # rather than `events/1` (so an unreachable state's descriptor counts)
    # -> red on `loan.archived`
    test "a one-name declaration answers [] when a reachable descriptor matches, [n] when none does" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
          <state id="on_loan">
              <transition event="copy.returned" target="returned"/>
          </state>
          <state id="archived">
              <transition event="loan.archived" target="returned"/>
          </state>
          <final id="returned"/>
      </scxml>
      """

      machine = chart(xml)

      assert Chart.check_accepts(machine, ["copy.returned"]).unreachable == []
      assert Chart.check_accepts(machine, ["loan.archived"]).unreachable == ["loan.archived"]
    end
  end

  describe "the reachability cases the record names" do
    # `lending` is entered only as the proper ancestor of the transition
    # target `on_loan`; its own transition listens for `copy.returned`.
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

    # sabotage: `Statifier.Chart`'s `walk_entry/4` `{:targets, _}` clause
    # stops marking the targets' proper ancestors (`ancestor_work` built over
    # `[]`) -> red (`copy.returned` becomes unreachable)
    test "a name on an ancestor of an entered state is reachable" do
      assert Chart.check_accepts(chart(@ancestor_only), ["copy.returned", "loan.renew"]) == %{
               unreachable: [],
               undeclared: ["loan.issued"]
             }
    end

    # `overdue` is entered only through the history's default transition;
    # `on_loan`, `lending`'s own `initial`, is never entered.
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

    # sabotage: `Statifier.Chart`'s `default_entry/2` `history_default:
    # t_index` clause returns `[]` -> red (`loan.lost` becomes unreachable)
    test "a name on a history pseudo-state's default target is reachable; one no path enters is not" do
      assert Chart.check_accepts(chart(@history_default), ["loan.lost", "loan.due"]) == %{
               unreachable: ["loan.due"],
               undeclared: ["dispute.resolved", "copy.returned"]
             }
    end
  end

  describe "purity" do
    # sabotage: n/a - `check_accepts/2` reads neither field; this pins that
    # a machine with neither answers the same result, which a mutation that
    # started reading them would break by raising or diverging.
    test "needs no source, identity or compile options on the machine" do
      xml = File.read!(@loan)
      {:ok, root} = Parser.parse(xml)
      {:ok, document} = Lowering.lower(root, xml)
      {:ok, bare} = Compiler.compile(document)
      declared = ["loan.renew", "loan.archived"]

      assert bare.identity == nil and bare.source == nil
      assert Chart.check_accepts(bare, declared) == Chart.check_accepts(loan_chart(), declared)
    end
  end
end
