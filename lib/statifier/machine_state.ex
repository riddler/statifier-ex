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

  ## The external queue is deliberately absent (Decision 8)

  Appendix D's `main_event_loop` owns both the internal and the external
  event queue. This struct only owns the internal one. The pure core takes
  one external event per call (ADR-0003); the session that drives it
  (st-cmq) owns queueing the waiting external events. This is a mechanical
  deviation in ADR-0002's sense - the semantics of processing one external
  event are unchanged, only the storage of the *waiting* ones moves outward
  - so it is legal, but the divergence must carry its reason at the port
  site: st-wju.6's `main_event_loop` port repeats this comment where it
  matters.

  ## `states_to_invoke` is deliberately absent

  Appendix D carries `statesToInvoke` as a global, but every read and write
  of it belongs to the invoke passes of `main_event_loop`, which land with
  the invoke bead (st-cmq). Adding an unused field now would be exactly the
  "dead field nobody can test" mistake the bead warns against for
  `origin`/`sendid` on `Statifier.Event`. st-cmq adds it deliberately, with
  a caller, rather than this bead adding it as a placeholder.

  ## `running` and `status` differ only across `exit_interpreter` (Decision 6)

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
  is only ever called by st-wju.6's `initialize/2`, immediately before it
  enters the initial states.

  ## The counter contract (Decision 5)

  - `new/2` sets `macrostep: 0, microstep: 0`. Zero means "no macrostep has
    begun"; it is never the number of a real step.
  - `begin_macrostep/1` is the **only** writer of `macrostep`: it increments
    it by one and resets `microstep` to `0`. st-wju.6 calls it once in
    `initialize/2` (so the initialization macrostep is **macrostep 1**) and
    once per accepted external event in `handle_event/2` (so the first
    external event is **macrostep 2**).
  - `begin_microstep/1` is the **only** writer of `microstep`: it increments
    it by one. It is called once per *pseudocode microstep* - one
    exit/execute/enter round - so the first microstep of a macrostep is
    **microstep 1**.
  - A selection round that dequeues an internal event enabling no
    transitions does **not** advance `microstep`: no exit or entry
    happened, so there was no microstep. The consumed event is still
    visible, because the event-dequeued trace effect is emitted at the
    current counters.
  - Cause metadata and trace effects are both stamped with the counters
    *as they stand at the moment of the stamp*, i.e. after the `begin_*`
    call for the step they belong to.

  No later function may assign `macrostep` or `microstep` directly; the
  contract above is enforced by review (there being exactly two writer
  functions), not mechanically.

  ## `==` is not a position-equality test (Decision 2)

  `internal_queue` is an `:queue.queue/0`. Two `:queue` values holding the
  same events in the same order can differ structurally - the front/rear
  split depends on the push/pop history - so `==` on two `%MachineState{}`
  values is *not* a reliable "same position" test. A comparison that needs
  to know whether two machine_states are at the same interpreter position
  (st-wju.6's fold-to-quiescence-versus-step-by-step acceptance test, for
  one) must compare a normalized view - `configuration`,
  `internal_events/1`, `history_values`, the counters, `status` - never raw
  struct equality. `internal_events/1` is exactly that normalized,
  inspection-and-assertion view of the queue; no code outside this module
  touches `:queue` directly.
  """

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
    datamodel: %{},
    running: true,
    status: :running,
    macrostep: 0,
    microstep: 0,
    trace: false
  ]

  @typedoc """
  The datamodel slot - a map today (`docs/datamodel.md:33-41`'s evaluation
  context is a predicator context, i.e. a map), typed as `map()` rather
  than `term()`/`any()` so st-af3 adds content, not shape, and dialyzer has
  something to check in the meantime.
  """
  @type datamodel :: map()

  @typedoc """
  Whether trace effects are emitted (Decision 12). A plain boolean, not a
  level: the `Effect.trace/3` gate's contract is one field read and nothing
  built when off, and a later level would arrive as a separate field so
  this one never turns into a comparison.
  """
  @type trace :: boolean()

  @type t :: %__MODULE__{
          machine: Machine.t(),
          configuration: MapSet.t(non_neg_integer()),
          internal_queue: :queue.queue(Event.t()),
          history_values: %{optional(non_neg_integer()) => MapSet.t(non_neg_integer())},
          datamodel: datamodel(),
          running: boolean(),
          status: :running | :done,
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          trace: trace()
        }

  @doc """
  A fresh position over `machine`: empty configuration, empty internal
  queue, no history values, counters at zero, `running: true`,
  `status: :running`. Does **not** enter any state - entering the initial
  configuration is `initialize/2`'s job (st-wju.6), not this constructor's.

  Options: `:trace` (default `false`) and `:datamodel` (default `%{}`).
  """
  @spec new(machine :: Machine.t(), opts :: keyword()) :: t()
  def new(%Machine{} = machine, opts \\ []) do
    %__MODULE__{
      machine: machine,
      configuration: MapSet.new(),
      internal_queue: :queue.new(),
      history_values: %{},
      datamodel: Keyword.get(opts, :datamodel, %{}),
      running: true,
      status: :running,
      macrostep: 0,
      microstep: 0,
      trace: Keyword.get(opts, :trace, false)
    }
  end

  @doc """
  The active *leaf* states - `configuration` filtered by
  `Statifier.Machine.atomic?/2`. A `:final` is atomic (per `Machine`'s own
  Decision 4) and therefore appears in this view. `:history` pseudo-states
  never enter `configuration` in the first place, so this filter never has
  to exclude them - there is nothing history-shaped to filter out. The
  string-id translation of this view is st-wju.7's API boundary, not
  this module's: everything here stays integer indexes (ADR-0005).

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
  order the queue's own opaque structure does not directly expose
  (Decision 2). This is the inspection and assertion path for every test
  and every future debugger; no interpreter code path needs it, since
  `dequeue_internal/1` alone drives selection.
  """
  @spec internal_events(machine_state :: t()) :: [Event.t()]
  def internal_events(%__MODULE__{internal_queue: queue}), do: :queue.to_list(queue)

  @doc """
  Raises an internal event: builds its `Cause` from `origin` and the
  machine_state's own counters *as they stand right now*, builds the
  `:internal` event, and enqueues it - so cause metadata cannot be
  forgotten at a call site. This is the one function st-wju.4
  (`done.state.*`) and st-wju.5 (`<raise>`) call; there is no
  `raise_platform/4` sibling here (st-af3 decides whether `error.execution`
  needs one).
  """
  @spec raise_internal(
          machine_state :: t(),
          name :: String.t(),
          origin :: Cause.origin(),
          opts :: keyword()
        ) :: t()
  def raise_internal(
        %__MODULE__{macrostep: macrostep, microstep: microstep} = machine_state,
        name,
        origin,
        opts \\ []
      ) do
    cause = Cause.new(origin, macrostep, microstep)
    event = Event.internal(name, cause, opts)
    enqueue_internal(machine_state, event)
  end

  @doc """
  Begins a new macrostep: increments `macrostep` by one and resets
  `microstep` to `0`. The only writer of `macrostep` (counter contract,
  Decision 5).
  """
  @spec begin_macrostep(machine_state :: t()) :: t()
  def begin_macrostep(%__MODULE__{macrostep: macrostep} = machine_state) do
    %{machine_state | macrostep: macrostep + 1, microstep: 0}
  end

  @doc """
  Begins a new microstep: increments `microstep` by one, leaving
  `macrostep` unchanged. The only writer of `microstep` (counter contract,
  Decision 5) - called once per exit/execute/enter round, never for a
  selection round that enabled no transitions.
  """
  @spec begin_microstep(machine_state :: t()) :: t()
  def begin_microstep(%__MODULE__{microstep: microstep} = machine_state) do
    %{machine_state | microstep: microstep + 1}
  end
end
