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

  describe "row S17: a <foreach> item or index that is not a legal variable name" do
    # Each chart compiles today; the runtime refuses the loop in
    # `Statifier.Machine.Content.Foreach`'s `check_name` with the reason
    # the finding's kind names.
    defp foreach_chart(attributes) do
      chart("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
             initial="lending" datamodel="predicator">
        <datamodel>
          <data id="copies" expr="[1, 2]"/>
        </datamodel>
        <state id="lending">
          <onentry>
            <foreach array="copies" #{attributes}>
              <log expr="'copy'"/>
            </foreach>
          </onentry>
        </state>
      </scxml>
      """)
    end

    # sabotage: `"S17"` removed from `@rows` -> red
    test "an item that is not a variable name is an :illegal_item_name at the attribute" do
      assert [
               %{
                 row: "S17",
                 kind: :illegal_item_name,
                 location: %Location{start_line: 8},
                 data: %{attribute: :item, name: "copy.id"}
               }
             ] = Publish.findings(foreach_chart(~s(item="copy.id")))
    end

    # sabotage: the `:index` tuple dropped from the S17 clause -> red
    test "an index that is not a variable name is an :illegal_index_name" do
      assert Publish.findings(foreach_chart(~s(item="copy" index="'n'"))) == [
               %{
                 row: "S17",
                 kind: :illegal_index_name,
                 location: machine_index_location(~s(item="copy" index="'n'")),
                 data: %{attribute: :index, name: "'n'"}
               }
             ]
    end

    # sabotage: the `_` prefix test moved after the regex match in
    # `foreach_name_kind/2` -> red (`_copy` matches the name shape)
    test "a name that begins with _ is a :system_variable, item before index" do
      assert [
               %{kind: :system_variable, data: %{attribute: :item, name: "_copy"}},
               %{kind: :system_variable, data: %{attribute: :index, name: "_n"}}
             ] = Publish.findings(foreach_chart(~s(item="_copy" index="_n")))
    end

    # sabotage: `kind != :ok` filter dropped -> red (legal names reported)
    test "legal names, and an absent index, report nothing" do
      assert Publish.findings(foreach_chart(~s(item="copy" index="n"))) == []
      assert Publish.findings(foreach_chart(~s(item="copy"))) == []
    end

    # sabotage: the S17 clause reads only the first `<foreach>` -> red
    test "a nested <foreach> is judged too, in document order" do
      machine =
        chart("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
               initial="lending" datamodel="predicator">
          <state id="lending">
            <onentry>
              <foreach array="[[1]]" item="1row">
                <foreach array="[2]" item="cell" index="_i"/>
              </foreach>
            </onentry>
          </state>
        </scxml>
        """)

      assert [
               %{row: "S17", kind: :illegal_item_name, data: %{name: "1row"}},
               %{row: "S17", kind: :system_variable, data: %{name: "_i"}}
             ] = Publish.findings(machine)
    end

    defp machine_index_location(attributes) do
      machine = foreach_chart(attributes)

      [%Statifier.Machine.Content.Foreach{index_location: location}] =
        for %Statifier.Machine.Content.Foreach{} = node <- Tuple.to_list(machine.contents),
            do: node

      location
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
