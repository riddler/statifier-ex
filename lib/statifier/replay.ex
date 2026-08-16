defmodule Statifier.Replay do
  @moduledoc """
  Re-drives a `Statifier.Session.Recording` through the pure core, with no
  process and no timer (ADR-0034).

  ## The reuse boundary

  `run/1` reuses every *deciding* component a live `Statifier.Session`
  uses, unchanged: `Statifier.Interpreter.initialize/2`,
  `Statifier.Interpreter.handle_event/2`, `Statifier.Interpreter.cancel/1`,
  `Statifier.Session.Effects.plan/1`, and `Statifier.Session.Inbox`. This
  module's `drain/1` mirrors `Statifier.Session`'s
  `handle_continue(:drain, _)` line for line, and its `perform/2` mirrors
  `perform_instruction/3` for four of the seven instruction kinds
  `Statifier.Session.Effects.instruction()` names:
  `{:notify, effect}`, `{:enqueue_event, event}`, `{:unroutable, effect}`,
  and `{:halt, reason}` are handled exactly as the live session handles
  them.

  The other three - `{:schedule, ...}`, and the process-facing halves of
  `{:notify, ...}`/`{:unroutable, ...}` that `send/2` to subscribers - are
  the ones `lib/statifier/session.ex` performs by calling
  `Process.send_after/3` or delivering to a subscriber process. This module
  is not a process and has no subscribers, so it records what those
  instructions mean instead of performing them: a `{:schedule, ...}`
  becomes a pending-timer credit rather than a real `Process.send_after/3`
  call, and every `{:notify, ...}`/`{:unroutable, ...}` becomes a message
  appended to `result().stream` instead of a `send/2`. Everything above
  that line (deciding what to do) is reused byte for byte; everything below
  it (performing it against a real process and a real clock) is replaced,
  which is exactly the split `lib/statifier/session.ex`'s own moduledoc
  documents and ADR-0003 is the warrant for (ADR-0034).

  ## Why replacing `{:schedule, ...}` dissolves the double-delivery seam

  A live session's `{:schedule, ...}` clause arms a real
  `Process.send_after/3` timer. Feeding a recording that already holds both
  the `{:interpret, effects}` entry that scheduled a `:send_delayed` and the
  later `{:timer, send_id, event}` entry recording its firing into a *live*
  session would arm a second, real timer on top of the firing already
  waiting in the recording - delivering the event twice. This module never
  arms a timer at all: `{:schedule, send_id, _delay_ms, _event}` only
  increments a plain count under `send_id` in `pending`, and a
  `{:timer, send_id, event}` entry draws one credit from that count before
  enqueuing the event. Each recorded firing is therefore delivered exactly
  once, at its recorded position (ADR-0034 decision 1).

  `pending` and `raced` are plain `%{send_id() => non_neg_integer()}` count
  maps rather than `Statifier.Session.Timers`, which is keyed by
  `reference()` - minting a reference here would be the one impure call in
  a module whose entire claim is purity. Counts are sufficient because
  replay never cancels a *real* timer and never needs to correlate a firing
  to the specific arming that produced it; spec 6.3's "cancel them all" is a
  whole-key move either way. `nil` (an unnamed `send_delayed`) is a
  legitimate key in both maps.

  A `{:cancel_timers, send_id}` instruction does not delete `send_id`'s
  pending count - it moves the whole count from `pending` into `raced`.
  This models `Process.cancel_timer/1` returning `false` when the delay has
  already elapsed and the delayed-send message is already sitting in the
  live session's mailbox: the cancel does not unsend it, and
  `lib/statifier/session.ex`'s `handle_info/2` enqueues it unconditionally
  when it arrives. A recording can therefore legitimately hold a
  `{:timer, send_id, event}` entry *after* the `{:cancel, ...}` effect that
  cancelled that same id - the cancel and the fire raced, and the fire won.
  A firing draws credit from `pending` first and `raced` second, delivered
  normally either way; only a firing with credit in neither map means the
  recording is inconsistent with the machine it is being replayed against,
  which `run/1` reports as `{:error, {:unscheduled_timer_firing, send_id}}`
  rather than silently proceeding.

  ## `{:deliver, ...}`/`{:raise, ...}` defer to the recorded `{:internal, ...}` entry

  A live session's `{:raise, ...}` instruction and every `{:deliver, ...}`
  route except a self-addressed `{:session, sid}` reach
  `Statifier.Interpreter.deliver_internal/5` through
  `Statifier.Session`'s own private seam, and every one of those calls is
  recorded as an `{:internal, kind, name, origin, opts}` entry
  (ADR-0039, ADR-0029) at its own position in the session's serialized
  input order - interleaved with, not nested inside, the entry that
  triggered it. Performing the delivery again while re-deriving that
  triggering entry's own effects would raise the same internal event twice,
  so this module's `perform_instruction/3` clauses for `{:raise, ...}` and
  `{:deliver, ...}` (other than the self-match) are no-ops: the *only*
  place `Interpreter.deliver_internal/5` is called from this module is
  `apply_entry/2`'s own `{:internal, ...}` clause, walking the recording's
  flat entry list. A self-addressed `{:session, sid}` needs no recorded
  entry at all and resolves locally by plain equality against
  `state.machine_state.datamodel["_sessionid"]`, deterministically, with no
  registry involved live or in replay (decision 10) - the same reason
  `Statifier.Session`'s own resolver never calls `deliver_internal/5` for
  that one route either.

  ## No Appendix D function is reimplemented

  Every state transition this module performs is a call into
  `Statifier.Interpreter` or `Statifier.Session.Effects`; nothing here
  duplicates a pseudocode-named function under a new name. `drain/1` is the
  one loop this module owns, and it is not part of Appendix D itself - it is
  this codebase's own port of `mainEventLoop`'s dequeue tail
  (`lib/statifier/session.ex:350-374`'s own comment), reused here with a
  `Statifier.Session.Inbox` in place of a process mailbox, exactly as the
  live session already reuses it in place of the blocking
  `externalQueue.dequeue()`.
  """

  alias Statifier.Effect
  alias Statifier.Effect.Done
  alias Statifier.Effect.Invoke
  alias Statifier.Event
  alias Statifier.Interpreter
  alias Statifier.MachineState
  alias Statifier.Session.Effects
  alias Statifier.Session.Inbox
  alias Statifier.Session.Recording

  defmodule State do
    @moduledoc false

    @enforce_keys [:machine_state, :inbox]
    defstruct [
      :machine_state,
      :inbox,
      done_effect: nil,
      halted: nil,
      stream: [],
      pending: %{},
      raced: %{},
      live_invoke_ids: MapSet.new()
    ]

    @type t :: %__MODULE__{
            machine_state: MachineState.t(),
            inbox: Inbox.t(),
            done_effect: Done.t() | nil,
            halted: Statifier.Replay.halt_reason() | nil,
            stream: [Statifier.Replay.message()],
            pending: %{(String.t() | nil) => non_neg_integer()},
            raced: %{(String.t() | nil) => non_neg_integer()},
            live_invoke_ids: MapSet.t(String.t())
          }
  end

  @typedoc "The three ways a replayed run can come to a stop, mirroring `Statifier.Session`'s `halted`."
  @type halt_reason :: :done | :cancelled | :budget_exhausted

  @typedoc "One replayed stream message - the subscriber shapes, envelope stripped."
  @type message ::
          {:effect, Effect.t()} | {:unroutable, Effect.t()} | {:halted, halt_reason()}

  @typedoc "What `run/1` returns on success: the terminal position, the replayed stream, and its status."
  @type result :: %{
          machine_state: MachineState.t(),
          stream: [message()],
          status: :running | halt_reason()
        }

  @doc """
  Replays `recording` from scratch: `Statifier.Interpreter.initialize/2`
  over `Recording.machine/1` and `Recording.opts/1`, then folds
  `Recording.entries/1` in order, draining after each one exactly as the
  live session that produced the recording did.

  Returns `{:error, {:unscheduled_timer_firing, send_id}}` the moment a
  `{:timer, send_id, _event}` entry has no credit in either the `pending`
  or `raced` bookkeeping - see the moduledoc for what that means and the
  one legitimate case (the cancel/fire race) it does not misfire on.
  """
  @spec run(recording :: Recording.t()) ::
          {:ok, result()} | {:error, {:unscheduled_timer_firing, String.t() | nil}}
  def run(recording) do
    {machine_state, effects} =
      Interpreter.initialize(Recording.machine(recording), Recording.opts(recording))

    state =
      %State{machine_state: machine_state, inbox: Inbox.new()}
      |> perform(effects)
      |> drain()

    recording
    |> Recording.entries()
    |> Enum.reduce_while(state, fn entry, state ->
      case apply_entry(entry, state) do
        {:ok, state} -> {:cont, state}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      %State{} = state -> {:ok, to_result(state)}
      {:error, _reason} = error -> error
    end
  end

  # -- entries --------------------------------------------------------------

  @spec apply_entry(entry :: Recording.entry(), state :: State.t()) ::
          {:ok, State.t()} | {:error, {:unscheduled_timer_firing, String.t() | nil}}
  defp apply_entry({:event, %Event{invokeid: id} = event}, state) do
    if id != nil and not MapSet.member?(state.live_invoke_ids, id) do
      # Decision 6's replay half: the live session discarded this event at
      # drain time (`lib/statifier/session.ex`'s own `handle_continue(:drain,
      # _)` clause) before it was ever recorded as delivered to the core, so
      # a sound recording never actually needed this branch - but a
      # recording captured by an older build, or hand-built in a test, can
      # still carry one. Skipping it here rather than draining it is what
      # keeps a discarded-event recording replaying to the same
      # configuration the live run reached (ADR-0034's round-trip
      # obligation), instead of the two disagreeing about what the core saw.
      {:ok, state}
    else
      {:ok, %{state | inbox: Inbox.enqueue_event(state.inbox, event)} |> drain()}
    end
  end

  defp apply_entry(:cancel, state) do
    {:ok, %{state | inbox: Inbox.enqueue_cancel(state.inbox)} |> drain()}
  end

  defp apply_entry({:interpret, effects}, state) when is_list(effects) do
    {:ok, state |> perform(effects) |> drain()}
  end

  # Mirrors the `{:event, _}` clause above: re-enter through the ADR-0039
  # seam, then drain to quiescence. Not an error-only path - Phase 4 routes
  # ordinary `<send target="#_internal">` through the same seam, so an
  # entirely successful run produces these entries too (see the moduledoc's
  # "defer to the recorded entry" section for why this is the *only* place
  # `Interpreter.deliver_internal/5` is called from this module).
  defp apply_entry({:internal, kind, name, origin, opts}, state) do
    {:ok, state |> perform_internal(kind, name, origin, opts) |> drain()}
  end

  defp apply_entry({:timer, send_id, %Event{} = event}, state) do
    case draw_credit(state, send_id) do
      {:ok, state} ->
        {:ok, %{state | inbox: Inbox.enqueue_event(state.inbox, event)} |> drain()}

      :error ->
        {:error, {:unscheduled_timer_firing, send_id}}
    end
  end

  @spec draw_credit(state :: State.t(), send_id :: String.t() | nil) ::
          {:ok, State.t()} | :error
  defp draw_credit(state, send_id) do
    with :error <- take_credit(state, :pending, send_id) do
      take_credit(state, :raced, send_id)
    end
  end

  @spec take_credit(state :: State.t(), map_key :: :pending | :raced, send_id :: String.t() | nil) ::
          {:ok, State.t()} | :error
  defp take_credit(state, map_key, send_id) do
    counts = Map.fetch!(Map.from_struct(state), map_key)

    case Map.get(counts, send_id, 0) do
      n when n > 1 -> {:ok, Map.put(state, map_key, Map.put(counts, send_id, n - 1))}
      1 -> {:ok, Map.put(state, map_key, Map.delete(counts, send_id))}
      0 -> :error
    end
  end

  # -- draining (mirrors `Statifier.Session`'s `handle_continue(:drain, _)`
  # line for line - `lib/statifier/session.ex:357-374`) -------------------

  @spec drain(state :: State.t()) :: State.t()
  defp drain(state) do
    case Inbox.next(state.inbox) do
      :empty ->
        state

      {:ok, :cancel, inbox} ->
        %{state | inbox: inbox} |> drain_cancel() |> drain()

      {:ok, {:event, _event}, _inbox} when state.halted != nil ->
        state

      {:ok, {:event, event}, inbox} ->
        %{state | inbox: inbox} |> drain_event(event) |> drain()
    end
  end

  @spec drain_cancel(state :: State.t()) :: State.t()
  defp drain_cancel(state) do
    case Interpreter.cancel(state.machine_state) do
      {:ok, machine_state, effects} ->
        %{state | machine_state: machine_state}
        |> perform(effects, halt_override: :cancelled)

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

  # `apply_entry/2`'s `{:internal, ...}` clause's own body - the one call
  # site of `Interpreter.deliver_internal/5` in this module (see the
  # moduledoc's "defer to the recorded entry" section).
  @spec perform_internal(
          state :: State.t(),
          kind :: :internal | :platform,
          name :: String.t(),
          origin :: term(),
          opts :: keyword()
        ) :: State.t()
  defp perform_internal(state, kind, name, origin, opts) do
    case Interpreter.deliver_internal(state.machine_state, kind, name, origin, opts) do
      {:ok, machine_state, effects} ->
        %{state | machine_state: machine_state} |> perform(effects)

      {:error, :not_running} ->
        state
    end
  end

  # -- performing (Statifier.Session.Effects plans; this records instead of
  # performing - see the moduledoc's reuse-boundary section) --------------

  @spec perform(state :: State.t(), effects :: [Effect.t()], opts :: keyword()) :: State.t()
  defp perform(state, effects, opts \\ []) do
    halt_override = Keyword.get(opts, :halt_override)

    effects
    |> Effects.plan(state.machine_state.datamodel["_sessionid"])
    |> Enum.reduce(state, &perform_instruction(&1, &2, halt_override))
  end

  @spec perform_instruction(
          instruction :: Effects.instruction(),
          state :: State.t(),
          halt_override :: halt_reason() | nil
        ) :: State.t()
  defp perform_instruction({:notify, {:done, %Done{}} = effect}, state, _override) do
    state = append(state, {:effect, effect})
    %{state | done_effect: elem(effect, 1)}
  end

  defp perform_instruction({:notify, effect}, state, _override) do
    append(state, {:effect, effect})
  end

  defp perform_instruction({:enqueue_event, event}, state, _override) do
    %{state | inbox: Inbox.enqueue_event(state.inbox, event)}
  end

  # Deferred to the corresponding recorded `{:internal, ...}` entry - see the
  # moduledoc's "defer to the recorded entry" section. Performing it here too
  # would raise the same internal event twice.
  defp perform_instruction({:raise, _kind, _name, _origin, _opts}, state, _override) do
    state
  end

  # The one route that needs no recorded entry: a session addressing
  # *itself* resolves by plain equality, deterministically, with no registry
  # involved live or in replay (decision 10) - the same reason
  # `Statifier.Session`'s own resolver never calls `deliver_internal/5` for
  # this route either.
  defp perform_instruction({:deliver, {:session, sid}, event, _effect}, state, _override) do
    if sid == state.machine_state.datamodel["_sessionid"] do
      %{state | inbox: Inbox.enqueue_event(state.inbox, event)}
    else
      state
    end
  end

  # `:internal`, `:parent`, and `{:invoke, _}` - deferred to the
  # corresponding recorded `{:internal, ...}` entry, same reason as the
  # `{:raise, ...}` clause above.
  defp perform_instruction({:deliver, _route, _event, _effect}, state, _override) do
    state
  end

  defp perform_instruction(
         {:schedule, send_id, _delay_ms, _route, _event, _effect},
         state,
         _override
       ) do
    %{state | pending: Map.update(state.pending, send_id, 1, &(&1 + 1))}
  end

  defp perform_instruction({:cancel_timers, send_id}, state, _override) do
    case Map.pop(state.pending, send_id) do
      {nil, pending} ->
        %{state | pending: pending}

      {count, pending} ->
        %{state | pending: pending, raced: Map.update(state.raced, send_id, count, &(&1 + count))}
    end
  end

  # A child process is not replayable (ADR-0034): every contribution it made
  # to the parent's run is already in the recorded event log, reached
  # through the parent's own `{:internal, ...}`/`{:event, ...}` entries, not
  # through re-starting the child. The `{:notify, effect}` instruction
  # always planned ahead of this one (`Statifier.Session.Effects.plan_one/2`)
  # has already appended the `{:invoke, _}` effect itself to `stream`; this
  # clause starts no process, but it does add `invoke.invoke_id` to
  # `live_invoke_ids` (Decision 6) - the same live-invocation set a real
  # session keeps in `Statifier.Session.Invocations`, re-derived here from
  # the same `{:start_child, _, _}`/`{:stop_child, _}` instructions this
  # module already folds, so a recorded `{:event, %Event{invokeid: id}}`
  # discards identically on replay (see `apply_entry/2`'s `{:event, _}`
  # clause below).
  defp perform_instruction(
         {:start_child, %Invoke{invoke_id: invoke_id}, _effect},
         state,
         _override
       ) do
    %{state | live_invoke_ids: MapSet.put(state.live_invoke_ids, invoke_id)}
  end

  # `{:cancel_invoke, _}`'s own performed half (Decision 6): a live session
  # pops its `Invocations` table entry here; this module has no table, so it
  # removes `invoke_id` from `live_invoke_ids` instead - the same predicate
  # change, with no process to cancel.
  defp perform_instruction({:stop_child, invoke_id}, state, _override) do
    %{state | live_invoke_ids: MapSet.delete(state.live_invoke_ids, invoke_id)}
  end

  # Autoforward delivery is a live-process action (`Statifier.Session`
  # `send_event/2`s the child, unmodified) with nothing to replay against - a
  # replayed run has no live child, and every contribution the child made to
  # the parent's run is already in the recorded event log, the same reason
  # `{:start_child, _, _}` above starts nothing. The `{:notify, effect}`
  # instruction planned ahead of this one has already appended the
  # `{:autoforward, _}` effect itself to `stream`.
  defp perform_instruction({:forward, _invoke_id, _event}, state, _override) do
    state
  end

  defp perform_instruction({:unroutable, effect}, state, _override) do
    append(state, {:unroutable, effect})
  end

  defp perform_instruction({:halt, reason}, state, override) do
    reason = override || reason
    state = %{state | halted: reason}
    append(state, {:halted, reason})
  end

  @spec append(state :: State.t(), message :: message()) :: State.t()
  defp append(state, message), do: %{state | stream: [message | state.stream]}

  # -- result -----------------------------------------------------------------

  @spec to_result(state :: State.t()) :: result()
  defp to_result(state) do
    %{
      machine_state: state.machine_state,
      stream: Enum.reverse(state.stream),
      status: state.halted || :running
    }
  end
end
