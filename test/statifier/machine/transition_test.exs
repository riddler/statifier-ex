defmodule Statifier.Machine.TransitionTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Machine.Transition
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp compile_errors!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:error, errors} = Compiler.compile(document)
    errors
  end

  defp idx(machine, name) do
    {:ok, index} = Machine.index(machine, name)
    index
  end

  # Exercises every transition role that gets a t_index: two
  # plain transitions on `a` (one targetless, one with a dot-split
  # descriptor), a plain transition *and* an `<initial>` element's
  # transition on `b` (the latter a forward reference to `b1`, not yet
  # numbered when `b` itself is visited - and the pair proves a state's own
  # plain transitions are numbered before its `<initial>` element's, since
  # `b` is the one state in this document with both), a plain-with-cond
  # transition on `b1`, and `h`'s history default transition. Hand-drawn
  # document order:
  #
  #  0 scxml (root)
  #  1   a
  #  2   b               (children [3, 4])
  #  3     b1
  #  4     h              (history)
  #
  # and transition source order, by owning state's own visit order (a
  # state's own transitions are assigned before its children's, and within
  # a state, its plain transitions are assigned before its `<initial>`
  # element's):
  #
  #  t0  a's "go" transition        -> target b
  #  t1  a's "a.b c" transition     -> targetless
  #  t2  b's "noop" transition      -> targetless
  #  t3  b's <initial> transition   -> target b1 (forward reference)
  #  t4  b1's transition (cond)     -> target a
  #  t5  h's default transition     -> target b1
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b"/>
          <transition event="a.b c"/>
      </state>
      <state id="b">
          <transition event="noop"/>
          <initial>
              <transition target="b1"/>
          </initial>
          <state id="b1">
              <transition event="x" cond="score &gt; 1" target="a"/>
          </state>
          <history id="h" type="shallow">
              <transition target="b1"/>
          </history>
      </state>
  </scxml>
  """

  defp machine, do: compile!(@document)

  defp state_of(machine, name) do
    {:ok, index} = Machine.index(machine, name)
    elem(machine.states, index)
  end

  describe "compile/1 - t_index density and document order" do
    # sabotage: `Statifier.Compiler.assign_transitions/4` increments with
    # `{[t_next | t_indexes], t_next, acc}` instead of `t_next + 1` -> every
    # transition in one state's own group collides on the same t_index key,
    # collapsing the tuple to far fewer than 6 entries, reddening this count.
    test "one t_index per <transition> element, dense from 0, across a document with <initial> and <history>" do
      m = machine()

      assert tuple_size(m.transitions) == 6
      assert m.transitions |> Tuple.to_list() |> Enum.map(& &1.t_index) == [0, 1, 2, 3, 4, 5]
    end

    # sabotage: `Statifier.Compiler.assign_own_transitions/4`'s non-history
    # clause assigns the `<initial>` element's transitions *before* the
    # state's own plain transitions (order of the two `assign_transitions`
    # calls swapped) -> `b`, the one state in this document with both a
    # plain transition ("noop") and an `<initial>` element, gets them
    # numbered in the wrong relative order, reddening the second assertion.
    test "a state's own transitions are numbered before its children's, plain before <initial>" do
      m = machine()

      a_t_indexes = state_of(m, "a").transitions
      b_plain_t_indexes = state_of(m, "b").transitions
      b_initial_t_index = state_of(m, "b").initial_transition
      b1_t_indexes = state_of(m, "b1").transitions

      assert Enum.max(a_t_indexes) < Enum.min(b_plain_t_indexes)
      assert Enum.max(b_plain_t_indexes) < b_initial_t_index
      assert b_initial_t_index < Enum.min(b1_t_indexes)
    end
  end

  describe "compile/1 - target resolution" do
    # sabotage: `Statifier.Compiler.build_transition/3` stores raw
    # `transition.target` (the id list) instead of mapping each id through
    # `id_to_index` -> `targets` holds `["b"]` instead of `[1]`, reddening
    # this equality assertion.
    test "a transition's target resolves to the target state's index" do
      m = machine()

      go_t_index = state_of(m, "a").transitions |> Enum.min()
      go_transition = Machine.transition(m, go_t_index)

      assert go_transition.targets == [idx(m, "b")]
    end

    # sabotage: `Statifier.Compiler.build_transition/3` appends the
    # transition's own `source` index to `targets`
    # (`Enum.map(transition.target, &Map.fetch!(id_to_index, &1)) ++ [source]`)
    # -> a genuinely targetless transition (`transition.target == []`) picks
    # up a spurious target instead of staying `[]`, reddening this
    # assertion.
    test "a targetless transition resolves to an empty target list" do
      m = machine()

      targetless_t_index = state_of(m, "a").transitions |> Enum.max()
      targetless_transition = Machine.transition(m, targetless_t_index)

      assert targetless_transition.targets == []
    end

    # sabotage: `Statifier.Compiler.build_transition/3`'s target resolution
    # is applied to `transition.target` in isolation - this test proves it
    # also works for an `<initial>` element's transition, whose target is a
    # forward reference to a state numbered *after* the `<initial>` element
    # itself is visited (`b1` is index 3, `b` is index 2). Sabotage: swap
    # `Map.fetch!(id_to_index, &1)` for `Map.get(id_to_index, &1, 0)` in
    # `build_transition/3` -> a genuinely broken forward reference would
    # silently resolve to index 0 instead of raising, so this assertion (the
    # correct index) still catches a wrong mapping even though it does not
    # catch every way `Map.get`'s default could hide a bug.
    test "a forward-referencing target (the <initial> element's transition) resolves correctly" do
      m = machine()

      initial_t_index = state_of(m, "b").initial_transition
      initial_transition = Machine.transition(m, initial_t_index)

      assert initial_transition.targets == [idx(m, "b1")]
    end
  end

  describe "compile/1 - event descriptor splitting" do
    # sabotage: `Statifier.Compiler.build_transition/3` maps
    # `String.split(&1, ".")` down to `[&1]` (no dot split) -> `events`
    # comes back `[["a.b"], ["c"]]` instead of `[["a", "b"], ["c"]]`,
    # reddening this assertion.
    test "each whitespace-split descriptor is further dot-split into tokens" do
      m = machine()

      dot_t_index = state_of(m, "a").transitions |> Enum.max()
      dot_transition = Machine.transition(m, dot_t_index)

      assert dot_transition.events == [["a", "b"], ["c"]]
    end
  end

  describe "compile/1 - selectability wiring (state.transitions vs initial_transition/history_default)" do
    # sabotage: `Statifier.Compiler.assign_own_transitions/4`'s `:history`
    # clause returns the assigned t_index in the *first* (selectable)
    # position instead of the third (history_default) - `{t_indexes, nil,
    # nil, ...}` instead of `{[], nil, List.first(t_indexes), ...}` -> `h`'s
    # default transition shows up in `h.transitions` instead of
    # `h.history_default`, reddening both assertions below.
    test "a history state's default transition is reachable only through history_default" do
      m = machine()
      h = state_of(m, "h")

      assert h.transitions == []
      refute h.history_default == nil
      assert Machine.transition(m, h.history_default).targets == [idx(m, "b1")]
    end

    # sabotage: `Statifier.Compiler.assign_own_transitions/4`'s non-history
    # clause returns `List.first(initial_t_indexes)` in the *first*
    # (selectable) position instead of the second (`initial_transition`) ->
    # `b`'s `<initial>` transition shows up in `b.transitions` (alongside
    # its genuine "noop" plain transition, so the list grows to two entries)
    # instead of `b.initial_transition`, reddening both assertions below.
    test "an <initial> element's transition is reachable only through initial_transition" do
      m = machine()
      b = state_of(m, "b")

      assert length(b.transitions) == 1
      refute b.initial_transition == nil
      refute b.initial_transition in b.transitions
    end

    # sabotage: `Statifier.Compiler.walk_siblings/7` stores `own_transitions`
    # (the correct plain list) as `Enum.reverse(own_transitions)` on the
    # compiled state -> `a`'s two plain transitions swap positions,
    # reddening this order assertion.
    test "a state's plain transitions are its selectable transitions, in source order" do
      m = machine()
      a = state_of(m, "a")

      [go_t_index, dot_t_index] = a.transitions
      assert Machine.transition(m, go_t_index).events == [["go"]]
      assert Machine.transition(m, dot_t_index).events == [["a", "b"], ["c"]]
    end
  end

  describe "compile/1 - cond, type, location, cond_location" do
    # sabotage: `Statifier.Compiler.build_cond/2` is changed to always
    # return `{:ok, nil}` regardless of `transition.cond` -> a transition
    # that genuinely wrote `cond="score &gt; 1"` compiles with `cond: nil`
    # instead of a compiled expr, reddening this pattern match.
    test "cond compiles through the expression seam into a Machine.expr()" do
      m = machine()

      cond_t_index = state_of(m, "b1").transitions |> hd()
      cond_transition = Machine.transition(m, cond_t_index)

      assert {:compiled, %Predicator.Compiled{}, "score > 1"} = cond_transition.cond
    end

    # sabotage: `Statifier.Lowering.Builders`'s transition builder defaults
    # `type` to `:internal` instead of `:external` (the `Attributes.atom/4`
    # call's last argument) -> this reddens because none of the transitions
    # in `@document` write `type=` explicitly, so every one carries the
    # lowering default straight through the compiler.
    test "type defaults to :external and is carried through" do
      m = machine()
      go_t_index = state_of(m, "a").transitions |> Enum.min()

      assert Machine.transition(m, go_t_index).type == :external
    end

    # sabotage: `Statifier.Compiler.build_transition/3` hardcodes
    # `cond_location: nil` instead of `cond_location: cond_location(transition)`
    # -> the second assertion below reddens.
    test "location and cond_location are both non-nil on a transition that wrote cond" do
      m = machine()
      cond_t_index = state_of(m, "b1").transitions |> hd()
      cond_transition = Machine.transition(m, cond_t_index)

      refute cond_transition.location == nil
      refute cond_transition.cond_location == nil
    end

    # sabotage: `Statifier.Compiler.cond_location/1`'s no-cond clause
    # (`defp cond_location(%DTransition{cond: nil}), do: nil`) is deleted,
    # falling through to the general clause, which would return the
    # transition's own `location` instead of `nil` -> this refutation
    # reddens for a transition that never wrote `cond`.
    test "cond_location is nil on a transition with no cond" do
      m = machine()
      go_t_index = state_of(m, "a").transitions |> Enum.min()

      assert Machine.transition(m, go_t_index).cond == nil
      assert Machine.transition(m, go_t_index).cond_location == nil
    end
  end

  describe "compile/1 - content stays empty (the executable-content pass's job)" do
    # sabotage: n/a - this asserts a field this phase deliberately leaves at
    # its default; there is no lib/ behavior computing a non-empty value yet
    # for sabotage to break.
    test "content is [] on every compiled transition in this phase" do
      m = machine()

      m.transitions
      |> Tuple.to_list()
      |> Enum.each(fn %Transition{} = transition -> assert transition.content == [] end)
    end
  end

  describe "Machine.transition/2" do
    # sabotage: `Machine.transition/2` reads `elem(transitions, t_index + 1)`
    # instead of `elem(transitions, t_index)` -> every lookup reads one slot
    # past the one asked for, reddening this identity assertion.
    test "looks up the transition at t_index by elem/2" do
      m = machine()

      Enum.each(0..(tuple_size(m.transitions) - 1), fn t_index ->
        assert Machine.transition(m, t_index).t_index == t_index
      end)
    end
  end

  describe "compile/1 - cond compile errors accumulate" do
    @two_bad_conds """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" cond="score &gt;" target="b"/>
        </state>
        <state id="b">
            <transition event="stop" cond="1 +" target="a"/>
        </state>
    </scxml>
    """

    # sabotage: `Statifier.Compiler.build_transitions/3` pipes its collected
    # errors through `Enum.take(1)` instead of `Enum.sort_by(& &1.location.start_offset)`
    # -> only one of the two genuinely broken `cond`s is reported, reddening
    # this length assertion.
    test "two bad conds on two different transitions both get reported, sorted by location" do
      errors = compile_errors!(@two_bad_conds)

      assert length(errors) == 2

      assert [
               %Statifier.Compiler.Error{
                 reason: {:expression_compile_error, {:transition, 0}, _source1, _parse_error1}
               },
               %Statifier.Compiler.Error{
                 reason: {:expression_compile_error, {:transition, 1}, _source2, _parse_error2}
               }
             ] = errors

      assert Enum.map(errors, & &1.location.start_offset) ==
               Enum.sort(Enum.map(errors, & &1.location.start_offset))
    end
  end
end
