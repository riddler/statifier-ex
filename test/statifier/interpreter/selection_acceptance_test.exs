defmodule Statifier.Interpreter.SelectionAcceptanceTest do
  use ExUnit.Case, async: true

  alias Predicator.Errors.UndefinedVariableError
  alias Statifier.Compiler
  alias Statifier.Evaluator
  alias Statifier.Event
  alias Statifier.Interpreter.Selection
  alias Statifier.Lowering
  alias Statifier.Machine.Transition
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Hand-drawn from `@document`, depth-first, document order - one document
  # covering every acceptance-criteria line a test can decide, so this
  # file reads as one whole next to the narrower per-rule fixtures in the
  # other test files in this directory.
  #
  #  0 scxml (root)
  #  1   full_name           -- 3.13: full-name match
  #  2   boundary_prefix     -- 3.13: boundary prefix match
  #  3   non_boundary        -- 3.13: non-boundary NON-match
  #  4   trailing_star       -- 3.13: trailing .* (foo.* matches foo AND foo.bar)
  #  5   trailing_dot        -- 3.13: trailing dot behaves as bare prefix
  #  6   bare_star           -- 3.13: bare * matches every event
  #  7   multi_descriptor    -- 3.13: multi-descriptor, any match enables
  #  8   ancestor            -- child preempts ancestor
  #  9     descendant
  # 10   multi               -- sibling document-order priority (two txns)
  # 11   parallel_holder     -- parallel regions keep non-conflicting transitions
  # 12     preg1              (children [13], last 14)
  # 13       preg1a            (transition event="go" internal -> preg1b)
  # 14       preg1b
  # 15     preg2              (children [16], last 17)
  # 16       preg2a            (transition event="go" internal -> preg2b)
  # 17       preg2b
  # 18   targetless_holder   -- targetless selects with empty exit set
  # 19   domain_holder       -- internal vs external domain, same source/target
  # 20     domain_child
  # 21   cond_holder         -- cond="true" -> {:ok, true}
  # 22   condfalse_holder    -- cond="false" -> {:ok, false}
  # 23   condunbound_holder  -- cond names an unbound variable -> {:error, %Evaluator.Error{}}
  # 24   nocond_holder       -- nil cond -> {:ok, true}
  # 25   tgt
  # 26   tgt-a
  # 27   tgt-b
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="full_name">
      <state id="full_name">
          <transition event="error.execution" target="tgt"/>
      </state>
      <state id="boundary_prefix">
          <transition event="error" target="tgt"/>
      </state>
      <state id="non_boundary">
          <transition event="error" target="tgt"/>
      </state>
      <state id="trailing_star">
          <transition event="foo.*" target="tgt"/>
      </state>
      <state id="trailing_dot">
          <transition event="foo." target="tgt"/>
      </state>
      <state id="bare_star">
          <transition event="*" target="tgt"/>
      </state>
      <state id="multi_descriptor">
          <transition event="foo *" target="tgt"/>
      </state>
      <state id="ancestor">
          <transition event="shared" target="tgt"/>
          <state id="descendant">
              <transition event="shared" target="tgt"/>
          </state>
      </state>
      <state id="multi">
          <transition event="multi-evt" target="tgt-a"/>
          <transition event="multi-evt" target="tgt-b"/>
      </state>
      <parallel id="parallel_holder">
          <state id="preg1">
              <state id="preg1a">
                  <transition event="go" target="preg1b" type="internal"/>
              </state>
              <state id="preg1b"/>
          </state>
          <state id="preg2">
              <state id="preg2a">
                  <transition event="go" target="preg2b" type="internal"/>
              </state>
              <state id="preg2b"/>
          </state>
      </parallel>
      <state id="targetless_holder">
          <transition event="tless-evt"/>
      </state>
      <state id="domain_holder">
          <transition event="dom-internal" target="domain_child" type="internal"/>
          <transition event="dom-external" target="domain_child" type="external"/>
          <state id="domain_child"/>
      </state>
      <state id="cond_holder">
          <transition event="c-evt" cond="true" target="tgt"/>
      </state>
      <state id="condfalse_holder">
          <transition event="cf-evt" cond="false" target="tgt"/>
      </state>
      <state id="condunbound_holder">
          <transition event="cu-evt" cond="nope" target="tgt"/>
      </state>
      <state id="nocond_holder">
          <transition event="nc-evt" target="tgt"/>
      </state>
      <state id="tgt"/>
      <state id="tgt-a"/>
      <state id="tgt-b"/>
  </scxml>
  """

  @indexes %{
    full_name: 1,
    boundary_prefix: 2,
    non_boundary: 3,
    trailing_star: 4,
    trailing_dot: 5,
    bare_star: 6,
    multi_descriptor: 7,
    ancestor: 8,
    descendant: 9,
    multi: 10,
    parallel_holder: 11,
    preg1: 12,
    preg1a: 13,
    preg1b: 14,
    preg2: 15,
    preg2a: 16,
    preg2b: 17,
    targetless_holder: 18,
    domain_holder: 19,
    domain_child: 20,
    cond_holder: 21,
    condfalse_holder: 22,
    condunbound_holder: 23,
    nocond_holder: 24,
    tgt: 25,
    tgt_a: 26,
    tgt_b: 27
  }

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp machine_state(machine, configuration) do
    %{MachineState.new(machine) | configuration: MapSet.new(configuration)}
  end

  # Finds the transition among `machine`'s own transitions whose single event
  # descriptor is `event_name` - every transition under test here has a
  # distinct `event` attribute purely as a lookup key (mirrors
  # selection_test.exs and selection_domain_test.exs).
  defp transition_named(machine, event_name) do
    machine.transitions
    |> Tuple.to_list()
    |> Enum.find(&(&1.events == [[event_name]]))
  end

  # AC: "select_transitions, select_eventless_transitions (separate functions,
  # as in the pseudocode), remove_conflicting_transitions,
  # get_transition_domain, find_lcca, compute_exit_set each diff cleanly
  # against their pseudocode block" - the executable half of that criterion:
  # every spec-named function exists and is public under the spec's name, so
  # a silent rename is a failure here, not only in review.
  #
  # sabotage: `select_transitions/2` in lib/statifier/interpreter/selection.ex
  # is renamed to `select_transitions2/2` -> `function_exported?/3` returns
  # false for it, reddening the `Enum.all?/2` assertion below.
  test "all eight spec-named functions exist and are public" do
    # `function_exported?/3` only consults already-loaded modules; nothing
    # else in a solitary run of this test forces `Selection` to load first.
    Code.ensure_loaded!(Selection)

    spec_functions = [
      {Selection, :select_transitions, 2},
      {Selection, :select_eventless_transitions, 1},
      {Selection, :remove_conflicting_transitions, 2},
      {Selection, :compute_exit_set, 2},
      {Selection, :get_transition_domain, 2},
      {Selection, :get_effective_target_states, 2},
      {Selection, :find_lcca, 2},
      {Selection, :condition_match, 2}
    ]

    assert length(spec_functions) == 8
    assert Enum.all?(spec_functions, fn {m, f, a} -> function_exported?(m, f, a) end)
  end

  # AC: "3.13 matcher: full-name, boundary prefix, non-boundary NON-match,
  # trailing .* and trailing dot, bare *, multi-descriptor - each a named
  # test" - re-asserted end to end from a real compiled document rather than
  # the literal token lists name_match_test.exs uses, so this exercises the
  # compiler's `events` shape feeding the matcher, not the matcher's own
  # rules (`name_match_test.exs` already covers those).
  #
  # sabotage: `descriptor_match?/2` in
  # lib/statifier/interpreter/name_match.ex compares
  # `Enum.take(event_tokens, length(normalized)) == Enum.reverse(normalized)`
  # instead of `== normalized` -> the two-token descriptor `["error",
  # "execution"]` no longer equals its own reverse, so this reddens.
  test "3.13: full-name match" do
    m = machine()
    ms = machine_state(m, [idx(:full_name)])

    {_ms, transitions} = Selection.select_transitions(ms, Event.external("error.execution"))

    assert [%Transition{events: [["error", "execution"]]}] = transitions
  end

  # sabotage: `descriptor_match?/2` compares
  # `Enum.take(event_tokens, length(event_tokens))` (the whole event) instead
  # of `Enum.take(event_tokens, length(normalized))` (the prefix) -> the
  # one-token descriptor `["error"]` no longer equals the full two-token
  # event, reddening this boundary-prefix case.
  test "3.13: boundary prefix match (error matches error.execution)" do
    m = machine()
    ms = machine_state(m, [idx(:boundary_prefix)])

    {_ms, transitions} = Selection.select_transitions(ms, Event.external("error.execution"))

    assert [%Transition{events: [["error"]]}] = transitions
  end

  # sabotage: `descriptor_match?/2` is replaced with a character-level
  # `String.starts_with?/2` over the joined descriptor and event name (v1's
  # bug) -> `"errors.execution"` starts with `"error"` as a string even
  # though `errors` and `error` are not the same token, so this wrongly
  # matches and the assertion below (no selection) reddens.
  test "3.13: non-boundary NON-match (error does not match errors.execution)" do
    m = machine()
    ms = machine_state(m, [idx(:non_boundary)])

    assert {_ms, []} = Selection.select_transitions(ms, Event.external("errors.execution"))
  end

  # sabotage: `normalize/1` only strips a trailing `"*"` when it is the
  # descriptor's *only* token (`["*"] -> []`, everything else left alone) -
  # the exact `foo.*`-matches-`foo` gap `docs/architecture.md` names - so
  # `["foo", "*"]` is compared literally against `["foo"]` and `["foo",
  # "bar"]`, matching neither, and both selects below fail to fire.
  test "3.13: trailing .* matches both the bare prefix and a longer name" do
    m = machine()
    ms = machine_state(m, [idx(:trailing_star)])

    {_ms, matches_bare} = Selection.select_transitions(ms, Event.external("foo"))
    {_ms, matches_longer} = Selection.select_transitions(ms, Event.external("foo.bar"))

    assert [%Transition{}] = matches_bare
    assert [%Transition{}] = matches_longer
  end

  # sabotage: `normalize/1`'s trailing-`""`  clause is deleted (only the
  # trailing-`"*"` clause remains) -> `"foo."` splits to `["foo", ""]`,
  # stays unnormalized, and no longer equals `["foo"]`, reddening this case.
  test "3.13: trailing dot behaves as the bare prefix (foo. matches foo)" do
    m = machine()
    ms = machine_state(m, [idx(:trailing_dot)])

    {_ms, transitions} = Selection.select_transitions(ms, Event.external("foo"))

    assert [%Transition{}] = transitions
  end

  # sabotage: `normalize/1`'s `"*"` clause returns the descriptor unchanged
  # instead of `:lists.droplast(descriptor)` -> the bare descriptor `["*"]`
  # is compared literally instead of as an empty prefix, so it no longer
  # matches an unrelated event name, reddening this case.
  test "3.13: bare * matches every event" do
    m = machine()
    ms = machine_state(m, [idx(:bare_star)])

    {_ms, transitions} = Selection.select_transitions(ms, Event.external("totally.unrelated"))

    assert [%Transition{}] = transitions
  end

  # sabotage: `name_match?/2`'s `Enum.any?/2` is changed to `Enum.all?/2` -
  # a multi-descriptor attribute now requires every descriptor to match
  # instead of any one - so `"foo"` (which does not match `"bar"`) drags
  # down the otherwise-matching `"*"`, and this reddens.
  test "3.13: multi-descriptor - any match enables, including a bare * alongside a specific one" do
    m = machine()
    ms = machine_state(m, [idx(:multi_descriptor)])

    {_ms, transitions} = Selection.select_transitions(ms, Event.external("bar"))

    assert [%Transition{}] = transitions
  end

  # AC: "Child preempts ancestor" - re-asserted end to end (`selection_test.exs`
  # already covers the shape; this is the acceptance-criteria line by name).
  #
  # sabotage: `selected_for_atomic_state/5` walks
  # `Machine.proper_ancestors(machine, state_index)` only, dropping
  # `state_index` itself from the head of the list -> the child's own
  # transition is skipped and the ancestor's is wrongly selected instead.
  test "child preempts ancestor" do
    m = machine()
    ms = machine_state(m, [idx(:descendant)])

    {_ms, transitions} = Selection.select_transitions(ms, Event.external("shared"))

    assert [%Transition{source: source}] = transitions
    assert source == idx(:descendant)
  end

  # AC: "sibling document-order priority"
  #
  # sabotage: `first_matching_transition/5` reverses the state's own
  # `transitions` list before searching -> the second-written transition
  # (targeting `tgt-b`) wins instead of the first.
  test "sibling document-order priority" do
    m = machine()
    ms = machine_state(m, [idx(:multi)])

    {_ms, transitions} = Selection.select_transitions(ms, Event.external("multi-evt"))

    assert [%Transition{targets: [target]}] = transitions
    assert target == idx(:tgt_a)
  end

  # AC: "parallel regions keep non-conflicting transitions (named regression
  # test for the v1 bug)"
  #
  # sabotage: `conflicts?/3` is replaced with a function that always returns
  # `true` (v1's "one group" collapse: any two enabled transitions are
  # treated as conflicting regardless of their actual exit sets) -> only one
  # of the two region-internal transitions survives instead of both.
  test "parallel regions keep non-conflicting transitions" do
    m = machine()
    ms = machine_state(m, [idx(:preg1a), idx(:preg2a)])

    {_ms, transitions} = Selection.select_transitions(ms, Event.external("go"))

    sources = transitions |> Enum.map(& &1.source) |> Enum.sort()
    assert sources == Enum.sort([idx(:preg1a), idx(:preg2a)])
  end

  # AC: "Targetless transitions select with empty exit set"
  #
  # sabotage: `compute_exit_set/2`'s `Enum.reject(&(&1.targets == []))` guard
  # is dropped and `union_exit_set/3`'s `nil ->` branch (a transition whose
  # domain resolved to `nil`) is changed from `acc` to
  # `MapSet.put(acc, transition.source)` -> the targetless transition's exit
  # set is no longer empty, reddening this assertion.
  test "a targetless transition selects, and its exit set is empty" do
    m = machine()
    ms = machine_state(m, [idx(:targetless_holder)])
    transition = transition_named(m, "tless-evt")

    {_ms, transitions} = Selection.select_transitions(ms, Event.external("tless-evt"))
    assert [%Transition{targets: []}] = transitions

    assert Selection.compute_exit_set(ms, [transition]) == MapSet.new()
  end

  # AC: "internal vs external domain difference tested on same source/target"
  #
  # sabotage: `transition_domain/3` drops the `type == :internal` check from
  # its guard, so the compound-source/all-targets-descendants branch fires
  # for the `:external` transition too -> both transitions' domains come back
  # equal (`domain_holder`) instead of differing.
  test "internal vs external domain on the same source/target" do
    m = machine()
    ms = machine_state(m, [])
    internal = transition_named(m, "dom-internal")
    external = transition_named(m, "dom-external")

    assert Selection.get_transition_domain(ms, internal) == idx(:domain_holder)
    # The LCCA of [domain_holder, domain_child] is the scxml root - domain_holder
    # itself is rejected by the LCCA's proper-descendant test.
    assert Selection.get_transition_domain(ms, external) == 0
  end

  # AC: "cond gates selection" - `condition_match/2` evaluates a written
  # `cond` through `Statifier.Evaluator` rather than treating it as an
  # automatic error: `nil` passes, a truthy expression passes, a falsy one
  # does not, and an expression that fails to evaluate (here, an unbound
  # variable) surfaces as an `Evaluator.Error`, not a swallowed `false`.
  #
  # sabotage: `evaluate_cond/2`'s `{:ok, true} -> {:ok, true}` clause is
  # changed to `{:ok, true} -> {:ok, false}` -> the `cond="true"` assertion
  # below reddens.
  test "condition_match/2: nil -> {:ok, true}, true -> {:ok, true}, false -> {:ok, false}, unbound -> error" do
    m = machine()
    ms = machine_state(m, [])
    nocond = transition_named(m, "nc-evt")
    condtrue = transition_named(m, "c-evt")
    condfalse = transition_named(m, "cf-evt")
    condunbound = transition_named(m, "cu-evt")

    assert Selection.condition_match(ms, nocond) == {:ok, true}
    assert Selection.condition_match(ms, condtrue) == {:ok, true}
    assert Selection.condition_match(ms, condfalse) == {:ok, false}

    assert {:error, %Evaluator.Error{error: %UndefinedVariableError{}}} =
             Selection.condition_match(ms, condunbound)
  end

  # AC: "All functions pure, plain values in and out; callable standalone in
  # iex" - the executable form of `docs/observability.md` constraint 5: every
  # one of the eight functions is called directly here with values built by
  # hand from the compiled machine, no support code and no stepping.
  #
  # sabotage: `condition_match/2`'s `cond: nil` clause is changed from
  # `{:ok, true}` to `{:error, :nope}` -> this reddens both the direct
  # `condition_match/2` assertion and the `select_transitions/2` assertion
  # below (the no-cond transition is no longer enabled), since every other
  # function in this test either calls it or is unaffected.
  test "all eight functions are callable standalone with plain values" do
    m = machine()
    dom_transition = transition_named(m, "dom-internal")
    nocond_transition = transition_named(m, "nc-evt")
    ms = machine_state(m, [idx(:domain_child), idx(:nocond_holder)])

    assert Selection.find_lcca(m, [idx(:preg1a), idx(:preg2a)]) == 0

    assert Selection.get_effective_target_states(ms, dom_transition) == [idx(:domain_child)]
    assert Selection.get_transition_domain(ms, dom_transition) == idx(:domain_holder)
    assert Selection.compute_exit_set(ms, [dom_transition]) == MapSet.new([idx(:domain_child)])
    assert Selection.condition_match(ms, nocond_transition) == {:ok, true}

    {_ms, selected} = Selection.select_transitions(ms, Event.external("nc-evt"))
    assert [%Transition{events: [["nc-evt"]]}] = selected

    {_ms, eventless_selected} = Selection.select_eventless_transitions(ms)
    assert eventless_selected == []

    assert Selection.remove_conflicting_transitions(ms, [nocond_transition]) == [
             nocond_transition
           ]
  end
end
