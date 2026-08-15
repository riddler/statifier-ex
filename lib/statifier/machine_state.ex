defmodule Statifier.MachineState do
  @moduledoc """
  The reified interpreter position - every Appendix D global and loop
  variable this core keeps, per `docs/observability.md` constraint 1
  (ADR-0012): any `%MachineState{}` value is a complete, inspectable,
  resumable position. `Statifier.Machine` is the compiled document this
  struct walks; interpreter modules alias `Statifier.MachineState` as
  `MachineState` and `Statifier.Machine.State` as `State`, never
  abbreviating either further, because the two names are one character
  apart and mean very different things - a compiled state versus a runtime
  position.

  ## The configuration is full, not leaf-only (ADR-0005)

  `configuration` holds every active state's index, ancestors included -
  the same "full configuration" ADR-0005 commits to everywhere else in this
  codebase. Leaf states (the ones a consumer usually wants: "what is the
  machine actually doing") are `active_leaf_states/1`, a derived view over
  `configuration`, never a second field to keep in sync.

  ## The external queue is deliberately absent

  Appendix D's `main_event_loop` owns both the internal and the external
  event queue. This struct only owns the internal one. The pure core takes
  one external event per call (ADR-0003); the session that drives it owns
  queueing the waiting external events. This is a mechanical deviation in
  ADR-0002's sense - the semantics of processing one external event are
  unchanged, only the storage of the *waiting* ones moves outward - so it
  is legal, but the divergence must carry its reason at the port site: the
  `main_event_loop` port (`Statifier.Interpreter.main_event_loop/1`)
  repeats this comment at its own site, where it matters.

  ## `states_to_invoke` is deliberately absent

  Appendix D carries `statesToInvoke` as a global, but every read and write
  of it belongs to the invoke passes of `main_event_loop`, not yet
  implemented. Adding an unused field now would be exactly the "dead field
  nobody can test" mistake avoided for `origin`/`sendid` on
  `Statifier.Event`: the field is added deliberately, with a caller, once
  the invoke passes exist, rather than added now as a placeholder ahead of
  any caller.

  ## `entered_states` is `s.isFirstEntry` moved off the state

  Appendix D tracks first entry as a mutable flag on the state itself,
  `s.isFirstEntry`, set `false` the moment late binding consumes it
  (`enterStates`, `appendix-d.txt:307-315`). A compiled `%Machine.State{}`
  is immutable compile-time data in this port (`docs/architecture.md`
  principle 4), so there is nowhere on the state to flip that flag - the set
  moves to the runtime struct instead, keyed by `state_index`. This is an
  ADR-0002 mechanical deviation: the semantics are unchanged (a state's
  first entry is still detected exactly once, before any second entry could
  read it), only the storage moves from the immutable compiled document to
  the position that changes every microstep.

  `entered_states` is populated unconditionally - every entered state's
  index is added here, not only under `binding == :late` - even though only
  late binding ever reads it (`Statifier.Interpreter.Datamodel.enter_state/2`
  is a no-op under `:early`). Considered and rejected: gating the `MapSet.put`
  on `machine.binding == :late`, which would save one put per state entry
  under early binding at the cost of making the field's meaning conditional
  on the document being interpreted - exactly the "not a complete,
  inspectable position" failure ADR-0012 constraint 1 exists to prevent. A
  `%MachineState{}` value must be a complete, inspectable, resumable
  position regardless of which document produced it; `entered_states` is
  that same field on every document, not only late-binding ones.

  Not a substitute for `states_for_default_entry`
  (`Statifier.Interpreter.ExitEntry.entry_set()`): that set is recomputed
  fresh per `enter_states/2` call and answers "was this state entered via its
  `<initial>` default this time", while `entered_states` accumulates across
  the whole session and answers "has this state ever been entered before" -
  a state re-entered through history restoration has no default entry at
  all, so the two sets diverge exactly where late binding's "first time"
  question needs the session-long answer.

  ## `running` and `status` differ only across `exit_interpreter`

  `running` is Appendix D's `running` flag verbatim: the interpreter loop's
  continue condition, set `false` when a top-level final is entered.
  `status` is `:running | :done` and only becomes `:done` after
  `exit_interpreter` has finished and the terminal `{:done, _}` effect has
  been produced. The two therefore differ for exactly the window between
  top-level final entry and the end of `exit_interpreter` - the window in
  which `exit_interpreter` still has to run `onexit` content on a machine
  that is no longer `running`. `new/2` produces `running: true,
  status: :running`; a machine_state that has not been initialized yet is
  indistinguishable from a running one, which is harmless because `new/2`
  is only ever called by `Statifier.Interpreter.initialize/2`, immediately
  before it enters the initial states.

  ## The counter contract

  - `new/2` sets `macrostep: 0, microstep: 0, round: 0`. Zero means "no
    macrostep has begun", "no microstep of the current macrostep has
    begun", and "no round of the current macrostep's fold has begun",
    respectively; none of the three is ever the number of a real step or
    round.
  - `begin_macrostep/1` is the **only** writer of `macrostep`: it increments
    it by one and resets both `microstep` and `round` to `0`. Its callers
    are `Statifier.Interpreter.initialize/2`, once (so the initialization
    macrostep is **macrostep 1**), and `Statifier.Interpreter.handle_event/2`,
    once per accepted external event (so the first external event is
    **macrostep 2**).
  - `begin_microstep/1` is the **only** writer of `microstep`: it increments
    it by one. It is called once per *pseudocode microstep* - one
    exit/execute/enter round - so the first microstep of a macrostep is
    **microstep 1**. Its callers are `Statifier.Interpreter.initialize/2`,
    directly, once, immediately before its own `enter_states/2` call (the
    initial entry is itself a microstep even though the pseudocode's
    `enterStates([doc.initial.transition])` sits outside `microstep`), and
    `run_selected/3`, the private tail shared by every selection round, on
    the branch where the selected transition set is non-empty.
  - A selection round that dequeues an internal event enabling no
    transitions does **not** advance `microstep`: no exit or entry
    happened, so there was no microstep. The consumed event is still
    visible, because the event-dequeued trace effect is emitted at the
    current counters.
  - `begin_round/1` is the **only** writer of `round`: it increments it by
    one. Its single call site is `Statifier.Interpreter.microstep/1`'s
    head, both clauses included, so the first round of a macrostep's fold
    is **round 1** and every round the fold spends is counted, whether or
    not it advances `microstep` - which is what makes `round` defined even
    under `max_macrostep_rounds: :infinity`, where it counts up rather than
    deriving from the budget (ADR-0020). Effects emitted before the fold
    begins - `handle_event/2`'s own `EventDequeued` and everything
    `initialize/2` emits before entering the fold - are stamped `round: 0`
    for the same reason they are stamped `microstep: 0`: no round has
    begun yet.
  - Cause metadata and trace effects are both stamped with the counters
    *as they stand at the moment of the stamp*, i.e. after the `begin_*`
    call for the step they belong to.

  No later function may assign `macrostep`, `microstep`, or `round`
  directly; the contract above is enforced by review (there being exactly
  three writer functions, `begin_macrostep/1`, `begin_microstep/1`, and
  `begin_round/1`), not mechanically.

  ## System variables live in the datamodel

  Spec 5.10 places `_sessionid`, `_name`, `_ioprocessors`, and `_event`
  alongside the author's own data in the datamodel - `datamodel` therefore
  is not "the author's data only". `Statifier.Evaluator.SystemVariables`
  owns the shape of each; this module owns *when* each is written, and each
  has exactly one writer:

  - `_sessionid`, `_name`, and `_ioprocessors` are written exactly once, by
    `new/2`, from `SystemVariables.initial/2` merged **over** the
    `:datamodel` option's map - an author-supplied datamodel can never
    shadow a system variable.
  - `_event` is **seeded** to `nil` by `new/2` from the same
    `SystemVariables.initial/2` map, and thereafter written only by
    `put_event/2`. That is one writer per phase rather than two writers of
    one value: the seed is what makes `_event` *declared* for the session's
    whole lifetime with no value yet (spec 5.10, and see
    `SystemVariables.initial/2`'s own docs for why an absent key would say
    something different and wrong), and `put_event/2` is the only thing
    that ever gives it one. The same enforced-by-review status the counter
    contract above states for `macrostep`/`microstep` applies to that second
    half.

  Every key in `datamodel` is a string, at every level, for every reachable
  `%MachineState{}` value - not merely "in practice today" but by
  construction. Every writer except the `:datamodel` option produces string
  keys because every other key this codebase ever writes comes from an SCXML
  id, which is a string by construction; the `:datamodel` option is the one
  source whose keys a caller chooses, and `new/2` checks it (`checked_datamodel!/1`
  below) before it ever reaches the struct. The invariant exists because the
  expression context built over this map (`Statifier.Evaluator.context/1`)
  binds each root by string name - a map that failed the invariant would
  either crash at the first evaluation site or be silently rewritten under a
  precedence rule the caller never saw, neither of which this module lets
  happen.

  Seeding the system variables in `new/2` rather than at
  `interpret`'s own datamodel-initialization step is a mechanical deviation
  from Appendix D's ordering, not a semantic one (ADR-0002):
  `Statifier.Interpreter.initialize/2` calls `new/2` as its first statement,
  so the variables are bound before anything can read them, and `new/2` is
  the only writer of the struct's initial fields regardless.

  ## `==` is not a position-equality test

  `internal_queue` is an `:queue.queue/0`. Two `:queue` values holding the
  same events in the same order can differ structurally - the front/rear
  split depends on the push/pop history - so `==` on two `%MachineState{}`
  values is *not* a reliable "same position" test. A comparison that needs
  to know whether two machine_states are at the same interpreter position (a
  fold-to-quiescence-versus-step-by-step acceptance test, for one) must
  compare a normalized view - `configuration`, `internal_events/1`,
  `history_values`, the counters, `status` - never raw struct equality.
  `internal_events/1` is exactly that normalized, inspection-and-assertion
  view of the queue; no code outside this module touches `:queue` directly.
  """

  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Event
  alias Statifier.Event.Cause
  alias Statifier.Machine

  @enforce_keys [:machine]
  defstruct [
    :machine,
    # MapSet.new/0 in new/2; nil is unreachable once new/2 has run.
    configuration: nil,
    # :queue.new/0 in new/2; nil is unreachable once new/2 has run.
    internal_queue: nil,
    history_values: %{},
    entered_states: MapSet.new(),
    datamodel: %{},
    running: true,
    status: :running,
    macrostep: 0,
    microstep: 0,
    round: 0,
    trace: false,
    max_macrostep_rounds: 10_000
  ]

  @typedoc """
  The datamodel slot - a map today (`docs/datamodel.md:33-41`'s evaluation
  context is a predicator context, i.e. a map), typed as `map()` rather
  than `term()`/`any()` so that filling in real datamodel evaluation only
  adds content, not shape, and dialyzer has something to check in the
  meantime.
  """
  @type datamodel :: map()

  @typedoc """
  Whether trace effects are emitted. A plain boolean, not a level: the
  `Effect.trace/3` gate's contract is one field read and nothing built when
  off, and a later level would arrive as a separate field so this one
  never turns into a comparison.
  """
  @type trace :: boolean()

  @typedoc """
  The round budget one macrostep's fold may spend - `pos_integer()`, or
  `:infinity` for the spec's literal unbounded behavior (ADR-0019). Set once
  in `new/2` and read-only thereafter, like `trace`. One round is one
  `Statifier.Interpreter.microstep/1` call inside the fold, empty rounds
  included; it is not a microstep count, because a livelocked fold can run
  forever without advancing the microstep counter at all. The `round`
  counter counts the same rounds this budget bounds, so at exhaustion
  `round` equals the spent budget (ADR-0020).
  """
  @type max_macrostep_rounds :: pos_integer() | :infinity

  @type t :: %__MODULE__{
          machine: Machine.t(),
          configuration: MapSet.t(non_neg_integer()),
          internal_queue: :queue.queue(Event.t()),
          history_values: %{optional(non_neg_integer()) => MapSet.t(non_neg_integer())},
          entered_states: MapSet.t(non_neg_integer()),
          datamodel: datamodel(),
          running: boolean(),
          status: :running | :done,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer(),
          trace: trace(),
          max_macrostep_rounds: max_macrostep_rounds()
        }

  @doc """
  A fresh position over `machine`: empty configuration, empty internal
  queue, no history values, counters at zero, `running: true`,
  `status: :running`. Does **not** enter any state - entering the initial
  configuration is the not-yet-implemented `initialize/2`'s job, not this
  constructor's.

  Options: `:trace` (default `false`), `:datamodel` (default `%{}`),
  `:session_id` (default a freshly generated `sess_` UXID, ADR-0008), and
  `:max_macrostep_rounds` (default `10_000`). All four system variables
  (`SystemVariables.initial/2`) are merged **over** the `:datamodel`
  option's map, so author-supplied data can never shadow a system variable.

  `:datamodel` must be string-keyed at every level: raises `ArgumentError`
  if any key, in the map itself or in a map nested inside it (directly or
  inside a list, at any depth), is an atom other than `true`/`false` -
  exactly the keys `Predicator.Context`'s own normalization would rewrite.
  Boolean keys and non-atom keys (integers, for one) are accepted, and a
  struct value's fields are never inspected, since predicator's walk does
  not descend into one either.
  """
  @spec new(machine :: Machine.t(), opts :: keyword()) :: t()
  def new(%Machine{} = machine, opts \\ []) do
    session_id = Keyword.get_lazy(opts, :session_id, fn -> UXID.generate!(prefix: "sess") end)
    author_datamodel = opts |> Keyword.get(:datamodel, %{}) |> checked_datamodel!()

    %__MODULE__{
      machine: machine,
      configuration: MapSet.new(),
      internal_queue: :queue.new(),
      history_values: %{},
      entered_states: MapSet.new(),
      datamodel: Map.merge(author_datamodel, SystemVariables.initial(machine, session_id)),
      running: true,
      status: :running,
      macrostep: 0,
      microstep: 0,
      round: 0,
      trace: Keyword.get(opts, :trace, false),
      max_macrostep_rounds: Keyword.get(opts, :max_macrostep_rounds, 10_000)
    }
  end

  # Mirrors `Predicator.Context`'s own `normalize_value/1` walk
  # (`deps/predicator/lib/predicator/context.ex`): lists and non-struct maps
  # are descended, structs pass through whole, scalars are ignored. Inside a
  # map, `normalize_map/1` rewrites exactly the atom keys that are not
  # `true`/`false` - `config[true]` is a literal atom-key lookup upstream, so
  # boolean keys are data, not variable names - and those are exactly the keys
  # refused here. What that buys: a caller-supplied datamodel that reaches the
  # struct is one predicator's normalization would not change, at any depth, so
  # the map stored here and the map every expression evaluates against are the
  # same map. The refusal is deliberate rather than a silent stringification:
  # coercing would duplicate upstream's precedence rules here, and would drop
  # one of `%{"x" => 1, x: 2}`'s two entries by a rule the caller never stated.
  @spec checked_datamodel!(datamodel :: map()) :: map()
  defp checked_datamodel!(datamodel) when is_map(datamodel) do
    check_keys!(datamodel, [])
    datamodel
  end

  @spec check_keys!(value :: term(), path :: [term()]) :: :ok
  defp check_keys!(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.each(fn {element, index} -> check_keys!(element, [index | path]) end)
  end

  defp check_keys!(%_struct{}, _path), do: :ok

  defp check_keys!(map, path) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      if offending_key?(key), do: raise(ArgumentError, key_message(key, path))
      check_keys!(value, [key | path])
    end)
  end

  defp check_keys!(_scalar, _path), do: :ok

  @spec offending_key?(key :: term()) :: boolean()
  defp offending_key?(key), do: is_atom(key) and not is_boolean(key)

  @spec key_message(key :: term(), path :: [term()]) :: String.t()
  defp key_message(key, path) do
    location =
      case Enum.reverse(path) do
        [] -> "the top level"
        segments -> Enum.map_join(segments, " -> ", &inspect/1)
      end

    "the :datamodel option must not contain the key #{inspect(key)} at #{location}: " <>
      "datamodel keys must be strings at every level, and an atom key would be " <>
      "rewritten (or dropped, if a string key of the same name is present) by the " <>
      "expression context this datamodel is evaluated against"
  end

  @doc """
  The active *leaf* states - `configuration` filtered by
  `Statifier.Machine.atomic?/2`. A `:final` is atomic - `kind` and
  atomicity are independent facts (`Machine.atomic?/2`) - and therefore
  appears in this view. `:history` pseudo-states never enter
  `configuration` in the first place, so this filter never has to exclude
  them - there is nothing history-shaped to filter out. The string-id
  translation of this view belongs to a future API boundary, not this
  module's: everything here stays integer indexes (ADR-0005).

  This is `O(n)` in the configuration size and is meant for the API
  boundary and for inspection, not for a per-microstep interpreter path.
  """
  @spec active_leaf_states(machine_state :: t()) :: MapSet.t(non_neg_integer())
  def active_leaf_states(%__MODULE__{machine: machine, configuration: configuration}) do
    MapSet.filter(configuration, &Machine.atomic?(machine, &1))
  end

  @doc """
  Enqueues `event` on the internal queue, FIFO. The one and only writer of
  `internal_queue` alongside `dequeue_internal/1`.
  """
  @spec enqueue_internal(machine_state :: t(), event :: Event.t()) :: t()
  def enqueue_internal(%__MODULE__{internal_queue: queue} = machine_state, %Event{} = event) do
    %{machine_state | internal_queue: :queue.in(event, queue)}
  end

  @doc """
  Dequeues the oldest event on the internal queue - `{:ok, event,
  machine_state}` with the event removed, or `:empty` when the queue holds
  nothing.
  """
  @spec dequeue_internal(machine_state :: t()) :: {:ok, Event.t(), t()} | :empty
  def dequeue_internal(%__MODULE__{internal_queue: queue} = machine_state) do
    case :queue.out(queue) do
      {{:value, event}, rest} -> {:ok, event, %{machine_state | internal_queue: rest}}
      {:empty, _rest} -> :empty
    end
  end

  @doc """
  The pending internal events as a plain list, oldest first - the FIFO
  order the queue's own opaque structure does not directly expose. This is
  the inspection and assertion path for every test and every future
  debugger; no interpreter code path needs it, since `dequeue_internal/1`
  alone drives selection.
  """
  @spec internal_events(machine_state :: t()) :: [Event.t()]
  def internal_events(%__MODULE__{internal_queue: queue}), do: :queue.to_list(queue)

  @doc """
  `datamodel["_event"] = event` (Appendix D) - the one and only writer of
  the `_event` system variable (spec 5.10.1). Both of `mainEventLoop`'s
  assignments, the external one (`Statifier.Interpreter.handle_event/2`)
  and the internal one (`Statifier.Interpreter.internal_round/1`), go
  through here.
  """
  @spec put_event(machine_state :: t(), event :: Event.t()) :: t()
  def put_event(%__MODULE__{datamodel: datamodel} = machine_state, %Event{} = event) do
    %{machine_state | datamodel: Map.put(datamodel, "_event", SystemVariables.event(event))}
  end

  @doc """
  Raises an internal event: builds its `Cause` from `origin` and the
  machine_state's own counters *as they stand right now*, builds the
  `:internal` event, and enqueues it - so cause metadata cannot be
  forgotten at a call site. This is the function `<raise>`'s
  executable-content implementation (`Statifier.Machine.Content.Raise`)
  calls. `done.state.*` is a `:platform` event per spec 5.10.1 and is
  raised through `raise_platform/4` instead - both enqueue on this same
  internal queue, `type` is provenance, not routing.

  `origin` is `Cause.origin/0`: `<raise>` passes `{:content, c_index,
  owner}` (the raising node and its owning onentry/onexit/transition
  block). The round is stamped as it stood at the raise - same rule as the
  counters.
  """
  @spec raise_internal(
          machine_state :: t(),
          name :: String.t(),
          origin :: Cause.origin(),
          opts :: keyword()
        ) :: t()
  def raise_internal(
        %__MODULE__{macrostep: macrostep, microstep: microstep, round: round} = machine_state,
        name,
        origin,
        opts \\ []
      ) do
    cause = Cause.new(origin, macrostep, microstep, round)
    event = Event.internal(name, cause, opts)
    enqueue_internal(machine_state, event)
  end

  @doc """
  Raises a platform event: identical to `raise_internal/4` except it builds
  an `Event.platform/3` event instead of `Event.internal/3` - so `type` is
  stamped `:platform` per spec 5.10.1. This is the function
  `Statifier.Interpreter.ExitEntry.raise_parent_completion/3` calls for
  `done.state.*`: `Statifier.Event`'s moduledoc classifies `done.state.*`
  as a platform-raised event, not one raised by executable content, and
  `raise_internal/4` would stamp the wrong `type`.

  Both `raise_internal/4` and this function enqueue on the *same* internal
  queue - `type` is provenance, not routing - so nothing about ordering or
  dequeue changes between the two.

  `origin` is `Cause.origin/0`: `done.state.*` on entering a final state
  passes `{:state, state_index}` (no content node backs it). The round is
  stamped as it stood at the raise - same rule as the counters.
  """
  @spec raise_platform(
          machine_state :: t(),
          name :: String.t(),
          origin :: Cause.origin(),
          opts :: keyword()
        ) :: t()
  def raise_platform(
        %__MODULE__{macrostep: macrostep, microstep: microstep, round: round} = machine_state,
        name,
        origin,
        opts \\ []
      ) do
    cause = Cause.new(origin, macrostep, microstep, round)
    event = Event.platform(name, cause, opts)
    enqueue_internal(machine_state, event)
  end

  @doc """
  Begins a new macrostep: increments `macrostep` by one and resets both
  `microstep` and `round` to `0`. The only writer of `macrostep` (the
  counter contract above).
  """
  @spec begin_macrostep(machine_state :: t()) :: t()
  def begin_macrostep(%__MODULE__{macrostep: macrostep} = machine_state) do
    %{machine_state | macrostep: macrostep + 1, microstep: 0, round: 0}
  end

  @doc """
  Begins a new microstep: increments `microstep` by one, leaving
  `macrostep` unchanged. The only writer of `microstep` (the counter
  contract above) - called once per exit/execute/enter round, never for a
  selection round that enabled no transitions.
  """
  @spec begin_microstep(machine_state :: t()) :: t()
  def begin_microstep(%__MODULE__{microstep: microstep} = machine_state) do
    %{machine_state | microstep: microstep + 1}
  end

  @doc """
  Begins a new round of this macrostep's fold: increments `round` by one,
  leaving `macrostep` and `microstep` unchanged. The only writer of `round`
  (the counter contract above) - called once per
  `Statifier.Interpreter.microstep/1` invocation, empty rounds and the
  terminal probe included, which is the same definition of a round that
  `max_macrostep_rounds` uses (ADR-0020).
  """
  @spec begin_round(machine_state :: t()) :: t()
  def begin_round(%__MODULE__{round: round} = machine_state) do
    %{machine_state | round: round + 1}
  end
end
