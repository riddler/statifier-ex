defmodule Statifier.Effect.Trace.FinalizeAutoforward do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted once per external
  event, at the end of the finalize/autoforward pass: `for state in
  configuration: for inv in state.invoke: if inv.invokeid ==
  externalEvent.invokeid: applyFinalize(inv, externalEvent); if
  inv.autoforward: send(inv.id, externalEvent)` (Appendix D,
  `Statifier.Interpreter`'s own moduledoc section "The finalize/autoforward
  pass runs once per external event, inside `handle_event/2`, before
  transition selection"). This is a phase boundary Appendix D itself names,
  just not one `docs/observability.md`'s constraint-2 table enumerated when
  it was written - `<invoke>` did not exist in this interpreter yet
  (ADR-0012's parenthetical is illustrative, not a closed list).

  `event` is the external event the pass matched invocations against -
  carried whole, the same reasoning `Statifier.Effect.Autoforward`'s own
  moduledoc gives for not decomposing it. `finalized` are the `invoke_id`s
  of every currently-active invocation whose `invokeid` equalled `event`'s
  own (spec 6.5's matching rule), i.e. every invocation `apply_finalize/5`
  ran - regardless of which of the three shapes
  (`Statifier.Machine.Invoke.finalize`'s absent/empty/populated split) its
  own `<finalize>` took, since a debugger asking "whose finalize ran" wants
  the invocation's identity, not that internal split (already visible, for
  the populated case, through `Trace.ContentExecuted`'s own `{:finalize,
  state_index, invoke_index}` owner). `forwarded` are the `invoke_id`s of
  every invocation `event` was autoforwarded to, in the pass's own walk
  order (configuration document order across states, document order within
  a state) - the same identities `Statifier.Effect.Autoforward` payloads in
  the same effect list already carry, gathered here as one summary of the
  whole pass rather than left for a consumer to reconstruct by filtering.

  Emitted every time the pass runs, including when `finalized` and
  `forwarded` are both empty - either because no invocation matched or
  autoforwarded, or because `active_invocations` was empty and the pass
  short-circuited - the same "includes the empty set" reasoning
  `Trace.TransitionsSelected` and `Trace.ExitSet` already carry into this
  vocabulary.

  Built with `new/2`, never a struct literal, so `macrostep`/`microstep`/
  `round` are always stamped from the `Statifier.MachineState` at hand.
  """

  alias Statifier.{Event, MachineState}

  @enforce_keys [:event, :finalized, :forwarded, :macrostep, :microstep, :round]
  defstruct [:event, :finalized, :forwarded, :macrostep, :microstep, :round]

  @type t :: %__MODULE__{
          event: Event.t(),
          finalized: [String.t()],
          forwarded: [String.t()],
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }

  @doc """
  Stamps `macrostep`/`microstep`/`round` from `machine_state` and sets
  `fields` (`:event`, `:finalized`, `:forwarded`).
  """
  @spec new(machine_state :: MachineState.t(), fields :: keyword()) :: t()
  def new(%MachineState{macrostep: macrostep, microstep: microstep, round: round}, fields) do
    struct!(
      __MODULE__,
      Keyword.merge(fields, macrostep: macrostep, microstep: microstep, round: round)
    )
  end
end
