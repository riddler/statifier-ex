defmodule Statifier.Effect.BudgetExhausted do
  @moduledoc """
  Payload for `{:budget_exhausted, %__MODULE__{}}` - ADR-0019's outcome when
  `Statifier.Interpreter.macrostep/1`'s fold spends
  `Statifier.MachineState.max_macrostep_rounds` without reaching quiescence.

  A core effect, not a trace effect: it is the outcome of the call rather
  than diagnostics about it, so it must be observable with `trace: false`.
  `Statifier.Effect.Trace.MacrostepStable` is *not* emitted alongside it -
  the configuration did not stabilize - which keeps the three macrostep
  outcomes (stable, done, budget-exhausted) mutually exclusive.

  `configuration` is the full configuration (ADR-0005, ancestors included)
  as the last round left it; `budget` is the value that was spent, i.e.
  `max_macrostep_rounds` for that fold; `pending_internal_events` is
  `Statifier.MachineState.internal_events/1`'s ordered view of the queue,
  which is where a livelock's repeatedly-raised events pile up.
  `macrostep`/`microstep` are the counters as they stand at exhaustion - and
  `microstep` may well be `0`, because a fold can livelock without any
  microstep ever running.

  The machine_state returned alongside this effect is a complete, resumable
  position (ADR-0012): step it through
  `Statifier.Interpreter.microstep/1` to watch the cycle round by round.
  """

  @enforce_keys [:configuration, :budget, :pending_internal_events, :macrostep, :microstep]
  defstruct [:configuration, :budget, :pending_internal_events, :macrostep, :microstep]

  @type t :: %__MODULE__{
          configuration: MapSet.t(non_neg_integer()),
          budget: pos_integer() | :infinity,
          pending_internal_events: [Statifier.Event.t()],
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }
end
