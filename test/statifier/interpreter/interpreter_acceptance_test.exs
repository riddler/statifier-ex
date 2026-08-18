defmodule Statifier.Interpreter.InterpreterAcceptanceTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Effect, Event, Interpreter, Lowering}
  alias Statifier.{Machine, MachineState, Parser, Validator}

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
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
  #
  # `FinalizeAutoforward` and `InvokePass` join them for the same reason
  # (`entry_test.exs`'s own `microsteps_on/1` spells out both cases): the
  # first is stamped before any microstep of its macrostep has run, the
  # second is stamped after a fold that may have run zero microsteps (an
  # eventless probe with nothing to select and an already-empty internal
  # queue reaches quiescence without ever calling `begin_microstep/1`).
  defp microsteps_on(effects) do
    Enum.flat_map(effects, fn
      {:trace, %Effect.Trace.EventDequeued{}} -> []
      {:trace, %Effect.Trace.TransitionsSelected{}} -> []
      {:trace, %Effect.Trace.FinalizeAutoforward{}} -> []
      {:trace, %Effect.Trace.InvokePass{}} -> []
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
      {:quiescent, next_state, round_effects} ->
        round_tripped = :erlang.binary_to_term(:erlang.term_to_binary(next_state))
        {round_tripped, effects ++ round_effects}

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

  # AC (st-af3.2): "a failing cond enqueues error.execution catchable in the
  # same macrostep", proven through the real interpreter loop rather than
  # `Selection`'s entry points directly (`selection_test.exs` already covers
  # those). The `go` transition's cond names an unbound variable, so
  # `Selection.select_transitions/2` does not enable it and raises
  # `error.execution` on the internal queue instead; the sibling
  # `event="error.execution"` transition on the same state is what proves
  # the raised event is catchable within the one `handle_event/2` call that
  # raised it - one macrostep, per `docs/architecture.md` principle 3 and
  # spec 3.12.2/5.10.1. Deliberately event-matched (not eventless) so the
  # macrostep terminates - see the plan's "What We're NOT Doing" on the
  # eventless-cond-error livelock (st-sd1) - see the "an erroring eventless
  # cond terminates on the round budget" block below, which is the pair to
  # this one: this block proves an event-matched failing cond is catchable
  # same-macrostep, that block proves an eventless failing cond terminates
  # on ADR-0019's round budget instead of livelocking.
  describe "a failed cond becomes a catchable error.execution" do
    @catch_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a" datamodel="predicator">
        <state id="a">
            <transition event="go" cond="nope" target="b"/>
            <transition event="error.execution" target="caught"/>
        </state>
        <state id="b"/>
        <state id="caught"/>
    </scxml>
    """

    # No `event="error.execution"` catcher anywhere - proves the engine
    # reaches quiescence with the error consumed rather than hanging, and
    # that the failed cond actually gated the transition (`b` is never
    # entered).
    @uncaught_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a" datamodel="predicator">
        <state id="a">
            <transition event="go" cond="nope" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """

    defp catch_machine, do: compile!(@catch_document)
    defp uncaught_machine, do: compile!(@uncaught_document)

    defp state_index(machine, id) do
      {:ok, index} = Machine.index(machine, id)
      index
    end

    defp catcher_transition(machine) do
      machine.transitions
      |> Tuple.to_list()
      |> Enum.find(&(&1.events == [["error", "execution"]]))
    end

    # sabotage: `Selection.raise_cond_errors/2` (via `Cause.origin/0`'s
    # `{:transition, t_index}` arm) is short-circuited to return
    # `machine_state` unchanged, dropping the error before it reaches the
    # internal queue -> `handle_event/2` no longer has anything to catch,
    # so the configuration stays `a` and this assertion reddens.
    test "the error is raised, dequeued, and selected on inside one handle_event/2 call - configuration holds caught, not b" do
      m = catch_machine()
      {fresh, _init_effects} = Interpreter.initialize(m)

      assert {:ok, result, _effects} = Interpreter.handle_event(fresh, Event.external("go"))

      assert result.configuration == MapSet.new([0, state_index(m, "caught")])
      refute state_index(m, "b") in result.configuration
    end

    # sabotage: `Interpreter.handle_event/2`'s `MachineState.begin_macrostep/1`
    # call is duplicated so a second macrostep begins mid-round while
    # catching the internal `error.execution` -> the macrostep counter
    # advances by two instead of one, reddening the equality below.
    test "same macrostep: the macrostep counter advances by exactly the one handle_event/2 began, and the internal queue is empty at quiescence" do
      m = catch_machine()
      {fresh, _init_effects} = Interpreter.initialize(m)

      assert {:ok, result, _effects} = Interpreter.handle_event(fresh, Event.external("go"))

      assert result.macrostep == fresh.macrostep + 1
      assert MachineState.internal_events(result) == []
    end

    # sabotage: `Interpreter.internal_round/1`'s dequeue branch is changed
    # to select without first emitting `Trace.EventDequeued` (the trace
    # effect is dropped, selection still runs) -> no `EventDequeued` with
    # `from: :internal` for `error.execution` shows up, reddening the
    # `Enum.find_index` assertions below.
    test "trace: EventDequeued(from: :internal) for error.execution is followed by TransitionsSelected naming the catcher" do
      m = catch_machine()
      {fresh, _init_effects} = Interpreter.initialize(m, trace: true)
      catcher = catcher_transition(m)

      assert {:ok, _result, effects} = Interpreter.handle_event(fresh, Event.external("go"))

      dequeued_index =
        Enum.find_index(effects, fn
          {:trace,
           %Effect.Trace.EventDequeued{from: :internal, event: %{name: "error.execution"}}} ->
            true

          _other ->
            false
        end)

      selected_index =
        Enum.find_index(effects, fn
          {:trace, %Effect.Trace.TransitionsSelected{t_indexes: t_indexes}} ->
            catcher.t_index in t_indexes

          _other ->
            false
        end)

      assert is_integer(dequeued_index)
      assert is_integer(selected_index)
      assert dequeued_index < selected_index
    end

    # sabotage: `Selection.cond_enabled/3`'s `{:error, reason} -> {false,
    # cond_errors ++ [{transition, reason}]}` clause is changed to `{:error,
    # _reason} -> {true, cond_errors}` -> a failing cond wrongly enables its
    # transition, so `handle_event/2` takes `go` straight to `b` instead of
    # gating it, reddening the configuration assertion below.
    test "an uncaught error.execution reaches quiescence with the error consumed and the configuration still in a" do
      m = uncaught_machine()
      {fresh, _init_effects} = Interpreter.initialize(m)

      assert {:ok, result, _effects} = Interpreter.handle_event(fresh, Event.external("go"))

      assert result.configuration == MapSet.new([0, state_index(m, "a")])
      assert MachineState.internal_events(result) == []
      assert result.running
    end
  end

  # AC (st-sd1): "A macrostep that cannot reach quiescence terminates with a
  # defined, observable outcome instead of hanging" - the bead's own
  # reproduction, driven through the real interpreter loop rather than the
  # fold's unit fixture (`macrostep_test.exs`'s self-loop block already
  # covers the shape-agnostic budget). Eventless, not event-matched, which
  # is the one difference from `@uncaught_document` above: each round, the
  # eventless probe evaluates the failing cond, enqueues `error.execution`,
  # and returns `[]`; `internal_round/1` dequeues the error and selects on
  # it, which never re-evaluates the eventless cond (an event-matched round
  # short-circuits `%Transition{events: []}` before reaching it); nothing is
  # enabled, the queue empties, and the cycle repeats forever without
  # ADR-0019's round budget. The livelock strikes during the initialization
  # macrostep, so the entry point is `Interpreter.initialize/2` with a small
  # explicit budget so a regression reddens in milliseconds instead of at
  # ExUnit's 60-second timeout.
  describe "an erroring eventless cond terminates on the round budget" do
    @livelock_document """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a" datamodel="predicator">
        <state id="a">
            <transition cond="nope" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """

    defp livelock_machine, do: compile!(@livelock_document)

    defp budget_exhausted(effects) do
      Enum.find_value(effects, fn
        {:budget_exhausted, payload} -> payload
        _other -> nil
      end)
    end

    # sabotage: the `defp macrostep(machine_state, effects, 0)` head is
    # removed, so the fold is unbounded again -> this test hangs. Confirmed
    # red under this test's own `@tag timeout: 5_000` while the mutation
    # was in place (the mutation genuinely reintroduces the hang; only the
    # wait to observe it is bounded); reverted and confirmed green. This is
    # the whole bead in one mutation.
    @tag timeout: 5_000
    test "it terminates with the effect instead of hanging" do
      m = livelock_machine()

      {result, effects} = Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)

      assert [%Effect.BudgetExhausted{budget: 20}] =
               for({:budget_exhausted, payload} <- effects, do: payload)

      refute has_trace?(effects, Effect.Trace.MacrostepStable)
      assert result.running
      assert result.status == :running
      assert result.configuration == MapSet.new([0, state_index(m, "a")])
      refute state_index(m, "b") in result.configuration
    end

    # sabotage: `spend/1`'s integer clause is changed to `rounds_left`
    # (never decrementing) - the mechanical form of "the budget is charged
    # only on rounds that run a microstep": the livelock's rounds never run
    # one, so under either phrasing the fold never spends its budget and
    # times this test out. Confirmed red under this test's own
    # `@tag timeout: 5_000` while the mutation was in place; reverted and
    # confirmed green.
    @tag timeout: 5_000
    test "the bound counts rounds, not microsteps" do
      m = livelock_machine()

      {_result, effects} = Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)

      assert %Effect.BudgetExhausted{microstep: 1} = budget_exhausted(effects)
    end

    # Verified against the running interpreter rather than assumed from the
    # plan's prose: for this single-transition reproduction, each round's
    # eventless probe raises exactly one `error.execution` and
    # `internal_round/1` dequeues that same event before the round ends -
    # the "queue empties, cycle repeats" this phase's own Manual
    # Verification item describes - so the queue is genuinely empty at
    # every round boundary, exhaustion included, whatever the budget. (An
    # earlier draft of this test asserted the field non-empty, per the
    # plan text; that assertion cannot pass against correct `lib/` code for
    # this exact fixture and was corrected here rather than weakened - see
    # this phase's implementation report.) What this test actually proves,
    # per ADR-0019's "the pending internal events ... is where a livelock's
    # repeatedly-raised events pile up": the payload's field is read live
    # from the machine_state's own queue at the moment of exhaustion, not a
    # placeholder - so it would show a non-empty queue on a livelock shape
    # where events do pile up (e.g. one that raises more per round than
    # `internal_round/1` drains).
    #
    # sabotage: `terminal_effects/2`'s `:exhausted` clause hardcodes
    # `pending_internal_events: [%Statifier.Event{name: "bogus"}]` instead
    # of reading `MachineState.internal_events(machine_state)` -> the
    # equality assertion below reddens (the hardcoded placeholder does not
    # match the real, empty queue).
    test "the pending internal events field reads the machine_state's own queue" do
      m = livelock_machine()

      {result, effects} = Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)

      assert %Effect.BudgetExhausted{pending_internal_events: pending} =
               budget_exhausted(effects)

      assert pending == MachineState.internal_events(result)
    end

    # `Effect.BudgetExhausted.budget` always echoes the configured
    # `machine_state.max_macrostep_rounds`, whatever value the fold was
    # actually seeded with - so a mutation that reseeds the fold from a
    # stale carried-over value would still report `budget: 20` and slip
    # past a check of that field alone. The round-count assertion below is
    # what actually exercises the seed: it counts this fixture's own
    # `Trace.EventDequeued(from: :internal)` occurrences, one per
    # completed round (`internal_round/1` dequeues and reraises
    # `error.execution` every round), and requires the full budget's worth
    # in *each* call.
    #
    # sabotage: `macrostep/1`'s seed is changed from
    # `machine_state.max_macrostep_rounds` to `machine_state.microstep`
    # (a value already on the struct, carried across calls rather than
    # read fresh from the configured budget) -> both calls run only one
    # round instead of twenty, reddening the round-count assertions below
    # (the `budget: 20` match alone does not catch this, since that field
    # is read from the configured option, not the fold's actual seed -
    # confirmed by running this exact mutation and observing it pass under
    # a `budget:`-only assertion before this stronger check was added).
    test "a later call gets a fresh budget and exhausts again" do
      m = livelock_machine()

      {exhausted, init_effects} =
        Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)

      assert {:ok, _result, effects} = Interpreter.handle_event(exhausted, Event.external("go"))

      assert [%Effect.BudgetExhausted{budget: 20}] =
               for({:budget_exhausted, payload} <- effects, do: payload)

      assert internal_dequeue_count(init_effects) == 20
      assert internal_dequeue_count(effects) == 20
    end

    defp internal_dequeue_count(effects) do
      Enum.count(effects, fn
        {:trace, %Effect.Trace.EventDequeued{from: :internal}} -> true
        _other -> false
      end)
    end

    # sabotage: `begin_round/1`'s call is deleted from `microstep/1`'s
    # general clause -> `result.round` stays `0` instead of `20`, reddening
    # the equality assertion.
    test "the exhausted position carries round == 20 at max_macrostep_rounds: 20" do
      m = livelock_machine()

      {result, _effects} = Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)

      assert result.round == 20
    end

    # `begin_macrostep/1`'s reset half of the counter contract, on the one
    # fixture where it is visible: sending an external event to an already
    # -exhausted position begins a fresh macrostep, so `round` resets to `0`
    # before the fold spends the same budget again and exhausts a second
    # time at `20`.
    #
    # sabotage: `begin_macrostep/1`'s `round: 0` reset is deleted -> the
    # second call's round keeps counting up from the first exhaustion's `20`
    # instead of resetting, so it reaches `40` instead of `20`, reddening
    # the equality assertion.
    test "the round resets on the next macrostep and reaches 20 again" do
      m = livelock_machine()

      {exhausted, _init_effects} =
        Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)

      assert exhausted.round == 20

      assert {:ok, result, _effects} = Interpreter.handle_event(exhausted, Event.external("go"))

      assert result.round == 20
    end

    # The bead's acceptance criterion, stated directly on the fixture: a
    # livelocked trace's rounds are ordered and countable.
    #
    # sabotage: `MachineState.begin_round/1` returns `machine_state`
    # unchanged (the pre-st-ux0 behavior) -> every round stamps `round: 0`,
    # so the list below is twenty zeros instead of 1..20 and the assertion
    # reddens.
    test "a livelocked trace orders its rounds and reports how many ran" do
      m = livelock_machine()

      {_result, effects} = Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)

      dequeued_rounds =
        for {:trace, %Effect.Trace.EventDequeued{from: :internal, round: round}} <- effects,
            do: round

      assert dequeued_rounds == Enum.to_list(1..20)
    end

    # The "diff one round against another" half of the same criterion: this
    # fixture's own round emits exactly three trace effects (an eventless
    # `TransitionsSelected`, the internal `EventDequeued`, and the
    # re-raised `TransitionsSelected` on that event), and every round's
    # three share one ordinal that differs from the next round's. The
    # pre-fold `EntrySet` (stamped `round: 0`, per the counter contract) is
    # excluded first, since it belongs to no round of the fold.
    #
    # sabotage: `MachineState.begin_round/1` returns `machine_state`
    # unchanged -> every round is stamped `round: 0`, so all twenty rounds'
    # effects collapse into a single sixty-effect-wide group instead of
    # twenty three-wide groups with distinct ordinals, reddening the
    # assertion.
    test "one round's effects share one ordinal, distinct from the next round's" do
      m = livelock_machine()

      {_result, effects} = Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)

      rounds =
        for {:trace, payload} <- effects, payload.round > 0, do: payload.round

      grouped = Enum.chunk_by(rounds, & &1)

      [first_group, second_group | _rest] = grouped

      assert length(first_group) == 3
      assert length(second_group) == 3
      assert hd(first_group) == 1
      assert hd(second_group) == 2
      refute hd(first_group) == hd(second_group)
    end

    # sabotage: `terminal_effects/2`'s `:exhausted` clause stamps
    # `round: machine_state.microstep` instead of `machine_state.round` ->
    # the depth assertion reddens (microstep is 1 here, the depth is 20).
    test "the exhausted effect reports how deep the fold got" do
      m = livelock_machine()

      {_result, effects} = Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)

      assert %Effect.BudgetExhausted{round: 20, budget: 20} = budget_exhausted(effects)
    end

    # Verified against the running interpreter rather than assumed from the
    # plan's prose: for this fixture, the probe's `error.execution` is
    # raised and dequeued within the *same* round (`internal_round/1`
    # drains the queue before the round ends), so each cause's round
    # exactly equals its own dequeue's round - both sequences are `1..20`.
    # That is not guaranteed in general (ADR-0020's worked example
    # describes a raise in round *k* dequeued in round *k*+1 when the
    # queue does not drain in one round), so this test asserts only the
    # three properties the bead actually needs - ascending, twenty
    # distinct values, starting at 1 - rather than a fixed offset that
    # would be fixture-specific.
    #
    # sabotage: `MachineState.begin_round/1` returns `machine_state`
    # unchanged -> every raised cause is stamped `round: 0`, so the
    # collected list is twenty zeros instead of twenty distinct ascending
    # values, reddening the assertion.
    test "the dequeued causes' rounds are strictly ascending, twenty distinct values, starting at 1" do
      m = livelock_machine()

      {_result, effects} = Interpreter.initialize(m, max_macrostep_rounds: 20, trace: true)

      cause_rounds =
        for {:trace, %Effect.Trace.EventDequeued{from: :internal, event: event}} <- effects,
            do: event.cause.round

      assert length(cause_rounds) == 20
      assert cause_rounds == Enum.uniq(cause_rounds)
      assert cause_rounds == Enum.sort(cause_rounds)
      assert hd(cause_rounds) == 1
    end
  end
end
