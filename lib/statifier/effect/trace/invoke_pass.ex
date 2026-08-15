defmodule Statifier.Effect.Trace.InvokePass do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted once the invoke pass
  finishes: `for state in statesToInvoke.sort(entryOrder): for inv in
  state.invoke.sort(documentOrder): invoke(inv)` followed by
  `statesToInvoke.clear()` (Appendix D, `Statifier.Interpreter`'s own
  moduledoc section "The invoke pass runs at the end of every fold, inside
  `main_event_loop/3`"). This is a phase boundary Appendix D itself names,
  just not one `docs/observability.md`'s constraint-2 table enumerated when
  it was written - `<invoke>` did not exist in this interpreter yet
  (ADR-0012's parenthetical is illustrative, not a closed list).

  `state_indexes` are `states_to_invoke` sorted into entry order
  (constraint 3, integer indexes) - the walk `run_invoke_pass/1` performed,
  including a state that owns no `<invoke>` at all, since it still passed
  through `statesToInvoke` on entry and a debugger stepping this pass wants
  to see the states it visited, not only the ones that produced an
  invocation. `invoke_ids` are the `Statifier.Effect.Invoke.invoke_id`
  values of every invocation this pass actually started, in the order the
  pass emitted their effects (entry order across states, document order
  within one state) - an invocation whose argument evaluation raised
  `error.execution` (ADR-0031) contributes no entry here, the same way it
  contributes no `Effect.Invoke`.

  Emitted every time the pass runs, even when both lists are empty - the
  same "includes the empty set" reasoning `Trace.TransitionsSelected` and
  `Trace.ExitSet` already carry into this vocabulary, so a trace consumer
  never has to distinguish "the pass ran and did nothing" from "the pass did
  not run" by its absence.

  Built with `new/2`, never a struct literal, so `macrostep`/`microstep`/
  `round` are always stamped from the `Statifier.MachineState` at hand.
  """

  alias Statifier.MachineState

  @enforce_keys [:state_indexes, :invoke_ids, :macrostep, :microstep, :round]
  defstruct [:state_indexes, :invoke_ids, :macrostep, :microstep, :round]

  @type t :: %__MODULE__{
          state_indexes: [non_neg_integer()],
          invoke_ids: [String.t()],
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }

  @doc """
  Stamps `macrostep`/`microstep`/`round` from `machine_state` and sets
  `fields` (`:state_indexes`, `:invoke_ids`).
  """
  @spec new(machine_state :: MachineState.t(), fields :: keyword()) :: t()
  def new(%MachineState{macrostep: macrostep, microstep: microstep, round: round}, fields) do
    struct!(
      __MODULE__,
      Keyword.merge(fields, macrostep: macrostep, microstep: microstep, round: round)
    )
  end
end
