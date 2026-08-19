defmodule Statifier.Interpreter.ExitEntry do
  @moduledoc """
  Appendix D's exit and entry blocks, ported function for function
  (ADR-0002) - the half of the algorithm that changes the configuration.
  `Statifier.Interpreter.Selection` answers "which transitions fire and
  what would they leave"; this module actually leaves and enters states.

  `machine_state` stands in for the pseudocode's globals exactly as
  `Statifier.Interpreter.Selection`'s moduledoc states for the same reason
  (`docs/observability.md` constraint 1) - every function here that reads a
  global takes `machine_state` as its first argument.

  ## Return shapes

  `exit_states/2` and `enter_states/2` are the two functions here that both
  mutate the position and emit effects, so both return
  `{MachineState.t(), [Effect.t()]}` - the shape `docs/observability.md`
  fixes for `microstep/1`. `Statifier.Interpreter.microstep/2` is their
  caller for the ordinary exit/entry path. Effect order within the returned
  list is emission order: the trace effect first, then each block's effects
  in the order the blocks ran.

  `run_onexit_blocks/2` and `donedata/2` are public for a second caller:
  `Statifier.Interpreter.exit_interpreter/1`'s termination walk needs
  exactly the same per-state onexit body and the same `<donedata>` folding
  rule that `depart/2` and `raise_parent_completion/3` already use here, so
  this module owns both rather than the interpreter carrying a second
  copy.

  ## Ordering

  Exit order and entry order are never hand-sorted here: `exit_states/2`
  pipes `Statifier.Interpreter.Selection.compute_exit_set/2`'s `MapSet`
  through `Statifier.Machine.exit_order/2` (descending index), and
  `enter_states/2` mirrors it through `Statifier.Machine.document_order/2`
  (ascending index).

  ## The content seam

  Every call site that would run executable content - `<onexit>`,
  `<onentry>`, an `<initial>` transition's content, default history
  content - goes through the private `execute_block/3` seam, which
  delegates to `Statifier.Interpreter.Content.execute_block/3`: that module
  owns the block runner and the `Trace.ContentExecuted` emission that wraps
  it. This module owns only *where and in what order* blocks run, which is
  what the exit/entry pseudocode defines.

  ## History recording

  `exit_states/2` records history in a full first pass over the exit set,
  reading the configuration exactly as it stood before any state exited -
  *before* the first `onexit` runs and before any state is removed. The
  pseudocode writes two consecutive `for s in statesToExit` loops for
  exactly this reason: recording inside the delete loop would let a
  later-exiting state's deep history see a configuration its own siblings
  have already been removed from.

  One mechanical deviation in the recorded value itself: the pseudocode's
  `configuration.toList().filter(f)` produces an ordered list, while
  `machine_state.history_values` holds a `MapSet`. Order is dropped rather
  than preserved because nothing reads it - `add_descendant_states_to_enter/3`
  re-enters a restored value through the same descendant and ancestor walks
  any other target set goes through, and `enter_states/2` sorts the whole
  entry set into document order afterwards regardless.

  ## The entry set

  `compute_entry_set/2`, `add_descendant_states_to_enter/3`, and
  `add_ancestor_states_to_enter/4` are pure queries: none of them touch
  `machine_state.configuration`, none of them emit an effect. The
  pseudocode's three `statesToEnter` / `statesForDefaultEntry` /
  `defaultHistoryContent` out-parameters become one accumulator of type
  `entry_set()`, threaded in and returned last - the minimal mechanical
  deviation Elixir's lack of out-parameters forces. `default_history_content`
  stores the default transition's `t_index` rather than its `[c_index]` list:
  strictly more information, and what the content seam actually needs to
  build a `Content.owner()`.
  """

  alias Statifier.Effect.CancelInvoke
  alias Statifier.{Evaluator, EventData, Machine, MachineState}
  alias Statifier.Interpreter.{Content, Datamodel, Selection}
  alias Statifier.Machine.{Donedata, Param, State, Transition}

  require Statifier.Effect, as: Effect

  @typedoc """
  The pseudocode's three `computeEntrySet` out-parameters, threaded as one
  accumulator: the states a transition set will enter, the subset of those
  entered via a compound state's `<initial>` declaration rather than as an
  explicit target (so default-entry content runs only for them), and a map
  from a history state's parent to the `t_index` of the default transition
  whose content runs because that history was unrecorded.
  """
  @type entry_set :: {
          states_to_enter :: MapSet.t(non_neg_integer()),
          states_for_default_entry :: MapSet.t(non_neg_integer()),
          default_history_content :: %{optional(non_neg_integer()) => non_neg_integer()}
        }

  @doc """
  `exitStates` (Appendix D) - the exit-ordered set of states
  `enabled_transitions` leave, with history recorded before any state
  exits and `onexit` content run per state in exit order.

  Body, in the pseudocode's own order:

  1. `exit_set` = `Selection.compute_exit_set/2` over `enabled_transitions`
     - an *unordered* `MapSet`.
  2. `states_to_invoke` loses every member of `exit_set`, over that same
     unordered set - `statesToInvoke.delete(s)` (Appendix D), which runs
     before the exit-order sort and before `record_history_values/2`.
  3. `exit_set` is sorted into exit order via `Machine.exit_order/2` into
     `states_to_exit`: `compute_exit_set/2` returns unordered, and ordering
     it is this function's job, not `Selection`'s.
  4. `record_history_values/2` runs its whole first pass over
     `states_to_exit`, reading the untouched configuration.
  5. `states_to_exit` is reduced through `depart/2`, each state running its
     `onexit` blocks and then leaving the configuration.
  6. `Effect.trace(pre_exit_state, Effect.Trace.ExitSet, indexes:
     states_to_exit, configuration: machine_state.configuration)` is
     emitted last: `macrostep`/`microstep`/`round` are stamped against
     `pre_exit_state`, captured as `machine_state` stood after step 2's
     `states_to_invoke` update and before the departure reduce (ADR-0012 -
     `test/fixtures/adr_judge/0012_trace_prestate_captured.diff` is the
     sanctioned shape), while `configuration` is read from the
     post-departure `machine_state` because "the configuration after this
     exit set was applied" does not exist until step 5 has run.
     The payload's position in the returned list is unchanged: it is still
     first, since the list is concatenated at the end either way.
  """
  @spec exit_states(machine_state :: MachineState.t(), enabled_transitions :: [Transition.t()]) ::
          {MachineState.t(), [Effect.t()]}
  def exit_states(%MachineState{machine: machine} = machine_state, enabled_transitions) do
    exit_set = Selection.compute_exit_set(machine_state, enabled_transitions)

    machine_state = %{
      machine_state
      | states_to_invoke: MapSet.difference(machine_state.states_to_invoke, exit_set)
    }

    states_to_exit = Machine.exit_order(machine, exit_set)

    # ADR-0012: the counters this payload stamps must be the ones that stood
    # at the exit-set phase boundary, so the trace is stamped against
    # `pre_exit_state`; only `configuration` is read from the post-departure
    # state, because "the configuration after this exit set was applied"
    # does not exist until the reduce below has run. Effect-list
    # position is unchanged: the list is concatenated at the end either way.
    pre_exit_state = machine_state

    machine_state = record_history_values(machine_state, states_to_exit)

    {machine_state, depart_effects} =
      Enum.reduce(states_to_exit, {machine_state, []}, fn state_index, {ms, effects} ->
        {ms, new_effects} = depart(ms, state_index)
        {ms, effects ++ new_effects}
      end)

    trace_effects =
      Effect.trace(pre_exit_state, Effect.Trace.ExitSet,
        indexes: states_to_exit,
        configuration: machine_state.configuration
      )

    {machine_state, trace_effects ++ depart_effects}
  end

  # `exitStates`'s history-recording loop - `for s in statesToExit: for h
  # in s.history: historyValue[h.id] = ...` - the whole first pass, run
  # before any `onexit` content and before any state leaves the
  # configuration. Reads `history_children` (populated by the compiler), so
  # this is a field read per exiting state, never a scan.
  @spec record_history_values(
          machine_state :: MachineState.t(),
          states_to_exit :: [non_neg_integer()]
        ) :: MachineState.t()
  defp record_history_values(%MachineState{machine: machine} = machine_state, states_to_exit) do
    Enum.reduce(states_to_exit, machine_state, fn state_index, ms ->
      machine
      |> Machine.at(state_index)
      |> Map.fetch!(:history_children)
      |> Enum.reduce(ms, &record_one_history_value(&2, state_index, &1))
    end)
  end

  # `historyValue[h.id] = ...` for one history child `history_index` of one
  # exiting state `state_index` - overwrites unconditionally, which is what
  # the pseudocode's assignment does (a revisit replaces the previous
  # record rather than merging).
  @spec record_one_history_value(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          history_index :: non_neg_integer()
        ) :: MachineState.t()
  defp record_one_history_value(machine_state, state_index, history_index) do
    value = recorded_value(machine_state, state_index, history_index)
    %{machine_state | history_values: Map.put(machine_state.history_values, history_index, value)}
  end

  # The two lambdas `exitStates` records history with, verbatim: a
  # `:shallow` history records `s`'s active *immediate* children; a `:deep`
  # history records `s`'s active *atomic descendants*. `descendant?/3` is
  # proper, which is correct here because `s` is not atomic when it has a
  # history child.
  @spec recorded_value(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          history_index :: non_neg_integer()
        ) :: MapSet.t(non_neg_integer())
  defp recorded_value(
         %MachineState{machine: machine, configuration: configuration},
         state_index,
         history_index
       ) do
    case Machine.at(machine, history_index).history_type do
      :shallow ->
        MapSet.filter(configuration, &(Machine.at(machine, &1).parent == state_index))

      :deep ->
        MapSet.filter(
          configuration,
          &(Machine.atomic?(machine, &1) and Machine.descendant?(machine, &1, state_index))
        )
    end
  end

  # `exitStates`'s per-state exit body: run its onexit blocks, then
  # `cancelInvoke(inv)` for each of its live invocations - spec 6.4's "the
  # cancel operation MUST act as if it were the final `<onexit>` handler in
  # the invoking state" - then remove it from the configuration.
  @spec depart(machine_state :: MachineState.t(), state_index :: non_neg_integer()) ::
          {MachineState.t(), [Effect.t()]}
  defp depart(machine_state, state_index) do
    {machine_state, onexit_effects} = run_onexit_blocks(machine_state, state_index)

    {machine_state, cancel_effects} = cancel_invocations_for_state(machine_state, state_index)

    machine_state = %{
      machine_state
      | configuration: MapSet.delete(machine_state.configuration, state_index)
    }

    {machine_state, onexit_effects ++ cancel_effects}
  end

  @doc """
  `exitStates`'s per-state `for content in s.onexit: executeContent(content)`
  (Appendix D) - `state_index`'s `onexit` blocks, in document order, each
  through the `execute_block/3` seam with `{:onexit, state_index, ordinal}`
  - `ordinal` is the block's position in the state's own `onexit` list,
  exactly what `Machine.Content.owner()` documents it to be.

  Two callers: `depart/2` (this module's own `exit_states/2` path) and
  `Statifier.Interpreter.exit_interpreter/1` (the termination block, which
  runs every active state's `onexit` blocks the same way, in exit order,
  without the rest of `exitStates`'s history-recording and configuration
  bookkeeping).
  """
  @spec run_onexit_blocks(machine_state :: MachineState.t(), state_index :: non_neg_integer()) ::
          {MachineState.t(), [Effect.t()]}
  def run_onexit_blocks(%MachineState{machine: machine} = machine_state, state_index) do
    machine
    |> Machine.at(state_index)
    |> Map.fetch!(:onexit)
    |> Enum.with_index()
    |> Enum.reduce({machine_state, []}, fn {block, ordinal}, {ms, effects} ->
      {ms, new_effects} = execute_block(ms, {:onexit, state_index, ordinal}, block.content)
      {ms, effects ++ new_effects}
    end)
  end

  @doc """
  `for inv in s.invoke: cancelInvoke(inv)` (Appendix D) - one
  `{:cancel_invoke, %Effect.CancelInvoke{}}` per live invocation of
  `state_index`: walk its compiled `invoke` list in document order, and for
  each `{state_index, invoke_index}` found in `machine_state.active_invocations`
  emit a cancel and delete the entry. An invocation whose arguments failed
  (ADR-0031), and one whose resolved `type` was unsupported (6.4.1), never
  reached `active_invocations`, so neither produces a cancel.

  Two callers, both after that state's own `onexit` blocks and before it
  leaves the configuration - both the pseudocode's own order in `exitStates`
  and `exitInterpreter`, and spec 6.4's "the cancel operation MUST act as if
  it were the final `<onexit>` handler in the invoking state": `depart/2`
  (this module's own `exit_states/2` path) and
  `Statifier.Interpreter.exit_interpreter/1` (the termination walk), the
  same second-caller shape `run_onexit_blocks/2` above already has.
  """
  @spec cancel_invocations_for_state(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer()
        ) :: {MachineState.t(), [Effect.t()]}
  def cancel_invocations_for_state(%MachineState{machine: machine} = machine_state, state_index) do
    {ms, reversed_effects} =
      machine
      |> Machine.at(state_index)
      |> Map.fetch!(:invoke)
      |> Enum.with_index()
      |> Enum.reduce({machine_state, []}, fn {_invoke, invoke_index}, {ms, effects} ->
        cancel_one_invocation(ms, state_index, invoke_index, effects)
      end)

    {ms, Enum.reverse(reversed_effects)}
  end

  # One invocation's own `cancelInvoke(inv)`: emit and forget it when it is
  # still live (present in `active_invocations`), or leave `ms`/`effects`
  # untouched when it never started - either because its argument evaluation
  # raised `error.execution` (ADR-0031) before an `Effect.Invoke` was ever
  # built, or because its resolved `type` was unsupported (6.4.1), which
  # does build and emit an `Effect.Invoke` but never records the invocation
  # live. `effects` accumulates prepended
  # (`[effect | effects]`) rather than appended (`effects ++ [effect]`);
  # Appendix D's List datatype names only `append(l)` (`spec-cache/appendix-d.txt:21`)
  # with no complexity contract, and appending here per invoke was O(n) per
  # invoke, O(n^2) over a state's whole `invoke` list. The caller,
  # `cancel_invocations_for_state/2` above, reverses once after the fold so
  # cancels still emit in the pseudocode's `for inv in s.invoke` document
  # order.
  @spec cancel_one_invocation(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          invoke_index :: non_neg_integer(),
          effects :: [Effect.t()]
        ) :: {MachineState.t(), [Effect.t()]}
  defp cancel_one_invocation(machine_state, state_index, invoke_index, effects) do
    case Map.fetch(machine_state.active_invocations, {state_index, invoke_index}) do
      {:ok, invoke_id} ->
        effect =
          {:cancel_invoke,
           %CancelInvoke{
             invoke_id: invoke_id,
             state_index: state_index,
             macrostep: machine_state.macrostep,
             microstep: machine_state.microstep,
             round: machine_state.round
           }}

        machine_state = %{
          machine_state
          | active_invocations:
              Map.delete(machine_state.active_invocations, {state_index, invoke_index})
        }

        {machine_state, [effect | effects]}

      :error ->
        {machine_state, effects}
    end
  end

  # ADR-0002: the pseudocode's `executeContent(content)`. See
  # `Statifier.Interpreter.Content.execute_block/3` for the block runner
  # itself and the `Trace.ContentExecuted` emission that wraps it; this
  # module owns only *where and in what order* blocks run, which is what
  # the exit/entry pseudocode defines.
  @spec execute_block(
          machine_state :: MachineState.t(),
          owner :: Machine.Content.owner(),
          c_indexes :: [non_neg_integer()]
        ) :: {MachineState.t(), [Effect.t()]}
  defp execute_block(machine_state, owner, c_indexes),
    do: Content.execute_block(machine_state, owner, c_indexes)

  @doc """
  `computeEntrySet` (Appendix D) - the entry-set bookkeeping every
  `enabled_transitions` transition contributes, folded into one
  `entry_set()` accumulator.

  Per transition, in the pseudocode's own order: each *written* target
  (`transition.targets`, not the resolved history/effective set) through
  `add_descendant_states_to_enter/3`, then the transition's domain
  (`Selection.get_transition_domain/2`), then each *effective* target
  (`Selection.get_effective_target_states/2` - already resolves both
  history branches, consumed rather than re-resolved here) through
  `add_ancestor_states_to_enter/4` bounded by that domain. The
  written-versus-effective distinction is the pseudocode's own and is
  preserved here rather than collapsed into one walk.
  """
  @spec compute_entry_set(machine_state :: MachineState.t(), transitions :: [Transition.t()]) ::
          entry_set()
  def compute_entry_set(%MachineState{} = machine_state, transitions) do
    Enum.reduce(transitions, {MapSet.new(), MapSet.new(), %{}}, fn transition, acc ->
      entry_set_for_transition(machine_state, transition, acc)
    end)
  end

  # `computeEntrySet`'s per-transition body: the written-target descendant
  # walk, then the effective-target ancestor walk bounded by the domain.
  @spec entry_set_for_transition(
          machine_state :: MachineState.t(),
          transition :: Transition.t(),
          acc :: entry_set()
        ) :: entry_set()
  defp entry_set_for_transition(machine_state, %Transition{} = transition, acc) do
    acc =
      Enum.reduce(transition.targets, acc, fn target, acc ->
        add_descendant_states_to_enter(machine_state, target, acc)
      end)

    domain = Selection.get_transition_domain(machine_state, transition)

    machine_state
    |> Selection.get_effective_target_states(transition)
    |> Enum.reduce(acc, fn target, acc ->
      add_ancestor_states_to_enter(machine_state, target, domain, acc)
    end)
  end

  @doc """
  `addDescendantStatesToEnter` (Appendix D) - `state_index` and, depending on
  its kind, the descendants entering with it.

  Four cases, matching the pseudocode's own branches:

  - **history** (`enter_history_target/3`): a recorded value in
    `machine_state.history_values` restores those states; an unrecorded one
    registers `default_history_content` and follows the history's default
    transition's targets instead.
  - **compound**: `state_index` is added, flagged in
    `states_for_default_entry`, and its initial targets are entered
    (`enter_initial_targets/3`). When the document wrote an `<initial>`
    element, the targets come from
    `Machine.transition(machine, state.initial_transition).targets` - the
    pseudocode's `state.initial.transition.target` - because that transition
    is also what carries the default-entry content `run_default_entry/3`
    runs on the way in. **Mechanical deviation**:
    `Statifier.Compiler.resolve_initial/3` only populates
    `initial_transition` for a written `<initial>` element; a state
    defaulted through the `initial` attribute or the first-child fallback
    carries its resolved default in `State.initial` instead, with no
    synthesized transition (there being no `<initial>` content to run in
    that case either). `enter_initial_targets/3` reads `initial_transition`
    when set and falls back to `State.initial` otherwise, rather than
    asserting non-nil.
  - **parallel**: `state_index` is added and each child region not already
    covered by a `states_to_enter` descendant is entered
    (`enter_uncovered_regions/3`).
  - **atomic / final / anything else**: `state_index` is added and nothing
    else happens.
  """
  @spec add_descendant_states_to_enter(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          acc :: entry_set()
        ) :: entry_set()
  def add_descendant_states_to_enter(
        %MachineState{machine: machine} = machine_state,
        state_index,
        acc
      ) do
    cond do
      Machine.history?(machine, state_index) ->
        enter_history_target(machine_state, state_index, acc)

      Machine.compound?(machine, state_index) ->
        acc
        |> add_state(state_index)
        |> flag_default_entry(state_index)
        |> then(&enter_initial_targets(machine_state, state_index, &1))

      Machine.parallel?(machine, state_index) ->
        acc
        |> add_state(state_index)
        |> then(&enter_uncovered_regions(machine_state, state_index, &1))

      true ->
        add_state(acc, state_index)
    end
  end

  # The history arm of `addDescendantStatesToEnter`: a recorded value
  # restores those states directly; an unrecorded history registers
  # `default_history_content[history.parent] = history_default_t_index` -
  # the `t_index`, not the pseudocode's bare content list, since that is
  # what the content seam needs to build a `Content.owner()` - and follows
  # the default transition's targets instead. Both branches finish through
  # `enter_restored/4`, the shared "enter these targets, then walk ancestors
  # up to the history's parent" tail.
  @spec enter_history_target(
          machine_state :: MachineState.t(),
          history_index :: non_neg_integer(),
          acc :: entry_set()
        ) :: entry_set()
  defp enter_history_target(%MachineState{machine: machine} = machine_state, history_index, acc) do
    history_state = Machine.at(machine, history_index)

    case Map.fetch(machine_state.history_values, history_index) do
      {:ok, recorded} ->
        enter_restored(machine_state, MapSet.to_list(recorded), history_state.parent, acc)

      :error ->
        default_t_index = history_state.history_default
        targets = Map.fetch!(Machine.transition(machine, default_t_index), :targets)

        acc
        |> register_default_history_content(history_state.parent, default_t_index)
        |> then(&enter_restored(machine_state, targets, history_state.parent, &1))
    end
  end

  # Shared tail of both history branches and, via the pseudocode's own
  # duplication, the same shape a recorded value and an unrecorded default
  # both need: enter every target's descendants, then walk each target's
  # ancestors up to (excluding) `parent_index`.
  @spec enter_restored(
          machine_state :: MachineState.t(),
          targets :: [non_neg_integer()],
          parent_index :: non_neg_integer(),
          acc :: entry_set()
        ) :: entry_set()
  defp enter_restored(machine_state, targets, parent_index, acc) do
    acc =
      Enum.reduce(targets, acc, fn target, acc ->
        add_descendant_states_to_enter(machine_state, target, acc)
      end)

    Enum.reduce(targets, acc, fn target, acc ->
      add_ancestor_states_to_enter(machine_state, target, parent_index, acc)
    end)
  end

  # The compound arm's tail: `state.initial.transition.target`'s descendants,
  # then those same targets' ancestors bounded by `state_index` itself -
  # `addAncestorStatesToEnter(s, state, ...)` in the pseudocode.
  @spec enter_initial_targets(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          acc :: entry_set()
        ) :: entry_set()
  defp enter_initial_targets(%MachineState{machine: machine} = machine_state, state_index, acc) do
    targets = initial_targets(machine, state_index)

    acc =
      Enum.reduce(targets, acc, fn target, acc ->
        add_descendant_states_to_enter(machine_state, target, acc)
      end)

    Enum.reduce(targets, acc, fn target, acc ->
      add_ancestor_states_to_enter(machine_state, target, state_index, acc)
    end)
  end

  # `state.initial.transition.target` (Appendix D). Mechanical deviation
  # (see `add_descendant_states_to_enter/3`'s compound-arm doc): a written
  # `<initial>` element gives a real `t_index`, resolved through
  # `Machine.transition/2`; a defaulted state (the `initial` attribute or
  # the first-child fallback) has no such transition, so its already-
  # resolved `State.initial` indexes are used directly instead.
  @spec initial_targets(machine :: Machine.t(), state_index :: non_neg_integer()) :: [
          non_neg_integer()
        ]
  defp initial_targets(machine, state_index) do
    %State{initial_transition: t_index, initial: initial} = Machine.at(machine, state_index)

    case t_index do
      nil -> initial
      t_index -> Machine.transition(machine, t_index).targets
    end
  end

  # The parallel arm's tail, and the parallel expansion inside
  # `addAncestorStatesToEnter`: every child region of `state_index` not
  # already covered (`covered?/3`) by a descendant already in
  # `states_to_enter` is entered.
  @spec enter_uncovered_regions(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          acc :: entry_set()
        ) :: entry_set()
  defp enter_uncovered_regions(%MachineState{machine: machine} = machine_state, state_index, acc) do
    machine
    |> region_indexes(state_index)
    |> Enum.reduce(acc, fn child_index, acc ->
      if covered?(machine, child_index, acc) do
        acc
      else
        add_descendant_states_to_enter(machine_state, child_index, acc)
      end
    end)
  end

  # The local spelling of `Machine.child_states/2` - `getChildStates(state1)`
  # (Appendix D), "a list containing all `<state>`, `<final>`, and
  # `<parallel>` children of `state1`", i.e. its actual regions.
  # `Machine.children/2` (all direct children, `:history` included) is the
  # wrong function here: a `:history` pseudo-state is never itself entered -
  # it never becomes a member of `states_to_enter` - so treating it as an
  # uncovered region would recurse into `enter_history_target/3` on every
  # pass and never satisfy `covered?/3`, looping forever.
  @spec region_indexes(machine :: Machine.t(), state_index :: non_neg_integer()) :: [
          non_neg_integer()
        ]
  defp region_indexes(machine, state_index), do: Machine.child_states(machine, state_index)

  # `statesToEnter.some(lambda s: isDescendant(s, child))` - whether some
  # already-accumulated state is a (proper) descendant of `child_index`,
  # i.e. `child_index`'s region is already spoken for.
  @spec covered?(machine :: Machine.t(), child_index :: non_neg_integer(), acc :: entry_set()) ::
          boolean()
  defp covered?(machine, child_index, {states_to_enter, _default_entry, _history_content}) do
    Enum.any?(states_to_enter, &Machine.descendant?(machine, &1, child_index))
  end

  @doc """
  `addAncestorStatesToEnter` (Appendix D) - every proper ancestor of
  `state_index` up to but excluding `ancestor` is added, each parallel
  ancestor also pulling in its uncovered regions.

  `Machine.proper_ancestors/2` returns *all* ancestors up to the `:scxml`
  root (no two-argument bound), so the pseudocode's
  `getProperAncestors(state, ancestor)` is expressed as
  `Enum.take_while(&(&1 != ancestor))` over the one-argument helper. A
  `nil` `ancestor` (a targetless transition's domain, or a direct call with
  no bound) therefore correctly takes every ancestor, since `nil` never
  appears in `proper_ancestors/2`'s result.
  """
  @spec add_ancestor_states_to_enter(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          ancestor :: non_neg_integer() | nil,
          acc :: entry_set()
        ) :: entry_set()
  def add_ancestor_states_to_enter(
        %MachineState{machine: machine} = machine_state,
        state_index,
        ancestor,
        acc
      ) do
    machine
    |> Machine.proper_ancestors(state_index)
    |> Enum.take_while(&(&1 != ancestor))
    |> Enum.reduce(acc, fn anc, acc ->
      acc = add_state(acc, anc)

      if Machine.parallel?(machine, anc) do
        enter_uncovered_regions(machine_state, anc, acc)
      else
        acc
      end
    end)
  end

  # `statesToEnter.add(s)` - the one member every arm of
  # `addDescendantStatesToEnter` and every ancestor of
  # `addAncestorStatesToEnter` adds, unconditionally.
  @spec add_state(acc :: entry_set(), state_index :: non_neg_integer()) :: entry_set()
  defp add_state({states_to_enter, default_entry, history_content}, state_index) do
    {MapSet.put(states_to_enter, state_index), default_entry, history_content}
  end

  # `statesForDefaultEntry.add(state)` - flags a compound state entered via
  # its `<initial>` declaration rather than as an explicit target, so
  # `enter_states/2` knows to run its default-entry content.
  @spec flag_default_entry(acc :: entry_set(), state_index :: non_neg_integer()) :: entry_set()
  defp flag_default_entry({states_to_enter, default_entry, history_content}, state_index) do
    {states_to_enter, MapSet.put(default_entry, state_index), history_content}
  end

  # `defaultHistoryContent[state.parent] = state.transition.content` -
  # keyed by the history state's *parent* index, valued by the default
  # transition's `t_index` rather than its content list.
  @spec register_default_history_content(
          acc :: entry_set(),
          parent_index :: non_neg_integer(),
          t_index :: non_neg_integer()
        ) :: entry_set()
  defp register_default_history_content(
         {states_to_enter, default_entry, history_content},
         parent_index,
         t_index
       ) do
    {states_to_enter, default_entry, Map.put(history_content, parent_index, t_index)}
  end

  @doc """
  `enterStates` (Appendix D) - the entry-ordered set `compute_entry_set/2`
  computes, added to the configuration with `onentry`, default-entry, and
  default-history content run per state, then completion events raised.

  Body, in the pseudocode's own order:

  1. `compute_entry_set/2` over `enabled_transitions`.
  2. `entry_order` = `Machine.document_order/2` over `states_to_enter` -
     ascending index, the mirror of `exit_states/2`'s `exit_order`.
  3. `entry_order` is reduced through `arrive/3`, each state added to the
     configuration, its `onentry` blocks run, its default-entry / default-
     history content run when flagged/registered, then its completion
     events raised.
  4. `Effect.trace(pre_entry_state, Effect.Trace.EntrySet, indexes:
     entry_order, configuration: machine_state.configuration)` is emitted
     last: `macrostep`/`microstep`/`round` are stamped against
     `pre_entry_state`, captured as `machine_state` stood before step 3's
     `arrive/3` reduce (ADR-0012, mirroring `exit_states/2`), while
     `configuration` is read from the post-entry `machine_state` because
     "the configuration after this entry set was applied" does not exist
     until step 3 has run. The payload's position in the returned
     list is unchanged: it is still first, since the list is concatenated
     at the end either way.
  """
  @spec enter_states(machine_state :: MachineState.t(), enabled_transitions :: [Transition.t()]) ::
          {MachineState.t(), [Effect.t()]}
  def enter_states(%MachineState{machine: machine} = machine_state, enabled_transitions) do
    {states_to_enter, states_for_default_entry, default_history_content} =
      compute_entry_set(machine_state, enabled_transitions)

    entry_order = Machine.document_order(machine, states_to_enter)

    # ADR-0012: the counters this payload stamps must be the ones that stood
    # at the entry-set phase boundary, so the trace is stamped against
    # `pre_entry_state`; only `configuration` is read from the post-entry
    # state, because "the configuration after this entry set was applied"
    # does not exist until the reduce below has run. Effect-list
    # position is unchanged: the list is concatenated at the end either way.
    pre_entry_state = machine_state

    bookkeeping = {states_for_default_entry, default_history_content}

    {machine_state, arrive_effects} =
      Enum.reduce(entry_order, {machine_state, []}, fn state_index, {ms, effects} ->
        {ms, new_effects} = arrive(ms, state_index, bookkeeping)
        {ms, effects ++ new_effects}
      end)

    trace_effects =
      Effect.trace(pre_entry_state, Effect.Trace.EntrySet,
        indexes: entry_order,
        configuration: machine_state.configuration
      )

    {machine_state, trace_effects ++ arrive_effects}
  end

  # `enterStates`'s per-state entry body: add to the configuration, add
  # `state_index` to `states_to_invoke` unconditionally (see
  # `MachineState`'s own moduledoc section on that field), bind
  # `state_index`'s own datamodel under `binding == "late"` on first entry
  # (`MachineState.entered_states` is the ADR-0002 substitute for Appendix
  # D's `s.isFirstEntry`, see that field's moduledoc section), run
  # `onentry` blocks, run default-entry / default-history content, then
  # raise this state's completion events.
  @spec arrive(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          bookkeeping ::
            {MapSet.t(non_neg_integer()), %{optional(non_neg_integer()) => non_neg_integer()}}
        ) :: {MachineState.t(), [Effect.t()]}
  defp arrive(machine_state, state_index, bookkeeping) do
    machine_state = %{
      machine_state
      | configuration: MapSet.put(machine_state.configuration, state_index)
    }

    # `statesToInvoke.add(s)` (Appendix D) - unconditional, no test for
    # `s.invoke`; the invoke pass (a later caller) is what skips a state
    # with none.
    machine_state = %{
      machine_state
      | states_to_invoke: MapSet.put(machine_state.states_to_invoke, state_index)
    }

    # `if binding == "late" and s.isFirstEntry: initializeDataModel(...); s.isFirstEntry = false`
    # (Appendix D `:312-314`). Membership is tested *before* the `MapSet.put`
    # below - reversing that order would put `state_index` into
    # `entered_states` first, so the membership test would then always see
    # its own index already present and `first_entry?` would be `false` on
    # *every* entry, first included: `Datamodel.enter_state/2` would never
    # run at all, and every state-scoped late-bound `<data>` would stay
    # permanently `nil`.
    first_entry? = not MapSet.member?(machine_state.entered_states, state_index)

    machine_state = %{
      machine_state
      | entered_states: MapSet.put(machine_state.entered_states, state_index)
    }

    # `initializeDataModel(datamodel.s, doc.s)` precedes the onentry loop
    # (Appendix D `:311-313`), and spec 5.3.3 says so directly: "before any
    # <onentry> markup". `data_effects` is threaded first in the final
    # concatenation below for the same reason - see "The Appendix D rule" in
    # the initial-datamodel-binding-effect plan.
    {machine_state, data_effects} =
      if first_entry?,
        do: Datamodel.enter_state(machine_state, state_index),
        else: {machine_state, []}

    {machine_state, onentry_effects} = run_onentry_blocks(machine_state, state_index)

    {machine_state, default_entry_effects} =
      run_default_entry(machine_state, state_index, bookkeeping)

    {machine_state, completion_effects} = raise_completion_events(machine_state, state_index)

    {machine_state,
     data_effects ++ onentry_effects ++ default_entry_effects ++ completion_effects}
  end

  # `state.onentry` in document order, each block through the
  # `execute_block/3` seam with `{:onentry, state_index, ordinal}` -
  # `ordinal` is the block's position in the state's own `onentry` list,
  # the mirror of `run_onexit_blocks/2`.
  @spec run_onentry_blocks(machine_state :: MachineState.t(), state_index :: non_neg_integer()) ::
          {MachineState.t(), [Effect.t()]}
  defp run_onentry_blocks(%MachineState{machine: machine} = machine_state, state_index) do
    machine
    |> Machine.at(state_index)
    |> Map.fetch!(:onentry)
    |> Enum.with_index()
    |> Enum.reduce({machine_state, []}, fn {block, ordinal}, {ms, effects} ->
      {ms, new_effects} = execute_block(ms, {:onentry, state_index, ordinal}, block.content)
      {ms, effects ++ new_effects}
    end)
  end

  # The default-entry and default-history-content steps of `enterStates`'s
  # per-state body: when `state_index` is flagged in
  # `states_for_default_entry`, run its `<initial>` transition's content -
  # guarded on `initial_transition` being non-nil, since a state defaulted
  # through the `initial` attribute or the first-child fallback has no
  # `<initial>` element and therefore no content to run; when
  # `default_history_content` registers a default transition for
  # `state_index`, run that transition's content too.
  @spec run_default_entry(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          bookkeeping ::
            {MapSet.t(non_neg_integer()), %{optional(non_neg_integer()) => non_neg_integer()}}
        ) :: {MachineState.t(), [Effect.t()]}
  defp run_default_entry(
         %MachineState{machine: machine} = machine_state,
         state_index,
         {states_for_default_entry, default_history_content}
       ) do
    {machine_state, initial_effects} =
      if MapSet.member?(states_for_default_entry, state_index) do
        run_initial_transition_content(machine_state, machine, state_index)
      else
        {machine_state, []}
      end

    {machine_state, history_effects} =
      case Map.fetch(default_history_content, state_index) do
        {:ok, t_index} -> run_transition_content(machine_state, machine, t_index)
        :error -> {machine_state, []}
      end

    {machine_state, initial_effects ++ history_effects}
  end

  # `state.initial.transition`'s content - only when the document actually
  # wrote an `<initial>` element; see
  # `add_descendant_states_to_enter/3`'s compound-arm doc for why
  # `initial_transition` can be `nil` here.
  @spec run_initial_transition_content(
          machine_state :: MachineState.t(),
          machine :: Machine.t(),
          state_index :: non_neg_integer()
        ) :: {MachineState.t(), [Effect.t()]}
  defp run_initial_transition_content(machine_state, machine, state_index) do
    case Machine.at(machine, state_index).initial_transition do
      nil -> {machine_state, []}
      t_index -> run_transition_content(machine_state, machine, t_index)
    end
  end

  # `execute_block/3` for a transition's own content, shared by the
  # `<initial>` transition and the default history transition - both own
  # their content as `{:transition, t_index}`.
  @spec run_transition_content(
          machine_state :: MachineState.t(),
          machine :: Machine.t(),
          t_index :: non_neg_integer()
        ) :: {MachineState.t(), [Effect.t()]}
  defp run_transition_content(machine_state, machine, t_index) do
    content = Machine.transition(machine, t_index).content
    execute_block(machine_state, {:transition, t_index}, content)
  end

  # `enterStates`'s `isFinalState(s)` tail. State index 0 is the `:scxml`
  # root, so a final state whose parent is 0 is a top-level final:
  # `running: false`, nothing raised - the pseudocode's
  # `isSCXMLElement(s.parent)`. Otherwise `done.state.*` is raised for the
  # parent (and, when it completes a parallel, the grandparent too) through
  # `raise_parent_completion/3`.
  @spec raise_completion_events(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer()
        ) :: {MachineState.t(), [Effect.t()]}
  defp raise_completion_events(%MachineState{machine: machine} = machine_state, state_index) do
    if Machine.final?(machine, state_index) do
      parent = Machine.at(machine, state_index).parent

      if parent == 0 do
        {%{machine_state | running: false}, []}
      else
        raise_parent_completion(machine_state, state_index, parent)
      end
    else
      {machine_state, []}
    end
  end

  # `new Event("done.state." + parent.id, s.donedata)`, skipped when
  # `parent` has no written id. As of st-t8w this guard is defense in depth,
  # not the primary gate: `Statifier.Validator.Checks.FinalParent` now
  # refuses any document where a `<final>`'s parent carries no `id`, so an
  # id-less parent should never reach this point through the ordinary
  # Parser -> Lowering -> Validator -> Compiler pipeline. The guard stays
  # anyway because `Statifier.Compiler.compile/1` is public and reachable
  # without going through `Statifier.Validator.validate/2`
  # (`docs/architecture.md` principle 4 makes the validator the only gate in
  # the *pipeline*, not a type-level guarantee about every caller), and
  # `Machine.id/2`'s return type still admits `nil`. Then, when `parent`'s
  # own parent is a `:parallel` whose every region now satisfies
  # `in_final_state?/2`, `done.state.{grandparent_id}` follows with no
  # `data` - the pseudocode's nested check, not a sibling of this one; see
  # `maybe_raise_grandparent_completion/3` for why *its* guard is not
  # defense in depth.
  @spec raise_parent_completion(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          parent :: non_neg_integer()
        ) :: {MachineState.t(), [Effect.t()]}
  defp raise_parent_completion(
         %MachineState{machine: machine} = machine_state,
         state_index,
         parent
       ) do
    case Machine.id(machine, parent) do
      parent_id when is_binary(parent_id) and parent_id != "" ->
        # `donedata/2` is called before the `done.state.*` raise, and its
        # returned `machine_state` (which may already carry a queued
        # `error.execution`) is what the raise below builds on - not the
        # `machine_state` this function was called with. 5.6/5.7 place
        # `error.execution` "in the internal event queue" at evaluation
        # time, and evaluation completes before the done event is raised,
        # so the error is enqueued first.
        {machine_state, donedata} = donedata(machine_state, state_index)

        machine_state =
          MachineState.raise_platform(
            machine_state,
            "done.state." <> parent_id,
            {:state, state_index},
            data: donedata
          )

        maybe_raise_grandparent_completion(machine_state, state_index, parent)

      _no_id ->
        {machine_state, []}
    end
  end

  # The grandparent-parallel half of `raise_parent_completion/3`: raised
  # only when `parent`'s own parent is a `:parallel` and every one of its
  # regions (`region_indexes/2` - never a `:history` pseudo-state, the same
  # landmine `enter_uncovered_regions/3` avoids) satisfies
  # `in_final_state?/2`. Same id guard as the parent event, but unlike that
  # one this guard is NOT made unreachable by `Checks.FinalParent` (st-t8w) -
  # do not delete it "by symmetry" with the parent guard above. Whether a
  # `:parallel`'s every region currently satisfies `in_final_state?/2` is a
  # runtime configuration property, not a static document property, so no
  # validator rule can refuse the id-less `:parallel` ahead of time; this
  # guard remains the only thing standing between that document and a raise
  # with no id to name.
  @spec maybe_raise_grandparent_completion(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          parent :: non_neg_integer()
        ) :: {MachineState.t(), [Effect.t()]}
  defp maybe_raise_grandparent_completion(
         %MachineState{machine: machine} = machine_state,
         state_index,
         parent
       ) do
    grandparent = Machine.at(machine, parent).parent

    parallel_complete? =
      grandparent != nil and Machine.parallel?(machine, grandparent) and
        machine
        |> region_indexes(grandparent)
        |> Enum.all?(&in_final_state?(machine_state, &1))

    if parallel_complete? do
      case Machine.id(machine, grandparent) do
        grandparent_id when is_binary(grandparent_id) and grandparent_id != "" ->
          {MachineState.raise_platform(
             machine_state,
             "done.state." <> grandparent_id,
             {:state, state_index}
           ), []}

        _no_id ->
          {machine_state, []}
      end
    else
      {machine_state, []}
    end
  end

  @doc """
  `returnDoneEvent`'s `s.donedata` argument (Appendix D) - `state_index`'s
  `<donedata>`, folded to the value a raised or returned `done.*` event
  carries as `data`.

  - No `<donedata>` at all, or a `%Donedata{expr: nil, params: []}` (no
    `<content>` or `<param>` child at all) - `{machine_state, :undefined}`:
    "no data", the same spelling every other absent-payload writer uses
    (`docs/adr/0037-unbound-spelled-undefined-at-the-writer.md`).
  - `{:static, text}` - `<content>`'s text body, which can only originate
    there (`Statifier.Compiler.build_content_expr/2`). Coerced through
    `Statifier.EventData.coerce({:text, text})` (Decision 3 of the plan on
    this module) so `<content>21</content>` becomes the integer `21`
    (W3C test529), not the string `"21"`.
  - `{:compiled, _, _}` - `<content expr>`. Evaluated against a fresh
    `Statifier.Evaluator.context/1`; success is coerced through
    `EventData.coerce({:value, v})` (identity - an evaluated expression
    already produced a legal data value, so it is never re-run through the
    text ladder). Failure raises `error.execution` via
    `MachineState.raise_platform/4` and returns `:undefined` donedata -
    **not** the empty string spec 5.6 names for `<content>` generally
    (ADR-0021 records that deviation and its scope), and not `nil` either:
    a failed evaluation produced no data, it did not produce a null value
    (W3C test528).
  - `expr: nil` with a non-empty `params` list - `<param>` children, folded
    against one `Statifier.Evaluator.context/1` built once for the whole
    fold. Each param is evaluated in document order; a failure raises its
    own `error.execution` (spec 5.7: "If the evaluation of 'expr' produces
    an error, or if neither 'location' nor 'expr' is present, or if the
    value of 'location' is not a valid location for a data value in the
    underlying data model, the SCXML Processor MUST place the error
    'error.execution' in the internal event queue and MUST ignore the name
    and value") and is dropped rather than aborting the remaining params.
    The surviving `{name, value}` pairs, still in document order, go
    through `EventData.coerce({:params, pairs})`, which returns `:undefined`
    for an empty result (`Statifier.EventData`'s own moduledoc, Decision 5) -
    so a `<donedata>` whose only param fails produces `:undefined` data, the
    same shape as no donedata at all, not `%{}`. The `<content>` arm above
    and this params arm are mutually exclusive by validator check
    (`Statifier.Validator.Checks.Donedata`), so there is no case where both
    are non-empty.

  Two callers: `raise_parent_completion/3` (a non-top-level final's
  `done.state.*`) and `Statifier.Interpreter.exit_interpreter/1` (a
  top-level final's terminal `{:done, _}` effect) - the same folding rule
  either way. `<donedata>` carries no `c_index`
  (`lib/statifier/machine/content.ex:25-28`), so
  `Statifier.Interpreter.Content.raise_execution_error/4`'s `{:content,
  c_index, owner}` origin shape does not apply here; the raise below uses
  `{:state, state_index}` instead, the same origin shape
  `raise_parent_completion/3` already stamps on the `done.state.*` event
  itself - for both the `<content>` arm and each failing `<param>`.
  """
  @spec donedata(machine_state :: MachineState.t(), state_index :: non_neg_integer()) ::
          {MachineState.t(), term()}
  def donedata(%MachineState{machine: machine} = machine_state, state_index) do
    case Machine.at(machine, state_index).donedata do
      nil ->
        {machine_state, :undefined}

      %Donedata{expr: nil, params: []} ->
        {machine_state, :undefined}

      %Donedata{expr: nil, params: params} ->
        evaluate_donedata_params(machine_state, state_index, params)

      %Donedata{expr: {:static, text}} ->
        {machine_state, EventData.coerce({:text, text})}

      %Donedata{expr: {:compiled, _predicator_compiled, _source} = expr} ->
        evaluate_donedata(machine_state, state_index, expr)
    end
  end

  # The `{:compiled, ...}` arm of `donedata/2`: evaluate against a fresh
  # context, coerce a success through the `{:value, _}` identity rung, or
  # raise `error.execution` and return `nil` on failure (ADR-0021).
  #
  # ADR-0014 item 4's four committed fields are all present across the two
  # arguments, none of them duplicated into a new struct: the owning node's
  # constraint-3 identity is the `{:state, state_index}` origin, and the
  # expression source string, predicator's own error struct, and its span
  # are the three fields of the `%Statifier.Evaluator.Error{}` that
  # `Evaluator.evaluate/2` returns as `reason` (see that struct's moduledoc,
  # which states it carries no `owner` precisely because the raise site
  # stamps one). This mirrors `Statifier.Interpreter.Selection`'s failed-`cond`
  # raise, which passes the same `data: reason` alongside a
  # `{:transition, t_index}` origin for the same reason.
  @spec evaluate_donedata(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          expr :: Machine.expr()
        ) :: {MachineState.t(), term()}
  defp evaluate_donedata(machine_state, state_index, expr) do
    context = Evaluator.context(machine_state)

    case Evaluator.evaluate(context, expr) do
      {:ok, value} ->
        {machine_state, EventData.coerce({:value, value})}

      {:error, reason} ->
        machine_state =
          MachineState.raise_platform(
            machine_state,
            "error.execution",
            {:state, state_index},
            data: reason
          )

        {machine_state, :undefined}
    end
  end

  # The params arm of `donedata/2`: one context for the whole fold (per
  # `docs/datamodel.md`'s "evaluate once, not per param" guidance), each
  # `<param>` evaluated in document order against it. A failure raises its
  # own `error.execution` and is dropped from the result rather than
  # aborting the fold (spec 5.7's "MUST ignore the name and value" - see
  # `donedata/2`'s own doc for the full quote). The surviving pairs, still
  # in document order, are handed to `EventData.coerce({:params, _})`
  # (Decision 5).
  @spec evaluate_donedata_params(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          params :: [Param.t()]
        ) :: {MachineState.t(), term()}
  defp evaluate_donedata_params(machine_state, state_index, params) do
    context = Evaluator.context(machine_state)

    {machine_state, pairs} =
      params
      |> Enum.with_index()
      |> Enum.reduce({machine_state, []}, fn {%Param{name: name, expr: expr}, param_index},
                                             {machine_state, pairs} ->
        case Evaluator.evaluate(context, expr) do
          {:ok, value} ->
            {machine_state, [{name, value} | pairs]}

          {:error, reason} ->
            # `{:donedata_param, state_index, param_index}`, not the
            # `{:state, state_index}` the `<content>` arm uses: 5.7 fails
            # each `<param>` independently, so several siblings can raise in
            # one step and a state-level origin would stamp all of them
            # identically (`docs/observability.md` constraint 4 - see
            # `Statifier.Event.Cause`'s own arm for the full argument).
            # `param_index` is the document-order position in this state's
            # `donedata.params`, which is how a diagnostic reaches the
            # failing `<param>`'s `name` and `expr_location`.
            machine_state =
              MachineState.raise_platform(
                machine_state,
                "error.execution",
                {:donedata_param, state_index, param_index},
                data: reason
              )

            {machine_state, pairs}
        end
      end)

    {machine_state, EventData.coerce({:params, Enum.reverse(pairs)})}
  end

  @doc """
  `isInFinalState` (Appendix D) - whether `state_index` is, itself or
  through its active descendants, "in a final state": a compound state
  answers true when some active child is a `:final`; a parallel answers
  true only when *every* region does, recursively; anything else (an
  atomic `:final` included) answers false. Ported verbatim.
  """
  @spec in_final_state?(machine_state :: MachineState.t(), state_index :: non_neg_integer()) ::
          boolean()
  # `isInFinalState` is `in_final_state?` - orthographic, not semantic, and a
  # near miss on the canonical `is_in_final_state` by construction - per
  # ADR-0002's 2026-08-09 predicate-naming amendment.
  def in_final_state?(%MachineState{machine: machine} = machine_state, state_index) do
    cond do
      Machine.compound?(machine, state_index) ->
        machine
        |> region_indexes(state_index)
        |> Enum.any?(fn child ->
          MapSet.member?(machine_state.configuration, child) and Machine.final?(machine, child)
        end)

      Machine.parallel?(machine, state_index) ->
        machine
        |> region_indexes(state_index)
        |> Enum.all?(&in_final_state?(machine_state, &1))

      true ->
        false
    end
  end
end
