defmodule StatifierTest do
  use ExUnit.Case, async: true

  alias Statifier.{Event, Machine}
  alias Statifier.Validator.Warning

  # sabotage: in `Statifier.compile/1`, swap `Compiler.compile(document)` for
  # `{:ok, document}` (return the uncompiled document instead of running the
  # compiler) -> the `%Machine{}` pattern match below goes red because the
  # returned struct is a `%Statifier.Document{}`, not a `%Statifier.Machine{}`
  test "compiles a small document to a Machine whose id_to_index holds the written ids" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """

    assert {:ok, %Machine{id_to_index: id_to_index}} = Statifier.compile(xml)
    assert %{"a" => _a_index, "b" => _b_index} = id_to_index
  end

  # sabotage: in `Statifier.compile/1`'s private `parse/1` helper, change the
  # error clause to `{:error, error} -> {:error, error}` (drop the
  # one-element-list wrap) -> the `[%Statifier.Parser.ParseError{}]` pattern
  # below goes red because the error comes back bare, not wrapped in a list
  test "malformed XML fails at the parse stage with a list of ParseError" do
    xml = "<scxml><state id=\"a\"></scxml>"

    assert {:error, errors} = Statifier.compile(xml)
    assert is_list(errors)
    assert [%Statifier.Parser.ParseError{}] = errors
  end

  # sabotage: in `Statifier.compile/1`, swap the `with` clause order so
  # `Validator.validate/2` runs before `Lowering.lower/1` (pass the DOM
  # root straight to the validator) -> this test reddens with a
  # FunctionClauseError instead of the expected [%Lowering.Error{}] match,
  # because the validator never receives a %Statifier.Document{}
  test "a foreign or unexpected root element fails at the lowering stage with a list of Lowering.Error" do
    xml = ~s(<foo/>)

    assert {:error, errors} = Statifier.compile(xml)
    assert is_list(errors)
    assert [%Statifier.Lowering.Error{}] = errors
  end

  # sabotage: in `Statifier.compile/1`, drop the `Validator.validate/2` step
  # from the `with` chain (feed the lowered document straight to
  # `Compiler.compile/1`) -> this test reddens because the transition to an
  # unknown target no longer fails validation and the pipeline instead
  # returns {:ok, %Machine{}}
  test "a transition to an unknown target fails at the validation stage with a list of Validator.Error" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" target="missing"/>
        </state>
    </scxml>
    """

    assert {:error, errors} = Statifier.compile(xml)
    assert is_list(errors)
    assert [%Statifier.Validator.Error{}] = errors
  end

  # sabotage: in `Statifier.compile/1`, replace the final `Compiler.compile(document)`
  # call with `{:ok, %Machine{states: {}, id_to_index: %{}, transitions: {},
  # contents: {}, location: document.location}}` (fabricate a Machine instead
  # of compiling) -> this test reddens because compile/1 now returns {:ok, _}
  # instead of the expected list of Compiler.Error for the broken expression
  test "an uncompilable expression fails at the compiler stage with a list of Compiler.Error" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" cond="1 &gt;" target="a"/>
        </state>
    </scxml>
    """

    assert {:error, errors} = Statifier.compile(xml)
    assert is_list(errors)
    assert [%Statifier.Compiler.Error{}] = errors
  end

  # ADR-0042: `compile/2`'s `invoke_content_markup` option only relaxes
  # `Checks.Boilerplate` for the one call site that sets it
  # (`Statifier.Invoke.Source.resolve/2`); a bare `compile/1` call - and an
  # explicit `compile(xml, [])` - must keep rejecting a namespace-less root
  # exactly as before.
  #
  # sabotage: `Checks.Boilerplate.check_namespace/2`'s guard is changed from
  # `namespace == Namespace.scxml_namespace() or (relaxed? and
  # is_nil(namespace))` to `namespace == Namespace.scxml_namespace() or
  # is_nil(namespace)` (dropping the `relaxed?` guard entirely) -> a
  # namespace-less root now passes clean even with no option given, and this
  # assertion's `{:error, [...]}` match reddens with `{:ok, %Machine{}}`.
  test "a namespace-less root still fails Statifier.compile/1 with no options given" do
    xml = """
    <scxml version="1.0" initial="a">
        <state id="a"/>
    </scxml>
    """

    assert {:error, errors} = Statifier.compile(xml)

    assert Enum.any?(
             errors,
             &match?(%Statifier.Validator.Error{reason: {:bad_namespace, nil}}, &1)
           )

    assert {:error, errors} = Statifier.compile(xml, [])

    assert Enum.any?(
             errors,
             &match?(%Statifier.Validator.Error{reason: {:bad_namespace, nil}}, &1)
           )
  end

  # sabotage: `Statifier.compile/2`'s `Validator.validate(document, source,
  # opts)` call is changed to `Validator.validate(document, source)` (opts
  # dropped entirely) -> `invoke_content_markup: true` never reaches
  # `Context.build/3`, and this assertion reddens with `{:error, [...]}`
  # instead of `{:ok, %Machine{}}`.
  test "invoke_content_markup: true relaxes the namespace-less root at compile/2's own boundary" do
    xml = """
    <scxml version="1.0" initial="a">
        <state id="a"/>
    </scxml>
    """

    assert {:ok, %Machine{}} = Statifier.compile(xml, invoke_content_markup: true)
  end

  # sabotage: in `Statifier.Lowering.Builders.build_script/2`, the `case
  # Attributes.value(element, "src")` clauses are swapped -> `<script src>`
  # would build a struct instead of reporting
  # `{:unsupported_attribute, "script", "src"}`, and this pipeline would
  # return `{:ok, %Machine{}}` instead of the expected error list.
  test "<script src> fails Statifier.compile/1 with the named unsupported_attribute error" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <onentry>
                <script src="foo.js"/>
            </onentry>
        </state>
    </scxml>
    """

    assert {:error, errors} = Statifier.compile(xml)
    assert is_list(errors)

    assert [%Statifier.Lowering.Error{reason: {:unsupported_attribute, "script", "src"}}] =
             errors
  end

  # sabotage: in `Statifier.compile/1`, drop the `%Machine{machine | warnings:
  # warnings}` stamp and return `Compiler.compile(document)` directly as the
  # `with`'s do-block value -> this test reddens because `machine.warnings`
  # comes back `[]` instead of the one expected finalize_forbidden_content
  # warning, even though the document did trip the check
  test "a document with <raise> inside <finalize> compiles with the finding on Machine.warnings" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state id="s">
            <invoke type="t">
                <finalize>
                    <raise event="done"/>
                </finalize>
            </invoke>
        </state>
    </scxml>
    """

    assert {:ok, %Machine{warnings: [warning]}} = Statifier.compile(xml)
    assert %Warning{reason: {:finalize_forbidden_content, "raise"}} = warning
  end

  # sabotage: in `Statifier.compile/1`, change `warnings: warnings` to
  # `warnings: ["fake" | warnings]` (stamp a synthesized extra finding rather
  # than the validator's list as-is) -> this test reddens because
  # `machine.warnings` comes back non-empty for a document the validator
  # found nothing wrong with
  test "the same document without <raise> inside <finalize> compiles with no warnings" do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
        <state id="s">
            <invoke type="t">
                <finalize>
                    <log expr="'done'"/>
                </finalize>
            </invoke>
        </state>
    </scxml>
    """

    assert {:ok, %Machine{warnings: []}} = Statifier.compile(xml)
  end

  describe "initialize/2" do
    @compound_doc """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <state id="a1">
                <transition event="go" target="b"/>
            </state>
        </state>
        <state id="b"/>
    </scxml>
    """

    defp compound_machine do
      {:ok, machine} = Statifier.compile(@compound_doc)
      machine
    end

    # sabotage: in `Statifier.initialize/2`, replace the
    # `Interpreter.initialize(machine, opts)` body with
    # `Interpreter.initialize(machine, [])` (drop `opts`) -> the trace-effects
    # assertion below reddens because `trace: true` is never passed through
    # and no trace effects come back
    test "returns the initial leaf configuration as string ids, and an effect list gated by :trace" do
      machine = compound_machine()

      {machine_state, no_trace_effects} = Statifier.initialize(machine)
      assert Statifier.active_leaf_states(machine_state) == MapSet.new(["a1"])
      # Core effects (the `{:datamodel_init, _}` baseline among them) are
      # emitted regardless of `trace` - only the trace family is
      # gated.
      refute Enum.any?(no_trace_effects, &match?({:trace, _payload}, &1))

      {_machine_state, trace_effects} = Statifier.initialize(machine, trace: true)
      assert Enum.any?(trace_effects, &match?({:trace, _payload}, &1))
    end
  end

  describe "send_event/2" do
    # sabotage: in `Statifier.send_event/2`'s string clause, change
    # `Event.external(name)` to `Event.external("nope")` (ignore the given
    # name) -> the "reach the same configuration" assertion below reddens
    # because the string-clause call no longer moves the configuration to
    # "b"
    test "a name string and an %Event{} reach the same configuration" do
      machine = compound_machine()
      {machine_state, _effects} = Statifier.initialize(machine)

      assert {:ok, via_string, _effects} = Statifier.send_event(machine_state, "go")

      assert {:ok, via_event, _effects} =
               Statifier.send_event(machine_state, Event.external("go"))

      assert Statifier.active_leaf_states(via_string) == MapSet.new(["b"])
      assert Statifier.active_leaf_states(via_event) == MapSet.new(["b"])
    end

    # sabotage: in `Statifier.send_event/2`'s final clause, replace
    # `Interpreter.handle_event(machine_state, event)` with `{:error,
    # :not_running}` -> the `{:ok, _, _}` match below reddens because a live
    # machine_state now errors on an event that should simply enable
    # nothing
    test "an event that enables nothing leaves the configuration unchanged and still returns {:ok, _, _}" do
      machine = compound_machine()
      {machine_state, _effects} = Statifier.initialize(machine)

      assert {:ok, next, _effects} = Statifier.send_event(machine_state, "nope")
      assert Statifier.active_leaf_states(next) == MapSet.new(["a1"])
    end

    @terminal_doc """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="done">
        <final id="done"/>
    </scxml>
    """

    # sabotage: in `Statifier.send_event/2`'s final clause, change
    # `Interpreter.handle_event(machine_state, event)` to always return
    # `{:ok, machine_state, []}` -> the `{:error, :not_running}` match below
    # reddens because a terminated machine_state no longer errors
    test "a document that terminates on entry yields {:error, :not_running} from a subsequent send_event/2" do
      {:ok, machine} = Statifier.compile(@terminal_doc)
      {machine_state, _effects} = Statifier.initialize(machine)

      assert Statifier.send_event(machine_state, "go") == {:error, :not_running}
    end
  end

  describe "active_leaf_states/1" do
    # sabotage: in `Statifier.active_leaf_states/1`, drop the
    # `Enum.reject(&is_nil/1)` call -> this test reddens with a
    # `MapSet.new/1` crash (or a `nil` member) instead of the clean
    # `MapSet.new(["named"])` result, because the nameless leaf's `nil` id
    # is no longer filtered out
    test "returns leaves only, as string ids, excluding a nameless leaf state" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
          <parallel id="p">
              <state id="named"/>
              <state/>
          </parallel>
      </scxml>
      """

      {:ok, machine} = Statifier.compile(xml)
      {machine_state, _effects} = Statifier.initialize(machine)

      assert Statifier.active_leaf_states(machine_state) == MapSet.new(["named"])
      refute "p" in Statifier.active_leaf_states(machine_state)
    end
  end

  describe "compile/2 identity stamp" do
    @identity_xml """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a"/>
    </scxml>
    """

    # sabotage: `Statifier.compile/2`'s final `with` clause is changed from
    # `%Machine{machine | warnings: warnings, identity:
    # Identity.of_source(source, opts)}` to `%Machine{machine | warnings:
    # warnings}` (drop the identity stamp) -> this test reddens because
    # `Machine.identity/1` returns `nil` instead of an `%Identity{}`
    test "stamps a non-nil identity onto the compiled Machine" do
      assert {:ok, machine} = Statifier.compile(@identity_xml)
      assert %Statifier.Machine.Identity{} = Machine.identity(machine)
    end

    # sabotage: same mutation as above (drop the `identity:` key from the
    # final `%Machine{machine | ...}` update) -> this test reddens because
    # `Machine.identity(machine)` is `nil`, so the `%Identity{name: ...,
    # version: ...}` pattern match below fails
    test "chart_name and chart_version opts ride through to the stamped identity" do
      assert {:ok, machine} =
               Statifier.compile(@identity_xml, chart_name: "light", chart_version: "7")

      assert %Statifier.Machine.Identity{name: "light", version: "7"} = Machine.identity(machine)
    end

    # sabotage: `Statifier.compile/2`'s call to `Identity.of_source(source,
    # opts)` is changed to `Identity.of_source(source)` (drop `opts`) -> this
    # test reddens because `chart_name`/`chart_version` no longer ride
    # through, and the stamped identity's `name` comes back `nil` instead of
    # `"pass-through"`
    test "invoke_content_markup: true still threads chart_name/chart_version through" do
      xml = """
      <scxml version="1.0" initial="a">
          <state id="a"/>
      </scxml>
      """

      assert {:ok, machine} =
               Statifier.compile(xml,
                 invoke_content_markup: true,
                 chart_name: "pass-through",
                 chart_version: "1"
               )

      assert %Statifier.Machine.Identity{name: "pass-through", version: "1"} =
               Machine.identity(machine)
    end
  end

  describe "compile/2 source and compile_opts stamps" do
    @source_xml """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a"/>
    </scxml>
    """

    # sabotage: `Statifier.compile/2`'s final `%Machine{machine | ...}` update
    # drops the `source: source` key -> this test reddens because
    # `Machine.source(machine)` comes back `nil` instead of `@source_xml`
    test "stamps the exact source bytes compiled" do
      assert {:ok, machine} = Statifier.compile(@source_xml)
      assert Machine.source(machine) == @source_xml
    end

    # sabotage: `Statifier.compile/2`'s final `%Machine{machine | ...}` update
    # is left with no `compile_opts:` key at all -> this test reddens because
    # `Machine.compile_opts(machine)` comes back `[]` instead of
    # `[chart_name: "light"]`
    test "keeps only allowlisted keys, dropping one the caller passed that isn't recognized" do
      assert {:ok, machine} =
               Statifier.compile(@source_xml, chart_name: "light", not_a_real_opt: :whatever)

      assert Machine.compile_opts(machine) == [chart_name: "light"]
    end

    # sabotage: `Statifier.persisted_opts/1`'s comprehension is replaced with
    # `opts` (the caller's raw list, unfiltered) -> this test reddens because
    # `compile_opts` comes back in the caller's `[chart_version: ...,
    # chart_name: ...]` order instead of the allowlist's `[chart_name: ...,
    # chart_version: ...]` order
    test "orders compile_opts by the allowlist, not by the caller's argument order" do
      assert {:ok, machine} =
               Statifier.compile(@source_xml, chart_version: "7", chart_name: "light")

      assert Machine.compile_opts(machine) == [chart_name: "light", chart_version: "7"]
    end

    # sabotage: `Statifier.persisted_opts/1`'s `Keyword.has_key?(opts, key)`
    # guard is dropped, so every allowlisted key is stamped with a `nil`
    # value even when absent -> this test reddens because `compile_opts`
    # comes back `[invoke_content_markup: nil, chart_name: nil,
    # chart_version: nil]` instead of `[]`
    test "a default-opts compile stores []" do
      assert {:ok, machine} = Statifier.compile(@source_xml)
      assert Machine.compile_opts(machine) == []
    end
  end
end
