defmodule Statifier.PublishTest do
  @moduledoc """
  `Statifier.Publish.findings/2`: the one publish-time function, its
  finding shape, its declaration, and the two checks it composes today
  (ADR-0073 decisions 1 to 4). The loan chart is the example
  `docs/publish-time-checks.md` walks; the inline charts each isolate one
  clause.
  """

  use ExUnit.Case, async: true

  alias Statifier.{Invoke, Publish, Send}
  alias Statifier.Parser.Location

  @loan """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
         initial="on_loan" datamodel="predicator">
    <state id="on_loan">
      <transition event="loan.renew" target="on_loan"/>
      <transition event="loan.due" target="overdue">
        <send type="library:notices" target="overdue_notice" event="loan.overdue"/>
      </transition>
      <transition event="copy.returned" target="returned"/>
    </state>
    <state id="overdue">
      <transition event="copy.returned" target="returned"/>
    </state>
    <final id="returned"/>
  </scxml>
  """

  @declared_names ["loan.renew", "loan.due", "copy.returned", "patron.blocked"]

  defp loan, do: chart(@loan)

  defp chart(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  defp notices_registered do
    Send.Types.from_send_types(%{"library:notices" => Statifier.Send.Processor})
  end

  describe "the worked example of docs/publish-time-checks.md" do
    # sabotage: the S1 clause maps each unsupported send to a finding with
    # `row: "S2"` -> red
    test "an unregistered send type is one S1 finding at the send's location" do
      assert [
               %{
                 row: "S1",
                 kind: :unsupported_send_type,
                 location: %Location{start_line: 6},
                 data: %{type: "library:notices"}
               }
             ] = Publish.findings(loan())
    end

    # sabotage: the S1 clause passes `nil` to `unsupported_sends/2` instead
    # of `declaration[:send_types]` -> red (the registered type is still
    # reported)
    test "registering the type clears S1" do
      assert Publish.findings(loan(), send_types: notices_registered()) == []
    end

    # sabotage: the S15 clause maps `unreachable` to `:undeclared_descriptor`
    # -> red
    test "a declaration with a name the chart never selects on is one S15 finding" do
      assert Publish.findings(loan(),
               send_types: notices_registered(),
               accepts: @declared_names
             ) == [
               %{
                 row: "S15",
                 kind: :unreachable_name,
                 location: nil,
                 data: %{name: "patron.blocked"}
               }
             ]
    end

    # sabotage: `@rows` reordered to `["S15", "S1"]` -> red
    test "findings are ordered by row: S1 before S15" do
      assert [%{row: "S1"}, %{row: "S15"}] = Publish.findings(loan(), accepts: @declared_names)
    end
  end

  describe "row S15 composes check_accepts/2 both ways" do
    # sabotage: the S15 clause drops the `undeclared` half (`++ []`) -> red
    test "a descriptor the declaration does not state is an :undeclared_descriptor" do
      assert Publish.findings(loan(),
               send_types: notices_registered(),
               accepts: ["loan.renew", "copy.returned"]
             ) == [
               %{
                 row: "S15",
                 kind: :undeclared_descriptor,
                 location: nil,
                 data: %{descriptor: "loan.due"}
               }
             ]
    end

    # sabotage: the S15 clause passes `[]` instead of `declaration[:accepts]`
    # -> red (every descriptor is undeclared)
    test "with no accepts: the computed vocabulary is the contract and S15 reports nothing" do
      assert Publish.findings(loan(), send_types: notices_registered()) == []
    end
  end

  describe "the declaration" do
    # sabotage: `declaration!/1` accepts any list (the `Keyword.keyword?/1`
    # check dropped) -> red
    test "a list that is not a keyword list is refused" do
      assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
        Publish.findings(loan(), ["send_types"])
      end
    end

    # sabotage: the non-list `declaration!/1` clause deleted ->
    # FunctionClauseError instead of ArgumentError -> red
    test "a map is refused" do
      assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
        Publish.findings(loan(), %{accepts: []})
      end
    end

    # sabotage: the `{key, _value} -> raise_key(key)` clause replaced by
    # `-> :ok` -> red
    test "an unknown key is refused and the known keys are named" do
      assert_raise ArgumentError, ~r/unknown declaration key :routes/, fn ->
        Publish.findings(loan(), routes: nil)
      end
    end

    # sabotage: the `:accepts` guard widened to `is_list(value) or
    # is_binary(value)` -> red
    test "a value of the wrong shape is refused" do
      assert_raise ArgumentError, ~r/:accepts has the wrong shape/, fn ->
        Publish.findings(loan(), accepts: "loan.renew")
      end

      assert_raise ArgumentError, ~r/:send_types has the wrong shape/, fn ->
        Publish.findings(loan(), send_types: %{})
      end

      assert_raise ArgumentError, ~r/:invoke_types has the wrong shape/, fn ->
        Publish.findings(loan(), invoke_types: MapSet.new())
      end
    end

    # sabotage: the `:invoke_types` guard narrowed to `is_nil(value)` -> red
    test "invoke_types: is accepted as nil or a Statifier.Invoke.Types and changes nothing today" do
      registered = Invoke.Types.from_handlers(%{"library:catalog" => Statifier.Invoke.Handler})

      assert Publish.findings(loan(), send_types: notices_registered(), invoke_types: nil) == []

      assert Publish.findings(loan(), send_types: notices_registered(), invoke_types: registered) ==
               []
    end
  end

  describe "a chart with nothing to report" do
    @clean """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="ready">
        <state id="ready">
            <transition event="copy.returned" target="returned"/>
        </state>
        <final id="returned"/>
    </scxml>
    """

    # sabotage: `findings/2` appends a fixed finding after the flat_map -> red
    test "answers the empty list with and without a declaration" do
      assert Publish.findings(chart(@clean)) == []
      assert Publish.findings(chart(@clean), accepts: ["copy.returned"]) == []
    end
  end
end
