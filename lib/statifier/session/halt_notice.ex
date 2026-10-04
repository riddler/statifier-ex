defmodule Statifier.Session.HaltNotice do
  @moduledoc """
  The halt notice a session sends to the processes a send processor starts
  from `c:Statifier.Send.Processor.perform/2`, such as the timer that holds
  a delayed send (ADR-0069 decision 4: the processor owns the delay).

  Spec 6.2 asks that a delayed send be discarded when its session
  terminates before the delay elapses. A session's status can be `:done`,
  `:cancelled` or `:budget_exhausted` while its process is still alive, so a
  timer cannot tell from the process alone, and asking the session with a
  call can time out while the session is busy. Instead, a processor hands
  the process it starts to `watch/2` from inside `perform/2`, which a
  `Statifier.Session` runs in its own process, and the session sends that
  process

      {:statifier_halted, session, reason}

  when it halts, `session` being the session's pid and `reason` one of
  `:done`, `:cancelled` or `:budget_exhausted`. A process watched after the
  session has halted is sent the notice at once. The session never calls
  a watched process and never waits on it.

  The session also keeps the watched process under the key the processor
  gave it, so the processor can `take/1` the processes held under a key
  (to cancel them, say), and forgets each one when it ends.

  Outside a `Statifier.Session` (a host that performs instructions in its
  own process), there is no session to send the notice: `watch/2` keeps
  nothing and answers `:not_a_session`, and `take/1` answers `[]`.
  """

  @session_key {__MODULE__, :session}
  @watched_key {__MODULE__, :watched}

  @typedoc "Why the session halted, as its status names it."
  @type reason :: :done | :cancelled | :budget_exhausted

  @typedoc "The message a watched process is sent when its session halts."
  @type notice :: {:statifier_halted, session :: pid(), reason()}

  @doc """
  Watches `pid` under `key` for the session performing the current
  instruction: the session sends `pid` a `t:notice/0` when it halts, or at
  once when it has already halted, and keeps `pid` under `key` until `pid`
  ends or is taken with `take/1`.

  Call it from `c:Statifier.Send.Processor.perform/2`, which a session runs
  in its own process. Answers `:not_a_session`, keeping nothing, when the
  calling process is not a `Statifier.Session`.
  """
  @spec watch(key :: term(), pid :: pid()) :: :ok | :not_a_session
  def watch(key, pid) when is_pid(pid) do
    case Process.get(@session_key) do
      nil ->
        :not_a_session

      status ->
        # The session forgets the watched process when its `:DOWN` arrives
        # (ADR-0003: the session process, never the pure core, monitors it).
        ref = Process.monitor(pid)
        Process.put(@watched_key, Map.put(watched(), ref, {key, pid}))
        notify_halted(status, [pid])
        :ok
    end
  end

  @doc """
  Removes and answers every process watched under `key` in the calling
  session; a taken process is sent no notice. Answers `[]` outside
  a session or when none is held under `key`.
  """
  @spec take(key :: term()) :: [pid()]
  def take(key) do
    case Enum.split_with(watched(), &match?({_ref, {^key, _pid}}, &1)) do
      # Nothing taken, nothing written: outside a session the caller's
      # dictionary keeps no watched table, as the moduledoc says.
      {[], _kept} ->
        []

      {taken, kept} ->
        Process.put(@watched_key, Map.new(kept))

        Enum.map(taken, fn {ref, {_key, pid}} ->
          # ADR-0069 decision 4: a taken process is no longer the session's to forget.
          Process.demonitor(ref, [:flush])
          pid
        end)
    end
  end

  @doc false
  # `Statifier.Session.init/1`: marks the calling process as a running
  # session, so `watch/2` keeps what it is handed.
  @spec mark_session() :: :ok
  def mark_session do
    Process.put(@session_key, :running)
    :ok
  end

  @doc false
  # `Statifier.Session`'s halt: every watched process is sent the notice,
  # and a process watched later is sent it at once.
  @spec halted(reason :: reason()) :: :ok
  def halted(reason) do
    Process.put(@session_key, {:halted, reason})
    notify_halted({:halted, reason}, Enum.map(watched(), fn {_ref, {_key, pid}} -> pid end))
  end

  @doc false
  # `Statifier.Session.handle_info/2`'s `:DOWN` for a monitor it does not
  # otherwise own: answers `true` when `ref` was a watched process's, which
  # is then forgotten.
  @spec forget(ref :: reference()) :: boolean()
  def forget(ref) do
    case Map.pop(watched(), ref) do
      {nil, _watched} ->
        false

      {_entry, watched} ->
        Process.put(@watched_key, watched)
        true
    end
  end

  @spec watched() :: %{reference() => {term(), pid()}}
  defp watched, do: Process.get(@watched_key, %{})

  @spec notify_halted(status :: :running | {:halted, reason()}, pids :: [pid()]) :: :ok
  defp notify_halted(:running, _pids), do: :ok

  defp notify_halted({:halted, reason}, pids) do
    # ADR-0069 decision 4: the notice is a message, never a call, so a busy
    # watched process never holds the session.
    Enum.each(pids, &send(&1, {:statifier_halted, self(), reason}))
  end
end
