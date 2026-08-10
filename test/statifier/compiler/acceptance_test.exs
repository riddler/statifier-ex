defmodule Statifier.Compiler.AcceptanceTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp compile_errors!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:error, errors} = Compiler.compile(document)
    errors
  end

  defp idx(machine, name) do
    {:ok, index} = Machine.index(machine, name)
    index
  end

  defp state_of(machine, name), do: elem(machine.states, idx(machine, name))

  # One document exercising every shape the bead's eight acceptance criteria
  # name: nested compound states (main > branch > <nameless>, main > other >
  # {shallow_child, deep}), a parallel region with two branches (region1,
  # region2), a shallow history (region1_hist) and a deep history
  # (region2_deep), an <initial> element (other's, targeting the *second*
  # child so the default can't pass by coincidence), a first-child default
  # (branch's, whose only child is nameless), an explicit initial attribute
  # pointing at a *non-first* child (main's, "other" rather than "branch"),
  # a nameless state, a targetless transition (main's second), a multi-token
  # event descriptor ("a.b c"), a cond, onentry/onexit content, and a final
  # with donedata.
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="main">
      <state id="main" initial="other">
          <onentry>
              <raise event="entered"/>
          </onentry>
          <onexit>
              <log label="leaving"/>
          </onexit>
          <transition event="a.b c" cond="1 &gt; 0" target="parallel_state"/>
          <transition/>
          <state id="branch">
              <state/>
          </state>
          <state id="other">
              <initial>
                  <transition target="deep"/>
              </initial>
              <state id="shallow_child"/>
              <state id="deep"/>
          </state>
      </state>
      <parallel id="parallel_state">
          <state id="region1">
              <state id="region1_child"/>
              <history id="region1_hist" type="shallow">
                  <transition target="region1_child"/>
              </history>
          </state>
          <state id="region2">
              <state id="region2_child"/>
              <history id="region2_deep" type="deep">
                  <transition target="region2_child"/>
              </history>
          </state>
      </parallel>
      <final id="done">
          <donedata>
              <content expr="1 + 1"/>
          </donedata>
      </final>
  </scxml>
  """

  # AC: "Flat document-order layout: parent pointers, contiguous descendant
  # ranges; interned invariants asserted directly in tests"
  #
  # sabotage: in `Statifier.Compiler.walk_siblings/4`, change
  # `last = next_after_subtree - 1` to `last = next_after_subtree` -> every
  # state's range claims one index past its actual subtree, and both the
  # self-inclusive-range check and the parent/child agreement check below go
  # red (a state's own `last` would then include its next sibling's index).
  test "flat document-order layout: parent pointers and contiguous descendant ranges" do
    machine = compile!(@document)
    states = Tuple.to_list(machine.states)

    Enum.each(states, fn state ->
      assert state.last >= state.index

      descendant_indexes =
        states
        |> Enum.filter(&(&1.index >= state.index and &1.index <= state.last))
        |> Enum.map(& &1.index)

      assert descendant_indexes == Enum.to_list(state.index..state.last)

      Enum.each(state.children, fn child_index ->
        child = elem(machine.states, child_index)
        assert child.parent == state.index
      end)
    end)

    root = elem(machine.states, 0)
    assert root.parent == nil
    assert root.last == tuple_size(machine.states) - 1
  end

  # AC: "Single expr sum type {:static, term} | {:compiled, instructions,
  # source}; no x/x_expr/compiled triples anywhere" (positive form; the
  # negative form is the ninth test below).
  #
  # sabotage: in `Statifier.Compiler.Expressions.compile/3`'s success
  # clause, change `{:ok, {:compiled, compiled, source}}` to
  # `{:ok, {:compiled, compiled}}` (drop `source`) -> both pattern matches
  # below stop matching a 3-element tuple and go red.
  test "every expression slot holds one expr() value: {:static, term} or {:compiled, instructions, source}" do
    machine = compile!(@document)

    main_transition =
      state_of(machine, "main").transitions
      |> Enum.min()
      |> then(&Machine.transition(machine, &1))

    assert {:compiled, %Predicator.Compiled{}, "1 > 0"} = main_transition.cond

    done = state_of(machine, "done")
    assert {:compiled, %Predicator.Compiled{}, "1 + 1"} = done.donedata.expr
  end

  # AC: "Predicator position side table stored with instructions; upgrade
  # path to spans noted"
  #
  # sabotage: in `Statifier.Compiler.Expressions.compile/3`, change
  # `Predicator.compile_with_spans(source)` to
  # `Predicator.compile_with_positions(source)` -> the stored `positions`
  # table holds bare `{line, column}` points instead of `{{l,c},{l,c}}`
  # spans, and the span-shape assertion below goes red.
  test "compiled expressions carry predicator's position table alongside the instructions, as spans" do
    machine = compile!(@document)

    main_transition =
      state_of(machine, "main").transitions
      |> Enum.min()
      |> then(&Machine.transition(machine, &1))

    {:compiled, %Predicator.Compiled{} = compiled, _source} = main_transition.cond

    refute compiled.instructions == []
    refute compiled.positions == %{}

    for {_instruction_index, position} <- compiled.positions do
      assert {{start_line, start_column}, {end_line, end_column}} = position
      assert is_integer(start_line) and is_integer(start_column)
      assert is_integer(end_line) and is_integer(end_column)
    end
  end

  # AC: "cond compile failure is a compiler error naming source, location,
  # and predicator position"
  #
  # sabotage: in `Statifier.Compiler.Error.expression_compile_error/4`, drop
  # the `"(predicator line #{line}, column #{column})"` suffix from the
  # built message -> the regex assertion below (which requires the message
  # to name predicator's line/column) goes red.
  test "a cond compile failure is a compiler error naming the source, the document location, and predicator's position" do
    broken = String.replace(@document, ~s(cond="1 &gt; 0"), ~s(cond="1 &gt;"))

    assert [error] = compile_errors!(broken)
    assert error.message =~ "1 >"
    assert error.message =~ ~r/predicator line \d+, column \d+/
    refute error.location == nil

    assert {:expression_compile_error, {:transition, _t_index}, "1 >",
            %Predicator.Errors.ParseError{position: {line, column}}} = error.reason

    assert is_integer(line) and is_integer(column)
  end

  # AC: "Locations retained on every compiled state/transition/content node;
  # dense document-order t_index/c_index assigned"
  #
  # sabotage: in `Statifier.Compiler.build_transition/3`, change
  # `location: transition.location` to `location: nil` -> every compiled
  # transition's `location` is nil, and the `refute ... == nil` assertion
  # below goes red for every transition in the document.
  test "every compiled state, transition, and content node retains its location; t_index/c_index are dense" do
    machine = compile!(@document)

    Enum.each(Tuple.to_list(machine.states), fn state -> refute state.location == nil end)

    transitions = Tuple.to_list(machine.transitions)
    Enum.each(transitions, fn transition -> refute transition.location == nil end)

    assert Enum.map(transitions, & &1.t_index) ==
             Enum.to_list(0..(tuple_size(machine.transitions) - 1))

    contents = Tuple.to_list(machine.contents)
    Enum.each(contents, fn content -> refute content.location == nil end)
    assert Enum.map(contents, & &1.c_index) == Enum.to_list(0..(tuple_size(machine.contents) - 1))
  end

  # AC: "id-to-index and index-to-id both directions plus t_index/c_index
  # lookups on the Machine"
  #
  # sabotage: in `Statifier.Machine.id/2`, hardcode a `nil` return instead of
  # `at(machine, index).id` -> every id-direction lookup below returns `nil`
  # instead of the state's written id, reddening the round-trip assertion.
  test "id_to_index and index_to_id round-trip through Machine.index/2 and Machine.id/2, alongside t_index/c_index lookups" do
    machine = compile!(@document)

    ~w(main branch other shallow_child deep parallel_state region1 region1_child
       region1_hist region2 region2_child region2_deep done)
    |> Enum.each(fn id ->
      {:ok, index} = Machine.index(machine, id)
      assert Machine.id(machine, index) == id
    end)

    Enum.each(0..(tuple_size(machine.transitions) - 1), fn t_index ->
      assert Machine.transition(machine, t_index).t_index == t_index
    end)

    Enum.each(0..(tuple_size(machine.contents) - 1), fn c_index ->
      assert Machine.content(machine, c_index).c_index == c_index
    end)
  end

  # AC: "initial resolved to indexes at compile time (attribute, element,
  # and first-child default)"
  #
  # sabotage: delete `Statifier.Compiler.resolve_initial/3`'s clause
  # matching a written `initial` attribute (the `when initial != []` head)
  # -> `main` falls through to the first-child default (`branch`) instead
  # of its attribute's `other`, and the first assertion below goes red. The
  # document deliberately points `initial="other"` at a *non-first* child so
  # this sabotage cannot pass by coincidence.
  test "initial resolves to indexes at compile time from the attribute, the <initial> element, and the first-child default" do
    machine = compile!(@document)

    assert state_of(machine, "main").initial == [idx(machine, "other")]
    assert state_of(machine, "other").initial == [idx(machine, "deep")]
    assert state_of(machine, "branch").initial == [state_of(machine, "branch").children |> hd()]
    assert Machine.initial(machine) == [idx(machine, "main")]
  end

  # AC: "Sabotage: perturb numbering, range/order assertions go red" - the
  # bead's own model mutation, applied at the top of the walk rather than
  # inside one subtree, so it perturbs the whole machine's numbering.
  #
  # sabotage: in `Statifier.Compiler.compile/1`, change
  # `walk_siblings(document.states, 1, 0, acc0)` to
  # `walk_siblings(Enum.reverse(document.states), 1, 0, acc0)` -> the three
  # top-level children are numbered in reverse source order, so `main`
  # (written first) ends up with the *highest* top-level index instead of
  # the lowest, reddening both order assertions below.
  test "perturbing numbering reddens document-order and exit-order assertions" do
    machine = compile!(@document)

    main = idx(machine, "main")
    parallel_state = idx(machine, "parallel_state")
    done = idx(machine, "done")

    assert main < parallel_state
    assert parallel_state < done

    assert Machine.document_order(machine, [done, main, parallel_state]) == [
             main,
             parallel_state,
             done
           ]

    assert Machine.exit_order(machine, [done, main, parallel_state]) == [
             done,
             parallel_state,
             main
           ]
  end

  # Ninth test: the negative form of the expr() criterion - no compiled
  # struct anywhere under lib/statifier/machine/ has a field name starting
  # with `compiled_` or ending in `_expr` beside a raw sibling field.
  #
  # sabotage: add `compiled_cond: nil` to `Statifier.Machine.Transition`'s
  # `defstruct` (a literal `compiled_` field) -> the grep assertion below
  # goes red.
  test "no compiled struct has a compiled_ field or an x/x_expr pair beside a raw sibling" do
    {grep_output, _status} =
      System.cmd("grep", ["-rn", "compiled_", "--", "lib/statifier/machine/"],
        stderr_to_stdout: true
      )

    assert grep_output == ""

    modules = [
      Statifier.Machine.State,
      Statifier.Machine.Transition,
      Statifier.Machine.Content.Log,
      Statifier.Machine.Content.Raise,
      Statifier.Machine.Donedata,
      Statifier.Machine.Block
    ]

    Enum.each(modules, fn mod ->
      fields =
        mod.__struct__()
        |> Map.from_struct()
        |> Map.keys()
        |> Enum.map(&Atom.to_string/1)

      Enum.each(fields, fn field ->
        refute String.starts_with?(field, "compiled_")

        if String.ends_with?(field, "_expr") do
          refute String.replace_suffix(field, "_expr", "") in fields
        end
      end)
    end)
  end
end
