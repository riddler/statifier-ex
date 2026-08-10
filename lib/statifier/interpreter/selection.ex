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
  constraint 5). This phase lands the domain half of the block: `find_lcca/2`
  (delegated), `get_effective_target_states/2`, `get_transition_domain/2`,
  and `compute_exit_set/2` - "which states does this transition leave".
  Phase 3 adds `condition_match/2`, the two `select_*` walks, and
  `remove_conflicting_transitions/2` - "which transitions fire" - to this
  same module and extends this moduledoc with their decisions (7 through 11)
  when it lands.
  """

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
end
