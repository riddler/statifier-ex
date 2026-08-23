defmodule Statifier.Session.Telemetry do
  @moduledoc """
  The `Statifier.Session`-pinned view of `Statifier.Telemetry` (ADR-0067
  decision 2): every function here forwards to the caller-agnostic emitter
  with `driver: :session` pinned, so the nine functions 2.0.0 published keep
  their arities and keep working unchanged for existing consumers.

  The authoritative event contract - the full `@moduledoc` table, every
  measurement/metadata shape, the location-resolution rule, and the
  per-driver applicability table - now lives on `Statifier.Telemetry`. This
  module carries no copy of it.

  This module is superseded in documentation by `Statifier.Telemetry`;
  whether it is removed is a 3.0 question, not this record's (ADR-0067 open
  question 3). It is not `@deprecated`: this repo has no `@deprecated`
  precedent, and every function here still behaves exactly as documented.
  """

  alias Statifier.{Effect, Machine, MachineState, Telemetry}

  @doc """
  Every event name `Statifier.Session` can emit - delegates to
  `Statifier.Telemetry.events/0`, which is the same 27 names.
  """
  @spec events() :: [Telemetry.event_name()]
  defdelegate events(), to: Telemetry

  @doc "Emits `[:statifier, :session, :init]` with `driver: :session`."
  @spec init(
          session_id :: String.t(),
          machine :: Machine.t(),
          machine_state :: MachineState.t(),
          invoked_by :: {pid(), String.t()} | nil,
          resumed :: boolean()
        ) :: :ok
  def init(session_id, machine, machine_state, invoked_by, resumed) do
    Telemetry.init(:session, session_id, machine, machine_state, invoked_by, resumed)
  end

  @doc "Emits `[:statifier, :session, :halt]` with `driver: :session`."
  @spec halt(
          session_id :: String.t(),
          reason :: :done | :cancelled | :budget_exhausted,
          machine_state :: MachineState.t()
        ) :: :ok
  def halt(session_id, reason, machine_state) do
    Telemetry.halt(:session, session_id, reason, machine_state)
  end

  @doc "Emits `[:statifier, :session, :terminate]` with `driver: :session`."
  @spec terminate(
          session_id :: String.t(),
          reason :: term(),
          status :: term(),
          machine_state :: MachineState.t()
        ) :: :ok
  def terminate(session_id, reason, status, machine_state) do
    Telemetry.terminate(:session, session_id, reason, status, machine_state)
  end

  @doc """
  Emits `[:statifier, :session, :macrostep, :start]` with `driver: :session`.
  """
  @spec macrostep_start(
          session_id :: String.t(),
          trigger :: :initialize | :event | :cancel | :internal | :resume,
          event :: Statifier.Event.t() | nil,
          span_ref :: reference()
        ) :: :ok
  def macrostep_start(session_id, trigger, event, span_ref) do
    Telemetry.macrostep_start(:session, session_id, trigger, event, span_ref)
  end

  @doc """
  Emits `[:statifier, :session, :macrostep, :stop]` with `driver: :session`.
  """
  @spec macrostep_stop(
          session_id :: String.t(),
          trigger :: :initialize | :event | :cancel | :internal | :resume,
          machine_state :: MachineState.t(),
          event :: Statifier.Event.t() | nil,
          outcome :: :quiescent | :done | :cancelled | :budget_exhausted,
          start_time :: integer(),
          span_ref :: reference()
        ) :: :ok
  def macrostep_stop(session_id, trigger, machine_state, event, outcome, start_time, span_ref) do
    Telemetry.macrostep_stop(
      :session,
      session_id,
      trigger,
      machine_state,
      event,
      outcome,
      start_time,
      span_ref
    )
  end

  @doc "Emits `[:statifier, :session, :interpret]` with `driver: :session`."
  @spec interpret(
          session_id :: String.t(),
          effect_count :: non_neg_integer(),
          machine_state :: MachineState.t()
        ) :: :ok
  def interpret(session_id, effect_count, machine_state) do
    Telemetry.interpret(:session, session_id, effect_count, machine_state)
  end

  @doc """
  Emits `[:statifier, :session, :effect, kind]` or
  `[:statifier, :session, :trace, kind]` with `driver: :session`, dispatching
  on `effect`'s own tag.
  """
  @spec effect(session_id :: String.t(), machine :: Machine.t(), effect :: Effect.t()) :: :ok
  def effect(session_id, machine, effect) do
    Telemetry.effect(:session, session_id, machine, effect)
  end

  @doc """
  Emits `[:statifier, :session, :unroutable]` with `driver: :session` for an
  effect the session could not route.
  """
  @spec unroutable(session_id :: String.t(), machine :: Machine.t(), effect :: Effect.t()) :: :ok
  def unroutable(session_id, machine, effect) do
    Telemetry.unroutable(:session, session_id, machine, effect)
  end
end
