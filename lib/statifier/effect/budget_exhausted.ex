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
  `macrostep`/`microstep`/`round` are the counters as they stand at
  exhaustion - and `microstep` may well be `0`, because a fold can livelock
  without any microstep ever running. `round` is the rounds-spent count:
  always equal to `budget` on this path, since exhaustion is reached only
  after the fold has spent exactly that many rounds (ADR-0020) - which is
  why there is no separate `rounds_spent` field.

  The machine_state returned alongside this effect is a complete, resumable
  position (ADR-0012): step it through
  `Statifier.Interpreter.microstep/1` to watch the cycle round by round.
  """

  @enforce_keys [
    :configuration,
    :budget,
    :pending_internal_events,
    :macrostep,
    :microstep,
    :round
  ]
  defstruct [:configuration, :budget, :pending_internal_events, :macrostep, :microstep, :round]

  @type t :: %__MODULE__{
          configuration: MapSet.t(non_neg_integer()),
          budget: pos_integer() | :infinity,
          pending_internal_events: [Statifier.Event.t()],
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }
end
