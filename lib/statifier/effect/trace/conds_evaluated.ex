defmodule Statifier.Effect.Trace.CondsEvaluated do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted once per selection
  round in which at least one *written* `cond` was evaluated through
  `Statifier.Evaluator`, by both `select_transitions/2` and
  `select_eventless_transitions/1`.

  This is the guard seam. Predicator is deliberately telemetry-silent
  (predicator's ADR-0016), so an evaluation that fails, or one that quietly
  disables a transition a chart author expected to fire, leaves no trace of
  its own anywhere in the family. This payload is the engine-side answer:
  `evaluations` is the ordered list of the round's guard outcomes, in walk
  order - the same order `Statifier.Interpreter.Selection` raises
  `error.execution` in - one entry per evaluation the round performed.

  Each entry is a plain map, never a `%Statifier.Machine.Transition{}`
  (`docs/observability.md` constraint 3):

  - `t_index` - the transition whose `cond` was evaluated. Its
    `cond_location` resolves through `Statifier.Machine.transition/2`.
  - `outcome` - `:enabled` (`{:ok, true}`), `:disabled` (`{:ok, false}`), or
    `:error` (an evaluation error *or* a non-boolean result, which spec
    5.9.1 joins into one case - see
    `Statifier.Interpreter.Selection.condition_match/2`).
  - `reason` - the `{:error, reason}` term for an `:error` outcome, `nil`
    otherwise. The same term the round's `error.execution` carries as its
    `data`, so a consumer can join the two without re-deriving either.

  ## Why a transition with no `cond` is absent, and why an empty round emits nothing

  `Trace.TransitionsSelected` is emitted on every selection round including
  the empty one, because a round always *selects* - the empty set is a
  result. A round with no written `cond` on any candidate transition
  performs no evaluation at all, so there is no result to report and this
  effect is not emitted; and a `nil` `cond` short-circuits to `{:ok, true}`
  ahead of `Statifier.Evaluator` (`Selection.condition_match/2`), so it is
  not an evaluation either and gets no entry. The commitment is one entry
  per Predicator call, and no effect when the round made none.

  Built with `new/2`, never a struct literal, so
  `macrostep`/`microstep`/`round` are always stamped from the
  `Statifier.MachineState` at hand.
  """

  alias Statifier.MachineState

  @typedoc """
  One guard evaluation: the transition's `t_index`, what the evaluation
  answered, and the failure term when it failed.
  """
  @type evaluation :: %{
          t_index: non_neg_integer(),
          outcome: :enabled | :disabled | :error,
          reason: term() | nil
        }

  @enforce_keys [:evaluations, :macrostep, :microstep, :round]
  defstruct [:evaluations, :macrostep, :microstep, :round]

  @type t :: %__MODULE__{
          evaluations: [evaluation()],
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }

  @doc """
  Stamps `macrostep`/`microstep`/`round` from `machine_state` and sets
  `fields` (`:evaluations`).
  """
  @spec new(machine_state :: MachineState.t(), fields :: keyword()) :: t()
  def new(%MachineState{macrostep: macrostep, microstep: microstep, round: round}, fields) do
    struct!(
      __MODULE__,
      Keyword.merge(fields, macrostep: macrostep, microstep: microstep, round: round)
    )
  end
end
