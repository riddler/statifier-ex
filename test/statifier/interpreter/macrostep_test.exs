defmodule Statifier.Interpreter.MacrostepTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Interpreter
  alias Statifier.Lowering
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Hand-drawn from `@document`, depth-first, document order.
  #
  #  0 scxml (root)
  #  1   p1        -- eventless transition -> p2
  #  2   p2        -- eventless transition -> p3
  #  3   p3
  #  4   pre_q     -- eventless transition -> q1
  #  5   q1        -- onentry raises "go"; transition event="go" -> q2
  #  6   q2
  #  7   term      -- eventless transition -> final1
  #  8   final1    -- top-level <final>
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p1">
      <state id="p1">
          <transition target="p2"/>
      </state>
      <state id="p2">
          <transition target="p3"/>
      </state>
      <state id="p3"/>
      <state id="pre_q">
          <transition target="q1"/>
      </state>
      <state id="q1">
          <onentry>
              <raise event="go"/>
          </onentry>
          <transition event="go" target="q2"/>
      </state>
      <state id="q2"/>
      <state id="term">
          <transition target="final1"/>
      </state>
      <final id="final1"/>
  </scxml>
  """

  @indexes %{
    p1: 1,
    p2: 2,
    p3: 3,
    pre_q: 4,
    q1: 5,
    q2: 6,
    term: 7,
    final1: 8
  }

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp machine_state(machine, configuration, opts \\ [trace: true]) do
    %{MachineState.new(machine, opts) | configuration: MapSet.new(configuration)}
  end

  defp trace_effects(effects), do: Enum.filter(effects, &Effect.trace?/1)

  # Steps `microstep/1` by hand until it reports quiescence, accumulating
  # effects in call order - the step-by-step counterpart to `macrostep/1`,
  # used only by the equivalence test below. The quiescent round carries a
  # machine_state and effects of its own, so this takes both from the
  # return rather than falling back to the value it passed in.
  defp step_to_quiescence(machine_state, effects \\ []) do
    case Interpreter.microstep(machine_state) do
      {:quiescent, machine_state, round_effects} ->
        {machine_state, effects ++ round_effects}

      {machine_state, round_effects} ->
        step_to_quiescence(machine_state, effects ++ round_effects)
    end
  end

  # The normalized view `MachineState`'s own moduledoc requires for a
  # position comparison - never raw `%MachineState{}` equality, since two
  # `:queue` values holding the same events can differ structurally.
  defp normalized(machine_state) do
    %{
      configuration: machine_state.configuration,
      internal_events: MachineState.internal_events(machine_state),
      history_values: machine_state.history_values,
      macrostep: machine_state.macrostep,
      microstep: machine_state.microstep,
      status: machine_state.status,
      running: machine_state.running
    }
  end

  describe "macrostep/1" do
    # sabotage: `macrostep/3`'s non-quiescent clause is changed from
    # `macrostep(machine_state, effects ++ round_effects, spend(rounds_left))`
    # to `macrostep(machine_state, effects, spend(rounds_left))`, dropping
    # each round's effects while still recursing to quiescence -> the final
    # configuration is still right but the effect list is short, reddening
    # the `TransitionsSelected` count assertion below.
    test "a chain of eventless transitions drains in one call" do
      m = machine()
      ms = machine_state(m, [idx(:p1)])

      {result, effects} = Interpreter.macrostep(ms)

      assert MapSet.new([idx(:p3)]) == result.configuration
      assert result.microstep == ms.microstep + 2

      # Two microsteps ran: p1 -> p2, then p2 -> p3. Each contributes an
      # ExitSet and an EntrySet trace, so four structural traces plus three
      # TransitionsSelected rounds plus the final MacrostepStable. Three,
      # not two: the terminal eventless probe that ends the fold is a
      # selection like any other and emits its own row with `t_indexes: []`
      # (Decision 2, revised), which is what makes
      # `docs/observability.md`'s "includes the empty set" hold without an
      # exception.
      selected = for {:trace, %Effect.Trace.TransitionsSelected{} = p} <- effects, do: p
      assert length(selected) == 3
      assert [[], [], []] != Enum.map(selected, & &1.t_indexes)
      assert List.last(selected).t_indexes == []
    end

    # sabotage: `internal_round/1`'s
    # `Selection.select_transitions(machine_state, event)` result is
    # discarded and `transitions` forced to `[]` -> the dequeued "go"
    # event is consumed but never selected on, so the fold stalls at q1
    # instead of reaching q2, reddening the configuration assertion.
    test "an onentry-raised event is consumed in the same macrostep" do
      m = machine()
      ms = machine_state(m, [idx(:pre_q)])

      {result, _effects} = Interpreter.macrostep(ms)

      assert MapSet.new([idx(:q2)]) == result.configuration
      assert MachineState.internal_events(result) == []
    end

    # Eventless transitions are re-probed after every microstep, not only
    # once at the start: p2's own eventless transition cannot be selected
    # until p2 is active, which only happens after the first microstep
    # runs.
    #
    # sabotage: `run_selected/3`'s non-empty branch has its
    # `microstep(machine_state, transitions)` call replaced with
    # `microstep(machine_state, [])` (running an empty transition set
    # instead of the selected one) -> the first `microstep/1` call no
    # longer moves the configuration off p1, reddening the first
    # assertion.
    test "eventless transitions are retried after every microstep, not only at the start" do
      m = machine()
      ms = machine_state(m, [idx(:p1)])

      assert {after_first, _effects} = Interpreter.microstep(ms)
      assert after_first.configuration == MapSet.new([idx(:p2)])

      assert {after_second, _effects} = Interpreter.microstep(after_first)
      assert after_second.configuration == MapSet.new([idx(:p3)])
    end

    # sabotage: `macrostep/1`'s `Trace.MacrostepStable` call is given
    # `configuration: MapSet.new()` instead of
    # `configuration: machine_state.configuration` -> the trace's
    # configuration comes back empty instead of naming p3, reddening the
    # configuration assertion.
    test "MacrostepStable carries the configuration and counters at quiescence" do
      m = machine()
      ms = machine_state(m, [idx(:p1)])

      {result, effects} = Interpreter.macrostep(ms)

      assert [%Effect.Trace.MacrostepStable{} = stable] =
               for({:trace, %Effect.Trace.MacrostepStable{} = payload} <- effects, do: payload)

      assert stable.configuration == MapSet.new([idx(:p3)])
      assert stable.macrostep == result.macrostep
      assert stable.microstep == result.microstep
    end

    # sabotage: `macrostep/1`'s `if machine_state.running do ... else [] end`
    # guard is inverted to `if not machine_state.running do ... end` ->
    # a terminating fold now emits `MacrostepStable`, reddening the
    # "no MacrostepStable" assertion below.
    test "a macrostep that terminates mid-fold emits no MacrostepStable" do
      m = machine()
      ms = machine_state(m, [idx(:term)])

      {result, effects} = Interpreter.macrostep(ms)

      refute result.running
      refute Enum.any?(effects, &match?({:trace, %Effect.Trace.MacrostepStable{}}, &1))
    end

    # sabotage: `macrostep/1`'s `MacrostepStable` emission is built as a
    # bare `{:trace, Effect.Trace.MacrostepStable.new(...)}` list literal
    # instead of going through the gated `Effect.trace/3` macro -> a
    # `trace: false` run still emits `MacrostepStable`, reddening the
    # zero-trace-effects assertion.
    test "trace: false yields zero trace effects over a whole macrostep" do
      m = machine()
      ms = machine_state(m, [idx(:p1)], trace: false)

      {result, effects} = Interpreter.macrostep(ms)

      assert result.configuration == MapSet.new([idx(:p3)])
      assert trace_effects(effects) == []
    end

    # The constraint-1 test in its Phase-2 form: stepping with
    # `microstep/1` until `:quiescent` and folding with `macrostep/1` from
    # the same start reach the same normalized position and produce the
    # same effect sequence, except that the fold appends one extra
    # `MacrostepStable` the step loop never builds on its own.
    #
    # sabotage: `macrostep/3`'s accumulator is changed from
    # `macrostep(machine_state, effects ++ round_effects, spend(rounds_left))`
    # to `macrostep(machine_state, round_effects ++ effects, spend(rounds_left))`
    # (prepending instead of appending) -> the fold's effect order diverges
    # from the step loop's, reddening the effect-sequence equality.
    test "stepping and folding from the same start reach the same position and effects" do
      m = machine()
      ms = machine_state(m, [idx(:pre_q)])

      {fold_result, fold_effects} = Interpreter.macrostep(ms)
      {step_result, step_effects} = step_to_quiescence(ms)

      assert normalized(fold_result) == normalized(step_result)
      assert Enum.drop(fold_effects, -1) == step_effects

      assert [%Effect.Trace.MacrostepStable{}] =
               for(
                 {:trace, %Effect.Trace.MacrostepStable{} = payload} <- fold_effects,
                 do: payload
               )
    end
  end

  # An ordinary eventless self-loop - deliberately not a `cond`, so the
  # budget block proves the bound is shape-agnostic (ADR-0019: "The bound
  # must be engine-level and shape-agnostic").
  #
  #  0 scxml (root)
  #  1   spin      -- eventless transition -> spin
  @spin_document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="spin">
      <state id="spin">
          <transition target="spin"/>
      </state>
  </scxml>
  """

  defp spin_machine, do: compile!(@spin_document)

  defp budget_exhausted_effects(effects) do
    Enum.filter(effects, &match?({:budget_exhausted, _}, &1))
  end

  describe "macrostep/1 round budget" do
    # sabotage: `defp macrostep(machine_state, effects, 0)` (the base case)
    # is removed, so the fold is unbounded again -> the fold never returns
    # and the test hangs. Bounded with `@tag timeout: 2_000` while
    # confirming red, so the mutation costs about two seconds instead of
    # ExUnit's 60-second default; the mutation is still genuinely run, only
    # the wait is bounded.
    @tag timeout: 2_000
    test "exhaustion returns the effect and no MacrostepStable" do
      m = spin_machine()
      ms = machine_state(m, [1], max_macrostep_rounds: 5, trace: true)

      {_result, effects} = Interpreter.macrostep(ms)

      assert [{:budget_exhausted, %Effect.BudgetExhausted{budget: 5}}] =
               budget_exhausted_effects(effects)

      refute Enum.any?(effects, &match?({:trace, %Effect.Trace.MacrostepStable{}}, &1))
    end

    # sabotage: `macrostep/1` is given an extra clause that forces
    # `running: false` on the returned machine_state whenever the private
    # fold's outcome is `:exhausted` -> the `running` assertion below
    # reddens.
    test "the position is intact and resumable" do
      m = spin_machine()
      ms = machine_state(m, [1], max_macrostep_rounds: 5, trace: true)

      {result, _effects} = Interpreter.macrostep(ms)

      assert result.running
      assert result.status == :running
      assert result.configuration == MapSet.new([1])

      assert {next_result, _next_effects} = Interpreter.microstep(result)
      assert next_result.configuration == MapSet.new([1])
    end

    # sabotage: `spend/1`'s integer clause is changed from `rounds_left - 1`
    # to `rounds_left` (never decrementing) -> the fold no longer terminates
    # and the test hangs. Bounded with `@tag timeout: 2_000` while confirming
    # red. A second mutation - `defp macrostep(ms, effects, 0)` changed to
    # match `1` - reddens the counter equality by one instead of hanging.
    @tag timeout: 2_000
    test "the budget bounds rounds exactly" do
      m = spin_machine()
      ms = machine_state(m, [1], max_macrostep_rounds: 5, trace: true)

      {_result, effects} = Interpreter.macrostep(ms)

      assert [{:budget_exhausted, %Effect.BudgetExhausted{macrostep: macrostep, microstep: 5}}] =
               budget_exhausted_effects(effects)

      assert macrostep == ms.macrostep
    end

    # sabotage: `macrostep/1` seeds the fold with `0` instead of
    # `machine_state.max_macrostep_rounds` -> the chain exhausts immediately
    # and both assertions below redden.
    test "a legitimate chart is untouched by the default budget" do
      m = machine()
      ms = machine_state(m, [idx(:p1)])

      {result, effects} = Interpreter.macrostep(ms)

      assert result.configuration == MapSet.new([idx(:p3)])
      assert Enum.any?(effects, &match?({:trace, %Effect.Trace.MacrostepStable{}}, &1))
      assert budget_exhausted_effects(effects) == []
    end

    # The off-by-one boundary: the `@document` chain from `p1` folds to
    # quiescence in exactly three rounds (probed directly against the
    # running code, per the plan's instruction not to assume it).
    #
    # sabotage: the `0`-matching head is changed to a `when rounds_left <= 1`
    # guard -> the exact-budget case exhausts instead of reaching quiescence,
    # reddening the quiescence assertions.
    test "a budget exactly equal to the rounds needed still reaches quiescence" do
      m = machine()
      exact_ms = machine_state(m, [idx(:p1)], max_macrostep_rounds: 3, trace: true)
      short_ms = machine_state(m, [idx(:p1)], max_macrostep_rounds: 2, trace: true)

      {exact_result, exact_effects} = Interpreter.macrostep(exact_ms)

      assert exact_result.configuration == MapSet.new([idx(:p3)])
      assert Enum.any?(exact_effects, &match?({:trace, %Effect.Trace.MacrostepStable{}}, &1))
      assert budget_exhausted_effects(exact_effects) == []

      {_short_result, short_effects} = Interpreter.macrostep(short_ms)

      assert [{:budget_exhausted, _payload}] = budget_exhausted_effects(short_effects)
    end

    # sabotage: `spend(:infinity)` is changed to return `0` -> the
    # `:infinity` run exhausts after one round instead of reaching
    # quiescence, reddening the configuration assertion.
    test ":infinity folds a terminating chart to quiescence" do
      m = machine()
      ms = machine_state(m, [idx(:p1)], max_macrostep_rounds: :infinity, trace: true)

      {result, effects} = Interpreter.macrostep(ms)

      assert result.configuration == MapSet.new([idx(:p3)])
      assert Enum.any?(effects, &match?({:trace, %Effect.Trace.MacrostepStable{}}, &1))
      assert budget_exhausted_effects(effects) == []
    end

    # sabotage: `terminal_effects/2`'s `:exhausted` clause is routed through
    # `Effect.trace/3` instead of built directly -> the untraced run emits
    # nothing, reddening the effect assertion below.
    test "trace: false still yields the effect" do
      m = spin_machine()
      ms = machine_state(m, [1], max_macrostep_rounds: 5, trace: false)

      {_result, effects} = Interpreter.macrostep(ms)

      assert [{:budget_exhausted, _payload}] = budget_exhausted_effects(effects)
      assert trace_effects(effects) == []
    end
  end
end
