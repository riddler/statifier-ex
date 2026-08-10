defmodule Statifier.Interpreter.ExitEntry do
  @moduledoc """
  Appendix D's exit and entry blocks, ported function for function
  (ADR-0002) - the half of the algorithm that changes the configuration.
  `Statifier.Interpreter.Selection` answers "which transitions fire and
  what would they leave"; this module actually leaves and enters states.

  `machine_state` stands in for the pseudocode's globals exactly as
  `Statifier.Interpreter.Selection`'s moduledoc states for the same reason
  (`docs/observability.md` constraint 1, plan Decision 3 for this bead) -
  every function here that reads a global takes `machine_state` as its
  first argument.

  ## Return shapes (Decision 2)

  `exit_states/2` and `enter_states/2` are the two functions in this bead
  that both mutate the position and emit effects, so both return
  `{MachineState.t(), [Effect.t()]}` - the shape `docs/observability.md`
  fixes for `microstep/1`, their only future caller (st-wju.6). Effect
  order within the returned list is emission order: the trace effect
  first, then each block's effects in the order the blocks ran.

  ## Ordering (Decision 4)

  Exit order and entry order are never hand-sorted here: `exit_states/2`
  pipes `Statifier.Interpreter.Selection.compute_exit_set/2`'s `MapSet`
  through `Statifier.Machine.exit_order/2` (descending index).

  ## The content seam (Decision 6)

  Every call site that would run executable content - `<onexit>`,
  `<onentry>`, an `<initial>` transition's content, default history
  content - goes through the private `execute_block/3` seam, whose body is
  a no-op stub today. st-wju.5 owns the block runner and the
  `Trace.ContentExecuted` emission that wraps it; this bead owns only
  *where and in what order* blocks run. Replacing `execute_block/3`'s body
  changes no call site and no ordering.

  ## History recording (Decision 7)

  `exit_states/2` records history in a full first pass over the exit set,
  reading the configuration exactly as it stood before any state exited -
  *before* the first `onexit` runs and before any state is removed. The
  pseudocode writes two consecutive `for s in statesToExit` loops for
  exactly this reason: recording inside the delete loop would let a
  later-exiting state's deep history see a configuration its own siblings
  have already been removed from.

  ## The entry set (Decision 3)

  `compute_entry_set/2`, `add_descendant_states_to_enter/3`, and
  `add_ancestor_states_to_enter/4` are pure queries: none of them touch
  `machine_state.configuration`, none of them emit an effect. The
  pseudocode's three `statesToEnter` / `statesForDefaultEntry` /
  `defaultHistoryContent` out-parameters become one accumulator of type
  `entry_set()`, threaded in and returned last - the minimal mechanical
  deviation Elixir's lack of out-parameters forces. `default_history_content`
  stores the default transition's `t_index` rather than its `[c_index]` list
  (Decision 5): strictly more information, and what the content seam
  (Decision 6) actually needs to build a `Content.owner()`.
  """

  alias Statifier.Interpreter.Selection
  alias Statifier.Machine
  alias Statifier.Machine.Content
  alias Statifier.Machine.State
  alias Statifier.Machine.Transition
  alias Statifier.MachineState

  require Statifier.Effect, as: Effect

  @typedoc """
  The pseudocode's three `computeEntrySet` out-parameters (Decision 3),
  threaded as one accumulator: the states a transition set will enter, the
  subset of those entered via a compound state's `<initial>` declaration
  rather than as an explicit target (so default-entry content runs only for
  them), and a map from a history state's parent to the `t_index` of the
  default transition whose content runs because that history was
  unrecorded (Decision 5).
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

  1. `states_to_exit` = `Selection.compute_exit_set/2` over
     `enabled_transitions`, piped through `Machine.exit_order/2` for exit
     order (Decision 4) - the boundary decision this bead's own note
     records: `compute_exit_set/2` returns an unordered `MapSet`, and
     ordering it is this function's job, not `Selection`'s.
  2. The pseudocode's `statesToInvoke.delete(s)` line is skipped:
     `states_to_invoke` is deliberately absent from `MachineState` until
     st-cmq (invoke) adds it with its own caller.
  3. `Effect.trace(machine_state, Effect.Trace.ExitSet, indexes:
     states_to_exit)` is emitted before any mutation (Decision 13), over
     the *original* `machine_state` - the macro's own hygienic
     `machine_state` rebinding inside its expansion does not touch this
     function's parameter (Decision 13's own note).
  4. `record_history_values/2` runs its whole first pass over
     `states_to_exit`, reading the untouched configuration (Decision 7).
  5. `states_to_exit` is reduced through `depart/2`, each state running its
     `onexit` blocks and then leaving the configuration.
  """
  @spec exit_states(machine_state :: MachineState.t(), enabled_transitions :: [Transition.t()]) ::
          {MachineState.t(), [Effect.t()]}
  def exit_states(%MachineState{machine: machine} = machine_state, enabled_transitions) do
    states_to_exit =
      machine_state
      |> Selection.compute_exit_set(enabled_transitions)
      |> then(&Machine.exit_order(machine, &1))

    trace_effects = Effect.trace(machine_state, Effect.Trace.ExitSet, indexes: states_to_exit)

    machine_state = record_history_values(machine_state, states_to_exit)

    {machine_state, depart_effects} =
      Enum.reduce(states_to_exit, {machine_state, []}, fn state_index, {ms, effects} ->
        {ms, new_effects} = depart(ms, state_index)
        {ms, effects ++ new_effects}
      end)

    {machine_state, trace_effects ++ depart_effects}
  end

  # `exitStates`'s history-recording loop - `for s in statesToExit: for h
  # in s.history: historyValue[h.id] = ...` - the whole first pass, run
  # before any `onexit` content and before any state leaves the
  # configuration (Decision 7). Reads `history_children` (populated by the
  # compiler), so this is a field read per exiting state, never a scan.
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

  # The two lambdas `exitStates` records history with, verbatim (Decision
  # 7): a `:shallow` history records `s`'s active *immediate* children; a
  # `:deep` history records `s`'s active *atomic descendants*.
  # `descendant?/3` is proper, which is correct here because `s` is not
  # atomic when it has a history child.
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

  # `exitStates`'s per-state exit body: run its onexit blocks, skip
  # `cancelInvoke` (st-cmq owns invocations; nothing exists yet to
  # cancel), then remove it from the configuration.
  @spec depart(machine_state :: MachineState.t(), state_index :: non_neg_integer()) ::
          {MachineState.t(), [Effect.t()]}
  defp depart(machine_state, state_index) do
    {machine_state, effects} = run_onexit_blocks(machine_state, state_index)

    machine_state = %{
      machine_state
      | configuration: MapSet.delete(machine_state.configuration, state_index)
    }

    {machine_state, effects}
  end

  # `state.onexit` in document order, each block through the `execute_block/3`
  # seam with `{:onexit, state_index, ordinal}` - `ordinal` is the block's
  # position in the state's own `onexit` list, exactly what
  # `Machine.Content.owner()` documents it to be.
  @spec run_onexit_blocks(machine_state :: MachineState.t(), state_index :: non_neg_integer()) ::
          {MachineState.t(), [Effect.t()]}
  defp run_onexit_blocks(%MachineState{machine: machine} = machine_state, state_index) do
    machine
    |> Machine.at(state_index)
    |> Map.fetch!(:onexit)
    |> Enum.with_index()
    |> Enum.reduce({machine_state, []}, fn {block, ordinal}, {ms, effects} ->
      {ms, new_effects} = execute_block(ms, {:onexit, state_index, ordinal}, block.content)
      {ms, effects ++ new_effects}
    end)
  end

  # ADR-0002: the pseudocode's `executeContent(content)`. st-wju.5 owns the
  # block runner and the `Trace.ContentExecuted` emission that wraps it;
  # this bead owns only *where and in what order* blocks run, which is
  # what the exit/entry pseudocode defines. Replacing this body with a
  # call to that runner changes no call site and no ordering (Decision 6).
  @spec execute_block(
          machine_state :: MachineState.t(),
          owner :: Content.owner(),
          c_indexes :: [non_neg_integer()]
        ) :: {MachineState.t(), [Effect.t()]}
  defp execute_block(machine_state, _owner, _c_indexes), do: {machine_state, []}

  @doc """
  `computeEntrySet` (Appendix D) - the entry-set bookkeeping every
  `enabled_transitions` transition contributes, folded into one
  `entry_set()` accumulator (Decision 3).

  Per transition, in the pseudocode's own order: each *written* target
  (`transition.targets`, not the resolved history/effective set) through
  `add_descendant_states_to_enter/3`, then the transition's domain
  (`Selection.get_transition_domain/2`), then each *effective* target
  (`Selection.get_effective_target_states/2` - already resolves both
  history branches, plan Decision 5 of st-wju.3, consumed rather than
  re-ported) through `add_ancestor_states_to_enter/4` bounded by that
  domain. The written-versus-effective distinction is the pseudocode's own
  and is preserved here rather than collapsed into one walk.
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
    registers `default_history_content` (Decision 5) and follows the
    history's default transition's targets instead.
  - **compound**: `state_index` is added, flagged in
    `states_for_default_entry`, and its initial targets are entered
    (`enter_initial_targets/3`). When the document wrote an `<initial>`
    element, the targets come from
    `Machine.transition(machine, state.initial_transition).targets` - the
    pseudocode's `state.initial.transition.target` - because that transition
    is also what carries the default-entry content Phase 3 runs. **Mechanical
    deviation**: `Statifier.Compiler.resolve_initial/3` only populates
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
  # `default_history_content[history.parent] = history_default_t_index`
  # (Decision 5 - the `t_index`, not the pseudocode's bare content list) and
  # follows the default transition's targets instead. Both branches finish
  # through `enter_restored/4`, the shared "enter these targets, then walk
  # ancestors up to the history's parent" tail.
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

  # `getChildStates(state)` (Appendix D) - "all `<state>`, `<final>`, and
  # `<parallel>` children of `state`", i.e. its actual regions. Mechanical
  # deviation: `Machine.child_indexes/2` returns *every* direct child
  # (its own `@doc` names it `getChildStates`, but the compiled `children`
  # field carries a `:history` child too, precisely so
  # `State.history_children` can be a lookup rather than a scan). A
  # `:history` pseudo-state is never itself entered - it never becomes a
  # member of `states_to_enter` - so treating it as an uncovered region
  # would recurse into `enter_history_target/3` on every pass and never
  # satisfy `covered?/3`, looping forever. Regions are `children --
  # history_children`.
  @spec region_indexes(machine :: Machine.t(), state_index :: non_neg_integer()) :: [
          non_neg_integer()
        ]
  defp region_indexes(machine, state_index) do
    %State{children: children, history_children: history_children} =
      Machine.at(machine, state_index)

    children -- history_children
  end

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
  # `enter_states/2` (Phase 3) knows to run its default-entry content.
  @spec flag_default_entry(acc :: entry_set(), state_index :: non_neg_integer()) :: entry_set()
  defp flag_default_entry({states_to_enter, default_entry, history_content}, state_index) do
    {states_to_enter, MapSet.put(default_entry, state_index), history_content}
  end

  # `defaultHistoryContent[state.parent] = state.transition.content` -
  # keyed by the history state's *parent* index, valued by the default
  # transition's `t_index` rather than its content list (Decision 5).
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
end
