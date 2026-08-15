defmodule Statifier.Session do
  @moduledoc """
  The GenServer effect interpreter (ADR-0003): the outer `while running`
  loop, the waiting external events, the delayed-send timers, and the
  fan-out of the effect stream to subscribers. The pure core decides; this
  module performs.

  This is the one module under `lib/statifier/` allowed to do I/O
  (`lib/mix/statifier/adr_guard.ex`'s `@effect_interpreter_paths`), which is
  why the deciding half lives in `Statifier.Session.Inbox`,
  `Statifier.Session.Timers`, and `Statifier.Session.Effects` - pure values
  and a pure function, testable with no process at all - and only the
  performing half lives here. A different path or module name fails the
  gate.

  ## A bare `start_link/2` stays legal; the runtime is opt-in

  `start_link/2` and the `use GenServer`-generated `child_spec/1` still work
  exactly as before: an embedder can place a session directly
  in their own supervision tree, and `:name` is passed to
  `GenServer.start_link/3` unchanged, so an embedder-owned
  `{:via, Registry, _}` works with no code here. A session started this way
  is legal and unregistered - ADR-0027 decision 2 sanctions this outright,
  since C.1 leaves "accessible to a given SCXML Processor" platform-defined,
  and an unregistered session is an inaccessible one to every *other*
  session (decision 10 below is the one exception, and it is about
  self-addressing, not registration).

  `Statifier.start_session/2` is the alternative that registers: it starts
  the session on `Statifier.SessionSupervisor` under `Statifier.Supervisor`
  (ADR-0027), and `init/1` below registers under `Statifier.Registry` when
  that registry is running - never fatal to the session when it is not, so
  a bare `start_link/2` embedder pays nothing for a runtime it never placed.

  `use GenServer, restart: :temporary` (ADR-0027 decision 4) is written
  explicitly, both because the generated `child_spec/1` otherwise defaults
  to `restart: :permanent` - which would have a supervisor restart a
  session that halted normally, the opposite of the next section - and
  because `:temporary` itself is a decision: a supervisor restart re-runs
  `start_link/2`, which generates a *fresh* `sess_` id and loses every
  bit of the crashed session's state, so restarting is actively wrong, not
  merely useless. Recovery that preserves identity is replay, not a
  restart flag.

  ## `:done` idles the session; it does not stop it

  The process stays alive with the terminal `%MachineState{}` and the
  retained `%Effect.Done{}` in hand, so `snapshot/1` and `status/1` still
  answer after termination. Stopping is the caller's move (`stop/2`), or the
  supervisor's. Further events are queued but never drained. The same is
  true, with a narrower meaning, for `:cancelled` (`cancel/1` reached the
  same `exit_interpreter/1` path) and for `:budget_exhausted` (ADR-0019):
  the session neither retries with a larger budget nor stops itself, and
  `cancel/1` still works from a budget-halted session, since the
  underlying `%MachineState{}` is still `running` and the inbox's cancel
  entry is checked before any drive of the core - a queued ordinary event
  is not.

  ## One subscriber stream

  There is no `:owner` concept. Subscribers are a monitored set;
  `start_link/2` takes `:subscribers` (default `[]`), and
  `subscribe/2`/`unsubscribe/2` manage it afterward. Every message a
  subscriber receives is `{:statifier, session_id, message}`, where
  `message` is one of:

    - `{:effect, effect}` - every effect the core (or an `interpret/2`
      caller) hands this session, trace effects included, in order. Trace
      effects are ordinary list members here too, never a side channel.
    - `{:unroutable, effect}` - a `:send`/`:send_delayed`/`:invoke`/
      `:cancel_invoke`/`:autoforward` effect this session cannot route yet
      (see `Statifier.Session.Effects`'s own moduledoc for exactly which).
    - `{:halted, :done | :cancelled | :budget_exhausted}` - one lifecycle
      message, following the effects that caused it.

  A subscriber that dies is dropped on its own `:DOWN`.

  ## A cancel is a queue entry, not an out-of-band call

  `cancel/1` enqueues the cancel marker onto this session's own external
  inbox (`Statifier.Session.Inbox.enqueue_cancel/1`), so a cancellation is
  recorded in the same ordered queue as every event
  (`docs/observability.md` constraint 6) rather than racing ahead of it
  through a side channel. Draining it runs `Statifier.Interpreter.cancel/1`
  - Appendix D's `running = false` followed by `exitInterpreter()` - and
  halts the session `:cancelled`, even though the `{:done, _}` effect that
  walk produces is still forwarded to subscribers exactly as natural
  termination's is.

  ## `<send>` routing

  A `<send>`/`<send_delayed>` with no `target` lands on this session's own
  external queue. `#_internal` and a self-addressed `#_scxml_<sessionid>`
  (decision 10: a session is always accessible to itself, registry or not)
  both resolve with no registry at all - the former through
  `Statifier.Interpreter.deliver_internal/5` (ADR-0039), the latter onto
  this session's own inbox. Every other `#_scxml_<sessionid>` resolves
  through `Registry.lookup(Statifier.Registry, sid)` (ADR-0027 decision 2):
  a hit casts the event onto that session's inbox via `send_event/2`; an
  empty lookup - the id never existed, named a bare unregistered session,
  or named a session that has since died - takes C.1's mandated
  `error.communication` path on the *sending* session's own internal queue,
  through the private `communication_error/4` resolver. `#_parent` and
  `#_<invokeid>` still resolve to `error.communication` the same way - the
  invocation table this module now holds (`Statifier.Session.Invocations`)
  answers "which child does `<invoke>` start", not yet "where does
  `#_parent`/`#_<invokeid>` deliver"; a later bead changes each resolver in
  turn, not this module's `{:deliver, ...}` clause. An unsupported `type` or
  an unparseable `target` raises `error.execution` the same way, at plan
  time. `:cancel_invoke` and `:autoforward` still plan as
  `{:unroutable, effect}`, pending later routing work. See
  `Statifier.Session.Effects` and `Statifier.Session.Target`.

  ## Starting an invocation's child session

  `{:invoke, %Effect.Invoke{}}` with a supported `type` plans
  `{:start_child, invoke, effect}` (`Statifier.Session.Effects`). Performing
  it resolves `invoke.content`/`invoke.src` through `Statifier.Invoke.Source`
  (`state.invoke_source`, the embedder-supplied resolver from `start_link/2`
  ADR-0038 hands off to), seeds the resolved child `Machine.t()`'s datamodel
  through `Statifier.Session.Invocations.seed_datamodel/2` (spec 6.4.3's
  name-matched `<param>`/namelist seeding), and starts it on
  `Statifier.SessionSupervisor` via `Statifier.start_session/2` with
  `invoked_by: {self(), invoke.invoke_id}`. Success monitors the child and
  records `{pid, session_id, monitor_ref, autoforward}` in
  `state.invocations`; either a resolve failure or a
  `Statifier.start_session/2` failure raises `error.communication` on this
  session's own internal queue instead (Decision 4: 3.12.2 names `<invoke>`
  outright as a communication-error source), through the private
  `invoke_error/4` resolver, and writes no table entry - "terminate the
  processing of the element without further action."

  A session started with `invoked_by: {parent_pid, invoke_id}` (an invoked
  child) monitors `parent_pid` in turn: the parent's `:DOWN` stops this
  session (a child whose parent is gone has nobody to report to), and a
  monitored child's own `:DOWN` pops its entry from `state.invocations` -
  both checked ahead of the ordinary subscriber `:DOWN` clause.

  ## Two snapshot shapes

  `snapshot/1` returns the whole `%MachineState{}` - the complete, resumable
  position tooling and replay need. `status/1` returns a small projection
  for a caller polling in a loop, since `snapshot/1` copies the entire
  compiled `machine` on every call. For a halted session, the projection's
  `configuration` is read from the retained `%Effect.Done{}` rather than
  `%MachineState{}.configuration`, which `exit_interpreter/1` empties by
  construction - mirroring the restore `test/support/case.ex` performs for
  the same reason.

  ## `interpret/2` is a public seam, not a test hook

  Decided by ADR-0029; see its own `@doc` for the recording contract it
  carries.

  ## Recording taps the input clauses, never the inbox

  `:record` (`start_link/2`) builds a `Statifier.Session.Recording.t()` that
  each of the five input-handling clauses appends one entry to, before that
  entry's effects are ever planned or performed - the same "one recordable
  input path" the converging-paths comment above `handle_info/2`'s fired-timer
  clause already describes. ADR-0029 named the
  four inputs a sound recording needs; ADR-0034 decided replay re-derives core
  effects and re-injects `interpret/2` batches rather than replaying against a
  live session, which is why the tap sits on the input side and not on the
  effect stream `notify/2` fans out. `recording/1` reads the value back; see
  its own `@doc` for the ordering caveat on when it is safe to call.
  """

  use GenServer, restart: :temporary

  alias Statifier.Effect
  alias Statifier.Effect.Done
  alias Statifier.Effect.Invoke
  alias Statifier.Event
  alias Statifier.Event.Cause
  alias Statifier.Interpreter
  alias Statifier.Invoke.Source
  alias Statifier.Machine
  alias Statifier.MachineState
  alias Statifier.Session.Effects
  alias Statifier.Session.Inbox
  alias Statifier.Session.Invocations
  alias Statifier.Session.Recording
  alias Statifier.Session.Target
  alias Statifier.Session.Timers

  defmodule State do
    @moduledoc false

    @enforce_keys [:machine_state, :session_id, :inbox, :timers]
    defstruct [
      :machine_state,
      :session_id,
      :done_effect,
      :inbox,
      :timers,
      :invoke_source,
      :invoked_by,
      timer_refs: %{},
      subscribers: %{},
      halted: nil,
      recording: nil,
      invocations: Invocations.new()
    ]

    @type t :: %__MODULE__{
            machine_state: Statifier.MachineState.t(),
            session_id: String.t(),
            done_effect: Statifier.Effect.Done.t() | nil,
            inbox: Statifier.Session.Inbox.t(),
            timers: Statifier.Session.Timers.t(),
            timer_refs: %{reference() => reference()},
            subscribers: %{pid() => reference()},
            halted: :done | :cancelled | :budget_exhausted | nil,
            recording: Statifier.Session.Recording.t() | nil,
            invocations: Statifier.Session.Invocations.t(),
            invoke_source: (String.t() -> {:ok, Machine.t()} | {:error, term()}) | nil,
            invoked_by: {pid(), String.t()} | nil
          }
  end

  @typedoc "A `GenServer` server reference - a pid, or whatever `:name` was started with."
  @type server :: GenServer.server()

  @typedoc """
  The small status projection `status/1` returns, as the counterpart to
  `snapshot/1`'s whole `%MachineState{}`.
  """
  @type status :: %{
          session_id: String.t(),
          status: :running | :done | :cancelled | :budget_exhausted,
          configuration: MapSet.t(String.t()),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer(),
          queued_events: non_neg_integer(),
          pending_timers: non_neg_integer()
        }

  # -- client -----------------------------------------------------------------

  @doc """
  Starts a session over `machine` (already compiled - `Statifier.compile/1`),
  running `Statifier.Interpreter.initialize/2` to quiescence before
  returning. A document that reaches a stable configuration, or even
  terminates, before any external event is ever sent is corpus-normal; the
  session comes up already `:running`, `:done`, or `:budget_exhausted`
  accordingly.

  `opts`:

    - `:name` - passed to `GenServer.start_link/3` unchanged, so
      `{:via, Registry, _}` works today with no code here.
    - `:session_id`, `:trace`, `:datamodel`, `:max_macrostep_rounds` -
      `Statifier.MachineState.new/2`'s own options, passed straight
      through. The session never generates the `sess_` id itself
      (ADR-0008); it reads it back off
      `machine_state.datamodel["_sessionid"]` once `new/2` has written it,
      since there is no `session_id` field on `%MachineState{}`.
    - `:subscribers` - pids to monitor and forward the effect stream to
      from the start (default `[]`); `subscribe/2` adds more afterward.
    - `:record` - when `true` (default `false`), builds a
      `Statifier.Session.Recording.t()` that captures every delivered event,
      timer firing, cancel marker, and `interpret/2` batch this session
      handles, in input order (ADR-0029). Read it back with `recording/1`.
    - `:invoke_source` - a `(src :: String.t() -> {:ok, Machine.t()} |
      {:error, term()})` function this session hands to
      `Statifier.Invoke.Source.resolve/2` for every `<invoke src="...">` it
      starts (ADR-0038). `nil` (the default) leaves every `src`-only
      invocation unresolved, per `Statifier.Invoke.Source`'s own contract.
    - `:invoked_by` - `{parent_pid, invoke_id}`, set by
      `Statifier.Session` itself when it starts a child for an `<invoke>`
      (never set by an ordinary caller). Makes this session monitor
      `parent_pid`, so a dead parent stops it in turn ("Starting an
      invocation's child session" above).
  """
  @spec start_link(machine :: Machine.t(), opts :: keyword()) :: GenServer.on_start()
  def start_link(%Machine{} = machine, opts \\ []) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {machine, opts}, gen_opts)
  end

  @doc "This session's `sess_` id - `datamodel[\"_sessionid\"]`, held apart for routing."
  @spec session_id(server :: server()) :: String.t()
  def session_id(server), do: GenServer.call(server, :session_id)

  @doc """
  The `Statifier.Session.Recording.t()` this session has captured so far, or
  `{:error, :not_recording}` if it was not started with `record: true`.

  Call this only after the run has quiesced relative to whatever this caller
  is waiting on - a timer firing arrives as a message with no ordering
  guarantee against this call, so a `recording/1` issued before an
  `assert_receive` on the effect it produced (or a `wait_for_status/3`-style
  poll) can race the entry it is meant to observe.
  """
  @spec recording(server :: server()) :: {:ok, Recording.t()} | {:error, :not_recording}
  def recording(server), do: GenServer.call(server, :recording)

  @doc """
  Delivers `event` to this session's external inbox (asynchronously - `:ok`
  is returned before the event is necessarily processed). A plain string is
  a convenience over `Statifier.Event.external/2` carrying no data; a
  caller that needs event data builds the `%Statifier.Event{}` directly.
  Queued behind whatever else is already waiting, and processed in that
  order.
  """
  @spec send_event(server :: server(), event :: Event.t() | String.t()) :: :ok
  def send_event(server, %Event{} = event) do
    GenServer.cast(server, {:enqueue_event, event})
  end

  def send_event(server, name) when is_binary(name), do: send_event(server, Event.external(name))

  @doc """
  Hands `effects` - any list of `Statifier.Effect.t()` values, from any
  driver of the pure core - to this session's own effect-interpretation
  path: planned through `Statifier.Session.Effects.plan/1` and performed
  exactly as the effects this session's own drive of the core produces.
  ADR-0003's "Embedders can supply their own effect interpreter", read the
  other way: an embedder that drives the core itself can still lean on this
  session for timer and routing service. It is also what makes
  `:send_delayed`/`:cancel` testable end to end before any document can
  produce them, and it funnels through the same internal cast path
  `send_event/2` uses, so it opens no side door around the inbox.

  **This widens what a recording has to contain** (ADR-0029). The
  three-input replay tuple - `(machine, initial data, external event
  log)` - reconstructs a run only when every effect this session
  interpreted came from `Statifier.Interpreter.initialize/2` or
  `handle_event/2`. An `interpret/2` call hands the session effects that no
  such call produced, so replaying a run that used it needs a fourth
  input: each `interpret/2` batch, recorded at its position in this
  session's serialized input order alongside the event log
  (`docs/observability.md` constraint 6). Calling this function does not
  void the replay guarantee - it obligates the recording. That is a
  statement about the recording's contents, not a leak in the boundary:
  the calls are still ordered, still observable, still on the one input
  path.
  """
  @spec interpret(server :: server(), effects :: [Effect.t()]) :: :ok
  def interpret(server, effects) when is_list(effects) do
    GenServer.cast(server, {:interpret, effects})
  end

  @doc """
  Enqueues the cancel marker onto this session's external inbox - a queue
  entry, not an out-of-band call, so a cancellation is recorded in the same
  ordered queue as every event: one queued behind several events is
  processed in that order, not ahead of them. Draining it runs
  `Statifier.Interpreter.cancel/1` - Appendix D's `running = false`
  followed by `exitInterpreter()` - and halts this session `:cancelled`.
  """
  @spec cancel(server :: server()) :: :ok
  def cancel(server), do: GenServer.cast(server, :enqueue_cancel)

  @doc """
  The whole `%Statifier.MachineState{}` this session currently holds - a
  complete, resumable position (`docs/observability.md` constraint 1). A
  term copy and nothing more: `MachineState` carries no pid, ref, port, or
  fun.
  """
  @spec snapshot(server :: server()) :: MachineState.t()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc """
  A small status projection - `session_id`, `status`, `configuration` (as
  string ids), the three step counters, and the queued-event and
  pending-timer counts - for a caller polling in a loop, since `snapshot/1`
  copies the entire compiled `machine` on every call. For a halted session,
  `configuration` is read from the retained `%Statifier.Effect.Done{}`
  rather than the (by-then-empty) `%MachineState{}.configuration`.
  """
  @spec status(server :: server()) :: status()
  def status(server), do: GenServer.call(server, :status)

  @doc """
  Adds `pid` to this session's monitored subscriber set. Idempotent - a
  pid already subscribed is not monitored twice.
  """
  @spec subscribe(server :: server(), pid :: pid()) :: :ok
  def subscribe(server, pid) when is_pid(pid), do: GenServer.call(server, {:subscribe, pid})

  @doc "Removes `pid` from this session's subscriber set. A no-op if it was never in it."
  @spec unsubscribe(server :: server(), pid :: pid()) :: :ok
  def unsubscribe(server, pid) when is_pid(pid), do: GenServer.call(server, {:unsubscribe, pid})

  @doc """
  Stops the session. `terminate/2` cancels every outstanding delayed-send
  timer before the process exits (spec 6.2's discard-on-termination), so
  nothing scheduled is ever delivered after this call returns.
  """
  @spec stop(server :: server(), reason :: term()) :: :ok
  def stop(server, reason \\ :normal), do: GenServer.stop(server, reason)

  # -- callbacks ----------------------------------------------------------

  @impl GenServer
  def init({%Machine{} = machine, opts}) do
    machine_opts = Keyword.take(opts, [:session_id, :trace, :datamodel, :max_macrostep_rounds])
    {machine_state, effects} = Interpreter.initialize(machine, machine_opts)

    subscribers =
      opts
      |> Keyword.get(:subscribers, [])
      |> Enum.reduce(%{}, fn pid, acc -> Map.put(acc, pid, Process.monitor(pid)) end)

    session_id = machine_state.datamodel["_sessionid"]
    register_session(session_id)

    recording =
      if Keyword.get(opts, :record, false) do
        Recording.new(machine, Keyword.put(machine_opts, :session_id, session_id))
      end

    invoked_by = Keyword.get(opts, :invoked_by)
    monitor_parent(invoked_by)

    state = %State{
      machine_state: machine_state,
      session_id: session_id,
      inbox: Inbox.new(),
      timers: Timers.new(),
      subscribers: subscribers,
      recording: recording,
      invocations: Invocations.new(),
      invoke_source: Keyword.get(opts, :invoke_source),
      invoked_by: invoked_by
    }

    {:ok, perform(state, effects), {:continue, :drain}}
  end

  # `invoked_by` is `nil` for every session started as a plain document (the
  # common case) and `{parent_pid, invoke_id}` for a child `Statifier.Session`
  # starts to serve an `<invoke>` ("Starting an invocation's child session",
  # this module's own moduledoc). Monitoring the parent here, rather than
  # leaving it to the parent's own side, is what makes a brutally-killed
  # parent take its children down (ADR-0027 decision 3): the child's own
  # `:DOWN` clause below stops it the moment that monitor fires.
  @spec monitor_parent(invoked_by :: {pid(), String.t()} | nil) :: :ok
  defp monitor_parent(nil), do: :ok

  defp monitor_parent({parent_pid, _invoke_id}) do
    Process.monitor(parent_pid)
    :ok
  end

  # ADR-0027 decision 2: registration happens here, not by a caller-supplied
  # `:name`, because the `sess_` id this session registers under does not
  # exist until `Interpreter.initialize/2` (above) has run - no `{:via,
  # ...}` tuple can name a session before it starts. There is no separate
  # `Statifier.Registry`-running check ahead of the call: `Registry.register/3`
  # itself raises when the named registry does not exist, and that raise is
  # rescued into the same no-op every other registration failure gets, so a
  # bare `start_link/2` embedder who never placed `Statifier.Supervisor`
  # stays legal and unregistered (the "bare `start_link/2`" section above)
  # through the same path as any other failure, not a second mechanism.
  # Failure is never fatal to the session: whether `Statifier.Registry`
  # was never started, crashed mid-call, or `session_id` somehow collides,
  # the session still starts, merely unreachable by id - exactly what an
  # unregistered session already is. Registration is a one-shot call made
  # here at `init/1` time only; a session that starts before
  # `Statifier.Supervisor` exists stays unregistered even if the runtime
  # is placed later, since nothing here retries it.
  @spec register_session(session_id :: String.t()) :: :ok
  defp register_session(session_id) do
    Registry.register(Statifier.Registry, session_id, nil)
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  # `mainEventLoop`'s dequeue tail (Appendix D), with `Statifier.Session.Inbox`
  # in place of the blocking `externalQueue.dequeue()`: while an entry is
  # waiting, drain it and continue; empty stops with no further work. A
  # `:cancel` entry is always drained, even while halted (a budget-halted
  # `%MachineState{}` is still `running`, so `Interpreter.cancel/1` still
  # succeeds) - an ordinary event is drained only while not halted, so it
  # stays queued rather than being silently dropped.
  @impl GenServer
  def handle_continue(:drain, state) do
    case Inbox.next(state.inbox) do
      :empty ->
        {:noreply, state}

      {:ok, :cancel, inbox} ->
        state = %{state | inbox: inbox} |> drain_cancel()
        {:noreply, state, {:continue, :drain}}

      {:ok, {:event, _event}, _inbox} when state.halted != nil ->
        {:noreply, state}

      {:ok, {:event, event}, inbox} ->
        state = %{state | inbox: inbox} |> drain_event(event)
        {:noreply, state, {:continue, :drain}}
    end
  end

  @impl GenServer
  def handle_call(:session_id, _from, state), do: {:reply, state.session_id, state}
  def handle_call(:snapshot, _from, state), do: {:reply, state.machine_state, state}
  def handle_call(:status, _from, state), do: {:reply, build_status(state), state}

  def handle_call(:recording, _from, %State{recording: nil} = state) do
    {:reply, {:error, :not_recording}, state}
  end

  def handle_call(:recording, _from, %State{recording: recording} = state) do
    {:reply, {:ok, recording}, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers =
      if Map.has_key?(state.subscribers, pid) do
        state.subscribers
      else
        Map.put(state.subscribers, pid, Process.monitor(pid))
      end

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    case Map.pop(state.subscribers, pid) do
      {nil, subscribers} ->
        {:reply, :ok, %{state | subscribers: subscribers}}

      {ref, subscribers} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | subscribers: subscribers}}
    end
  end

  @impl GenServer
  def handle_cast({:enqueue_event, event}, state) do
    state = record(state, &Recording.put_event(&1, event))
    {:noreply, %{state | inbox: Inbox.enqueue_event(state.inbox, event)}, {:continue, :drain}}
  end

  def handle_cast(:enqueue_cancel, state) do
    state = record(state, &Recording.put_cancel/1)
    {:noreply, %{state | inbox: Inbox.enqueue_cancel(state.inbox)}, {:continue, :drain}}
  end

  def handle_cast({:interpret, effects}, state) do
    state = record(state, &Recording.put_interpret(&1, effects))
    {:noreply, perform(state, effects), {:continue, :drain}}
  end

  # The fired-timer path (spec 6.2): forget the reference regardless of
  # whether this session is halted - a fired timer is gone either way - then
  # deliver by `route`, resolved now rather than at schedule time (6.2.3:
  # the route was decided when the `<send>` was *evaluated*, but a
  # cross-session target can only be *reached* once the timer actually
  # fires) - `deliver_fired/4` below. A `:self` route enqueues onto the
  # ordinary inbox exactly as `send_event/2` would, so a caller's send, a
  # self-targeted send re-enqueued from an effect, and a fired timer all
  # reach the core through the one recordable input path
  # (`docs/observability.md` constraint 6). `handle_continue/2`'s own halted
  # check decides whether it is drained now or stays queued.
  @impl GenServer
  def handle_info({:statifier_delayed_send, ref, send_id, route, event, effect}, state) do
    state = record(state, &Recording.put_timer(&1, send_id, event))

    state = %{
      state
      | timers: Timers.forget(state.timers, ref),
        timer_refs: Map.delete(state.timer_refs, ref)
    }

    state = deliver_fired(route, event, effect, state)

    {:noreply, state, {:continue, :drain}}
  end

  # This session's own invoking parent has gone down (`monitor_parent/1`'s
  # own comment) - a child with nobody to report to has nothing left to do.
  # Ahead of the general clause below on purpose: `pid` here is
  # `state.invoked_by`'s own parent pid, which is never also a subscriber or
  # an invocation this session started, so clause order never actually
  # picks between them for one `:DOWN` - but stating the parent case first
  # is what the moduledoc's own ordering claim documents.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %State{invoked_by: {pid, _id}} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Invocations.pop_by_pid(state.invocations, pid) do
      {{_invoke_id, _entry}, invocations} ->
        {:noreply, %{state | invocations: invocations}}

      {nil, _unchanged} ->
        case Map.get(state.subscribers, pid) do
          ^ref -> {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
          _other -> {:noreply, state}
        end
    end
  end

  # Spec 6.2: "If the SCXML session terminates before the delay interval has
  # elapsed, the SCXML Processor MUST discard the message without
  # attempting to deliver it." Every live timer this session ever scheduled
  # is cancelled here, `Statifier.Session.Timers.refs/1` in hand.
  @impl GenServer
  def terminate(_reason, state) do
    state.timers
    |> Timers.refs()
    |> Enum.each(fn ref ->
      case Map.get(state.timer_refs, ref) do
        nil -> :ok
        timer_ref -> Process.cancel_timer(timer_ref)
      end
    end)

    :ok
  end

  # -- draining -------------------------------------------------------------

  @spec drain_cancel(state :: State.t()) :: State.t()
  defp drain_cancel(state) do
    case Interpreter.cancel(state.machine_state) do
      {:ok, machine_state, effects} ->
        %{state | machine_state: machine_state}
        |> perform(effects, halt_override: :cancelled)

      # A race: something else already stopped the core (e.g. natural
      # termination reached it first). No crash, no further state change.
      {:error, :not_running} ->
        state
    end
  end

  @spec drain_event(state :: State.t(), event :: Event.t()) :: State.t()
  defp drain_event(state, event) do
    case Interpreter.handle_event(state.machine_state, event) do
      {:ok, machine_state, effects} ->
        %{state | machine_state: machine_state} |> perform(effects)

      {:error, :not_running} ->
        state
    end
  end

  # -- performing (Statifier.Session.Effects plans; this performs) --------

  @spec perform(state :: State.t(), effects :: [Effect.t()], opts :: keyword()) :: State.t()
  defp perform(state, effects, opts \\ []) do
    halt_override = Keyword.get(opts, :halt_override)

    effects
    |> Effects.plan(state.session_id)
    |> Enum.reduce(state, &perform_instruction(&1, &2, halt_override))
  end

  @spec perform_instruction(
          instruction :: Effects.instruction(),
          state :: State.t(),
          halt_override :: :cancelled | nil
        ) :: State.t()
  defp perform_instruction({:notify, {:done, %Done{}} = effect}, state, _override) do
    notify(state, {:effect, effect})
    %{state | done_effect: elem(effect, 1)}
  end

  defp perform_instruction({:notify, effect}, state, _override) do
    notify(state, {:effect, effect})
    state
  end

  defp perform_instruction({:enqueue_event, event}, state, _override) do
    %{state | inbox: Inbox.enqueue_event(state.inbox, event)}
  end

  # ADR-0039's re-entry seam: enqueue on the internal queue exactly as an
  # in-loop `raise` would, then run to quiescence. `:internal`
  # (`<send target="#_internal">`, a self-targeted `error.communication`
  # never - see `deliver/5` below) and `:platform`
  # (`error.execution`/`error.communication`) share this one door.
  defp perform_instruction({:raise, kind, name, origin, opts}, state, override) do
    deliver_internal(kind, name, origin, opts, state, override)
  end

  # A `<send>` whose route resolved to something other than `:self` (which
  # plans straight to `{:enqueue_event, _}` and never reaches here).
  defp perform_instruction({:deliver, route, event, effect}, state, override) do
    deliver(route, event, effect, state, override)
  end

  # The one `Process.send_after/3` call in the library. `ref` is a
  # correlation id this session mints itself and embeds in the message, so
  # the fired message can identify which entry to `Timers.forget/2` -
  # `Process.send_after/3` has no way to embed its own return value in the
  # message it delivers, since that value does not exist until the call
  # returns. `timer_ref`, the value `Process.cancel_timer/1` actually needs,
  # is kept in `timer_refs`, keyed by that same correlation id. `route` rides
  # along in the message unresolved - see `handle_info/2`'s own comment for
  # why resolution waits for the fire.
  defp perform_instruction({:schedule, send_id, delay_ms, route, event, effect}, state, _override) do
    ref = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:statifier_delayed_send, ref, send_id, route, event, effect},
        delay_ms
      )

    %{
      state
      | timers: Timers.put(state.timers, send_id, ref),
        timer_refs: Map.put(state.timer_refs, ref, timer_ref)
    }
  end

  defp perform_instruction({:cancel_timers, send_id}, state, _override) do
    {refs, timers} = Timers.take(state.timers, send_id)
    timer_refs = Enum.reduce(refs, state.timer_refs, &cancel_ref/2)
    %{state | timers: timers, timer_refs: timer_refs}
  end

  # 6.4's own body: resolve the child's source, seed its datamodel from the
  # name-matched `<param>`/namelist map, start it, and monitor it - or, on
  # any failure along the way, raise `error.communication` (Decision 4) and
  # write no table entry ("terminate the processing of the element without
  # further action"). `Statifier.Invoke.Source.resolve/2` and
  # `Statifier.start_session/2` are the two ways this can fail; both reach
  # `invoke_error/4` the same way, so a caller reading the effect stream
  # cannot (and need not) tell them apart.
  defp perform_instruction({:start_child, %Invoke{} = invoke, effect}, state, override) do
    case Source.resolve(invoke, invoke_source: state.invoke_source) do
      {:ok, machine} -> start_child(machine, invoke, effect, state, override)
      {:error, _reason} -> invoke_error(invoke, effect, state, override)
    end
  end

  defp perform_instruction({:unroutable, effect}, state, _override) do
    notify(state, {:unroutable, effect})
    state
  end

  defp perform_instruction({:halt, reason}, state, override) do
    reason = override || reason
    state = %{state | halted: reason}
    notify(state, {:halted, reason})
    state
  end

  # -- <invoke> starting -----------------------------------------------

  # `Source.resolve/2` succeeded: seed the child's datamodel (6.4.3), start
  # it on `Statifier.SessionSupervisor` with `invoked_by: {self(),
  # invoke.invoke_id}` (this module's own moduledoc, "Starting an
  # invocation's child session"), and record it in `state.invocations` on
  # success. `Statifier.start_session/2`'s own `{:error, _}` - most commonly
  # `Statifier.SessionSupervisor` not running - is Decision 4's other
  # failure path, handled identically to a `Source.resolve/2` failure.
  @spec start_child(
          machine :: Machine.t(),
          invoke :: Invoke.t(),
          effect :: Effect.t(),
          state :: State.t(),
          override :: :cancelled | nil
        ) :: State.t()
  defp start_child(machine, invoke, effect, state, override) do
    datamodel = Invocations.seed_datamodel(invoke.params, machine)

    case start_session(machine, invoke, datamodel) do
      {:ok, pid} ->
        entry = %{
          session_id: session_id(pid),
          pid: pid,
          monitor_ref: Process.monitor(pid),
          autoforward: invoke.autoforward == true
        }

        %{state | invocations: Invocations.put(state.invocations, invoke.invoke_id, entry)}

      {:error, _reason} ->
        invoke_error(invoke, effect, state, override)
    end
  end

  # `Statifier.start_session/2`'s own moduledoc promises `DynamicSupervisor.start_child/2`'s
  # `{:ok, pid} | {:error, term}` "most commonly `Statifier.SessionSupervisor`
  # itself not being started" - but `Statifier.SessionSupervisor` unstarted is
  # an *unregistered name*, and `GenServer.call/3` to one **exits** the caller
  # rather than returning `{:error, _}` (confirmed empirically: `Registry.lookup/2`
  # raises `ArgumentError` on the same condition, which is a different failure
  # shape from a `GenServer.call` to a name nothing is registered under).
  # `registry_lookup/1` below already exists to fold exactly this kind of
  # "no runtime placed" failure into `{:error, _}` for the registry; this does
  # the same for the session-start call, so a bare parent (no
  # `Statifier.Supervisor` anywhere) reaches `invoke_error/4` above instead of
  # crashing.
  @spec start_session(machine :: Machine.t(), invoke :: Invoke.t(), datamodel :: map()) ::
          {:ok, pid()} | {:error, term()}
  defp start_session(machine, invoke, datamodel) do
    Statifier.start_session(machine,
      invoked_by: {self(), invoke.invoke_id},
      datamodel: datamodel
    )
  catch
    :exit, reason -> {:error, reason}
  end

  # Decision 4's `error.communication` write: the same ADR-0037
  # `deliver_internal/5` door `communication_error/4` uses, with `<invoke>`'s
  # own origin (`{:invoke, state_index, invoke_index}`, spec 3.12.2's
  # "arising from `<send>` and `<invoke>`") and no `sendid` - there is no
  # triggering `<send>` here to name one. `effect` is accepted but unused:
  # the origin is built from `invoke` alone, kept as a parameter for the same
  # symmetry `communication_error/4`'s own signature has with its caller.
  @spec invoke_error(
          invoke :: Invoke.t(),
          effect :: Effect.t(),
          state :: State.t(),
          override :: :cancelled | nil
        ) :: State.t()
  defp invoke_error(invoke, _effect, state, override) do
    deliver_internal(
      :platform,
      "error.communication",
      {:invoke, invoke.state_index, invoke.invoke_index},
      [],
      state,
      override
    )
  end

  # -- <send> routing --------------------------------------------------

  # `:internal` resolves through the ADR-0039 seam with no registry needed at
  # all. `{:session, sid}` where `sid == state.session_id` is the clause
  # that needs no registry either: a session is accessible to itself whether
  # or not it is registered (decision 10), which narrows ADR-0027 decision
  # 2's "an unregistered session is an inaccessible one" - that sentence is
  # about reachability *by other sessions* - and is recorded as a
  # consequence in `docs/adr/0027-embedder-placed-session-runtime.md`. Every
  # other `{:session, sid}` resolves through `Statifier.Registry`
  # (`registry_lookup/1`): a hit casts onto that session's inbox, an empty
  # lookup takes C.1's mandated `error.communication` path via
  # `communication_error/4`. `:parent` and `{:invoke, _}` are still
  # unresolvable in this phase - there is no invocation table yet - so each
  # takes the same `communication_error/4` path, which a later bead changes
  # without touching this clause.
  @spec deliver(
          route :: Target.route(),
          event :: Event.t(),
          effect :: Effect.t(),
          state :: State.t(),
          override :: :cancelled | nil
        ) :: State.t()
  defp deliver(:internal, event, effect, state, override) do
    deliver_internal(
      :internal,
      event.name,
      origin_of(effect),
      [data: event.data, sendid: event.sendid],
      state,
      override
    )
  end

  defp deliver({:session, sid}, event, _effect, %State{session_id: sid} = state, _override) do
    %{state | inbox: Inbox.enqueue_event(state.inbox, event)}
  end

  defp deliver({:session, sid}, event, effect, state, override) do
    case registry_lookup(sid) do
      [{pid, _value}] ->
        send_event(pid, event)
        state

      [] ->
        communication_error(event, effect, state, override)
    end
  end

  defp deliver(:parent, event, effect, state, override) do
    communication_error(event, effect, state, override)
  end

  defp deliver({:invoke, _invokeid}, event, effect, state, override) do
    communication_error(event, effect, state, override)
  end

  # A delayed send's route is resolved only once the timer actually fires
  # (`handle_info/2`'s own comment) - `:self` is the one route
  # `deliver/5` above does not carry (an immediate `:self` send plans
  # straight to `{:enqueue_event, _}` and never reaches `deliver/5` at all),
  # so it gets its own clause here; every other route reuses `deliver/5`
  # unchanged.
  @spec deliver_fired(
          route :: Target.route(),
          event :: Event.t(),
          effect :: Effect.t(),
          state :: State.t()
        ) :: State.t()
  defp deliver_fired(:self, event, _effect, state) do
    %{state | inbox: Inbox.enqueue_event(state.inbox, event)}
  end

  defp deliver_fired(route, event, effect, state), do: deliver(route, event, effect, state, nil)

  # `Registry.lookup/2` raises `ArgumentError` when `Statifier.Registry`
  # itself is not running (no ETS table backs a registry nobody started),
  # which is exactly the "no runtime placed" case a bare `start_link/2`
  # sender is allowed to be in - so that raise is caught and folded into the
  # same empty-lookup shape a live registry returns for an unknown or dead
  # id. Both arrive at `communication_error/4` the same way; the caller
  # cannot tell "no registry" from "registry, but nothing there" apart, per
  # C.1's "does not exist or is inaccessible".
  @spec registry_lookup(sid :: String.t()) :: [{pid(), term()}]
  defp registry_lookup(sid) do
    Registry.lookup(Statifier.Registry, sid)
  rescue
    ArgumentError -> []
  end

  # C.1's mandated path for a route this phase cannot resolve: "a session
  # that does not exist or is inaccessible" -> `error.communication` on the
  # *sending* session's own internal queue, carrying the failing send's
  # `sendid`. One private resolver so a later bead's registry/invocation
  # table changes this function, not the `{:deliver, ...}` clause or the
  # planner.
  @spec communication_error(
          event :: Event.t(),
          effect :: Effect.t(),
          state :: State.t(),
          override :: :cancelled | nil
        ) :: State.t()
  defp communication_error(event, effect, state, override) do
    deliver_internal(
      :platform,
      "error.communication",
      origin_of(effect),
      [sendid: event.sendid],
      state,
      override
    )
  end

  # The one call site of `Interpreter.deliver_internal/5` - records the
  # call (ADR-0029, `docs/observability.md` constraint 6) before making it,
  # then performs whatever effects it returns exactly as `drain_event/2`
  # does. `{:error, :not_running}` is a no-op: a halted session has no queue
  # to raise onto.
  @spec deliver_internal(
          kind :: Effects.raise_kind(),
          name :: String.t(),
          origin :: Cause.origin(),
          opts :: keyword(),
          state :: State.t(),
          override :: :cancelled | nil
        ) :: State.t()
  defp deliver_internal(kind, name, origin, opts, state, override) do
    state = record(state, &Recording.put_internal(&1, kind, name, origin, opts))

    case Interpreter.deliver_internal(state.machine_state, kind, name, origin, opts) do
      {:ok, machine_state, effects} ->
        %{state | machine_state: machine_state} |> perform(effects, halt_override: override)

      {:error, :not_running} ->
        state
    end
  end

  # `Statifier.Effect.Send.owner/0`/`c_index` and
  # `Statifier.Effect.SendDelayed`'s own copies name the block that emitted
  # this send - the same identity `Statifier.Event.Cause.origin/0`'s
  # `{:content, c_index, owner}` arm already carries for every other
  # content-raised event.
  @spec origin_of(effect :: Effect.t()) :: Cause.origin()
  defp origin_of({:send, %Effect.Send{c_index: c_index, owner: owner}}),
    do: {:content, c_index, owner}

  defp origin_of({:send_delayed, %Effect.SendDelayed{c_index: c_index, owner: owner}}),
    do: {:content, c_index, owner}

  @spec cancel_ref(ref :: reference(), timer_refs :: %{reference() => reference()}) ::
          %{reference() => reference()}
  defp cancel_ref(ref, timer_refs) do
    case Map.pop(timer_refs, ref) do
      {nil, timer_refs} ->
        timer_refs

      {timer_ref, timer_refs} ->
        Process.cancel_timer(timer_ref)
        timer_refs
    end
  end

  @spec notify(state :: State.t(), message :: term()) :: :ok
  defp notify(state, message) do
    payload = {:statifier, state.session_id, message}
    Enum.each(state.subscribers, fn {pid, _ref} -> send(pid, payload) end)
    :ok
  end

  # A session started without `record: true` carries `recording: nil` and
  # pays only its call site's closure and this one clause match per input,
  # leaving the state untouched; a recording session hands its current value
  # through `append` and keeps the result.
  @spec record(state :: State.t(), append :: (Recording.t() -> Recording.t())) :: State.t()
  defp record(%State{recording: nil} = state, _append), do: state

  defp record(%State{recording: recording} = state, append) do
    %{state | recording: append.(recording)}
  end

  # -- status/1 -------------------------------------------------------------

  @spec build_status(state :: State.t()) :: status()
  defp build_status(state) do
    {status, configuration} = status_and_configuration(state)
    machine_state = state.machine_state

    %{
      session_id: state.session_id,
      status: status,
      configuration: translate_configuration(machine_state.machine, configuration),
      macrostep: machine_state.macrostep,
      microstep: machine_state.microstep,
      round: machine_state.round,
      queued_events: Inbox.size(state.inbox),
      pending_timers: Timers.count(state.timers)
    }
  end

  # `:done` and `:cancelled` both reach exit_interpreter/1, which empties
  # `configuration` by construction - the restore
  # `test/support/case.ex:23-32` performs, mirrored here. `:budget_exhausted`
  # never touches `exit_interpreter/1`, so its `%MachineState{}.configuration`
  # is still the live, resumable position (ADR-0019).
  @spec status_and_configuration(state :: State.t()) ::
          {:running | :done | :cancelled | :budget_exhausted, MapSet.t(non_neg_integer())}
  defp status_and_configuration(%State{halted: nil, machine_state: machine_state}) do
    {:running, machine_state.configuration}
  end

  defp status_and_configuration(%State{halted: reason, done_effect: %Done{configuration: config}})
       when reason in [:done, :cancelled] do
    {reason, config}
  end

  defp status_and_configuration(%State{halted: :budget_exhausted, machine_state: machine_state}) do
    {:budget_exhausted, machine_state.configuration}
  end

  @spec translate_configuration(machine :: Machine.t(), configuration :: MapSet.t()) ::
          MapSet.t(String.t())
  defp translate_configuration(machine, configuration) do
    configuration
    |> Enum.map(&Machine.id(machine, &1))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end
end
