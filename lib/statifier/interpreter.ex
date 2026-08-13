defmodule Statifier.Interpreter do
  @moduledoc """
  Appendix D's outer loop, ported function for function (ADR-0002), with its
  loop state reified onto `%Statifier.MachineState{}` per
  `docs/observability.md` constraint 1: any `%MachineState{}` value is a
  complete, resumable interpreter position, and this module keeps nothing
  of that position on the call stack.

  ## The map of the loop

  Appendix D's `interpret`/`mainEventLoop`/`microstep`/`exitInterpreter`
  collapse onto this module's functions:

  | This module | Appendix D |
  |---|---|
  | `microstep/2` | `microstep(enabledTransitions)` verbatim |
  | `microstep/1` | `mainEventLoop`'s inner `while running and not macrostepDone` loop body, hoisted into a value so a paused position is data, not a stack frame |
  | `macrostep/1` | that same inner loop, folded to quiescence |
  | `main_event_loop/1` | one outer-loop iteration plus the trailing `exitInterpreter()` |
  | `exit_interpreter/1` | `exitInterpreter` |
  | `initialize/2`, `handle_event/2` | `interpret`'s two entry seams |

  ## Stepping it

  Constraint 1's payoff is that a step debugger is `microstep/1` in iex with
  no support code. Fold to quiescence, then hand it an event and drive the
  next macrostep one round at a time, inspecting the position between calls:

      # in iex, with `machine` already compiled
      {machine_state, _effects} = Interpreter.initialize(machine, trace: true)
      machine_state = MachineState.begin_macrostep(machine_state)

      # one round at a time; a `{:quiescent, _, _}` return ends the macrostep
      {machine_state, effects} = Interpreter.microstep(machine_state)
      machine_state.configuration
      Interpreter.microstep(machine_state)

  Every binding above is an ordinary value: keep an earlier `machine_state`
  to rewind to it, or round-trip one through `:erlang.term_to_binary/1` to
  resume in another process. `macrostep/1` is the same loop run to its fixed
  point, so stepping and folding are the same code path, not two.

  ## Counters

  `Statifier.MachineState`'s counter contract is the source of truth;
  restated here only for where this module writes it. `microstep`'s writer
  (`Statifier.MachineState`'s docs name it) has exactly one call site in
  this module: the non-empty branch of `run_selected/3`, the private tail
  shared by every selection round (eventless, one dequeued internal event,
  and the external event `handle_event/2` selects on). A selection round
  that finds nothing to run never reaches that call, because no exit or
  entry happened - the same "no exit or entry happened" rule
  `MachineState`'s counter contract states for why an empty round does not
  advance `microstep`.

  `macrostep`'s writer has exactly two call sites in this module:
  `initialize/2` (the initialization macrostep is macrostep 1) and
  `handle_event/2`, once per accepted external event (macrostep 2 onward).
  `initialize/2` additionally advances the microstep counter once, directly,
  before its own `enter_states/2` call - the pseudocode's
  `enterStates([doc.initial.transition])` is not inside `microstep`, so
  **the initial entry is microstep 1**, not 0, and nothing the
  initialization macrostep emits is stamped `microstep: 0`.

  An external event is the one case that is. `begin_macrostep/1` resets the
  microstep counter, and `handle_event/2` emits `Trace.EventDequeued` and
  (via `run_selected/3`) `Trace.TransitionsSelected` before the round's
  first entry has happened, so both carry `microstep: 0` - the round has
  begun but no exit or entry has occurred yet, which is exactly what
  `microstep: 0` means under `MachineState`'s counter contract. The first
  `Trace.ExitSet` of that macrostep is microstep 1.

  This is also why the trace effects a selection round emits
  (`Trace.EventDequeued`, `Trace.TransitionsSelected`) are always stamped
  *one microstep behind* the `Trace.ExitSet` that follows them when the
  round is non-empty: both are built from the `machine_state` selection
  returned, which is still at the *previous* microstep's count - the
  counter only advances afterward, inside `run_selected/3`, right before
  `microstep/2` runs. The counter cannot be advanced before the selection
  result is known, because an empty result must not advance it.

  ## Deviations, with their reasons (ADR-0002)

  - **`microstep/1` is not a pseudocode function name.** It is
    `mainEventLoop`'s inner loop body, hoisted so a debugger can pause
    between rounds without support code (constraint 1). See `microstep/1`'s
    own `@doc`.
  - **Quiescence is a tagged return, not a bare atom.** `microstep/1`
    returns `{:quiescent, machine_state, effects}` so the round that ends a
    macrostep can carry out both the machine_state its selection returned
    and that selection's own `Trace.TransitionsSelected`. Every selection
    this module makes emits that trace, with no exception for the terminal
    probe, so `docs/observability.md`'s "includes the empty set" is
    literally true. See `microstep/1`'s own `@doc` for why the
    machine_state half is load-bearing rather than tidiness.
  - **The machine_state `Selection` returns is threaded, never discarded.**
    Both `Selection.select_eventless_transitions/1` and
    `Selection.select_transitions/2` return `{machine_state, transitions}`,
    and this module continues with the returned `machine_state` rather than
    the one it passed in - st-af3.2's real `cond` evaluation landed inside
    `Selection`, exactly as this was built to absorb: it reshaped that
    module's private walk, both entry points kept their signatures, and
    nothing here changed.
  - **The outer `while running` loop is driven by the caller.** ADR-0003:
    the pure core takes one external event per call, and the session that
    drives it (st-cmq) owns the waiting external events and their queue.
    `main_event_loop/1` is the loop's tail - fold to quiescence, then
    `exit_interpreter/1` when `running` went false - not the loop itself.
    See `main_event_loop/1`'s own `@doc` for the exact port-site comment.
  - **The invoke passes are skipped.** Nothing in this core can invoke yet,
    so `statesToInvoke`'s two loops, its `clear()`, and the post-invoke
    internal-queue re-check are all commented seams naming st-cmq, in the
    pseudocode's own position inside `main_event_loop/1`.
  - **`returnDoneEvent` becomes a returned effect, appended last.**
    `exit_interpreter/1` builds `{:done, %Effect.Done{}}` instead of
    performing an I/O call (ADR-0003), and appends it after `Trace.Done`
    rather than mid-walk - a mechanical reordering, since effects are a
    returned list and nothing downstream observes the difference in the
    pseudocode's own terms. See `exit_interpreter/1`'s own `@doc`.
  - **The macrostep fold is bounded.** Appendix D's inner loop is
    unbounded; a pure core has no external entity to cancel a
    non-terminating macrostep, so the fold spends a round budget and stops
    with a `:budget_exhausted` effect on exhaustion (ADR-0019). See the
    private fold's own comment above `defp macrostep/3`.
  """

  alias Statifier.Event
  alias Statifier.Interpreter.Content
  alias Statifier.Interpreter.Datamodel
  alias Statifier.Interpreter.ExitEntry
  alias Statifier.Interpreter.Selection
  alias Statifier.Machine
  alias Statifier.Machine.Transition
  alias Statifier.MachineState

  require Statifier.Effect, as: Effect

  @doc """
  `interpret`'s entry seam (Appendix D) - binds `opts` into a fresh
  `%MachineState{}`, enters the top-level initial states, then runs the
  initialization macrostep to quiescence. Documents that reach a stable
  configuration or even terminate before any external event is ever sent
  are corpus-normal (`enter_states/2` can already set `running: false` on a
  top-level `<final>` entry, and `main_event_loop/1` runs
  `exit_interpreter/1` when it does).

  `opts` passes straight to `MachineState.new/2` - no option is interpreted
  here, so a new one is a `MachineState` change, not an entry-point change.

  Cannot fail: a `%Machine{}` is valid by construction
  (`docs/architecture.md`), so this returns the same untagged
  `{machine_state, [effect]}` pair every other loop function in this module
  returns, rather than an `{:ok, _, _}` wrapper with one possible value.
  """
  @spec initialize(machine :: Machine.t(), opts :: keyword()) ::
          {MachineState.t(), [Effect.t()]}
  def initialize(%Machine{} = machine, opts \\ []) do
    machine_state =
      machine
      |> MachineState.new(opts)
      |> MachineState.begin_macrostep()
      |> MachineState.begin_microstep()

    # `datamodel = new Datamodel(doc)` / `if doc.binding == "early":
    # initializeDatamodel(datamodel, doc)` (Appendix D `:101-102`), fused
    # into one unconditional call. The pseudocode's `if doc.binding ==
    # "early":` guard is **not** ported to this call site - it moves inside
    # `Datamodel.initialize/1` instead (Decision 7,
    # `docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md`),
    # for three reasons that must be read together, not the usual single
    # ADR-0002 mechanical-deviation note:
    #   1. `initializeDatamodel` has no procedure body anywhere in Appendix
    #      D, so there is no pseudocode definition of what the guard is
    #      guarding - what it means is decided by clause 5.3.2/5.3.3/B.2.2
    #      prose, not by porting a block that does not exist.
    #   2. Spec 5.3.3 makes *creation* of every <data> unconditional under
    #      both bindings ("...MUST create the data elements at document
    #      initialization time"), so seeding cannot sit behind an
    #      early-only guard without violating that MUST.
    #   3. Under binding="late", a top-level <data> is contained in no
    #      state, so it is never in `enterStates`' `statesToEnter` - this
    #      call is the only place in the whole interpreter it can ever be
    #      bound.
    # `Datamodel.initialize/1` seeds every declared id unconditionally and
    # binds every d_index under :early, only the root's own under :late -
    # see its own moduledoc. `executeGlobalScriptElement(doc)` stays
    # skipped: st-af3's, no <script> support exists in this core yet.
    machine_state = Datamodel.initialize(machine_state)

    {machine_state, enter_effects} =
      ExitEntry.enter_states(machine_state, [initial_transition(machine)])

    {machine_state, loop_effects} = main_event_loop(machine_state)

    {machine_state, enter_effects ++ loop_effects}
  end

  # `expandScxmlSource(doc)` (Appendix D's own normalization step) is what
  # gives a document an `<initial>` element where it wrote none; this is
  # that step, done lazily for the root only. ADR-0002 mechanical
  # deviation: a synthesized transition is not a document element, so it
  # has no `t_index`.
  @spec initial_transition(machine :: Machine.t()) :: Transition.t()
  defp initial_transition(%Machine{} = machine) do
    case Machine.at(machine, 0).initial_transition do
      nil ->
        %Transition{
          t_index: nil,
          source: 0,
          targets: Machine.initial(machine),
          events: [],
          type: :external,
          content: [],
          location: machine.location
        }

      t_index ->
        Machine.transition(machine, t_index)
    end
  end

  @doc """
  `mainEventLoop`'s external-event tail (Appendix D) - the external-event
  counterpart to `internal_round/1`'s dequeue-and-select, driven by the
  caller instead of a blocking queue read (ADR-0003, `main_event_loop/1`'s
  own `@doc`). Rejects when the machine is not running - Appendix D's own
  `running` flag, so the guard reads as the pseudocode's loop condition -
  otherwise begins a new macrostep, selects on `event`, runs whatever it
  enables, and folds to quiescence.
  """
  @spec handle_event(machine_state :: MachineState.t(), event :: Event.t()) ::
          {:ok, MachineState.t(), [Effect.t()]} | {:error, :not_running}
  def handle_event(%MachineState{running: false}, %Event{}), do: {:error, :not_running}

  def handle_event(%MachineState{} = machine_state, %Event{} = event) do
    machine_state = MachineState.begin_macrostep(machine_state)

    dequeued =
      Effect.trace(machine_state, Effect.Trace.EventDequeued, event: event, from: :external)

    # `datamodel["_event"] = externalEvent` (Appendix D); the invoke
    # `finalize` and `autoforward` passes over the configuration are
    # st-cmq's.
    machine_state = MachineState.put_event(machine_state, event)

    {machine_state, transitions} = Selection.select_transitions(machine_state, event)
    {machine_state, selected_effects} = run_selected(machine_state, transitions, event)
    {machine_state, loop_effects} = main_event_loop(machine_state)

    {:ok, machine_state, dequeued ++ selected_effects ++ loop_effects}
  end

  @doc """
  `microstep(enabledTransitions)` (Appendix D) - exit the states
  `enabled_transitions` leave, run each transition's own content in
  document order, then enter the states they reach. The three calls run in
  exactly this order with nothing between them, matching the pseudocode
  line for line; the effect list is each block's effects concatenated in
  the same order.
  """
  @spec microstep(machine_state :: MachineState.t(), enabled_transitions :: [Transition.t()]) ::
          {MachineState.t(), [Effect.t()]}
  def microstep(%MachineState{} = machine_state, enabled_transitions) do
    {machine_state, exit_effects} = ExitEntry.exit_states(machine_state, enabled_transitions)

    {machine_state, content_effects} =
      execute_transition_content(machine_state, enabled_transitions)

    {machine_state, enter_effects} = ExitEntry.enter_states(machine_state, enabled_transitions)

    {machine_state, exit_effects ++ content_effects ++ enter_effects}
  end

  @doc """
  `mainEventLoop`'s inner `while running and not macrostepDone` loop body,
  hoisted into a named, resumable round (Decision 1) - not a pseudocode
  function name itself. One call makes exactly one round of progress:

  - Not `running` - returns `{:quiescent, machine_state, []}`, nothing
    changes.
  - An eventless transition is enabled - the round runs it, exactly as
    `microstep/2` above.
  - No eventless transition is enabled - falls to `internal_round/1`,
    which dequeues one internal event (if any) and selects on it.

  Never runs two rounds and never inspects the call stack for a paused
  position: the returned `machine_state` *is* the position, on both the
  progressing and the quiescent return.

  **Quiescence carries a machine_state and an effect list of its own**
  (Decision 2, revised). The round that ends a macrostep still ran a
  selection - `Selection.select_eventless_transitions/1` - and that call
  returns a machine_state. A bare `:quiescent` atom has nowhere to put it,
  so the fold would fall back to the machine_state it passed *in* and drop
  whatever the final selection wrote, on the one round every macrostep ends
  with.

  Be precise about which writes that loses, because the obvious candidate
  is not one of them. The two `Selection` entry points enqueue
  `error.execution` on a failed `cond` (st-af3.2) - `condition_match/2`
  itself stays a pure query and never enqueues, so the write happens in
  `select_transitions/2` and `select_eventless_transitions/1` on the way
  out - and that enqueue is
  self-rescuing: it leaves the internal queue non-empty, so
  `internal_round/1` takes its dequeue branch instead of the terminal one
  and the write survives even under the old shape - traced end to end and
  pinned by `InterpreterAcceptanceTest`'s
  "a failed cond becomes a catchable error.execution" tests. What the old
  shape lost was any selection-side write that does *not* touch the
  internal queue - a datamodel write, a memo, a diagnostic - since only a
  queue write changes which branch runs. Carrying the machine_state out
  closes that gap without having to predict which kind of write a future
  selection-side change lands on.

  The effect slot is the other half: it is what the terminal eventless
  probe's own `Trace.TransitionsSelected` rides out on, which is why
  `docs/observability.md`'s "includes the empty set" holds with no
  exception.
  """
  @spec microstep(machine_state :: MachineState.t()) ::
          {MachineState.t(), [Effect.t()]} | {:quiescent, MachineState.t(), [Effect.t()]}
  def microstep(%MachineState{running: false} = machine_state),
    do: {:quiescent, machine_state, []}

  def microstep(%MachineState{} = machine_state) do
    {machine_state, eventless_transitions} = Selection.select_eventless_transitions(machine_state)

    case eventless_transitions do
      [] -> internal_round(machine_state)
      _enabled -> run_selected(machine_state, eventless_transitions, nil)
    end
  end

  @doc """
  `mainEventLoop`'s inner `while running and not macrostepDone` loop,
  folded to quiescence over `microstep/1` (Decision 7) - not a pseudocode
  function name itself; `docs/observability.md`'s vocabulary for that same
  loop, hoisted so a paused position is a value on `%MachineState{}` rather
  than a stack frame (constraint 1). The fold ends one of three ways:

  - **Quiescence** - `microstep/1` returns
    `{:quiescent, machine_state, effects}`: no eventless transition is
    enabled and the internal queue is empty. That round's own effects (the
    terminal eventless probe's `Trace.TransitionsSelected`) are appended
    like any other round's, and its `machine_state` is the one this fold
    returns - never the one it passed in, which is what keeps a write made
    by the final selection from being dropped. The returned `machine_state`
    is still `running`, so this function then appends
    `Trace.MacrostepStable` with the configuration and counters as they
    stand.
  - **Termination** - a microstep entered a top-level `<final>`, setting
    `running: false` mid-fold. This is not quiescence -
    `Trace.MacrostepStable`'s own moduledoc reserves that trace for reaching
    a stable configuration - so no `Trace.MacrostepStable` is emitted;
    `Trace.Done` is the vocabulary row for this case, emitted by
    `exit_interpreter/1`.
  - **Budget exhaustion** (ADR-0019) - the private fold spent
    `machine_state.max_macrostep_rounds` without reaching quiescence. The
    position comes back exactly as the last round left it: `running` stays
    `true` and `status` stays `:running` (no `exit_interpreter/1` runs, no
    `Effect.Done` is built - faking termination would be a semantic lie).
    `Trace.MacrostepStable` is not emitted, and a
    `{:budget_exhausted, %Effect.BudgetExhausted{}}` core effect is
    appended last.

  The three outcomes are therefore mutually exclusive per macrostep.
  `macrostep/1` is public rather than starting private, because it is
  exactly `microstep/1` driven to a fixed point and a stepper and the fold
  should be the same code path (`docs/observability.md:41-42`).
  """
  @spec macrostep(machine_state :: MachineState.t()) :: {MachineState.t(), [Effect.t()]}
  # `macrostep` is not an Appendix D function name. It is
  # docs/observability.md's vocabulary for `mainEventLoop`'s inner
  # `while running and not macrostepDone` loop, hoisted into a fold over
  # `microstep/1` so that a paused position is a value on `%MachineState{}`
  # rather than a stack frame (constraint 1). Mechanical, not semantic: the
  # loop's condition and body are unchanged. ADR-0002.
  def macrostep(%MachineState{} = machine_state) do
    {outcome, machine_state, effects} =
      macrostep(machine_state, [], machine_state.max_macrostep_rounds)

    {machine_state, effects ++ terminal_effects(machine_state, outcome)}
  end

  # The three mutually exclusive ways one macrostep ends (ADR-0019).
  # `:quiescent` while still `running` is the stable configuration and the one
  # case `Trace.MacrostepStable` names; `:quiescent` with `running: false` is
  # termination, whose vocabulary row is `Trace.Done` from
  # `exit_interpreter/1`; `:exhausted` is the spent round budget, a core
  # effect because it is the outcome of the call rather than diagnostics about
  # it, so it is built directly and not through the `Effect.trace/3` gate.
  @spec terminal_effects(machine_state :: MachineState.t(), outcome :: :quiescent | :exhausted) ::
          [Effect.t()]
  defp terminal_effects(machine_state, :quiescent) do
    if machine_state.running do
      Effect.trace(machine_state, Effect.Trace.MacrostepStable,
        configuration: machine_state.configuration
      )
    else
      []
    end
  end

  defp terminal_effects(machine_state, :exhausted) do
    [
      {:budget_exhausted,
       %Effect.BudgetExhausted{
         configuration: machine_state.configuration,
         budget: machine_state.max_macrostep_rounds,
         pending_internal_events: MachineState.internal_events(machine_state),
         macrostep: machine_state.macrostep,
         microstep: machine_state.microstep
       }}
    ]
  end

  @spec macrostep(
          machine_state :: MachineState.t(),
          effects :: [Effect.t()],
          rounds_left :: MachineState.max_macrostep_rounds() | 0
        ) :: {:quiescent | :exhausted, MachineState.t(), [Effect.t()]}
  # ADR-0002 mechanical deviation (ADR-0019). Appendix D's inner loop is
  # unbounded, and the REC allows that ("A macrostep may not [terminate].
  # ... This is currently allowed.") because it presumes an interpreter
  # an "external entity" can cancel mid-macrostep. A pure core (ADR-0003)
  # has no external entity inside a fold - a non-terminating macrostep
  # would hang the calling process with no recourse - so the fold spends
  # one round per `microstep/1` call and stops with a `:budget_exhausted`
  # effect when `max_macrostep_rounds` runs out. The loop's condition and
  # body are otherwise unchanged; `max_macrostep_rounds: :infinity`
  # restores the literal spec behavior for a caller that owns its own
  # interruption.
  #
  # The private accumulator behind `macrostep/1` - repeatedly calls
  # `microstep/1` until it returns `:quiescent`, threading the machine_state
  # and appending each round's effects in order. Not an Appendix D function
  # name; see `macrostep/1`'s own comment. ADR-0002.
  defp macrostep(machine_state, effects, 0), do: {:exhausted, machine_state, effects}

  # The ordinary round, charged against the budget by `spend/1`; the name
  # carries the same ADR-0002 caveat as the clause above.
  defp macrostep(machine_state, effects, rounds_left) do
    case microstep(machine_state) do
      {:quiescent, machine_state, round_effects} ->
        {:quiescent, machine_state, effects ++ round_effects}

      {machine_state, round_effects} ->
        macrostep(machine_state, effects ++ round_effects, spend(rounds_left))
    end
  end

  @spec spend(rounds_left :: MachineState.max_macrostep_rounds()) ::
          MachineState.max_macrostep_rounds() | 0
  defp spend(:infinity), do: :infinity
  defp spend(rounds_left), do: rounds_left - 1

  # The eventless probe came back empty. `MachineState.dequeue_internal/1`
  # is the second half of Decision 2's quiescence test (no eventless
  # transition enabled *and* the internal queue is empty).
  #
  # Both branches record the empty eventless probe the same way
  # (`run_selected/3` with `[]`, giving `Trace.TransitionsSelected` with
  # `t_indexes: []`), and both carry out the machine_state selection
  # returned. The terminal branch differs only in tagging its return
  # `:quiescent` so the fold stops - it is a round that made no progress,
  # not a round that did not happen, and the `machine_state` it carries is
  # the one `Selection.select_eventless_transitions/1` handed back, never
  # the one `microstep/1` passed in (see `microstep/1`'s own `@doc`).
  #
  # A dequeued event continues: the `EventDequeued` trace, then selection on
  # the event, then whatever it enables.
  @spec internal_round(machine_state :: MachineState.t()) ::
          {MachineState.t(), [Effect.t()]} | {:quiescent, MachineState.t(), [Effect.t()]}
  defp internal_round(machine_state) do
    case MachineState.dequeue_internal(machine_state) do
      :empty ->
        {machine_state, probe_effects} = run_selected(machine_state, [], nil)
        {:quiescent, machine_state, probe_effects}

      {:ok, event, machine_state} ->
        # The eventless probe above dequeues nothing and runs before this
        # point, so it has no event to write - the pseudocode assigns
        # `_event` only when it has one, and `_event` keeps the previous
        # round's value until this dequeued event's own assignment below.
        {machine_state, eventless_probe_effects} = run_selected(machine_state, [], nil)

        dequeued_trace =
          Effect.trace(machine_state, Effect.Trace.EventDequeued, event: event, from: :internal)

        # datamodel["_event"] = internalEvent (Appendix D)
        machine_state = MachineState.put_event(machine_state, event)

        {machine_state, transitions} = Selection.select_transitions(machine_state, event)
        {machine_state, selected_effects} = run_selected(machine_state, transitions, event)

        {machine_state, eventless_probe_effects ++ dequeued_trace ++ selected_effects}
    end
  end

  # The `if not enabledTransitions.isEmpty(): microstep(enabledTransitions.toList())`
  # tail shared by every selection site (eventless, one dequeued internal
  # event, and - once handle_event/2 lands - the external event): emits
  # `Trace.TransitionsSelected` with `t_indexes: Enum.map(transitions, &
  # &1.t_index)` (the selected transitions themselves, per
  # `Selection.select_transitions/2`'s own note, already in the document
  # order of the states that selected them), then on a non-empty set begins
  # a microstep and runs it. Factored so the microstep counter's writer
  # (`Statifier.MachineState`'s counter contract) has exactly one call site.
  @spec run_selected(
          machine_state :: MachineState.t(),
          transitions :: [Transition.t()],
          event :: Event.t() | nil
        ) :: {MachineState.t(), [Effect.t()]}
  defp run_selected(machine_state, transitions, event) do
    selected_trace =
      Effect.trace(machine_state, Effect.Trace.TransitionsSelected,
        t_indexes: Enum.map(transitions, & &1.t_index),
        event: event
      )

    case transitions do
      [] ->
        {machine_state, selected_trace}

      _enabled ->
        machine_state = MachineState.begin_microstep(machine_state)
        {machine_state, microstep_effects} = microstep(machine_state, transitions)
        {machine_state, selected_trace ++ microstep_effects}
    end
  end

  # `executeTransitionContent(enabledTransitions)` (Appendix D) - each
  # enabled transition's own content block, through the same block runner
  # every other content site uses. The pseudocode iterates
  # `enabledTransitions` in the order it was given; selection already
  # produced them in the document order of the states that selected them,
  # so there is nothing to sort here.
  @spec execute_transition_content(
          machine_state :: MachineState.t(),
          enabled_transitions :: [Transition.t()]
        ) :: {MachineState.t(), [Effect.t()]}
  defp execute_transition_content(machine_state, enabled_transitions) do
    Enum.reduce(enabled_transitions, {machine_state, []}, fn transition, {ms, effects} ->
      {ms, new_effects} =
        Content.execute_block(ms, {:transition, transition.t_index}, transition.content)

      {ms, effects ++ new_effects}
    end)
  end

  @doc """
  `mainEventLoop`'s outer `while running` loop (Appendix D), one
  iteration's tail (Decision 6). The loop itself is driven by the caller -
  one call of `initialize/2` or `handle_event/2` performs one iteration,
  each having already run its own selection round before calling here - so
  this function is what is left of the pseudocode's loop body after that:
  fold to quiescence with `macrostep/1`, then run `exit_interpreter/1` when
  the fold left `running` false.
  """
  @spec main_event_loop(machine_state :: MachineState.t()) :: {MachineState.t(), [Effect.t()]}
  def main_event_loop(%MachineState{} = machine_state) do
    {machine_state, macrostep_effects} = macrostep(machine_state)

    # for state in statesToInvoke: invoke(state) (Appendix D) - skipped: no
    # <invoke> support exists yet, so there is nothing in statesToInvoke to
    # walk. st-cmq.
    #
    # statesToInvoke.clear() (Appendix D) - skipped alongside the invoke
    # pass above; `states_to_invoke` is deliberately absent from
    # `MachineState` until <invoke> support adds it with its own caller.
    # st-cmq.
    #
    # if not internalQueue.isEmpty(): continue (Appendix D) - skipped: this
    # guard exists only because invoking can raise internal events mid-loop,
    # and nothing invokes yet. st-cmq.

    if machine_state.running do
      # ADR-0002 mechanical deviation, ADR-0003. Appendix D's
      # `mainEventLoop` owns both queues and blocks on
      # `externalQueue.dequeue()` at the end of every iteration, then checks
      # `isCancelEvent/1` on what it dequeues. This core takes one external
      # event per call, so the outer `while running` loop is driven by the
      # caller (`handle_event/2`), and the waiting external events live in
      # the session, not this struct (st-cmq). The semantics of processing
      # one external event are unchanged; only the storage of the waiting
      # ones moves outward. `isCancelEvent/1` moves out with them.
      {machine_state, macrostep_effects}
    else
      {machine_state, exit_effects} = exit_interpreter(machine_state)
      {machine_state, macrostep_effects ++ exit_effects}
    end
  end

  @doc """
  `exitInterpreter` (Appendix D) - every active state exited in exit order,
  the top-level final's `<donedata>` collected, then the terminal effects.

  Body, in the pseudocode's own order, with the deviations Decision 10
  records:

  1. The configuration is captured *before* the walk (`configuration_at_exit`)
     - both `Trace.Done.configuration` and `Effect.Done.configuration`
     document themselves as "the configuration as it stood at exit", which
     the walk would otherwise leave empty.
  2. `states_to_exit` = `Machine.exit_order/2` over the configuration, and
     `Trace.ExitSet` is emitted over it before any state leaves - the same
     phase-boundary row `exit_states/2` emits, at the one other place this
     engine exits states. ADR-0012 item 2 binds the row to the boundaries
     Appendix D itself names, and `exitInterpreter` names one: its
     `statesToExit` is the same variable `exitStates` computes. `Trace.Done`
     carries the same set as `configuration`, but it arrives after the walk
     and means "the run ended here", so it is not a substitute for a marker
     that means "these are about to be exited".
  3. Each state, in exit order, runs its `onexit` blocks
     (`ExitEntry.run_onexit_blocks/2` - the same per-state body
     `exit_states/2`'s `depart/2` runs), then leaves the configuration.
     `cancelInvoke` is skipped: no `<invoke>` support exists yet. st-cmq.
  4. **No history recording.** Appendix D's `exitInterpreter` has no
     history-recording loop at all - unlike `exitStates`, which has two
     consecutive `for s in statesToExit` loops for exactly that reason.
     "Port as written" therefore means recording nothing here; this walk
     never touches `machine_state.history_values`.
  5. `returnDoneEvent(s.donedata)` fires for the one state, if any, that is
     `Machine.final?/2` with `parent == 0` - `isFinalState(s) and
     isSCXMLElement(s.parent)`, the same test
     `ExitEntry.raise_completion_events/2` already makes. Since the root is
     compound, at most one child is active, so at most one top-level final
     is ever in the exit set. Its donedata
     (`ExitEntry.static_donedata/2`) becomes both `Trace.Done`'s and
     `Effect.Done`'s `donedata`.
  6. The terminal effects are appended last, `{:done, %Effect.Done{}}` last
     of all - `returnDoneEvent` becomes a returned effect rather than an I/O
     call (ADR-0003), and moving its emission to the end of the list is a
     mechanical reordering: effects are a returned list, not an I/O call,
     so nothing the pseudocode's own terms observe changes order. Both
     `Trace.Done` and `Effect.Done` are populated from the same
     `configuration_at_exit` and `donedata` locals, so the trace row and the
     core effect always agree on the terminal position.

  `status: :done` is set only here, at the very end - the window
  `MachineState`'s moduledoc describes between `running: false` (from
  top-level final entry) and `status: :done` (once this walk finishes).
  """
  @spec exit_interpreter(machine_state :: MachineState.t()) :: {MachineState.t(), [Effect.t()]}
  def exit_interpreter(%MachineState{machine: machine} = machine_state) do
    configuration_at_exit = machine_state.configuration
    states_to_exit = Machine.exit_order(machine, configuration_at_exit)

    exit_set_trace = Effect.trace(machine_state, Effect.Trace.ExitSet, indexes: states_to_exit)

    {machine_state, donedata, exit_effects} =
      Enum.reduce(states_to_exit, {machine_state, nil, []}, fn state_index,
                                                               {ms, donedata, effects} ->
        {ms, onexit_effects} = ExitEntry.run_onexit_blocks(ms, state_index)

        # cancelInvoke(inv) for inv in s.invoke (Appendix D) - skipped: no
        # <invoke> support exists yet, so there is nothing to cancel. st-cmq.

        ms = %{ms | configuration: MapSet.delete(ms.configuration, state_index)}

        donedata =
          if Machine.final?(machine, state_index) and Machine.at(machine, state_index).parent == 0 do
            ExitEntry.static_donedata(machine, state_index)
          else
            donedata
          end

        {ms, donedata, effects ++ onexit_effects}
      end)

    done_trace =
      Effect.trace(machine_state, Effect.Trace.Done,
        configuration: configuration_at_exit,
        donedata: donedata
      )

    done_effect =
      {:done,
       %Effect.Done{
         donedata: donedata,
         configuration: configuration_at_exit,
         macrostep: machine_state.macrostep,
         microstep: machine_state.microstep
       }}

    machine_state = %{machine_state | status: :done}

    {machine_state, exit_set_trace ++ exit_effects ++ done_trace ++ [done_effect]}
  end
end
