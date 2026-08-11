defmodule Statifier.Interpreter.InterpreterAcceptanceTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Event
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

  # One document covering every acceptance-criteria line a test can decide,
  # in the shape of `selection_acceptance_test.exs`.
  #
  # Hand-drawn from `@document`, depth-first, document order.
  #
  #  0 scxml (root; initial="s0")
  #  1   s0      -- onentry log; eventless -> s0a (first eventless hop)
  #  2   s0a     -- eventless -> s1 (second, back-to-back eventless hop -
  #                 s0a's own transition cannot be selected until s0a is
  #                 already active, which only happens after s0's own
  #                 microstep runs: the "eventless retried after every
  #                 microstep" case)
  #  3   s1      -- onentry raises "e1" then "e2" in one block (both queued
  #                 at once); transition event="e1" -> s2
  #  4   s2      -- transition event="e2" -> s3 (e1 and e2 must be consumed
  #                 as two separate selection rounds, not drained together,
  #                 or s2's transition would never get its own round)
  #  5   s3      -- transition event="go" -> term (external event)
  #  6   term    -- eventless -> final1
  #  7   final1  -- top-level <final>
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s0">
      <state id="s0">
          <onentry>
              <log label="s0-enter"/>
          </onentry>
          <transition target="s0a"/>
      </state>
      <state id="s0a">
          <transition target="s1"/>
      </state>
      <state id="s1">
          <onentry>
              <raise event="e1"/>
              <raise event="e2"/>
          </onentry>
          <transition event="e1" target="s2"/>
      </state>
      <state id="s2">
          <transition event="e2" target="s3"/>
      </state>
      <state id="s3">
          <transition event="go" target="term"/>
      </state>
      <state id="term">
          <transition target="final1"/>
      </state>
      <final id="final1"/>
  </scxml>
  """

  @indexes %{
    s0: 1,
    s0a: 2,
    s1: 3,
    s2: 4,
    s3: 5,
    term: 6,
    final1: 7
  }

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp machine_state(machine, configuration, opts \\ [trace: true]) do
    %{MachineState.new(machine, opts) | configuration: MapSet.new(configuration)}
  end

  defp trace_effects(effects), do: Enum.filter(effects, &Effect.trace?/1)

  # The normalized view `MachineState`'s own moduledoc requires for a
  # position comparison - never raw `%MachineState{}` equality, since two
  # `:queue` values holding the same events in the same order can differ
  # structurally.
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

  defp has_trace?(effects, mod) do
    Enum.any?(effects, fn
      {:trace, %{__struct__: ^mod}} -> true
      _other -> false
    end)
  end

  # Every `{:trace, payload}` and `{:done, payload}` member's own
  # `microstep` field - the surface Decision 5's invariant ("no effect and
  # no cause is ever stamped `microstep: 0`") covers.
  #
  # `EventDequeued` and `TransitionsSelected` are deliberately excluded from
  # their *own* `microstep` field here, following `entry_test.exs`'s own
  # precedent: Decision 5's text stamps both *before* `begin_microstep/1`,
  # "the number of microsteps completed in this macrostep so far" - which
  # is legitimately `0` for the very first selection round of any
  # macrostep (`handle_event/2`'s own `EventDequeued` from `:external`, in
  # particular). The invariant is about step-*body* effects, not about the
  # pre-round selection trace's own stamp.
  defp microsteps_on(effects) do
    Enum.flat_map(effects, fn
      {:trace, %Effect.Trace.EventDequeued{}} -> []
      {:trace, %Effect.Trace.TransitionsSelected{}} -> []
      {:trace, payload} -> [payload.microstep]
      {:done, payload} -> [payload.microstep]
      _other -> []
    end)
  end

  # AC: "microstep/macrostep boundary is a resumable machine_state value;
  # stepping vs folding from the same start yields identical final state
  # and effect sequence" (`docs/observability.md` constraint 1).
  #
  # The round trip through `:erlang.binary_to_term(:erlang.term_to_binary/1)`
  # between every step is what makes this non-tautological: it proves
  # nothing about the paused position lives outside the struct (no pid, no
  # ref, no closure), which is the property a step debugger actually
  # depends on.
  #
  # sabotage: `macrostep/2`'s accumulator is changed from
  # `macrostep(machine_state, effects ++ round_effects)` to
  # `macrostep(machine_state, round_effects ++ effects)` (prepending instead
  # of appending) -> the fold's effect order diverges from the step loop's,
  # reddening the effect-sequence equality below.
  test "constraint 1: folding with macrostep/1 and stepping with microstep/1 (round-tripped through binary_to_term between every step) reach the same position and effects" do
    m = machine()
    ms = machine_state(m, [idx(:s0)])

    {fold_result, fold_effects} = Interpreter.macrostep(ms)
    {step_result, step_effects} = step_to_quiescence_round_tripped(ms)

    assert normalized(fold_result) == normalized(step_result)
    # macrostep/1 appends one extra MacrostepStable the bare step loop never
    # builds on its own (it stops the instant microstep/1 returns
    # :quiescent).
    assert Enum.drop(fold_effects, -1) == step_effects

    assert [%Effect.Trace.MacrostepStable{}] =
             for({:trace, %Effect.Trace.MacrostepStable{} = payload} <- fold_effects, do: payload)
  end

  defp step_to_quiescence_round_tripped(machine_state, effects \\ []) do
    case Interpreter.microstep(machine_state) do
      :quiescent ->
        {machine_state, effects}

      {next_state, round_effects} ->
        round_tripped = :erlang.binary_to_term(:erlang.term_to_binary(next_state))
        step_to_quiescence_round_tripped(round_tripped, effects ++ round_effects)
    end
  end

  # AC: "Trace: ... trace-off produces zero trace effects (asserted)".
  #
  # sabotage: `handle_event/2`'s `Effect.trace(machine_state,
  # Effect.Trace.EventDequeued, event: event, from: :external)` call is
  # replaced with an unconditional bare list literal
  # `[{:trace, Effect.Trace.EventDequeued.new(machine_state, event: event,
  # from: :external)}]` -> a `trace: false` run now carries a trace effect,
  # reddening the zero-trace assertion below.
  test "trace off is total across initialize/2 and several handle_event/2 calls" do
    m = machine()
    {fresh, init_effects} = Interpreter.initialize(m, trace: false)

    {:ok, no_match, no_match_effects} = Interpreter.handle_event(fresh, Event.external("nope"))
    {:ok, _done, done_effects} = Interpreter.handle_event(no_match, Event.external("go"))

    assert trace_effects(init_effects) == []
    assert trace_effects(no_match_effects) == []
    assert trace_effects(done_effects) == []
  end

  # AC: "Trace: event dequeued, transitions selected, macrostep stable,
  # done emitted here, gated" - the full seven-point vocabulary
  # (`docs/observability.md` constraint 2), every payload carrying the
  # counters.
  #
  # sabotage: `macrostep/1`'s `stable = if machine_state.running do
  # Effect.trace(...) else [] end` binding is replaced with a bare
  # `stable = []` -> no `MacrostepStable` is ever built, reddening the
  # "all seven vocabulary points present" assertion below.
  test "trace on covers the vocabulary: all seven payload modules appear, every one carrying the counters" do
    m = machine()
    {fresh, init_effects} = Interpreter.initialize(m, trace: true)
    {:ok, _done, event_effects} = Interpreter.handle_event(fresh, Event.external("go"))

    effects = init_effects ++ event_effects

    for mod <- [
          Effect.Trace.EventDequeued,
          Effect.Trace.TransitionsSelected,
          Effect.Trace.ExitSet,
          Effect.Trace.ContentExecuted,
          Effect.Trace.EntrySet,
          Effect.Trace.MacrostepStable,
          Effect.Trace.Done
        ] do
      assert has_trace?(effects, mod), "expected at least one #{inspect(mod)} trace effect"
    end

    for {:trace, payload} <- effects do
      assert is_integer(payload.macrostep) and payload.macrostep > 0
      assert is_integer(payload.microstep) and payload.microstep >= 0
    end

    # Decision 5's invariant, restated for this acceptance run: see
    # `microsteps_on/1`'s own comment for exactly which fields it covers
    # and why EventDequeued/TransitionsSelected's own `microstep` field is
    # excluded.
    refute 0 in microsteps_on(effects)
  end

  # AC: "exit_interpreter ports the pseudocode; terminal {:done, donedata}
  # emitted exactly once; static donedata only" and "handle_event on a done
  # chart returns a defined error shape".
  #
  # sabotage: `exit_interpreter/1`'s terminal effect list is built as
  # `[done_effect] ++ exit_effects ++ done_trace` instead of `exit_effects
  # ++ done_trace ++ [done_effect]` -> `{:done, _}` is no longer the last
  # member of its own call's effect list, reddening the assertion below.
  test "termination: exactly one {:done, _} across the whole run, last in its own call's effect list; handle_event/2 afterwards errors" do
    m = machine()
    {fresh, init_effects} = Interpreter.initialize(m, trace: true)
    refute Enum.any?(init_effects, &match?({:done, _}, &1))

    {:ok, done, event_effects} = Interpreter.handle_event(fresh, Event.external("go"))

    assert done.status == :done
    done_effects_in_call = for {:done, _payload} = effect <- event_effects, do: effect
    assert [done_effect] = done_effects_in_call
    assert List.last(event_effects) == done_effect

    assert Interpreter.handle_event(done, Event.external("go")) == {:error, :not_running}
  end

  # AC: "Quiescence loop diffs against the pseudocode: eventless retried
  # after every microstep, internal events consumed one per selection round".
  #
  # sabotage: `internal_round/1`'s success clause is changed to recurse
  # into itself and merge the result - draining every queued internal event
  # within one `internal_round/1` call (and therefore one `microstep/1`
  # call) instead of returning after exactly one round -> the "after one
  # microstep/1 call, e2 is still queued and s3 has not been reached yet"
  # assertion below reddens, since the mutated code reaches s3 in a single
  # call.
  test "quiescence diff: eventless transitions retry after every microstep, internal events are consumed one per selection round" do
    m = machine()
    ms = machine_state(m, [idx(:s0)])

    # s0's own eventless transition cannot fire s0a's until s0a is itself
    # active - each hop is its own microstep/1 call.
    assert {after_s0, _effects} = Interpreter.microstep(ms)
    assert after_s0.configuration == MapSet.new([idx(:s0a)])

    # Entering s1 runs its single onentry block, which raises "e1" then
    # "e2" - both land on the internal queue at once.
    assert {after_s0a, _effects} = Interpreter.microstep(after_s0)
    assert after_s0a.configuration == MapSet.new([idx(:s1)])
    assert [%{name: "e1"}, %{name: "e2"}] = MachineState.internal_events(after_s0a)

    # Step microstep/1 by hand from here: a single call must consume
    # exactly one queued event and leave the other pending - `microstep/1`
    # is one round, not a drain loop.
    assert {after_e1, _effects} = Interpreter.microstep(after_s0a)
    assert after_e1.configuration == MapSet.new([idx(:s2)])
    assert [%{name: "e2"}] = MachineState.internal_events(after_e1)

    assert {after_e2, _effects} = Interpreter.microstep(after_e1)
    assert after_e2.configuration == MapSet.new([idx(:s3)])
    assert MachineState.internal_events(after_e2) == []

    {result, effects} = Interpreter.macrostep(ms)

    assert result.configuration == MapSet.new([idx(:s3)])
    assert MachineState.internal_events(result) == []

    # "e1" and "e2" were both queued by s1's single onentry block, but each
    # is dequeued and selected on in its own round rather than drained
    # together - two separate EventDequeued(from: :internal) traces, not
    # one.
    internal_dequeues =
      for {:trace, %Effect.Trace.EventDequeued{from: :internal}} <- effects, do: 1

    assert length(internal_dequeues) == 2
  end
end
