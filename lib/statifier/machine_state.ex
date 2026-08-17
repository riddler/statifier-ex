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

  ## `states_to_invoke` is every state entered since the last invoke pass

  `states_to_invoke` mirrors Appendix D's `statesToInvoke` global: a
  `MapSet` of state indexes, added to by `Statifier.Interpreter.ExitEntry.arrive/3`
  (`enterStates`'s per-state entry body) and deleted from by
  `Statifier.Interpreter.ExitEntry.exit_states/2` (`exitStates`'s
  `for s in statesToExit: statesToInvoke.delete(s)`).

  Population is unconditional - a state with no `<invoke>` children still
  lands its index here on entry, exactly as `entered_states` below is
  populated unconditionally and for the same reason: a field whose contents
  depend on whether the document happens to carry `<invoke>` children has a
  meaning a reader cannot state without the document in hand, and
  ADR-0012 constraint 1 wants a `%MachineState{}` that inspects as a
  complete position regardless of which document produced it.

  The entry-order sort Appendix D's own pseudocode performs
  (`statesToInvoke.sort(entryOrder)`) happens at the invoke pass itself, not
  here - this field stores an unordered `MapSet`, the same pattern
  `configuration` uses everywhere in this module.

  It has two writers by design, matching the two Appendix D procedures that
  touch it: `exit_states/2` deletes any state that exits before the invoke
  pass runs, and the invoke pass empties whatever remains once it has walked
  it. Neither is a counter function - unlike `macrostep`/`microstep`/`round`
  above, membership here is not monotonic within a macrostep.

  ## `active_invocations` is `inv.invokeid` hoisted off compiled data

  Appendix D stores an invocation's generated identifier on the invocation
  object itself (`inv.invokeid`), read back by the cancel walks
  (`cancelInvoke(inv)`) and the finalize pass
  (`if inv.invokeid == externalEvent.invokeid: applyFinalize(...)`).
  `Statifier.Machine.Invoke` is immutable compiled data - the same "nowhere
  on the state to flip a mutable flag" situation `entered_states` above
  describes for `s.isFirstEntry` - so the live invokeid is hoisted onto this
  struct instead, keyed to match the pseudocode's own access pattern:

      active_invocations: %{{state_index, invoke_index} => invoke_id}

  `state_index` and `invoke_index` together name one compiled `<invoke>`
  element (`Statifier.Compiler.Expressions.owner_ref/0`'s `{:invoke, _, _}`
  shape); document order for a walk over one state's invocations always
  comes from the compiled `invoke` list itself, never from iterating this
  map. This is the same ADR-0002 mechanical deviation `entered_states`
  already declares: the semantics are unchanged (an invocation's id is still
  readable by exactly the same lookups Appendix D performs), only the
  storage moves off the immutable compiled document.

  **This is not ADR-0027 decision 3's parent-held session table.** That
  table maps an invokeid to `{child_session_id, pid, monitor_ref}` - process
  identity the session layer owns. `active_invocations` holds none of that:
  no pid, no monitor ref, no child session id, only the generated or
  author-written invokeid string. The session's own table is built on top of
  this one, not in place of it, by later work this struct does not depend on.

  Entries are written by the invoke pass (one entry per invocation that
  successfully started) and deleted by the cancel walks (a later phase's
  `depart/2`/`exit_interpreter/1` seams) when the owning invocation is
  cancelled.

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

  ## `invoke_counter` is the session-global platformid sequence (ADR-0008)

  Spec 6.4.1 mandates a generated invoke id of the form
  `stateid.platformid`, and its own MUST binds uniqueness to the
  platformid alone - "platformid MUST be unique within the current
  session" - not to the composite. `invoke_counter` is that platformid
  source: one auto-increment for the whole session, read from and written
  back to this struct by `Statifier.Interpreter.generate_invoke_id/3`
  (`lib/statifier/interpreter.ex`), never per-state or per-`<invoke>`
  element. A per-state counter would let `s0.1` and `s1.1` collide on
  platformid `1` while still satisfying composite uniqueness, which 6.4.1
  as written does not permit; one session-global counter makes every
  platformid distinct by construction and also keeps the anonymous-state
  fallback (`inv_<counter>`, no qualifier - `Machine.State.id` is `nil` for
  a state with no author-written id) unique with no special case.

  This field exists, instead of generating an id at the generation site,
  because ADR-0003 wins where ADR-0008's identifier aesthetics collide with
  the core's `(state, event) -> {state, [effect]}` contract: generating one
  reads the wall clock and a CSPRNG, and `<invoke idlocation>` writes the
  result into the datamodel, so minting it with entropy would make a
  recorded run and its replay diverge in program state. A counter that is a
  pure field on `%MachineState{}` replays identically and satisfies
  ADR-0012 constraint 1 (inspectable, not hidden generator state). See
  ADR-0008's 2026-08-15 amendment for the full argument, including why
  session ids are still generated from entropy (uniqueness *across*
  sessions, which entropy buys and a session-local counter cannot).

  Starts at `0` in `new/2` (no invocation has generated an id yet) and is
  incremented by `generate_invoke_id/3` immediately before use, so the
  first generated platformid is `inv_1` - the same "increment before
  read" idiom `begin_macrostep/1` etc. use below, though this field is not
  part of that trio's enforced-by-review contract: it is written directly
  at its one call site rather than through a dedicated `MachineState`
  function, matching how `active_invocations` and `states_to_invoke` are
  already mutated directly from `lib/statifier/interpreter.ex` and
  `lib/statifier/interpreter/exit_entry.ex` rather than through setters.
  An author-written `<invoke id="...">` is used verbatim and never
  composed, so it does not advance this counter - only a generated id
  consumes the sequence.

  ## `send_counter` is the session-global `send_` id sequence (ADR-0035)

  Spec 3.14 leaves `<send>`'s generated-id format unconstrained ("The SCXML
  processor MAY generate all other ids in any format, as long as they are
  unique"), unlike `<invoke>`'s spec-pinned `stateid.platformid` form.
  `send_counter` is the one auto-increment behind that free format: one
  session-global counter, read from and written back to this struct at
  `<send>`'s own generation site (a later phase's job, not this field's),
  producing ids `send_1`, `send_2`, ... in the order the processor mints
  them. Same reasoning as `invoke_counter` above for why this is a plain
  counter and not a generated id: ADR-0003's core is
  `(state, event) -> {state, [effect]}`, and generating one reads the wall
  clock and a CSPRNG, which `<send idlocation>` writing the result into the
  datamodel would turn into an observable replay divergence. A counter that
  is a pure field on `%MachineState{}` replays identically instead.

  **Not shared with `invoke_counter`.** ADR-0035 gives two reasons: the two
  sequences answer to different governing clauses (`<invoke>`'s format is
  pinned by 6.4.1; `<send>`'s is free per the 3.14 sentence above, so
  coupling a free-format sequence to a pinned one buys nothing), and sharing
  would let an `<invoke>` advance the send-id sequence, making a document's
  `send_` ids depend on how many invocations happened first - still
  deterministic and replayable, but no longer locally readable the way
  `idlocation` wants them to be. See ADR-0035 for the full argument.

  Starts at `0` in `new/2` (no send has generated an id yet). An
  author-written `<send id="...">` is used verbatim and never advances this
  counter, exactly as an author-written `<invoke id="...">` leaves
  `invoke_counter` untouched - only a generated id consumes the sequence,
  and a fresh id is generated on every execution of the element (3.14: "not
  at load time but each time the element is executed"), never memoized on
  it. No setter function, matching `invoke_counter`'s own precedent: written
  directly at its one call site rather than through a dedicated
  `MachineState` function.

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

  # Crockford base32's alphabet in `Base.hex_encode32/2`'s symbol order, so a
  # 32-entry character translation is exact and order-preserving. Crockford
  # over a fixed-width big-endian bit string keeps lexicographic order, which
  # is what makes a `sess_` id sort by creation millisecond.
  @hex32_alphabet ~c"0123456789abcdefghijklmnopqrstuv"
  @crockford_alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"
  @hex32_to_crockford Map.new(Enum.zip(@hex32_alphabet, @crockford_alphabet))

  @enforce_keys [:machine]
  defstruct [
    :machine,
    # MapSet.new/0 in new/2; nil is unreachable once new/2 has run.
    configuration: nil,
    # :queue.new/0 in new/2; nil is unreachable once new/2 has run.
    internal_queue: nil,
    history_values: %{},
    entered_states: MapSet.new(),
    states_to_invoke: MapSet.new(),
    active_invocations: %{},
    invoke_counter: 0,
    send_counter: 0,
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
          states_to_invoke: MapSet.t(non_neg_integer()),
          active_invocations: %{optional({non_neg_integer(), non_neg_integer()}) => String.t()},
          invoke_counter: non_neg_integer(),
          send_counter: non_neg_integer(),
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
  `:session_id` (default a freshly generated `sess_` id, ADR-0008), and
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

  A `nil` value anywhere in `:datamodel` means predicator's null (ADR-0037);
  an embedder that means "declared, no value yet" passes `:undefined`
  instead.
  """
  @spec new(machine :: Machine.t(), opts :: keyword()) :: t()
  def new(%Machine{} = machine, opts \\ []) do
    session_id = Keyword.get_lazy(opts, :session_id, &generate_session_id/0)
    author_datamodel = opts |> Keyword.get(:datamodel, %{}) |> checked_datamodel!()

    %__MODULE__{
      machine: machine,
      configuration: MapSet.new(),
      internal_queue: :queue.new(),
      history_values: %{},
      entered_states: MapSet.new(),
      states_to_invoke: MapSet.new(),
      active_invocations: %{},
      invoke_counter: 0,
      send_counter: 0,
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
  # ADR-0008 (2026-08-15 amendment): the `sess_` id is minted here rather than
  # by a library - 48-bit big-endian millisecond timestamp then 80 bits of
  # CSPRNG output, Crockford base32. This is the one generation site outside
  # the pure core, exactly where the dependency's call sat; ADR-0003 is
  # untouched, and entropy is kept at full strength because session ids must be
  # unique *across* sessions (the ADR-0027 registry and parent/child routing
  # depend on it).
  @spec generate_session_id() :: String.t()
  defp generate_session_id do
    # ADR-0008: 48-bit millisecond timestamp, then 80 bits of entropy.
    body = <<System.os_time(:millisecond)::48, :crypto.strong_rand_bytes(10)::binary>>
    "sess_" <> crockford32(body)
  end

  @spec crockford32(bytes :: binary()) :: String.t()
  defp crockford32(bytes) do
    bytes
    |> Base.hex_encode32(case: :lower, padding: false)
    |> String.to_charlist()
    |> Enum.map(&Map.fetch!(@hex32_to_crockford, &1))
    |> List.to_string()
  end

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

  # Predicator.Duration.new/1's eight unit keys (predicator 9.0,
  # `deps/predicator/lib/predicator/duration.ex`) - a native duration value
  # is a plain map with exactly these atom keys, so it fails this guard the
  # same way any other atom-keyed map would. `duration_hint/1` names that
  # specific, plausible cause without asserting it: an unrelated map that
  # happens to use one of these eight names as a key is possible too, and
  # the hint's wording ("if this came from...") stays true either way.
  @duration_unit_keys ~w(years months weeks days hours minutes seconds milliseconds)a

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
      "expression context this datamodel is evaluated against" <> duration_hint(key)
  end

  @spec duration_hint(key :: term()) :: String.t()
  defp duration_hint(key) when key in @duration_unit_keys do
    " (if this came from a Predicator.Duration.t() - Predicator.Duration.new/1, " <>
      "or a duration-typed expression result - seed it after conversion instead: " <>
      "durations use atom keys internally by design and cannot be passed through " <>
      "the :datamodel option as-is; Statifier.Duration.to_ms/1 converts one to " <>
      "milliseconds, or evaluate the expression through <data>/<assign> instead, " <>
      "which do not check this option's keys)"
  end

  defp duration_hint(_key), do: ""

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
  Whether the internal queue holds no pending events - `internalQueue.isEmpty()`
  (Appendix D), the post-invoke re-check's own test. Cheaper than
  `internal_events/1 == []`: `:queue.is_empty/1` never materializes the
  queue into a list, so this is the predicate the interpreter's hot path
  uses, and `internal_events/1` stays the inspection-and-assertion view.
  """
  @spec internal_queue_empty?(machine_state :: t()) :: boolean()
  def internal_queue_empty?(%__MODULE__{internal_queue: queue}), do: :queue.is_empty(queue)

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
