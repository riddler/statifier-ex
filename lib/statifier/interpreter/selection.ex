defmodule Statifier.Interpreter.Selection do
  @moduledoc """
  Appendix D transition selection, ported function for function (ADR-0002).

  Every function here that reads a global takes `machine_state` (or, when it
  needs only topology, `machine`) as its first argument - the mechanical
  deviation `docs/observability.md` constraint 1 sanctions for reifying the
  pseudocode's `configuration` and `historyValue` globals onto
  `%Statifier.MachineState{}`. Each function's own `@doc`
  says which global its first argument stands in for; this paragraph states
  the rule once so they do not each re-argue it.

  `compute_exit_set/2` returns a `MapSet` of indexes, not an `OrderedSet`:
  `remove_conflicting_transitions` wants set intersection and gets it directly,
  and a caller that wants exit *order*
  pipes the result through `Statifier.Machine.exit_order/2`, which already
  exists for exactly that. No function in this module orders an exit set
  itself.

  Every function is a pure query - plain values in, plain values out, no
  hidden context, callable standalone in `iex` (`docs/observability.md`
  constraint 5). The block divides in two. The domain half - `find_lcca/2`
  (delegated), `get_effective_target_states/2`, `get_transition_domain/2`,
  and `compute_exit_set/2` - answers "which states does this transition
  leave". The selection half - `condition_match/2`, `select_transitions/2`,
  `select_eventless_transitions/1`, and `remove_conflicting_transitions/2` -
  answers "which transitions fire", and calls into the domain half to do it.

  `select_transitions/2` and `select_eventless_transitions/1` are the two
  functions in this module that thread `machine_state` through their
  *return* value as well as their first argument: both return
  `{MachineState.t(), [Transition.t()], [Effect.t()]}` rather than a bare
  list, so that a failed `cond` discovered mid-walk has a machine_state to
  enqueue `error.execution` onto. The machine_state comes back **unchanged**
  when no `cond` fails during that round, and carries one `error.execution`
  event per failed `cond` - in walk order - when one or more do. Every other
  query in this module, including `remove_conflicting_transitions/2` itself,
  still returns a plain value with no machine_state, because none of them can
  raise.

  The third element is the round's guard trace: a one-element list
  holding `{:trace, %Effect.Trace.CondsEvaluated{}}` when the round evaluated
  at least one *written* `cond` under `trace: true`, and `[]` otherwise -
  including under `trace: false`, where the guard outcomes are never
  accumulated in the first place (`docs/observability.md` constraint 2's
  "the untraced hot path allocates nothing for trace"). This module still
  emits nothing and performs nothing: the effect rides out on the caller's
  effect list exactly like every other trace effect, and
  `Statifier.Interpreter` prepends it ahead of that round's
  `Trace.TransitionsSelected`. Predicator is telemetry-silent by its own
  ADR-0016, so this is the family's only view of a guard evaluation - see
  `Statifier.Effect.Trace.CondsEvaluated` and ADR-0040.

  The two walks and the conflict filter are Appendix D's two nested loops
  with labelled breaks, decomposed into named private helpers to stay under
  Credo's cyclomatic-complexity and nesting limits - each
  helper's doc names the pseudocode lines it stands in for, so "diff against
  the pseudocode" still works one level down. The enabled set is deduplicated
  by `t_index`, keeping the first occurrence, in place of the pseudocode's
  `OrderedSet`.
  """

  alias Statifier.{Evaluator, Event, Machine, MachineState}
  alias Statifier.Interpreter.NameMatch
  alias Statifier.Machine.Transition

  require Statifier.Effect, as: Effect

  # One evaluated `cond`, paired with the transition it belongs to - the
  # accumulator D2 threads through the private walk instead of writing
  # machine_state mid-walk. Strictly smaller than a machine_state, and every
  # helper below stays standalone-callable per docs/observability.md
  # constraint 5.
  #
  # This widened the element from D2's `{transition, reason}` failure pair
  # to carry the outcome too, rather than threading a second accumulator
  # beside it: `raise_cond_errors/2` filters this list down to the `:error`
  # entries it always had, and the guard trace maps the whole of it. Under
  # `trace: false` only `:error` entries are ever prepended (`cond_enabled/4`),
  # so the untraced hot path allocates exactly what D2 allocated.
  @typep cond_outcome ::
           {Transition.t(), :enabled | :disabled | {:error, term()}}

  @doc """
  `findLCCA` (Appendix D) - see `Statifier.Machine.lcca/2` for the body.

  One implementation, two names: `Machine.lcca/2` is the
  port under `Statifier.Machine`'s own convention of naming its query
  helpers after the spec operation they serve rather than after the spec
  function itself; this `defdelegate` puts the spec's own name at the
  interpreter's port surface, where `mix adr.check` looks and where
  ADR-0002 expects to find it.
  """
  defdelegate find_lcca(machine, indexes), to: Statifier.Machine, as: :lcca

  @doc """
  `getEffectiveTargetStates` (Appendix D) - `transition`'s targets, with every
  `:history` target resolved to a concrete set of indexes.

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

  Returns a plain list where the pseudocode accumulates into an
  `OrderedSet`, so the result is **not** deduplicated: `target="hs b1a"`,
  where `hs` resolves to `b1a`, yields that index twice. Every consumer is
  insensitive to it - `get_transition_domain/2` feeds the list to
  `Enum.all?/2` and to `find_lcca/2`, neither of which changes answer on a
  repeat, and `Statifier.Interpreter.ExitEntry`'s entry-set construction
  absorbs repeats into the set it is building - so the dedupe would be dead
  work at every call site that exists. Deduplicate at the consumer that
  needs it, if one ever does, rather than here.
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
  literal-port details:

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
  across `transitions`.

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
  `conditionMatch` (Appendix D) - the one `cond` seam. `nil` `cond` always
  passes; a *written* `cond` is evaluated through `Statifier.Evaluator`
  against a `Predicator.Context.t()` built from `machine_state` - once per
  call here, and once per selection round in the private walk below (the
  "once per evaluation site" contract `Statifier.Evaluator`'s own moduledoc
  states). `{:ok, true}` enables the transition; `{:ok, false}` and
  `{:error, _}` both do not.

  A non-boolean `{:ok, value}` - anything other than `true` or `false` - is
  treated as an `{:error, {:non_boolean_cond, value}}` rather than as a falsy
  value, because **spec 5.9.1 makes it the same case as an evaluation
  error**: "If a conditional expression cannot be evaluated as a boolean
  value ('true' or 'false') or if its evaluation causes an error, the SCXML
  Processor MUST treat the expression as if it evaluated to 'false' and MUST
  place the error 'error.execution' in the internal event queue." The spec
  joins the two with one `or` and gives them one consequence, so collapsing a
  non-boolean quietly to `false` would satisfy half of that MUST and drop the
  other half. This is not a deviation from Appendix D's `conditionMatch`; it
  is the normative clause `conditionMatch` evaluates under.

  The `{:error, _}` spelling is how a *pure query* carries both halves at
  once: `docs/architecture.md` principle 3 forbids this leaf from raising or
  rescuing, so it reports the failure and the two entry points below turn it
  into "not enabled" plus the enqueue. ADR-0004 is why there is no third
  option - predicator is the datamodel and has no ECMAScript truthiness to
  borrow, so "cannot be evaluated as a boolean" is decidable here rather
  than being a matter of taste.

  This function never enqueues anything itself - it is a pure query, plain
  values in and out, per this module's own moduledoc. The `{:error, _}`
  path's `error.execution` enqueue lives in the two entry points below, not
  here.

  Reached from compiled documents: `FeatureDetector`'s registry marks
  `conditional_transitions` `:supported`, and a compiled `cond`-bearing
  transition driven through a live `Statifier.Session` lands here. Also
  reachable, and tested, from a machine_state and transition built by hand.
  """
  @spec condition_match(machine_state :: MachineState.t(), transition :: Transition.t()) ::
          {:ok, boolean()} | {:error, term()}
  def condition_match(%MachineState{} = machine_state, %Transition{} = transition) do
    evaluate_cond(Evaluator.context(machine_state), transition)
  end

  # `conditionMatch`'s body over a context the caller already built - the
  # selection walk builds one per round (`Statifier.Evaluator`'s "once per
  # evaluation site" contract), while `condition_match/2` above builds one per
  # call so the spec-named port stays callable from a machine_state alone
  # (docs/observability.md constraint 5). ADR-0002 mechanical decomposition of
  # one pseudocode function, not a second one.
  @spec evaluate_cond(context :: Predicator.Context.t(), transition :: Transition.t()) ::
          {:ok, boolean()} | {:error, term()}
  defp evaluate_cond(_context, %Transition{cond: nil}), do: {:ok, true}

  defp evaluate_cond(context, %Transition{cond: cond}) do
    case Evaluator.evaluate(context, cond) do
      {:ok, true} -> {:ok, true}
      {:ok, false} -> {:ok, false}
      # D1: spec 5.9.1 joins "cannot be evaluated as a boolean value" and
      # "its evaluation causes an error" into one case with one consequence -
      # treat as false AND place error.execution. So this arm is the spec's
      # own requirement, not an addition to Appendix D's conditionMatch;
      # collapsing it to {:ok, false} would honor half the MUST and drop the
      # enqueue. See this function's caller's @doc for the full clause.
      {:ok, other} -> {:error, {:non_boolean_cond, other}}
      {:error, %Evaluator.Error{} = error} -> {:error, error}
    end
  end

  @doc """
  `selectTransitions` (Appendix D) - the transitions `event` enables, one per
  atomic state in `machine_state.configuration` at most (child preempts
  ancestor), deduplicated by `t_index`, and filtered through
  `remove_conflicting_transitions/2` per the pseudocode's own last line.

  `event.name` is tokenized once via `NameMatch.tokenize/1` before the walk
  and threaded down to every atomic state's search - a hoist out of the
  per-transition matcher - rather than re-split per transition.

  Returns `{machine_state, transitions, effects}`: the machine_state comes
  back unchanged when no `cond` fails during this round, and carries one
  `error.execution` per failed `cond` (in walk order) when one does;
  `effects` is the round's guard trace, `[]` unless a written `cond` was
  evaluated under `trace: true` - see the moduledoc.
  """
  @spec select_transitions(machine_state :: MachineState.t(), event :: Event.t()) ::
          {MachineState.t(), [Transition.t()], [Effect.t()]}
  def select_transitions(%MachineState{} = machine_state, %Event{name: name}) do
    event_tokens = NameMatch.tokenize(name)
    context = Evaluator.context(machine_state)

    {enabled, cond_outcomes} =
      machine_state
      |> atomic_states_in_document_order()
      |> Enum.flat_map_reduce(
        [],
        &selected_for_atomic_state(machine_state, context, &1, event_tokens, &2)
      )

    finish_round(machine_state, enabled, cond_outcomes)
  end

  @doc """
  `selectEventlessTransitions` (Appendix D) - `select_transitions/2`'s
  sibling for transitions with no `event` attribute (`events == []`). Same
  walk, same dedupe, same trailing `remove_conflicting_transitions/2` call;
  the pseudocode writes these as two functions rather than one parameterized
  by "is there an event" and this port keeps them that way
  (`Credo.Check.Design.DuplicatedCode` is disabled in `.credo.exs` for
  exactly this reason).

  Returns `{machine_state, transitions, effects}`, matching
  `select_transitions/2`: unchanged when no `cond` fails, carrying one
  `error.execution` per failed `cond` (in walk order) when one does, and the
  same round guard trace in the third element.
  """
  @spec select_eventless_transitions(machine_state :: MachineState.t()) ::
          {MachineState.t(), [Transition.t()], [Effect.t()]}
  def select_eventless_transitions(%MachineState{} = machine_state) do
    context = Evaluator.context(machine_state)

    {enabled, cond_outcomes} =
      machine_state
      |> atomic_states_in_document_order()
      |> Enum.flat_map_reduce(
        [],
        &selected_for_atomic_state(machine_state, context, &1, nil, &2)
      )

    finish_round(machine_state, enabled, cond_outcomes)
  end

  # The tail both selection functions share: restore walk order, raise the
  # failed `cond`s as `error.execution`, dedupe by `t_index`, filter
  # conflicts, and stamp the round's guard trace. Factored so the two ports
  # above stay a walk and a call to this, per ADR-0002's rule that a shared
  # tail is decomposition and not a third pseudocode function.
  @spec finish_round(
          machine_state :: MachineState.t(),
          enabled :: [Transition.t()],
          cond_outcomes :: [cond_outcome()]
        ) :: {MachineState.t(), [Transition.t()], [Effect.t()]}
  defp finish_round(machine_state, enabled, cond_outcomes) do
    # `cond_outcomes` accumulated prepended through `cond_enabled/4` below;
    # reverse once here to restore walk order before raising and before
    # stamping the trace (see that function's comment).
    cond_outcomes = Enum.reverse(cond_outcomes)
    machine_state = raise_cond_errors(machine_state, cond_outcomes)
    enabled = Enum.uniq_by(enabled, & &1.t_index)

    {machine_state, remove_conflicting_transitions(machine_state, enabled),
     conds_evaluated_trace(machine_state, cond_outcomes)}
  end

  # The guard seam's emission point. `[]` for a round that
  # evaluated no written `cond` at all - the effect reports evaluations, and
  # a round that performed none has nothing to report, unlike
  # `Trace.TransitionsSelected`, whose empty set is itself a result. Under
  # `trace: false` this is reached with at most the round's `:error` entries
  # and `Effect.trace/3` discards them without building anything.
  @spec conds_evaluated_trace(
          machine_state :: MachineState.t(),
          cond_outcomes :: [cond_outcome()]
        ) :: [Effect.t()]
  defp conds_evaluated_trace(_machine_state, []), do: []

  defp conds_evaluated_trace(machine_state, cond_outcomes) do
    Effect.trace(machine_state, Effect.Trace.CondsEvaluated,
      evaluations: Enum.map(cond_outcomes, &evaluation/1)
    )
  end

  @spec evaluation(outcome :: cond_outcome()) ::
          Effect.Trace.CondsEvaluated.evaluation()
  defp evaluation({%Transition{t_index: t_index}, {:error, reason}}),
    do: %{t_index: t_index, outcome: :error, reason: reason}

  defp evaluation({%Transition{t_index: t_index}, outcome}),
    do: %{t_index: t_index, outcome: outcome, reason: nil}

  # The atomic-state outer loop of both `selectTransitions` and
  # `selectEventlessTransitions`: every active leaf, in document order.
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
  # transition. `event_tokens` is `nil` for the eventless walk
  # and a token list for the event-matched walk; `first_matching_transition/5`
  # reads that to pick the right per-transition predicate.
  #
  # `Enum.reduce_while/3` for the same labelled `break loop` `Enum.find_value/2`
  # used to implement, now threading the cond-error accumulator out alongside
  # the result (D2). Structure is unchanged; only the accumulator is new.
  # ADR-0002.
  @spec selected_for_atomic_state(
          machine_state :: MachineState.t(),
          context :: Predicator.Context.t(),
          state_index :: non_neg_integer(),
          event_tokens :: [String.t()] | nil,
          cond_outcomes :: [cond_outcome()]
        ) :: {[Transition.t()], [cond_outcome()]}
  defp selected_for_atomic_state(
         %MachineState{machine: machine, trace: trace},
         context,
         state_index,
         event_tokens,
         cond_outcomes
       ) do
    [state_index | Machine.proper_ancestors(machine, state_index)]
    |> Enum.reduce_while({[], cond_outcomes}, fn s, {[], outcomes} ->
      case first_matching_transition(context, machine, s, event_tokens, trace, outcomes) do
        {nil, outcomes} -> {:cont, {[], outcomes}}
        {transition, outcomes} -> {:halt, {[transition], outcomes}}
      end
    end)
  end

  # The per-state inner loop: the state's own `transitions`, in the document
  # order they are stored, through `Machine.transition/2`, stopping at the
  # first one whose predicate holds. `Enum.reduce_while/3` in place of
  # `Enum.find/2`, threading the same accumulator (D2).
  @spec first_matching_transition(
          context :: Predicator.Context.t(),
          machine :: Machine.t(),
          state_index :: non_neg_integer(),
          event_tokens :: [String.t()] | nil,
          trace :: boolean(),
          cond_outcomes :: [cond_outcome()]
        ) :: {Transition.t() | nil, [cond_outcome()]}
  defp first_matching_transition(
         context,
         machine,
         state_index,
         event_tokens,
         trace,
         cond_outcomes
       ) do
    machine
    |> Machine.at(state_index)
    |> Map.fetch!(:transitions)
    |> Enum.map(&Machine.transition(machine, &1))
    |> Enum.reduce_while({nil, cond_outcomes}, fn transition, {nil, outcomes} ->
      case transition_enabled(context, transition, event_tokens, trace, outcomes) do
        {true, outcomes} -> {:halt, {transition, outcomes}}
        {false, outcomes} -> {:cont, {nil, outcomes}}
      end
    end)
  end

  # `event_tokens == nil` is the eventless predicate (`!t.event` in the
  # pseudocode); a token list is the event-matched predicate
  # (`t.event` and `nameMatch`). Both branches end in `condition_match/2`
  # (here, `cond_enabled/3` over a prebuilt context), which the pseudocode
  # calls unconditionally on the last candidate transition it is about to
  # accept.
  @spec transition_enabled(
          context :: Predicator.Context.t(),
          transition :: Transition.t(),
          event_tokens :: [String.t()] | nil,
          trace :: boolean(),
          cond_outcomes :: [cond_outcome()]
        ) :: {boolean(), [cond_outcome()]}
  defp transition_enabled(
         context,
         %Transition{events: []} = transition,
         nil,
         trace,
         cond_outcomes
       ) do
    cond_enabled(context, transition, trace, cond_outcomes)
  end

  defp transition_enabled(
         _context,
         %Transition{events: []},
         _event_tokens,
         _trace,
         cond_outcomes
       ) do
    {false, cond_outcomes}
  end

  defp transition_enabled(_context, %Transition{}, nil, _trace, cond_outcomes) do
    {false, cond_outcomes}
  end

  defp transition_enabled(
         context,
         %Transition{} = transition,
         event_tokens,
         trace,
         cond_outcomes
       ) do
    if NameMatch.name_match?(transition.events, event_tokens) do
      cond_enabled(context, transition, trace, cond_outcomes)
    else
      {false, cond_outcomes}
    end
  end

  # `condition_match/2`'s body over a prebuilt context, folding a failed
  # `cond` into the accumulator instead of dropping it. Not enabling *and*
  # recording: docs/architecture.md principle 3 - the error becomes an
  # event, it is never swallowed into a bare `false`.
  #
  # Prepends (`[{transition, outcome} | cond_outcomes]`) instead of appending
  # (`cond_outcomes ++ [...]`). `cond_outcomes` is threaded, unreordered,
  # through every fold between here and `select_transitions/2` /
  # `select_eventless_transitions/1` (`selected_for_atomic_state/5`'s and
  # `first_matching_transition/6`'s own `Enum.reduce_while/3` calls above),
  # so this is the one accumulation site for the whole configuration scan;
  # appending here was O(n) per recorded outcome. Appendix D's List datatype
  # names only `append(l)` (`spec-cache/appendix-d.txt:21`) with no
  # complexity contract - `finish_round/3` reverses once, before
  # `raise_cond_errors/2` and before stamping the guard trace, to restore the
  # "in walk order" both callers' `@doc`s promise.
  #
  # an `:error` is recorded unconditionally, because
  # `raise_cond_errors/2` needs it whatever `trace` says. `:enabled` and
  # `:disabled` are recorded only under `trace: true`, and only for a
  # *written* `cond` - a `nil` `cond` short-circuits inside
  # `evaluate_cond/2` without reaching `Statifier.Evaluator` at all, so it is
  # not an evaluation and gets no entry. That keeps `docs/observability.md`
  # constraint 2's "the untraced hot path allocates nothing for trace"
  # literally true: under `trace: false` this function allocates exactly what
  # D2's failure-only accumulator allocated.
  @spec cond_enabled(
          context :: Predicator.Context.t(),
          transition :: Transition.t(),
          trace :: boolean(),
          cond_outcomes :: [cond_outcome()]
        ) :: {boolean(), [cond_outcome()]}
  defp cond_enabled(context, transition, trace, cond_outcomes) do
    case evaluate_cond(context, transition) do
      {:ok, true} -> {true, record_outcome(transition, :enabled, trace, cond_outcomes)}
      {:ok, false} -> {false, record_outcome(transition, :disabled, trace, cond_outcomes)}
      {:error, reason} -> {false, [{transition, {:error, reason}} | cond_outcomes]}
    end
  end

  @spec record_outcome(
          transition :: Transition.t(),
          outcome :: :enabled | :disabled,
          trace :: boolean(),
          cond_outcomes :: [cond_outcome()]
        ) :: [cond_outcome()]
  defp record_outcome(%Transition{cond: nil}, _outcome, _trace, cond_outcomes),
    do: cond_outcomes

  defp record_outcome(_transition, _outcome, false, cond_outcomes), do: cond_outcomes

  defp record_outcome(transition, outcome, true, cond_outcomes),
    do: [{transition, outcome} | cond_outcomes]

  # The errors-are-events conversion for a failed `cond`, in document order -
  # `raise_platform/4` not `raise_internal/4` because spec 5.10.1 classifies
  # `error.*` as a platform event, exactly as
  # `Statifier.Interpreter.Content.raise_execution_error` does for a failed
  # content node; spec 3.12.2 is what puts it on the internal queue at all.
  # The origin names the transition, whose `cond_location` an ADR-0014 item 4
  # diagnostic resolves through `Machine.transition/2`.
  #
  # the accumulator now carries every recorded outcome, not only the
  # failures, so this filters to the `{:error, reason}` entries. Walk order
  # is preserved by the filter, which is what keeps "in walk order" true of
  # the raised events and of the guard trace alike.
  @spec raise_cond_errors(machine_state :: MachineState.t(), cond_outcomes :: [cond_outcome()]) ::
          MachineState.t()
  defp raise_cond_errors(machine_state, cond_outcomes) do
    Enum.reduce(cond_outcomes, machine_state, fn
      {transition, {:error, reason}}, ms ->
        MachineState.raise_platform(ms, "error.execution", {:transition, transition.t_index},
          data: reason
        )

      {_transition, _outcome}, ms ->
        ms
    end)
  end

  @doc """
  `removeConflictingTransitions` (Appendix D) - `enabled_transitions`,
  filtered down to a conflict-free set, ported exactly for its filter order:
  two transitions conflict iff their exit sets intersect;
  on conflict, a `t1` sourced in a descendant of `t2`'s source preempts
  `t2` (`t2` is marked for removal, `t1` keeps checking the rest of the
  filtered set); otherwise `t1` itself is preempted and its inner loop stops
  immediately - this is *not* "the earlier transition always wins", it is
  "the earlier transition wins unless the later one is the more specific
  (descendant) source". A surviving `t1` has every transition it marked for
  removal dropped from the filtered set and is appended to it.

  This is the function ADR-0002 was partly adopted to fix: v1's conflict
  resolution reduced every transition's exit set to a boolean "does it leave
  the nearest parallel ancestor" and collapsed an entire microstep to one
  transition whenever both a leaving and a non-leaving transition were
  enabled, discarding unrelated, genuinely non-conflicting transitions from
  other parallel regions. This port computes a real exit set per transition
  (`compute_exit_set/2`) and only ever removes a transition that actually
  intersects another's exit set.

  The insertion order `enabled_transitions` arrives in is
  `select_transitions/2`/`select_eventless_transitions/1`'s document-order,
  dedup-by-`t_index` walk - the pseudocode's own comment about
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
  # filtered_without_removed}` (t1 survives, its marked conflicts are gone).
  @spec resolve_against_filtered(
          machine_state :: MachineState.t(),
          t1 :: Transition.t(),
          filtered :: [Transition.t()]
        ) :: {:preempted, [Transition.t()]} | {:keep, [Transition.t()]}
  defp resolve_against_filtered(machine_state, t1, filtered) do
    result =
      Enum.reduce_while(
        filtered,
        {:keep, []},
        &conflict_step(machine_state, t1, filtered, &1, &2)
      )

    case result do
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
