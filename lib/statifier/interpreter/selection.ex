defmodule Statifier.Interpreter.Selection do
  @moduledoc """
  Appendix D transition selection, ported function for function (ADR-0002).

  Every function here that reads a global takes `machine_state` (or, when it
  needs only topology, `machine`) as its first argument - the mechanical
  deviation `docs/observability.md` constraint 1 sanctions for reifying the
  pseudocode's `configuration` and `historyValue` globals onto
  `%Statifier.MachineState{}` (plan Decision 3). Each function's own `@doc`
  says which global its first argument stands in for; this paragraph states
  the rule once so they do not each re-argue it.

  `compute_exit_set/2` returns a `MapSet` of indexes, not an `OrderedSet`
  (plan Decision 6): `remove_conflicting_transitions` (Phase 3) wants set
  intersection and gets it directly, and a caller that wants exit *order*
  pipes the result through `Statifier.Machine.exit_order/2`, which already
  exists for exactly that. No function in this module orders an exit set
  itself.

  Every function is a pure query - plain values in, plain values out, no
  hidden context, callable standalone in `iex` (`docs/observability.md`
  constraint 5). Phase 2 landed the domain half of the block: `find_lcca/2`
  (delegated), `get_effective_target_states/2`, `get_transition_domain/2`,
  and `compute_exit_set/2` - "which states does this transition leave".
  Phase 3 adds the selection half - `condition_match/2`,
  `select_transitions/2`, `select_eventless_transitions/1`, and
  `remove_conflicting_transitions/2` - "which transitions fire".

  `select_transitions/2` and `select_eventless_transitions/1` are the two
  functions in this module that thread `machine_state` through their
  *return* value as well as their first argument (plan Decision 8): both
  return `{MachineState.t(), [Transition.t()]}` rather than a bare list, so
  that when st-af3 replaces `condition_match/2`'s stub with a real
  evaluation and starts enqueuing `error.execution` on a failed `cond`, both
  entry points already have a machine_state to enqueue onto - st-af3 changes
  a function body, not either signature. Every other query in this module,
  including `remove_conflicting_transitions/2` itself, still returns a plain
  value with no machine_state, because none of them can raise. In this phase
  the machine_state comes back unchanged from both entry points; a test
  below pins that so the day it stops being true is a deliberate st-af3 edit.

  The two walks and the conflict filter are Appendix D's two nested loops
  with labelled breaks, decomposed into named private helpers to stay under
  Credo's cyclomatic-complexity and nesting limits (plan Decision 9) - each
  helper's doc names the pseudocode lines it stands in for, so "diff against
  the pseudocode" still works one level down. The enabled set is deduplicated
  by `t_index`, keeping the first occurrence, in place of the pseudocode's
  `OrderedSet` (plan Decision 10).
  """

  alias Statifier.Event
  alias Statifier.Interpreter.NameMatch
  alias Statifier.Machine
  alias Statifier.Machine.Transition
  alias Statifier.MachineState

  @doc """
  `findLCCA` (Appendix D) - see `Statifier.Machine.lcca/2` for the body.

  One implementation, two names (plan Decision 2): `Machine.lcca/2` is the
  port under st-wju.1's "name the spec operation it serves" convention;
  this `defdelegate` puts the spec's own name at the interpreter's port
  surface, where `mix adr.check` looks and where ADR-0002 expects to find it.
  """
  defdelegate find_lcca(machine, indexes), to: Statifier.Machine, as: :lcca

  @doc """
  `getEffectiveTargetStates` (Appendix D) - `transition`'s targets, with every
  `:history` target resolved to a concrete set of indexes (plan Decision 5).

  `machine_state` stands in for two pseudocode globals: `historyValue`
  (`machine_state.history_values`) and, indirectly through
  `machine_state.machine`, the topology `Machine.at/2` reads. A non-history
  target passes through unchanged. A `:history` target with a recorded entry
  in `history_values` contributes that entry's members. An unrecorded
  `:history` target recurses through its own `history_default` transition's
  targets - the pseudocode's `getEffectiveTargetStates(s.transition)` - which
  is itself ported as a call back into this function, since a history
  default's targets are ordinary transition targets that may (pathologically,
  but representably) include another history state.
  """
  @spec get_effective_target_states(
          machine_state :: MachineState.t(),
          transition :: Transition.t()
        ) :: [non_neg_integer()]
  def get_effective_target_states(%MachineState{} = machine_state, %Transition{} = transition) do
    Enum.flat_map(transition.targets, &effective_target_states(machine_state, &1))
  end

  @spec effective_target_states(machine_state :: MachineState.t(), target :: non_neg_integer()) ::
          [non_neg_integer()]
  defp effective_target_states(%MachineState{machine: machine} = machine_state, target) do
    if Machine.history?(machine, target) do
      history_effective_target_states(machine_state, machine, target)
    else
      [target]
    end
  end

  @spec history_effective_target_states(
          machine_state :: MachineState.t(),
          machine :: Machine.t(),
          history_index :: non_neg_integer()
        ) :: [non_neg_integer()]
  defp history_effective_target_states(machine_state, machine, history_index) do
    case Map.fetch(machine_state.history_values, history_index) do
      {:ok, recorded} ->
        MapSet.to_list(recorded)

      :error ->
        default_t_index = Machine.at(machine, history_index).history_default
        default_transition = Machine.transition(machine, default_t_index)
        get_effective_target_states(machine_state, default_transition)
    end
  end

  @doc """
  `getTransitionDomain` (Appendix D) - the single state whose descendants (in
  the configuration) `transition` exits, or `nil` for a transition with no
  effective targets.

  `machine_state` stands in for the same globals as
  `get_effective_target_states/2`, which this function calls first. Two
  literal-port details (plan Decision 6):

  - The guard here is on *effective* targets (an empty resolution, e.g. an
    unrecorded history with no default reachable, yields `nil`), distinct
    from `compute_exit_set/2`'s guard on *written* targets - the pseudocode
    keeps the two tests separate and so does this port.
  - `type == :internal` only ever narrows the domain to `source` when
    `source` is compound (`Machine.compound?/2`) and every effective target
    is a **proper** descendant of it (`Machine.descendant?/3`); every other
    case, including every `:external` transition, falls through to
    `find_lcca/2` on `[source | effective_targets]`.
  """
  @spec get_transition_domain(machine_state :: MachineState.t(), transition :: Transition.t()) ::
          non_neg_integer() | nil
  def get_transition_domain(
        %MachineState{machine: machine} = machine_state,
        %Transition{} = transition
      ) do
    case get_effective_target_states(machine_state, transition) do
      [] ->
        nil

      effective_targets ->
        transition_domain(machine, transition, effective_targets)
    end
  end

  @spec transition_domain(
          machine :: Machine.t(),
          transition :: Transition.t(),
          effective_targets :: [non_neg_integer()]
        ) :: non_neg_integer()
  # Not a re-derivation of get_transition_domain/2: this is that function's
  # own non-empty-effective-targets branch, pulled into a private helper so
  # the `[] -> nil` guard above it stays a two-line case.
  # ADR-0002 literal port, decomposed here for readability only.
  defp transition_domain(machine, %Transition{source: source, type: type}, effective_targets) do
    if type == :internal and Machine.compound?(machine, source) and
         Enum.all?(effective_targets, &Machine.descendant?(machine, &1, source)) do
      source
    else
      find_lcca(machine, [source | effective_targets])
    end
  end

  @doc """
  `computeExitSet` (Appendix D) - every index in `machine_state.configuration`
  that a proper descendant of any transition in `transitions`'s domain, unioned
  across `transitions` (plan Decision 6).

  Two literal-port details that must survive review:

  - The guard is `if t.target` - written targets (`transition.targets == []`),
    not the effective ones `get_transition_domain/2` resolves. A transition
    with written targets whose effective targets resolve empty still enters
    the loop; its domain is then `nil` and it is handled explicitly below,
    contributing nothing rather than being filtered out earlier by a merged
    test.
  - `Machine.descendant?/3` is **proper**, so a transition's domain is never a
    member of its own exit set - the whole reason that predicate's strictness
    exists (`Machine.descendant?/3`'s own `@doc`).
  """
  @spec compute_exit_set(machine_state :: MachineState.t(), transitions :: [Transition.t()]) ::
          MapSet.t(non_neg_integer())
  def compute_exit_set(%MachineState{} = machine_state, transitions) do
    transitions
    |> Enum.reject(&(&1.targets == []))
    |> Enum.reduce(MapSet.new(), &union_exit_set(machine_state, &1, &2))
  end

  @spec union_exit_set(
          machine_state :: MachineState.t(),
          transition :: Transition.t(),
          acc :: MapSet.t(non_neg_integer())
        ) :: MapSet.t(non_neg_integer())
  defp union_exit_set(machine_state, transition, acc) do
    case get_transition_domain(machine_state, transition) do
      # A transition with written targets can still resolve to no domain
      # (empty effective targets) - it contributes nothing to the exit set.
      nil ->
        acc

      domain ->
        MapSet.union(acc, descendants_in_configuration(machine_state, domain))
    end
  end

  @spec descendants_in_configuration(
          machine_state :: MachineState.t(),
          domain :: non_neg_integer()
        ) ::
          MapSet.t(non_neg_integer())
  defp descendants_in_configuration(
         %MachineState{machine: machine, configuration: configuration},
         domain
       ) do
    MapSet.filter(configuration, &Machine.descendant?(machine, &1, domain))
  end

  @doc """
  `conditionMatch` (Appendix D) - Decision 7's one `cond` seam. `nil` `cond`
  always passes; a *written* `cond` is currently an error rather than an
  assumed `true`, because treating an unevaluated condition as satisfied
  would be the "rescue-to-default at a leaf" failure `docs/architecture.md`
  names as a v1 defect. st-af3 replaces this function's body with a real
  predicator evaluation and, at the call site below, raises `error.execution`
  on the error case (an inline comment there cites st-af3 too); neither this
  function's signature nor the selection logic that calls it changes when
  that lands - only the body does.

  Unreachable from the corpus today: `FeatureDetector` marks
  `conditional_transitions` `:unsupported`, so no compiled document can carry
  a `cond`-bearing transition through selection yet. Reachable, and tested,
  from a machine_state and transition built by hand.
  """
  @spec condition_match(machine_state :: MachineState.t(), transition :: Transition.t()) ::
          {:ok, boolean()} | {:error, term()}
  def condition_match(%MachineState{}, %Transition{cond: nil}), do: {:ok, true}
  def condition_match(%MachineState{}, %Transition{}), do: {:error, {:unsupported, :cond}}

  @doc """
  `selectTransitions` (Appendix D) - the transitions `event` enables, one per
  atomic state in `machine_state.configuration` at most (child preempts
  ancestor), deduplicated by `t_index` (Decision 10), and filtered through
  `remove_conflicting_transitions/2` per the pseudocode's own last line.

  `event.name` is tokenized once via `NameMatch.tokenize/1` before the walk
  and threaded down to every atomic state's search (Decision 4's hoist out of
  the per-transition matcher) rather than re-split per transition.

  Returns `{machine_state, transitions}`: the machine_state comes back
  unchanged in this phase (plan Decision 8) - see the moduledoc.
  """
  @spec select_transitions(machine_state :: MachineState.t(), event :: Event.t()) ::
          {MachineState.t(), [Transition.t()]}
  def select_transitions(%MachineState{} = machine_state, %Event{name: name}) do
    event_tokens = NameMatch.tokenize(name)

    enabled =
      machine_state
      |> atomic_states_in_document_order()
      |> Enum.flat_map(&selected_for_atomic_state(machine_state, &1, event_tokens))
      |> Enum.uniq_by(& &1.t_index)

    {machine_state, remove_conflicting_transitions(machine_state, enabled)}
  end

  @doc """
  `selectEventlessTransitions` (Appendix D) - `select_transitions/2`'s
  sibling for transitions with no `event` attribute (`events == []`). Same
  walk, same dedupe, same trailing `remove_conflicting_transitions/2` call;
  the pseudocode writes these as two functions rather than one parameterized
  by "is there an event" and this port keeps them that way
  (`Credo.Check.Design.DuplicatedCode` is disabled in `.credo.exs` for
  exactly this reason).

  Returns `{machine_state, transitions}`, unchanged machine_state in this
  phase, matching `select_transitions/2` (plan Decision 8).
  """
  @spec select_eventless_transitions(machine_state :: MachineState.t()) ::
          {MachineState.t(), [Transition.t()]}
  def select_eventless_transitions(%MachineState{} = machine_state) do
    enabled =
      machine_state
      |> atomic_states_in_document_order()
      |> Enum.flat_map(&selected_for_atomic_state(machine_state, &1, nil))
      |> Enum.uniq_by(& &1.t_index)

    {machine_state, remove_conflicting_transitions(machine_state, enabled)}
  end

  # The atomic-state outer loop of both `selectTransitions` and
  # `selectEventlessTransitions`: every active leaf, in document order
  # (Decision 9).
  @spec atomic_states_in_document_order(machine_state :: MachineState.t()) :: [
          non_neg_integer()
        ]
  defp atomic_states_in_document_order(%MachineState{machine: machine} = machine_state) do
    machine_state
    |> MachineState.active_leaf_states()
    |> then(&Machine.document_order(machine, &1))
  end

  # The labelled `break loop` in each atomic state's walk: self, then each
  # proper ancestor outward, stopping at the first state that has an enabled
  # transition (Decision 9). `event_tokens` is `nil` for the eventless walk
  # and a token list for the event-matched walk; `first_matching_transition/4`
  # reads that to pick the right per-transition predicate. `List.wrap/1`
  # turns `find_value`'s `Transition.t() | nil` into the `[]` or `[transition]`
  # `flat_map` needs.
  @spec selected_for_atomic_state(
          machine_state :: MachineState.t(),
          state_index :: non_neg_integer(),
          event_tokens :: [String.t()] | nil
        ) :: [Transition.t()]
  defp selected_for_atomic_state(
         %MachineState{machine: machine} = machine_state,
         state_index,
         event_tokens
       ) do
    [state_index | Machine.proper_ancestors(machine, state_index)]
    |> Enum.find_value(&first_matching_transition(machine_state, machine, &1, event_tokens))
    |> List.wrap()
  end

  # The per-state inner loop: the state's own `transitions`, in the document
  # order they are stored, through `Machine.transition/2`, stopping at the
  # first one whose predicate holds (Decision 9).
  @spec first_matching_transition(
          machine_state :: MachineState.t(),
          machine :: Machine.t(),
          state_index :: non_neg_integer(),
          event_tokens :: [String.t()] | nil
        ) :: Transition.t() | nil
  defp first_matching_transition(machine_state, machine, state_index, event_tokens) do
    machine
    |> Machine.at(state_index)
    |> Map.fetch!(:transitions)
    |> Enum.map(&Machine.transition(machine, &1))
    |> Enum.find(&transition_enabled?(machine_state, &1, event_tokens))
  end

  # `event_tokens == nil` is the eventless predicate (`!t.event` in the
  # pseudocode); a token list is the event-matched predicate
  # (`t.event` and `nameMatch`). Both branches end in `condition_match/2`,
  # which the pseudocode calls unconditionally on the last candidate
  # transition it is about to accept.
  @spec transition_enabled?(
          machine_state :: MachineState.t(),
          transition :: Transition.t(),
          event_tokens :: [String.t()] | nil
        ) :: boolean()
  defp transition_enabled?(machine_state, %Transition{events: []} = transition, nil) do
    condition_match(machine_state, transition) == {:ok, true}
  end

  defp transition_enabled?(_machine_state, %Transition{events: []}, _event_tokens), do: false

  defp transition_enabled?(_machine_state, %Transition{}, nil), do: false

  defp transition_enabled?(machine_state, %Transition{} = transition, event_tokens) do
    NameMatch.name_match?(transition.events, event_tokens) and
      condition_match(machine_state, transition) == {:ok, true}
  end

  @doc """
  `removeConflictingTransitions` (Appendix D) - `enabled_transitions`,
  filtered down to a conflict-free set, ported exactly for its filter order
  (plan Decision 9): two transitions conflict iff their exit sets intersect;
  on conflict, a `t1` sourced in a descendant of `t2`'s source preempts
  `t2` (`t2` is marked for removal, `t1` keeps checking the rest of the
  filtered set); otherwise `t1` itself is preempted and its inner loop stops
  immediately - this is *not* "the earlier transition always wins", it is
  "the earlier transition wins unless the later one is the more specific
  (descendant) source". A surviving `t1` has every transition it marked for
  removal dropped from the filtered set and is appended to it.

  This is the function ADR-0002 was partly adopted to fix (plan "What v1 got
  wrong here"): v1's conflict resolution reduced every transition's exit set
  to a boolean "does it leave the nearest parallel ancestor" and collapsed an
  entire microstep to one transition whenever both a leaving and a
  non-leaving transition were enabled, discarding unrelated, genuinely
  non-conflicting transitions from other parallel regions. This port computes
  a real exit set per transition (`compute_exit_set/2`) and only ever removes
  a transition that actually intersects another's exit set.

  The insertion order `enabled_transitions` arrives in is
  `select_transitions/2`/`select_eventless_transitions/1`'s document-order,
  dedup-by-`t_index` walk (Decision 10) - the pseudocode's own comment about
  `toList`'s ordering "the order of the states that selected them" is exactly
  that walk, not anything this function itself orders.
  """
  @spec remove_conflicting_transitions(
          machine_state :: MachineState.t(),
          enabled_transitions :: [Transition.t()]
        ) :: [Transition.t()]
  def remove_conflicting_transitions(%MachineState{} = machine_state, enabled_transitions) do
    Enum.reduce(enabled_transitions, [], fn t1, filtered ->
      case resolve_against_filtered(machine_state, t1, filtered) do
        {:preempted, filtered} -> filtered
        {:keep, filtered} -> filtered ++ [t1]
      end
    end)
  end

  # The inner loop plus `t1Preempted`/`transitionsToRemove`: walks the
  # already-filtered set breaking on the first ancestor-sourced conflict
  # (`Enum.reduce_while/3` for the pseudocode's `break`), collecting
  # descendant-sourced conflicts to remove instead. Returns `{:preempted,
  # filtered}` (t1 does not survive, filtered is returned as-is) or `{:keep,
  # filtered_without_removed}` (t1 survives, its marked conflicts are gone)
  # (Decision 9).
  @spec resolve_against_filtered(
          machine_state :: MachineState.t(),
          t1 :: Transition.t(),
          filtered :: [Transition.t()]
        ) :: {:preempted, [Transition.t()]} | {:keep, [Transition.t()]}
  defp resolve_against_filtered(machine_state, t1, filtered) do
    filtered
    |> Enum.reduce_while({:keep, []}, &conflict_step(machine_state, t1, filtered, &1, &2))
    |> case do
      {:preempted, removed_filtered} -> {:preempted, removed_filtered}
      {:keep, to_remove} -> {:keep, filtered -- to_remove}
    end
  end

  # One step of the inner loop against a single already-filtered `t2`:
  # no conflict continues unchanged; a descendant-sourced conflict marks `t2`
  # for removal and continues; an ancestor-sourced conflict halts with `t1`
  # preempted.
  @spec conflict_step(
          machine_state :: MachineState.t(),
          t1 :: Transition.t(),
          filtered :: [Transition.t()],
          t2 :: Transition.t(),
          acc :: {:keep, [Transition.t()]}
        ) :: {:cont, {:keep, [Transition.t()]}} | {:halt, {:preempted, [Transition.t()]}}
  defp conflict_step(machine_state, t1, filtered, t2, {:keep, to_remove}) do
    cond do
      not conflicts?(machine_state, t1, t2) ->
        {:cont, {:keep, to_remove}}

      Machine.descendant?(machine_state.machine, t1.source, t2.source) ->
        {:cont, {:keep, [t2 | to_remove]}}

      true ->
        {:halt, {:preempted, filtered}}
    end
  end

  # Two transitions conflict iff their computed exit sets intersect.
  @spec conflicts?(machine_state :: MachineState.t(), t1 :: Transition.t(), t2 :: Transition.t()) ::
          boolean()
  defp conflicts?(machine_state, t1, t2) do
    not MapSet.disjoint?(
      compute_exit_set(machine_state, [t1]),
      compute_exit_set(machine_state, [t2])
    )
  end
end
