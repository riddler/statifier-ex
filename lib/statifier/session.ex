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

  ## No supervision tree, no registry, in this bead

  `start_link/2` and the `use GenServer`-generated `child_spec/1` are the
  whole of it: an embedder places a session in their own supervision tree,
  and `:name` is passed to `GenServer.start_link/3` unchanged, so
  `{:via, Registry, _}` works today with no code here. `use GenServer,
  restart: :transient` is written explicitly because the generated
  `child_spec/1` otherwise defaults to `restart: :permanent`, which would
  have an embedder's supervisor restart a session that halted normally -
  the opposite of the next section.

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

  ## Absent-target routing only

  A `<send>`/`<send_delayed>` with no `target` lands on this session's own
  external queue, per `Statifier.Event.internal/3`'s own `@doc`. Every
  other target - `#_internal` included - plans as `{:unroutable, effect}`
  and is forwarded, never guessed and never a crash. `:invoke`,
  `:cancel_invoke`, and `:autoforward` plan the same way today: there is no
  child session to route any of them to yet. `#_internal` resolution,
  `#_parent`, `#_scxml_<sessionid>`, and external URI targets are a later
  bead's work; see `Statifier.Session.Effects`.

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
  """

  use GenServer, restart: :transient

  alias Statifier.Effect
  alias Statifier.Effect.Done
  alias Statifier.Event
  alias Statifier.Interpreter
  alias Statifier.Machine
  alias Statifier.MachineState
  alias Statifier.Session.Effects
  alias Statifier.Session.Inbox
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
      timer_refs: %{},
      subscribers: %{},
      halted: nil
    ]

    @type t :: %__MODULE__{
            machine_state: Statifier.MachineState.t(),
            session_id: String.t(),
            done_effect: Statifier.Effect.Done.t() | nil,
            inbox: Statifier.Session.Inbox.t(),
            timers: Statifier.Session.Timers.t(),
            timer_refs: %{reference() => reference()},
            subscribers: %{pid() => reference()},
            halted: :done | :cancelled | :budget_exhausted | nil
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
      through. The session never generates the `sess_` UXID itself
      (ADR-0008); it reads it back off
      `machine_state.datamodel["_sessionid"]` once `new/2` has written it,
      since there is no `session_id` field on `%MachineState{}`.
    - `:subscribers` - pids to monitor and forward the effect stream to
      from the start (default `[]`); `subscribe/2` adds more afterward.
  """
  @spec start_link(machine :: Machine.t(), opts :: keyword()) :: GenServer.on_start()
  def start_link(%Machine{} = machine, opts \\ []) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {machine, opts}, gen_opts)
  end

  @doc "This session's `sess_` UXID - `datamodel[\"_sessionid\"]`, held apart for routing."
  @spec session_id(server :: server()) :: String.t()
  def session_id(server), do: GenServer.call(server, :session_id)

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

    state = %State{
      machine_state: machine_state,
      session_id: machine_state.datamodel["_sessionid"],
      inbox: Inbox.new(),
      timers: Timers.new(),
      subscribers: subscribers
    }

    {:ok, perform(state, effects), {:continue, :drain}}
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
    {:noreply, %{state | inbox: Inbox.enqueue_event(state.inbox, event)}, {:continue, :drain}}
  end

  def handle_cast(:enqueue_cancel, state) do
    {:noreply, %{state | inbox: Inbox.enqueue_cancel(state.inbox)}, {:continue, :drain}}
  end

  def handle_cast({:interpret, effects}, state) do
    {:noreply, perform(state, effects), {:continue, :drain}}
  end

  # The fired-timer path (spec 6.2): forget the reference regardless of
  # whether this session is halted - a fired timer is gone either way - then
  # enqueue its event onto the ordinary inbox exactly as `send_event/2`
  # would, so a caller's send, a self-targeted send re-enqueued from an
  # effect, and a fired timer all reach the core through the one recordable
  # input path (`docs/observability.md` constraint 6). `handle_continue/2`'s
  # own halted check decides whether it is drained now or stays queued.
  @impl GenServer
  def handle_info({:statifier_delayed_send, ref, _send_id, event}, state) do
    state = %{
      state
      | timers: Timers.forget(state.timers, ref),
        timer_refs: Map.delete(state.timer_refs, ref),
        inbox: Inbox.enqueue_event(state.inbox, event)
    }

    {:noreply, state, {:continue, :drain}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.subscribers, pid) do
      ^ref -> {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
      _other -> {:noreply, state}
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
    |> Effects.plan()
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

  # The one `Process.send_after/3` call in the library. `ref` is a
  # correlation id this session mints itself and embeds in the message, so
  # the fired message can identify which entry to `Timers.forget/2` -
  # `Process.send_after/3` has no way to embed its own return value in the
  # message it delivers, since that value does not exist until the call
  # returns. `timer_ref`, the value `Process.cancel_timer/1` actually needs,
  # is kept in `timer_refs`, keyed by that same correlation id.
  defp perform_instruction({:schedule, send_id, delay_ms, event}, state, _override) do
    ref = make_ref()

    timer_ref =
      Process.send_after(self(), {:statifier_delayed_send, ref, send_id, event}, delay_ms)

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
