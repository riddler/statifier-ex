defmodule Statifier.PublishTest do
  @moduledoc """
  `Statifier.Publish.findings/2`: the one publish-time function, its
  finding shape, its declaration, the two checks it composes (ADR-0073
  decisions 1 to 4), and each row's check that lands inside it. The loan
  chart is the example `docs/publish-time-checks.md` walks; the inline
  charts each isolate one clause.
  """

  use ExUnit.Case, async: true

  alias Statifier.{Evaluator, Interpreter, Invoke, Publish, Send}
  alias Statifier.Interpreter.Datamodel
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
    test "invoke_types: is accepted as nil or a Statifier.Invoke.Types" do
      registered = Invoke.Types.from_handlers(%{"library:catalog" => Statifier.Invoke.Handler})

      assert Publish.findings(loan(), send_types: notices_registered(), invoke_types: nil) == []

      assert Publish.findings(loan(), send_types: notices_registered(), invoke_types: registered) ==
               []
    end
  end

  describe "row S2: a built-in <send> whose literal target the engine cannot parse" do
    # Each chart compiles today; the runtime refuses the send in
    # `Statifier.Machine.Content.Send`'s `reject_reason/4` with
    # `{:invalid_target, target}`, the reason the finding's kind names.
    defp send_chart(attributes) do
      chart("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
             initial="on_loan" datamodel="predicator">
        <state id="on_loan">
          <transition event="loan.due" target="overdue">
            <send event="loan.overdue" #{attributes}/>
          </transition>
        </state>
        <final id="overdue"/>
      </scxml>
      """)
    end

    # sabotage: `"S2"` removed from `@rows` -> red
    test "the worked example without its type is one S2 finding at the send's location" do
      assert Publish.findings(send_chart(~s(target="overdue_notice"))) == [
               %{
                 row: "S2",
                 kind: :invalid_target,
                 location: send_location(send_chart(~s(target="overdue_notice"))),
                 data: %{target: "overdue_notice"}
               }
             ]
    end

    # sabotage: `built_in_type?/1`'s `{:static, type}` clause answers
    # `false` -> red
    test "a built-in type, short or long form, is judged the same way" do
      for type <- ["scxml", "http://www.w3.org/TR/scxml/#SCXMLEventProcessor"] do
        assert [%{row: "S2", kind: :invalid_target, data: %{target: "overdue_notice"}}] =
                 Publish.findings(send_chart(~s(type="#{type}" target="overdue_notice")))
      end
    end

    # sabotage: the `Target.parse/1` filter dropped from the S2 clause -> red
    # (every literal target reported)
    test "a target the built-in processor can parse, or none at all, reports nothing" do
      # `#_notices` parses; that no `<invoke id>` declares it is row S3's.
      for target <- ["#_internal", "#_parent", "#_scxml_loan-7", "#_notices"] do
        assert for(
                 %{row: "S2"} = finding <- Publish.findings(send_chart(~s(target="#{target}"))),
                 do: finding
               ) == []
      end

      assert Publish.findings(send_chart("")) == []
    end

    # sabotage: `built_in_type?/1`'s catch-all answers `true` -> red (the
    # registered send's opaque route is reported)
    test "a registered type's target is the processor's route and is not judged" do
      registered = Send.Types.from_send_types(%{"library:notices" => Statifier.Send.Processor})

      assert Publish.findings(send_chart(~s(type="library:notices" target="overdue_notice")),
               send_types: registered
             ) == []
    end

    # sabotage: the S2 clause's `target: {:static, target}` pattern widened
    # to `target: target` -> red (a targetexpr is judged)
    test "a targetexpr or a typeexpr is left to the runtime" do
      assert Publish.findings(send_chart(~s(targetexpr="'overdue_notice'"))) == []
      assert Publish.findings(send_chart(~s(typeexpr="'scxml'" target="overdue_notice"))) == []
    end

    # sabotage: `@rows` reordered to `["S2", "S1", "S15", "S17"]` -> red
    test "S2 findings follow S1 and precede S15, one per send in document order" do
      machine =
        chart("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
               initial="on_loan" datamodel="predicator">
          <state id="on_loan">
            <onentry>
              <send event="loan.opened" target="first_notice"/>
              <send event="loan.opened" type="library:notices" target="catalog"/>
              <send event="loan.opened" target="second_notice"/>
            </onentry>
          </state>
        </scxml>
        """)

      assert [
               %{row: "S1", data: %{type: "library:notices"}},
               %{row: "S2", data: %{target: "first_notice"}},
               %{row: "S2", data: %{target: "second_notice"}},
               %{row: "S15", kind: :unreachable_name}
             ] = Publish.findings(machine, accepts: ["loan.renew"])
    end

    defp send_location(machine) do
      [%Statifier.Machine.Content.Send{location: location}] =
        for %Statifier.Machine.Content.Send{} = node <- Tuple.to_list(machine.contents),
            do: node

      location
    end
  end

  describe "row S3: a literal #_<invokeid> target no <invoke id> in the chart declares" do
    # Each chart compiles today; with a route snapshot declared, the runtime
    # refuses the send in `Statifier.Machine.Content.Send`'s
    # `reject_reason/4` with `{:unreachable_target, target}`.
    defp invoke_chart(sends) do
      chart("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
             initial="lending" datamodel="predicator">
        <state id="lending">
          <invoke id="catalog" type="scxml">
            <content><scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"><final id="done"/></scxml></content>
          </invoke>
          <onentry>
            #{sends}
          </onentry>
        </state>
      </scxml>
      """)
    end

    # sabotage: "S3" dropped from `@rows` -> red
    test "a target naming no declared invoke is one :unreachable_target at the send" do
      assert [
               %{
                 row: "S3",
                 kind: :unreachable_target,
                 location: %Location{start_line: 8},
                 data: %{target: "#_holds"}
               }
             ] = Publish.findings(invoke_chart(~s(<send target="#_holds" event="loan.hold"/>)))
    end

    # sabotage: the S3 clause judges against an empty set of declared ids
    # -> red (`#_catalog` reported)
    test "a target naming a declared <invoke id> is not a finding" do
      assert Publish.findings(invoke_chart(~s(<send target="#_catalog" event="loan.hold"/>))) ==
               []
    end

    # sabotage: the S3 clause judges the raw target instead of the parsed
    # `{:invoke, id}` route -> red
    test "a session, #_parent, #_internal or absent target is not this row's" do
      sends = """
      <send target="#_scxml_branch" event="a"/>
      <send target="#_parent" event="b"/>
      <send target="#_internal" event="c"/>
      <send event="d"/>
      """

      assert Publish.findings(invoke_chart(sends)) == []
    end

    # sabotage: the built-in type filter dropped from the S3 clause -> red
    # (the registered send's opaque target is reported)
    test "a registered type's target is its processor's, and is not judged" do
      machine = invoke_chart(~s(<send type="library:notices" target="#_holds" event="e"/>))
      assert Publish.findings(machine, send_types: notices_registered()) == []
    end

    # sabotage: the built-in test narrowed to an absent `type` -> red
    test "an explicit scxml type is built-in and judged" do
      assert [%{row: "S3", data: %{target: "#_holds"}}] =
               Publish.findings(invoke_chart(~s(<send type="scxml" target="#_holds" event="e"/>)))
    end

    # sabotage: the built-in type filter dropped from the S3 clause -> red
    # (the `typeexpr` send is judged)
    test "a targetexpr or a typeexpr is left to the runtime" do
      sends = """
      <send targetexpr="'#_holds'" event="a"/>
      <send typeexpr="'scxml'" target="#_holds" event="b"/>
      """

      assert Publish.findings(invoke_chart(sends)) == []
    end

    # The runtime exempts a delayed send from the snapshot check and finds
    # the same unreachable invoke when the timer fires; the literal decides
    # it either way.
    # sabotage: "S3" dropped from `@rows` -> red
    test "a delayed send is judged too" do
      assert [%{row: "S3", data: %{target: "#_holds"}}] =
               Publish.findings(invoke_chart(~s(<send target="#_holds" delay="1s" event="e"/>)))
    end

    # An `idlocation` invoke's id is generated when it starts; no literal
    # can name it.
    # sabotage: "S3" dropped from `@rows` -> red
    test "an <invoke idlocation> declares no id" do
      machine =
        chart("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
               initial="lending" datamodel="predicator">
          <datamodel><data id="holds"/></datamodel>
          <state id="lending">
            <invoke idlocation="holds" type="scxml">
              <content><scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"><final id="done"/></scxml></content>
            </invoke>
            <onentry><send target="#_holds" event="e"/></onentry>
          </state>
        </scxml>
        """)

      assert [%{row: "S3", data: %{target: "#_holds"}}] = Publish.findings(machine)
    end

    # sabotage: `@rows` reordered to put "S3" before "S1" -> red
    test "S3 findings come after S1's and before S15's" do
      sends = """
      <send target="#_holds" event="loan.hold"/>
      <send type="library:notices" event="loan.notice"/>
      """

      assert [%{row: "S1"}, %{row: "S3"}, %{row: "S15"}] =
               Publish.findings(invoke_chart(sends), accepts: ["loan.nothing"])
    end
  end

  describe "row S6: an <invoke> whose literal type is not registered" do
    # The runtime refusal is `Statifier.Interpreter`'s
    # `reject_unregistered_type` (and `Statifier.Session.Effects`'
    # `plan_invoke`): an `error.execution` with the invocation as its
    # origin, and no child starts. Each chart below compiles today.
    @invokes """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
           initial="checking" datamodel="predicator">
      <state id="checking">
        <invoke type="library:catalog" src="catalog://copies"/>
        <invoke type="scxml" src="lookup.scxml"/>
        <transition event="done" target="holding"/>
      </state>
      <state id="holding">
        <invoke src="hold.scxml"/>
        <invoke typeexpr="'library:' + 'holds'" src="holds://queue"/>
        <invoke type="library:holds" src="holds://queue"/>
      </state>
    </scxml>
    """

    defp catalog_registered do
      Invoke.Types.from_handlers(%{"library:catalog" => Statifier.Invoke.Handler})
    end

    # sabotage: "S6" removed from `@rows` -> red (no S6 finding at all)
    test "with no invoke_types: every non-built-in literal type is one finding, in document order" do
      assert [
               %{
                 row: "S6",
                 kind: :unregistered_invoke_type,
                 location: %Location{start_line: 4},
                 data: %{type: "library:catalog"}
               },
               %{
                 row: "S6",
                 kind: :unregistered_invoke_type,
                 location: %Location{start_line: 11},
                 data: %{type: "library:holds"}
               }
             ] = Publish.findings(chart(@invokes))
    end

    # sabotage: the S6 clause passes `nil` to `registered?/2` instead of
    # `declaration[:invoke_types]` -> red (the registered type is still
    # reported)
    test "a registered type is not a finding; the built-ins stay registered" do
      assert [%{row: "S6", data: %{type: "library:holds"}}] =
               Publish.findings(chart(@invokes), invoke_types: catalog_registered())
    end

    # sabotage: the S6 clause matches any `type`, not only `{:static, type}`
    # -> red (the `typeexpr`'s compiled form becomes a finding)
    test "an absent type and a typeexpr are not judged" do
      types =
        for %{row: "S6", data: %{type: type}} <- Publish.findings(chart(@invokes)), do: type

      assert types == ["library:catalog", "library:holds"]
    end

    # sabotage: `@rows` reordered to
    # `["S1", "S2", "S15", "S6", "S16", "S17", "S18", "S19"]` -> red
    test "S6 findings come after S1's and before S15's" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator">
        <state id="s">
          <onentry><send type="library:notices" event="e"/></onentry>
          <invoke type="library:catalog" src="catalog://copies"/>
          <transition event="copy.returned" target="s"/>
        </state>
      </scxml>
      """

      assert [%{row: "S1"}, %{row: "S6"}, %{row: "S15"}] =
               Publish.findings(chart(xml), accepts: ["patron.blocked", "copy.returned"])
    end
  end

  describe "row S11: every literal write location's root is one the chart declares" do
    defp roots(body, invoke \\ "", top \\ "") do
      chart("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
             initial="lending" datamodel="predicator">
          <datamodel>
              <data id="copies" expr="[]"/>
              <data id="slot" expr="0"/>
          </datamodel>
          #{top}
          <state id="lending">
              <onentry>#{body}</onentry>
              #{invoke}
          </state>
      </scxml>
      """)
    end

    defp s11(machine), do: for(%{row: "S11"} = finding <- Publish.findings(machine), do: finding)

    # sabotage: `"S11"` removed from `@rows` -> red (no finding at all)
    test "an <assign> to a root no <data> declares is :unbound_location, at the attribute" do
      assert [
               %{
                 row: "S11",
                 kind: :unbound_location,
                 location: %Location{start_line: 9},
                 data: %{attribute: :location, source: "patron.name", root: "patron"}
               }
             ] = s11(roots(~s|<assign location="patron.name" expr="'Ada'"/>|))
    end

    # sabotage: `root_kind/2`'s `_` arm removed -> red (`_event` is not
    # declared, so it reads :unbound_location)
    test "a root that begins with _ is :system_variable, before the declared check" do
      assert [
               %{kind: :system_variable, data: %{root: "_event"}},
               %{kind: :system_variable, data: %{root: "_hold"}}
             ] =
               s11(
                 roots(
                   ~s|<assign location="_event.name" expr="1"/><assign location="_hold" expr="1"/>|
                 )
               )
    end

    # sabotage: `declared_roots/1` drops the `<data>` ids -> red
    test "a declared root, through a property, an index or a variable key, reports nothing" do
      body =
        ~s|<assign location="slot" expr="1"/><assign location="copies[0]" expr="1"/>| <>
          ~s|<assign location="copies[slot].title" expr="1"/>|

      assert s11(roots(body)) == []
    end

    # sabotage: `declared_roots/1` drops the `<foreach>` names -> red
    test "a <foreach> item or index is a root the loop declares" do
      body = """
      <foreach array="copies" item="copy" index="at"><log expr="copy"/></foreach>
      <assign location="copy" expr="1"/><assign location="at" expr="1"/>
      """

      assert s11(roots(body)) == []
    end

    # sabotage: `declared_roots/1` drops the script roots -> red
    test "a root a <script> assigns, top-level or in content, is declared" do
      body = ~s|<script>hold = 1</script><assign location="hold.until" expr="2"/>|
      top = "<script>if (true) { ledger = [] }</script>"

      assert s11(roots(body <> ~s|<assign location="ledger[0]" expr="2"/>|, "", top)) == []

      assert [%{data: %{root: "ledger"}}] =
               s11(roots(body <> ~s|<assign location="ledger[0]" expr="2"/>|))
    end

    # sabotage: `write_targets/1`'s `%Send{}` arm answers `[]` -> red
    test "a <send idlocation> and an <invoke idlocation> are judged at their attribute" do
      invoke = ~s|<invoke type="scxml" src="child.scxml" idlocation="child_id"/>|

      assert [
               %{
                 kind: :unbound_location,
                 location: %Location{},
                 data: %{attribute: :idlocation, source: "notice_id"}
               },
               %{kind: :unbound_location, data: %{attribute: :idlocation, source: "child_id"}}
             ] = s11(roots(~s|<send event="loan.due" idlocation="notice_id"/>|, invoke))
    end

    # sabotage: the `%Block{content: []}` arm of `invoke_write_targets/1`
    # answers `[]` -> red
    test "an empty <finalize> judges each namelist entry and <param location> it writes" do
      invoke = """
      <invoke type="scxml" src="child.scxml" namelist="copies due_on">
          <finalize/>
      </invoke>
      <invoke type="scxml" src="child.scxml">
          <param name="fine" location="fine"/>
          <finalize/>
      </invoke>
      """

      assert [
               %{data: %{attribute: :namelist, source: "due_on", root: "due_on"}},
               %{data: %{attribute: :location, source: "fine", root: "fine"}}
             ] = s11(roots("", invoke))
    end

    # sabotage: the S11 clause takes the root as the source up to its first
    # non-name character, whether or not the location resolves -> red
    test "a location that does not resolve is row S19's alone" do
      machine =
        roots(~s|<assign location="patron + 1" expr="2"/><assign location="patron +" expr="2"/>|)

      assert s11(machine) == []
      assert [%{row: "S19"}, %{row: "S19"}] = Publish.findings(machine)
    end

    # sabotage: `@rows` reordered to put "S11" after "S15" -> red
    test "S11 findings follow S1 and S2 and precede S15" do
      body = """
      <send type="library:notices" event="loan.overdue"/>
      <send target="!!" event="loan.overdue"/>
      <assign location="patron" expr="1"/>
      """

      assert [%{row: "S1"}, %{row: "S2"}, %{row: "S11"}, %{row: "S15"}] =
               Publish.findings(roots(body), accepts: ["never.selected"])
    end

    # The agreement with the runtime: every location the check reports,
    # `Statifier.Interpreter.Datamodel.write_location/4` refuses with the
    # same reason, and every location it passes, that write takes.
    # sabotage: `root_kind/2`'s last arm answers `:ok` -> red
    test "the runtime write refuses exactly the locations the check reports" do
      reported = ["patron", "patron.name", "_sessionid", "_x.y"]
      passed = ["slot", "copies[0]", "copies[slot]"]
      body = Enum.map_join(reported ++ passed, &~s|<assign location="#{&1}" expr="2"/>|)
      machine = roots(body)

      assert Enum.map(s11(machine), &{&1.kind, &1.data.source}) == [
               {:unbound_location, "patron"},
               {:unbound_location, "patron.name"},
               {:system_variable, "_sessionid"},
               {:system_variable, "_x.y"}
             ]

      {machine_state, _effects} = Interpreter.initialize(machine)
      context = Evaluator.context(machine_state)

      assert {:error, {:unbound_location, "patron"}} =
               Datamodel.write_location(machine_state, context, "patron", 2)

      assert {:error, {:unbound_location, "patron.name"}} =
               Datamodel.write_location(machine_state, context, "patron.name", 2)

      assert {:error, {:system_variable, "_sessionid"}} =
               Datamodel.write_location(machine_state, context, "_sessionid", 2)

      assert {:error, {:system_variable, "_x"}} =
               Datamodel.write_location(machine_state, context, "_x.y", 2)

      for source <- passed do
        assert {:ok, _state, _context, _write} =
                 Datamodel.write_location(machine_state, context, source, 2)
      end
    end
  end

  describe "row S16: a cycle of eventless transitions none of which carries a cond" do
    # Each chart compiles today. A cycle the check reports never reaches
    # quiescence at run time: the macrostep fold spends its round budget
    # and appends `{:budget_exhausted, _}` (ADR-0019), which the helper
    # below reads, so every reported case is pinned to the runtime refusal
    # it twins and every escaping case to its absence.
    defp exhausts_budget?(machine) do
      {_machine_state, effects} = Statifier.initialize(machine, max_macrostep_rounds: 50)
      Enum.any?(effects, &match?({:budget_exhausted, _}, &1))
    end

    defp cycle_chart(body) do
      chart("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator">
      #{body}
        <final id="done"/>
      </scxml>
      """)
    end

    # sabotage: `"S16"` removed from `@rows` -> red
    test "two states whose eventless transitions target each other are one finding" do
      machine =
        cycle_chart("""
          <state id="shelving">
            <transition target="checking"/>
          </state>
          <state id="checking">
            <transition target="shelving"/>
          </state>
        """)

      assert Publish.findings(machine) == [
               %{
                 row: "S16",
                 kind: :eventless_cycle,
                 location: transition_location(machine, "shelving"),
                 data: %{states: ["shelving", "checking"]}
               }
             ]

      assert exhausts_budget?(machine)
    end

    # sabotage: the targetless clause of `eventless_step/2` answers `nil`
    # -> red
    test "a targetless eventless transition is a cycle of its own state" do
      machine = cycle_chart(~s(<state id="shelving"><transition/></state>))

      assert [%{row: "S16", kind: :eventless_cycle, data: %{states: ["shelving"]}}] =
               Publish.findings(machine)

      assert exhausts_budget?(machine)
    end

    # sabotage: `entered_atomic/2` answers `nil` for an atomic target -> red
    test "an eventless transition that targets its own state is a cycle of that state" do
      machine = cycle_chart(~s(<state id="shelving"><transition target="shelving"/></state>))

      assert [%{data: %{states: ["shelving"]}}] = Publish.findings(machine)
      assert exhausts_budget?(machine)
    end

    # sabotage: `first_eventless/2` answers a transition with a `cond` as
    # if it had none -> red
    test "a cond on a transition of the cycle leaves it to the data" do
      machine =
        cycle_chart("""
          <state id="shelving">
            <transition target="checking"/>
          </state>
          <state id="checking">
            <transition cond="false" target="shelving"/>
          </state>
        """)

      assert Publish.findings(machine) == []
      refute exhausts_budget?(machine)
    end

    # The engine takes the first enabled eventless transition in document
    # order; a `cond` ahead of the cycle's transition can take the chart
    # out of it, so the check does not guess.
    # sabotage: `first_eventless/2` finds the first eventless transition
    # without a `cond` instead of the first eventless one -> red
    test "an earlier eventless transition with a cond in the same state leaves it to the data" do
      machine =
        cycle_chart("""
          <state id="shelving">
            <transition cond="true" target="done"/>
            <transition target="shelving"/>
          </state>
        """)

      assert Publish.findings(machine) == []
      refute exhausts_budget?(machine)
    end

    # sabotage: `entered_atomic/2` returns the target for a compound state
    # instead of following its initial -> red
    test "a cycle through a compound state follows its initial child" do
      machine =
        cycle_chart("""
          <state id="shelving">
            <transition target="stacks"/>
          </state>
          <state id="stacks" initial="aisle">
            <state id="aisle">
              <transition target="shelving"/>
            </state>
          </state>
        """)

      assert [%{data: %{states: ["shelving", "aisle"]}}] = Publish.findings(machine)
      assert exhausts_budget?(machine)
    end

    # sabotage: `eventless_step/2` reads only the atomic state's own
    # transitions, not its ancestors' -> red
    test "an ancestor's eventless transition is taken when the atomic state has none" do
      machine =
        cycle_chart("""
          <state id="stacks">
            <transition target="stacks"/>
            <state id="aisle"/>
          </state>
        """)

      assert Publish.findings(machine) == [
               %{
                 row: "S16",
                 kind: :eventless_cycle,
                 location: transition_location(machine, "stacks"),
                 data: %{states: ["aisle"]}
               }
             ]

      assert exhausts_budget?(machine)
    end

    # sabotage: `next_atomic/3` answers the source state for a targeted
    # transition, as if it were targetless -> red
    test "a chain that ends in a top-level final is not a cycle" do
      machine =
        cycle_chart("""
          <state id="shelving">
            <transition target="checking"/>
          </state>
          <state id="checking">
            <transition target="done"/>
          </state>
        """)

      assert Publish.findings(machine) == []
      refute exhausts_budget?(machine)
    end

    # sabotage: the walk from each state collects its whole path, not only
    # the part from the repeated state -> red (`arriving` is reported)
    test "states that lead into a cycle are not part of it, and each cycle is one finding" do
      machine =
        cycle_chart("""
          <state id="arriving">
            <transition target="shelving"/>
          </state>
          <state id="shelving">
            <transition target="checking"/>
          </state>
          <state id="checking">
            <transition target="shelving"/>
          </state>
          <state id="mending">
            <transition/>
          </state>
        """)

      assert [
               %{data: %{states: ["shelving", "checking"]}},
               %{data: %{states: ["mending"]}}
             ] = Publish.findings(machine)
    end

    # A history pseudo-state has no children, so it reads as atomic, but it
    # is never active and takes no step of its own.
    # sabotage: the `kind != :history` filter of the S16 clause dropped
    # -> red (the history reports a self-cycle through its parent's
    # targetless transition)
    test "a history state is never a state of a cycle" do
      machine =
        cycle_chart("""
          <state id="stacks" initial="aisle">
            <transition/>
            <history id="resume">
              <transition target="aisle"/>
            </history>
            <state id="aisle"/>
          </state>
        """)

      assert [%{row: "S16", kind: :eventless_cycle, data: %{states: ["aisle"]}}] =
               Publish.findings(machine)

      assert exhausts_budget?(machine)
    end

    # Another region's transitions select in the same round and can take
    # the chart out, so a state inside a `<parallel>` is left to run time.
    # sabotage: the parallel-ancestor guard of `eventless_step/2` dropped
    # -> red
    test "a state inside a parallel is left to run time" do
      machine =
        cycle_chart("""
          <parallel id="desk">
            <state id="returns">
              <transition target="returns"/>
            </state>
            <state id="loans"/>
          </parallel>
        """)

      assert Publish.findings(machine) == []
    end

    # What a history state enters depends on what it recorded at run time.
    # sabotage: the `:history` clause of `entered_atomic/2` removed -> red
    # (the history reads as an atomic state and takes its parent's step)
    test "a transition into a history state is left to run time" do
      machine =
        cycle_chart("""
          <state id="shelving">
            <transition target="resume"/>
          </state>
          <state id="stacks" initial="aisle">
            <transition target="shelving"/>
            <history id="resume">
              <transition target="aisle"/>
            </history>
            <state id="aisle"/>
          </state>
        """)

      assert Publish.findings(machine) == []
    end

    # sabotage: `@rows` reordered to put `"S16"` after `"S17"` -> red
    test "findings are ordered by row: S1, S16, then S17" do
      machine =
        chart("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator">
          <state id="shelving">
            <onentry>
              <send type="library:notices" event="shelved"/>
              <foreach array="[1]" item="1copy"/>
            </onentry>
            <transition/>
          </state>
        </scxml>
        """)

      assert [%{row: "S1"}, %{row: "S16"}, %{row: "S17"}] = Publish.findings(machine)
    end

    defp transition_location(machine, state_id) do
      {:ok, index} = Statifier.Machine.index(machine, state_id)
      [t_index | _rest] = Statifier.Machine.at(machine, index).transitions
      Statifier.Machine.transition(machine, t_index).location
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

  describe "row S18: a <script> that writes a root beginning with _" do
    @scripts """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
           initial="ready" datamodel="predicator">
      <datamodel><data id="copies" expr="1"/></datamodel>
      <script>_loans = 0; copies = 2</script>
      <state id="ready">
        <onentry>
          <script>_event.seen = true; if copies > 0 { while false { _hold[0] = 1 } }</script>
          <script>notes = _event.name; _event.count = 1</script>
        </onentry>
      </state>
    </scxml>
    """

    # The runtime refusal is `Statifier.Evaluator.run_program/2`'s
    # `{:system_variable, root}`: a write to any root beginning with `_`.
    # sabotage: "S18" dropped from `@rows` -> red (no S18 finding at all)
    test "every _-rooted assignment target is one finding, global scripts first, then <script> nodes in document order" do
      assert [
               %{row: "S18", kind: :system_variable, location: nil, data: %{root: "_loans"}},
               %{
                 row: "S18",
                 kind: :system_variable,
                 location: %Location{start_line: 7} = first,
                 data: %{root: "_event"}
               },
               %{row: "S18", kind: :system_variable, location: first, data: %{root: "_hold"}},
               %{
                 row: "S18",
                 kind: :system_variable,
                 location: %Location{start_line: 8},
                 data: %{root: "_event"}
               }
             ] = Publish.findings(chart(@scripts))
    end

    # sabotage: `location_root/1`'s `:property_access` clause answers ""
    # instead of walking inward -> red (`_event.seen` missed); the same for
    # its `:bracket_access` clause -> red (`_hold[0]` missed)
    test "a write through a property or bracket accessor is judged by its root" do
      roots =
        for %{row: "S18", data: %{root: root}} <- Publish.findings(chart(@scripts)), do: root

      assert "_hold" in roots
      assert Enum.count(roots, &(&1 == "_event")) == 2
    end

    # sabotage: the `_` prefix filter in `system_roots_written/1` replaced
    # by `is_binary/1` -> red (`notes` and `renewals` become findings)
    test "a read of a system variable and a write to a declared root are not findings" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator">
        <datamodel><data id="notes"/></datamodel>
        <script>notes = _sessionid</script>
        <state id="s"><onentry><script>renewals = _name; notes = renewals</script></onentry></state>
      </scxml>
      """

      assert Publish.findings(chart(xml)) == []
    end

    # sabotage: the per-script `Enum.uniq/1` dropped -> red (two findings)
    test "a root written twice in one script is one finding" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator">
        <script>_x = 1; _x = 2</script>
      </scxml>
      """

      assert [%{row: "S18", data: %{root: "_x"}}] = Publish.findings(chart(xml))
    end

    # A body outside the statement grammar compiles to `{:invalid, error}`
    # and is row S13's, not this row's.
    # sabotage: the content generator matches any `%Script{}` and reads
    # `elem(program, 2)` -> red (raises on the `{:invalid, error}` pair)
    test "a <script> that did not compile is not judged" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator">
        <state id="s"><onentry><script>_x = = 1</script></onentry></state>
      </scxml>
      """

      assert Publish.findings(chart(xml)) == []
    end

    # sabotage: `@rows` reordered to `["S18", "S1", "S15", "S17"]` -> red
    test "S18 findings come after S1's" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" datamodel="predicator">
        <script>_x = 1</script>
        <state id="s"><onentry><send type="library:notices" event="e"/></onentry></state>
      </scxml>
      """

      assert [%{row: "S1"}, %{row: "S18"}] = Publish.findings(chart(xml))
    end
  end

  describe "row S19: every literal write location is assignable" do
    defp writes(onentry, invoke \\ "") do
      chart("""
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0"
             initial="lending" datamodel="predicator">
          <datamodel>
              <data id="copies" expr="[]"/>
              <data id="slot" expr="0"/>
          </datamodel>
          <state id="lending">
              <onentry>#{onentry}</onentry>
              #{invoke}
          </state>
      </scxml>
      """)
    end

    defp s19(machine), do: for(%{row: "S19"} = finding <- Publish.findings(machine), do: finding)

    # sabotage: `"S19"` removed from `@rows` -> red (no finding at all)
    test "an <assign location> that names an operator expression is :not_assignable, at the attribute" do
      assert [
               %{
                 row: "S19",
                 kind: :not_assignable,
                 location: %Location{start_line: 8},
                 data: %{attribute: :location, source: "copies + 1"}
               }
             ] = s19(writes(~s|<assign location="copies + 1" expr="2"/>|))
    end

    # sabotage: the `ParseError` arm of `unassignable_kind/1` answers `:ok`
    # -> red
    test "a location that does not parse is :parse_error" do
      assert [%{kind: :parse_error, data: %{source: "copies +"}}] =
               s19(writes(~s|<assign location="copies +" expr="2"/>|))
    end

    # sabotage: `location_kind/1`'s guard narrowed to `[:not_assignable]`
    # -> red
    test "a membership test, an object literal, a cast, a duration and a relative date are :invalid_node" do
      sources = ["copies in copies", "{}", "copies::integer", "3d", "3d ago"]
      onentry = Enum.map_join(sources, &~s|<assign location="#{&1}" expr="2"/>|)

      assert Enum.map(s19(writes(onentry)), &{&1.kind, &1.data.source}) ==
               Enum.map(sources, &{:invalid_node, &1})
    end

    # sabotage: `location_kind/1`'s guard narrowed to
    # `[:not_assignable, :invalid_node]` -> red
    test "a computed bracket key is :computed_key" do
      onentry =
        ~s|<assign location="copies[1 + 1]" expr="2"/><assign location="copies[true]" expr="2"/>|

      assert [
               %{kind: :computed_key, data: %{source: "copies[1 + 1]"}},
               %{kind: :computed_key, data: %{source: "copies[true]"}}
             ] = s19(writes(onentry))
    end

    # sabotage: `unassignable_kind/1`'s `{:ok, _path}` arm answers
    # `:not_assignable` -> red
    test "assignable locations, a variable bracket key included, report nothing" do
      onentry =
        ~s|<assign location="slot" expr="1"/><assign location="copies[0]" expr="1"/>| <>
          ~s|<assign location="copies[slot]" expr="1"/><assign location="copies['a'].b" expr="1"/>|

      assert s19(writes(onentry)) == []
    end

    # The runtime resolves a bracket key before the expression it indexes,
    # so an unbound variable key would answer first and hide the refusal.
    # sabotage: `bracket_variables/1` answers `%{}` -> red
    test "a variable bracket key does not hide the refusal of what it indexes" do
      assert [%{kind: :not_assignable, data: %{source: "len(copies)[slot]"}}] =
               s19(writes(~s|<assign location="len(copies)[slot]" expr="2"/>|))
    end

    # sabotage: the `%Send{}` arm of the S19 clause answers `[]` -> red
    test "a <send idlocation> is judged at its attribute" do
      assert [
               %{
                 kind: :invalid_node,
                 location: %Location{},
                 data: %{attribute: :idlocation, source: "3d"}
               }
             ] =
               s19(writes(~s|<send event="loan.due" idlocation="3d"/>|))
    end

    # sabotage: `invoke_write_targets/1`'s `idlocation` answers `[]` -> red
    test "an <invoke idlocation> is judged" do
      invoke = ~s|<invoke type="scxml" src="child.scxml" idlocation="{}"/>|

      assert [%{kind: :invalid_node, data: %{attribute: :idlocation, source: "{}"}}] =
               s19(writes("", invoke))
    end

    # sabotage: the `%Block{content: []}` arm of `invoke_write_targets/1`
    # answers `[]` -> red
    test "an empty <finalize> judges each namelist entry and <param location> it writes" do
      invoke = """
      <invoke type="scxml" src="child.scxml" namelist="copies f()">
          <finalize/>
      </invoke>
      <invoke type="scxml" src="child.scxml">
          <param name="due" location="-slot"/>
          <finalize/>
      </invoke>
      """

      assert [
               %{kind: :not_assignable, data: %{attribute: :namelist, source: "f()"}},
               %{kind: :not_assignable, data: %{attribute: :location, source: "-slot"}}
             ] = s19(writes("", invoke))
    end

    # sabotage: `invoke_write_targets/1` judges the targets whatever the
    # `<finalize>` holds -> red
    test "a populated or absent <finalize> writes no namelist entry, so none is judged" do
      populated = """
      <invoke type="scxml" src="child.scxml" namelist="f()">
          <finalize><assign location="slot" expr="1"/></finalize>
      </invoke>
      """

      absent = ~s|<invoke type="scxml" src="child.scxml" namelist="f()"/>|

      assert s19(writes("", populated)) == []
      assert s19(writes("", absent)) == []
    end

    # sabotage: `in_content ++ in_invokes` swapped -> red
    test "executable content comes before the invokes" do
      invoke = ~s|<invoke type="scxml" src="child.scxml" idlocation="{}"/>|

      assert [%{data: %{source: "copies + 1"}}, %{data: %{source: "{}"}}] =
               s19(writes(~s|<assign location="copies + 1" expr="2"/>|, invoke))
    end

    # The agreement with the runtime: every location the check reports,
    # `Statifier.Interpreter.Datamodel.write_location/4` refuses, and every
    # location it passes, that write takes.
    # sabotage: `location_kind/1` answers `:ok` for every type -> red
    test "the runtime write refuses exactly the locations the check reports" do
      reported = ["copies +", "copies + 1", "len(copies)[slot]", "{}", "3d ago", "copies[1 + 1]"]
      passed = ["slot", "copies[0]", "copies[slot]"]
      onentry = Enum.map_join(reported ++ passed, &~s|<assign location="#{&1}" expr="2"/>|)
      machine = writes(onentry)

      assert Enum.map(s19(machine), & &1.data.source) == reported

      {machine_state, _effects} = Interpreter.initialize(machine)
      context = Evaluator.context(machine_state)

      for source <- reported do
        assert {:error, _reason} =
                 Datamodel.write_location(machine_state, context, source, 2)
      end

      for source <- passed do
        assert {:ok, _state, _context, _write} =
                 Datamodel.write_location(machine_state, context, source, 2)
      end
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
