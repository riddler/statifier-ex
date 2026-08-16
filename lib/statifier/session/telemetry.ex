defmodule Statifier.Session.Telemetry do
  @moduledoc """
  The `:telemetry` bridge (ADR-0040) - the single authoritative reference for
  every `[:statifier, :session, ...]` event `Statifier.Session` can emit.
  `Statifier.Session` is the ADR-0003 effect interpreter; this module is the
  emission half of that role, split out only because `.doctor.exs`'s 100%
  Doctor bar puts the event contract in a `@moduledoc` a consumer can read
  without opening the source (ADR-0040's "the session boundary is two
  files"). It holds no state, drives no core function, and is called from
  nowhere but `Statifier.Session`.

  `events/0` returns every name below, built from the same literal-atom lists
  the emitters use, so a consumer can `:telemetry.attach_many/4` to the whole
  surface without hand-copying names out of this table.

  ## Measurements are numbers, metadata is everything else

  Every measurement is a number - `:telemetry_metrics`-aggregatable. Every
  identity - a session id, an effect struct, a resolved location, and every
  constraint-3 index (`state_index`, `t_index`, `c_index`, `invoke_index`) -
  is metadata, including the ones that happen to be integers: an opaque
  index has no numeric meaning to average.

  A `configuration` in metadata (on `:halt`, on the `:macrostep, :stop` event,
  and on the `:effect, :done`/`:trace, :done` events below) is translated
  from the raw `MapSet.t(non_neg_integer())` the machine state or the
  `Done`/`Trace.Done` payload's own `configuration` field carries into a
  `MapSet.t(String.t())` of state ids via `Statifier.Machine.id/2`, so a
  subscriber never needs a `Machine` handle to read a configuration out of an
  event - including the terminal one, where `MachineState.configuration` is
  already empty and the payload's own field is the only carrier left.

  ## Span correlation

  The macrostep span's start and stop halves both carry `span_ref`, a
  `make_ref/0` reference generated once per span and passed unchanged from
  `macrostep_start/4` to the matching `macrostep_stop/7` - the
  `telemetry_span_context` convention `:telemetry.span/3` uses, so a
  subscriber (including an OTel bridge) pairs a span's two halves on
  `span_ref` rather than on `(session_id, macrostep)`, which is unusable for
  this because `macrostep` is not stable across the span (below) and ADR-0039
  re-entry can nest an `:internal` span inside an `:event` span already in
  flight, producing `start, start, stop, stop` with no other way to tell
  which start belongs to which stop. Each span - including a nested one - gets
  its own `span_ref`. Both halves also carry `monotonic_time`
  (`System.monotonic_time/0`), matching `:telemetry_metrics`/OTel convention.

  The start half deliberately carries no `macrostep`. The counter this span
  opens against advances *inside* the core call the span brackets
  (`MachineState.begin_macrostep/1`, called from `Interpreter.handle_event/2`
  among others), so a `macrostep` read at the start half can be the
  pre-increment value while the stop half reports the post-increment one -
  the two would silently disagree on a pairing key. `span_ref` is the
  correlation mechanism; the stop half is the only place `macrostep` is
  authoritative for this span.

  This bridge hand-rolls the span pair rather than calling
  `:telemetry.span/3`: that helper wraps its span function in a `rescue`, so
  it always emits a matching `:exception` event, and this bridge has no
  `:exception` half to offer (below) - forwarding decisions the session's
  `perform/3` already made deterministically, not evaluating one under a
  `rescue` of its own would invent a failure mode the session does not have.

  ## Two consumer-facing caveats

  There is deliberately no fourth, `:exception`-named member of the
  `:macrostep` span family alongside `:start`/`:stop` (previous section): a
  crash mid-span - inside `perform/3`, say - leaves that span's start
  unmatched by any stop. A subscriber pairing on `span_ref` should not expect
  every `span_ref` it sees on a start to arrive again on a stop.

  The `:initialize` span's start event is emitted *after*
  `Interpreter.initialize/2` has already returned (`Statifier.Session.init/1`
  needs the `machine_state` that call produces before it can call
  `Statifier.Session.Telemetry.init/4`, which happens first), so its
  `system_time` is not the wall-clock instant the span actually opened at,
  even though `duration` on the matching stop is still measured from a
  `System.monotonic_time/0` reading taken before that call.

  ## Locations are resolved at emission, for single-index effects only

  An effect carrying exactly one resolvable index gets `metadata.location`,
  resolved through `Statifier.Machine.content/2`, `Statifier.Machine.at/2`,
  or `Statifier.Machine.transition/2` as appropriate, and carried as the
  `%Statifier.Parser.Location{}` struct verbatim. An effect with no index, or
  an index field present but `nil`, carries no `location` key at all - a key
  that can never hold a value is contract noise a consumer would otherwise
  have to learn to ignore, so it is simply absent rather than present and
  `nil`. An effect carrying a *list* of indexes carries the list in metadata
  (nested in the `effect` struct) and its length as a `size` measurement,
  with no `location` key - resolving one location per list entry would put
  an O(configuration) `Machine` walk on every microstep of a high-volume
  traced run, for a value a consumer with the index list and a `Machine`
  handle can already compute. The one exception is a singleton list:
  `Trace.TransitionsSelected` with exactly one `t_indexes` entry - the
  overwhelmingly common traced case - resolves that one index through
  `Statifier.Machine.transition/2` exactly as the single-index rule above,
  because a one-element list costs the same O(1) lookup a bare index would;
  the O(configuration) argument only bites a genuine list. With zero or many
  entries, `Trace.TransitionsSelected` carries no `location` key either.
  `cond_location` is never resolved: no effect in the vocabulary is emitted
  from guard evaluation.

  ## Lifecycle and span events (7), emitted regardless of `trace`

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier, :session, :init]` | `system_time` | `session_id`, `machine_name`, `trace`, `invoked_by` |
  | `[:statifier, :session, :halt]` | `macrostep`, `microstep`, `round` | `session_id`, `reason`, `configuration` |
  | `[:statifier, :session, :terminate]` | `macrostep`, `microstep`, `round` | `session_id`, `reason`, `status` |
  | `[:statifier, :session, :macrostep, :start]` | `system_time`, `monotonic_time` | `session_id`, `trigger`, `event_name`, `span_ref` |
  | `[:statifier, :session, :macrostep, :stop]` | `duration`, `macrostep`, `microsteps`, `rounds`, `monotonic_time` | `session_id`, `trigger`, `outcome`, `event_name`, `configuration`, `span_ref` |
  | `[:statifier, :session, :interpret]` | `effect_count`, `macrostep`, `microstep` | `session_id` |
  | `[:statifier, :session, :unroutable]` | `macrostep`, `microstep` | `session_id`, `effect`, `target`, `send_id`, `location` |

  `[:statifier, :session, :unroutable]` names a routing failure the session
  itself detected (the `{:unroutable, effect}` instruction), not an effect
  the core produced - a consumer alerting on it wants one name to attach to
  rather than a filter across the nine effect names below.

  `[:statifier, :session, :terminate]` fires from `terminate/2` and is
  therefore subject to the GenServer contract: it does not fire on a brutal
  kill. `:halt` is the event to build a "session finished" metric on.

  `duration` (on `:macrostep, :stop`) is `:native` units, per `:telemetry`'s
  own convention - unit conversion (`System.convert_time_unit/3`) is left to
  the consumer.

  ## Core effect events (9), emitted regardless of `trace`

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier, :session, :effect, :send]` | `macrostep`, `microstep` | `session_id`, `effect`, `location`, `send_id`, `target`, `c_index`, `owner` |
  | `[:statifier, :session, :effect, :send_delayed]` | `macrostep`, `microstep`, `delay_ms` | `session_id`, `effect`, `location`, `send_id`, `target`, `c_index`, `owner` |
  | `[:statifier, :session, :effect, :cancel]` | `macrostep`, `microstep` | `session_id`, `effect`, `location`, `send_id`, `c_index`, `owner` |
  | `[:statifier, :session, :effect, :invoke]` | `macrostep`, `microstep` | `session_id`, `effect`, `location`, `invoke_id`, `state_index`, `invoke_index` |
  | `[:statifier, :session, :effect, :cancel_invoke]` | `macrostep`, `microstep` | `session_id`, `effect`, `location`, `invoke_id`, `state_index` |
  | `[:statifier, :session, :effect, :autoforward]` | `macrostep`, `microstep` | `session_id`, `effect`, `location`, `invoke_id`, `state_index` |
  | `[:statifier, :session, :effect, :budget_exhausted]` | `macrostep`, `microstep`, `round`, `budget` | `session_id`, `effect`, `location` |
  | `[:statifier, :session, :effect, :done]` | `macrostep`, `microstep` | `session_id`, `effect`, `location`, `configuration` |
  | `[:statifier, :session, :effect, :log]` | `macrostep`, `microstep` | `session_id`, `effect`, `location`, `label`, `c_index`, `owner` |

  ## Trace effect events (9), emitted only under `trace: true`

  The trace family vanishes **in the core**, not at this bridge:
  `Statifier.Effect.trace/3` expands to no effect at all when
  `machine_state.trace` is `false`, so there is nothing here to forward.
  This module contains no `if trace` of its own.

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:statifier, :session, :trace, :event_dequeued]` | `macrostep`, `microstep`, `round` | `session_id`, `effect` |
  | `[:statifier, :session, :trace, :transitions_selected]` | `macrostep`, `microstep`, `round`, `size` | `session_id`, `effect`, `location` (singleton `t_indexes` only) |
  | `[:statifier, :session, :trace, :exit_set]` | `macrostep`, `microstep`, `round`, `size` | `session_id`, `effect` |
  | `[:statifier, :session, :trace, :content_executed]` | `macrostep`, `microstep`, `round`, `size` | `session_id`, `effect` |
  | `[:statifier, :session, :trace, :entry_set]` | `macrostep`, `microstep`, `round`, `size` | `session_id`, `effect` |
  | `[:statifier, :session, :trace, :macrostep_stable]` | `macrostep`, `microstep`, `round` | `session_id`, `effect` |
  | `[:statifier, :session, :trace, :done]` | `macrostep`, `microstep`, `round` | `session_id`, `effect`, `configuration` |
  | `[:statifier, :session, :trace, :invoke_pass]` | `macrostep`, `microstep`, `round`, `size` | `session_id`, `effect` |
  | `[:statifier, :session, :trace, :finalize_autoforward]` | `macrostep`, `microstep`, `round` | `session_id`, `effect` |

  `kind` (the fourth segment) is derived by a private, multi-clause function
  pattern-matching each `Statifier.Effect.Trace.*` struct to a literal atom -
  never `Module.split/1` composed with `String.to_atom/1`, which
  `Credo.Check.Warning.UnsafeToAtom` forbids and which would make this
  module's event list impossible to enumerate ahead of a call.
  """

  alias Statifier.Effect
  alias Statifier.Effect.Autoforward
  alias Statifier.Effect.BudgetExhausted
  alias Statifier.Effect.Cancel
  alias Statifier.Effect.CancelInvoke
  alias Statifier.Effect.Done
  alias Statifier.Effect.Invoke
  alias Statifier.Effect.Log
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Effect.Trace
  alias Statifier.Machine
  alias Statifier.MachineState

  @typedoc "One `:telemetry` event name this module can emit."
  @type event_name :: [atom(), ...]

  @typedoc "One of the nine core effect payload structs (`Statifier.Effect.core/0`, unwrapped)."
  @type core_payload ::
          Send.t()
          | SendDelayed.t()
          | Cancel.t()
          | Invoke.t()
          | CancelInvoke.t()
          | Autoforward.t()
          | BudgetExhausted.t()
          | Done.t()
          | Log.t()

  @typedoc "One of the nine trace payload structs (`Statifier.Effect.trace/0`, unwrapped)."
  @type trace_payload ::
          Trace.EventDequeued.t()
          | Trace.TransitionsSelected.t()
          | Trace.ExitSet.t()
          | Trace.ContentExecuted.t()
          | Trace.EntrySet.t()
          | Trace.MacrostepStable.t()
          | Trace.Done.t()
          | Trace.InvokePass.t()
          | Trace.FinalizeAutoforward.t()

  @lifecycle_events [
    [:statifier, :session, :init],
    [:statifier, :session, :halt],
    [:statifier, :session, :terminate],
    [:statifier, :session, :macrostep, :start],
    [:statifier, :session, :macrostep, :stop],
    [:statifier, :session, :interpret],
    [:statifier, :session, :unroutable]
  ]

  @effect_kinds [
    :send,
    :send_delayed,
    :cancel,
    :invoke,
    :cancel_invoke,
    :autoforward,
    :budget_exhausted,
    :done,
    :log
  ]

  @trace_kinds [
    :event_dequeued,
    :transitions_selected,
    :exit_set,
    :content_executed,
    :entry_set,
    :macrostep_stable,
    :done,
    :invoke_pass,
    :finalize_autoforward
  ]

  @doc """
  Every event name this module can ever emit - the 7 lifecycle/span names,
  the 9 `[:statifier, :session, :effect, kind]` names, and the 9
  `[:statifier, :session, :trace, kind]` names, built from
  `@lifecycle_events`/`@effect_kinds`/`@trace_kinds`, the module's single
  definition site for the vocabulary.
  """
  @spec events() :: [event_name()]
  def events do
    @lifecycle_events ++
      Enum.map(@effect_kinds, &[:statifier, :session, :effect, &1]) ++
      Enum.map(@trace_kinds, &[:statifier, :session, :trace, &1])
  end

  @doc "Emits `[:statifier, :session, :init]`."
  @spec init(
          session_id :: String.t(),
          machine :: Machine.t(),
          machine_state :: MachineState.t(),
          invoked_by :: {pid(), String.t()} | nil
        ) :: :ok
  def init(session_id, machine, machine_state, invoked_by) do
    :telemetry.execute(
      [:statifier, :session, :init],
      %{system_time: System.system_time()},
      %{
        session_id: session_id,
        machine_name: machine.name,
        trace: machine_state.trace,
        invoked_by: invoked_by
      }
    )
  end

  @doc "Emits `[:statifier, :session, :halt]`."
  @spec halt(
          session_id :: String.t(),
          reason :: :done | :cancelled | :budget_exhausted,
          machine_state :: MachineState.t()
        ) :: :ok
  def halt(session_id, reason, machine_state) do
    :telemetry.execute(
      [:statifier, :session, :halt],
      %{
        macrostep: machine_state.macrostep,
        microstep: machine_state.microstep,
        round: machine_state.round
      },
      %{session_id: session_id, reason: reason, configuration: configuration_ids(machine_state)}
    )
  end

  @doc "Emits `[:statifier, :session, :terminate]`."
  @spec terminate(
          session_id :: String.t(),
          reason :: term(),
          status :: term(),
          machine_state :: MachineState.t()
        ) :: :ok
  def terminate(session_id, reason, status, machine_state) do
    :telemetry.execute(
      [:statifier, :session, :terminate],
      %{
        macrostep: machine_state.macrostep,
        microstep: machine_state.microstep,
        round: machine_state.round
      },
      %{session_id: session_id, reason: reason, status: status}
    )
  end

  @doc """
  Emits `[:statifier, :session, :macrostep, :start]`. `span_ref` is a
  `make_ref/0` reference generated once by the caller and passed unchanged
  to the matching `macrostep_stop/7` - the pairing mechanism a subscriber
  needs (Decision 2 below), since `macrostep` cannot serve that role here:
  the counter this span opens against advances *inside* the core call the
  span brackets, so the start half is emitted before the increment and the
  stop half after it. Carrying the pre-increment value on start would look
  paired with the wrong stop on every span whose trigger's core call
  advances the counter (`:event`, and any other trigger with the same
  shape); carrying the post-increment value on start would require reading
  it out of a machine state the start half does not otherwise need. Rather
  than pick one and leave the other case's start event silently wrong, the
  start half carries no `macrostep` at all - `span_ref` is the only
  correlation mechanism, and it is exact by construction.
  """
  @spec macrostep_start(
          session_id :: String.t(),
          trigger :: :initialize | :event | :cancel | :internal,
          event :: Statifier.Event.t() | nil,
          span_ref :: reference()
        ) :: :ok
  def macrostep_start(session_id, trigger, event, span_ref) do
    :telemetry.execute(
      [:statifier, :session, :macrostep, :start],
      %{system_time: System.system_time(), monotonic_time: System.monotonic_time()},
      %{
        session_id: session_id,
        trigger: trigger,
        event_name: event_name(event),
        span_ref: span_ref
      }
    )
  end

  @doc """
  Emits `[:statifier, :session, :macrostep, :stop]`. `start_time` is a
  `System.monotonic_time/0` reading taken at the matching
  `macrostep_start/4`; `duration` is the difference, in `:native` units.
  `span_ref` is the same reference passed to that `macrostep_start/4` call,
  carried again here so a subscriber can pair this stop with its start
  (Decision 2) - nested spans (an `:internal` span opened by ADR-0039
  re-entry inside an `:event` span already in flight) each get their own
  reference, so `start, start, stop, stop` is disambiguated by `span_ref`
  rather than by call order.
  """
  @spec macrostep_stop(
          session_id :: String.t(),
          trigger :: :initialize | :event | :cancel | :internal,
          machine_state :: MachineState.t(),
          event :: Statifier.Event.t() | nil,
          outcome :: :quiescent | :done | :cancelled | :budget_exhausted,
          start_time :: integer(),
          span_ref :: reference()
        ) :: :ok
  def macrostep_stop(session_id, trigger, machine_state, event, outcome, start_time, span_ref) do
    :telemetry.execute(
      [:statifier, :session, :macrostep, :stop],
      %{
        duration: System.monotonic_time() - start_time,
        macrostep: machine_state.macrostep,
        microsteps: machine_state.microstep,
        rounds: machine_state.round,
        monotonic_time: System.monotonic_time()
      },
      %{
        session_id: session_id,
        trigger: trigger,
        outcome: outcome,
        event_name: event_name(event),
        configuration: configuration_ids(machine_state),
        span_ref: span_ref
      }
    )
  end

  @doc "Emits `[:statifier, :session, :interpret]`."
  @spec interpret(
          session_id :: String.t(),
          effect_count :: non_neg_integer(),
          machine_state :: MachineState.t()
        ) :: :ok
  def interpret(session_id, effect_count, machine_state) do
    :telemetry.execute(
      [:statifier, :session, :interpret],
      %{
        effect_count: effect_count,
        macrostep: machine_state.macrostep,
        microstep: machine_state.microstep
      },
      %{session_id: session_id}
    )
  end

  @doc """
  Emits `[:statifier, :session, :effect, kind]` or
  `[:statifier, :session, :trace, kind]`, dispatching on `effect`'s own tag.
  `machine` resolves `location` per the moduledoc's single-index rule.
  """
  @spec effect(session_id :: String.t(), machine :: Machine.t(), effect :: Effect.t()) :: :ok
  def effect(session_id, machine, {:trace, payload}) do
    kind = trace_kind(payload)
    {measurements, extra} = trace_shape(machine, payload)

    :telemetry.execute(
      [:statifier, :session, :trace, kind],
      measurements,
      base_metadata(session_id, payload, extra)
    )
  end

  def effect(session_id, machine, {kind, payload}) do
    {measurements, extra} = core_shape(machine, payload)

    :telemetry.execute(
      [:statifier, :session, :effect, kind],
      measurements,
      base_metadata(session_id, payload, extra)
    )
  end

  @doc "Emits `[:statifier, :session, :unroutable]` for an effect the session could not route."
  @spec unroutable(session_id :: String.t(), machine :: Machine.t(), effect :: Effect.t()) :: :ok
  def unroutable(session_id, machine, {_kind, payload}) do
    :telemetry.execute(
      [:statifier, :session, :unroutable],
      %{macrostep: payload.macrostep, microstep: payload.microstep},
      %{
        session_id: session_id,
        effect: payload,
        target: Map.get(payload, :target),
        send_id: Map.get(payload, :send_id),
        location: location(machine, payload)
      }
    )
  end

  # -- shape builders ---------------------------------------------------

  @spec base_metadata(session_id :: String.t(), payload :: struct(), extra :: map()) :: map()
  defp base_metadata(session_id, payload, extra) do
    Map.merge(%{session_id: session_id, effect: payload}, extra)
  end

  @spec core_shape(machine :: Machine.t(), payload :: core_payload()) :: {map(), map()}
  defp core_shape(machine, %Send{} = send) do
    {%{macrostep: send.macrostep, microstep: send.microstep},
     %{
       location: location(machine, send),
       send_id: send.send_id,
       target: send.target,
       c_index: send.c_index,
       owner: send.owner
     }}
  end

  defp core_shape(machine, %SendDelayed{} = send) do
    {%{macrostep: send.macrostep, microstep: send.microstep, delay_ms: send.delay_ms},
     %{
       location: location(machine, send),
       send_id: send.send_id,
       target: send.target,
       c_index: send.c_index,
       owner: send.owner
     }}
  end

  defp core_shape(machine, %Cancel{} = cancel) do
    {%{macrostep: cancel.macrostep, microstep: cancel.microstep},
     %{
       location: location(machine, cancel),
       send_id: cancel.send_id,
       c_index: cancel.c_index,
       owner: cancel.owner
     }}
  end

  defp core_shape(machine, %Invoke{} = invoke) do
    {%{macrostep: invoke.macrostep, microstep: invoke.microstep},
     %{
       location: location(machine, invoke),
       invoke_id: invoke.invoke_id,
       state_index: invoke.state_index,
       invoke_index: invoke.invoke_index
     }}
  end

  defp core_shape(machine, %CancelInvoke{} = cancel_invoke) do
    {%{macrostep: cancel_invoke.macrostep, microstep: cancel_invoke.microstep},
     %{
       location: location(machine, cancel_invoke),
       invoke_id: cancel_invoke.invoke_id,
       state_index: cancel_invoke.state_index
     }}
  end

  defp core_shape(machine, %Autoforward{} = autoforward) do
    {%{macrostep: autoforward.macrostep, microstep: autoforward.microstep},
     %{
       location: location(machine, autoforward),
       invoke_id: autoforward.invoke_id,
       state_index: autoforward.state_index
     }}
  end

  defp core_shape(machine, %BudgetExhausted{} = budget_exhausted) do
    {%{
       macrostep: budget_exhausted.macrostep,
       microstep: budget_exhausted.microstep,
       round: budget_exhausted.round,
       budget: budget_exhausted.budget
     }, %{location: location(machine, budget_exhausted)}}
  end

  defp core_shape(machine, %Done{} = done) do
    {%{macrostep: done.macrostep, microstep: done.microstep},
     %{
       location: location(machine, done),
       configuration: resolve_configuration(machine, done.configuration)
     }}
  end

  defp core_shape(machine, %Log{} = log) do
    {%{macrostep: log.macrostep, microstep: log.microstep},
     %{location: location(machine, log), label: log.label, c_index: log.c_index, owner: log.owner}}
  end

  @spec trace_shape(machine :: Machine.t(), payload :: trace_payload()) :: {map(), map()}
  defp trace_shape(_machine, %Trace.EventDequeued{} = payload) do
    {counters(payload), %{}}
  end

  # Singleton carve-out (ADR-0040 Decision 4, amended): a one-element
  # `t_indexes` is the overwhelmingly common traced case and is O(1) to
  # resolve, unlike the worst-case O(configuration) walk the family's
  # exclusion below still guards against. Resolved exactly as the
  # single-index effect resolver (`location/2`) resolves a bare `t_index`.
  defp trace_shape(machine, %Trace.TransitionsSelected{t_indexes: [t_index]} = payload) do
    {Map.put(counters(payload), :size, 1),
     %{location: Machine.transition(machine, t_index).location}}
  end

  defp trace_shape(_machine, %Trace.TransitionsSelected{t_indexes: t_indexes} = payload) do
    {Map.put(counters(payload), :size, length(t_indexes)), %{}}
  end

  defp trace_shape(_machine, %Trace.ExitSet{indexes: indexes} = payload) do
    {Map.put(counters(payload), :size, length(indexes)), %{}}
  end

  defp trace_shape(_machine, %Trace.ContentExecuted{c_indexes: c_indexes} = payload) do
    {Map.put(counters(payload), :size, length(c_indexes)), %{}}
  end

  defp trace_shape(_machine, %Trace.EntrySet{indexes: indexes} = payload) do
    {Map.put(counters(payload), :size, length(indexes)), %{}}
  end

  defp trace_shape(_machine, %Trace.MacrostepStable{} = payload) do
    {counters(payload), %{}}
  end

  defp trace_shape(machine, %Trace.Done{} = payload) do
    {counters(payload), %{configuration: resolve_configuration(machine, payload.configuration)}}
  end

  defp trace_shape(_machine, %Trace.InvokePass{state_indexes: state_indexes} = payload) do
    {Map.put(counters(payload), :size, length(state_indexes)), %{}}
  end

  defp trace_shape(_machine, %Trace.FinalizeAutoforward{} = payload) do
    {counters(payload), %{}}
  end

  @spec counters(payload :: trace_payload()) :: map()
  defp counters(%{macrostep: macrostep, microstep: microstep, round: round}) do
    %{macrostep: macrostep, microstep: microstep, round: round}
  end

  # -- kind and location resolution --------------------------------------

  @spec trace_kind(payload :: trace_payload()) :: atom()
  defp trace_kind(%Trace.EventDequeued{}), do: :event_dequeued
  defp trace_kind(%Trace.TransitionsSelected{}), do: :transitions_selected
  defp trace_kind(%Trace.ExitSet{}), do: :exit_set
  defp trace_kind(%Trace.ContentExecuted{}), do: :content_executed
  defp trace_kind(%Trace.EntrySet{}), do: :entry_set
  defp trace_kind(%Trace.MacrostepStable{}), do: :macrostep_stable
  defp trace_kind(%Trace.Done{}), do: :done
  defp trace_kind(%Trace.InvokePass{}), do: :invoke_pass
  defp trace_kind(%Trace.FinalizeAutoforward{}), do: :finalize_autoforward

  # The single-index resolver (Decision 4): whichever of `c_index`/
  # `state_index`/`t_index` `payload` carries, resolved through the matching
  # `Machine` reader and its `.location`; `nil` for a `nil` index or an
  # effect with none of the three fields (a list-carrying effect, or one
  # with no index at all, like `Effect.Done`/`Effect.BudgetExhausted`).
  @spec location(machine :: Machine.t(), payload :: struct()) ::
          Statifier.Parser.Location.t() | nil
  defp location(_machine, %{c_index: nil}), do: nil
  defp location(machine, %{c_index: c_index}), do: Machine.content(machine, c_index).location
  defp location(_machine, %{state_index: nil}), do: nil

  defp location(machine, %{state_index: state_index}),
    do: Machine.at(machine, state_index).location

  defp location(_machine, %{t_index: nil}), do: nil
  defp location(machine, %{t_index: t_index}), do: Machine.transition(machine, t_index).location
  defp location(_machine, _payload), do: nil

  @spec configuration_ids(machine_state :: MachineState.t()) :: MapSet.t(String.t())
  defp configuration_ids(%MachineState{machine: machine, configuration: configuration}) do
    resolve_configuration(machine, configuration)
  end

  # Shared by `configuration_ids/1` (a live `MachineState`'s own
  # configuration) and `Effect.Done`/`Trace.Done`'s own `configuration`
  # field (the full configuration as it stood at exit, carried on the
  # payload itself rather than read off `machine_state` - by the time
  # either `:done` effect is emitted, `MachineState.configuration` is
  # already empty). Same translation either way: a raw
  # `MapSet.t(non_neg_integer())` of constraint-3 indexes resolved to state
  # ids via `Machine.id/2`.
  @spec resolve_configuration(
          machine :: Machine.t(),
          configuration :: MapSet.t(non_neg_integer())
        ) ::
          MapSet.t(String.t())
  defp resolve_configuration(machine, configuration) do
    configuration
    |> Enum.map(&Machine.id(machine, &1))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @spec event_name(event :: Statifier.Event.t() | nil) :: String.t() | nil
  defp event_name(nil), do: nil
  defp event_name(%Statifier.Event{name: name}), do: name
end
