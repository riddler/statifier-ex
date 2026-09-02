defmodule Statifier.Effect.Trace.Done do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted alongside
  `Statifier.Effect.Done` at top-level final entry / `exit_interpreter`
  (`docs/observability.md` constraint 2's "done" row). `donedata` and
  `configuration` mirror the core `:done` effect's payload - both effects
  are built from the same `configuration_at_exit` binding in
  `Statifier.Interpreter.exit_interpreter/1`, so they can never disagree.
  `donedata_error` mirrors it too, from the same local (ADR-0021's
  2026-09-02 note) - see `Statifier.Effect.Done` for what it carries and
  for the first-error rule when several `<param>`s fail.
  This effect exists for the observability row (ADR-0012,
  `docs/observability.md:68`), not because it is the only carrier of the
  configuration.

  Built with `new/2`, never a struct literal, so `macrostep`/`microstep`/
  `round` are always stamped from the `Statifier.MachineState` at hand.
  """

  alias Statifier.MachineState

  @enforce_keys [:configuration, :macrostep, :microstep, :round]
  defstruct [:donedata, :donedata_error, :configuration, :macrostep, :microstep, :round]

  @type t :: %__MODULE__{
          donedata: term() | nil,
          donedata_error: term() | nil,
          configuration: MapSet.t(non_neg_integer()),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }

  @doc """
  Stamps `macrostep`/`microstep`/`round` from `machine_state` and sets
  `fields` (`:configuration`, optional `:donedata` and `:donedata_error`).
  """
  @spec new(machine_state :: MachineState.t(), fields :: keyword()) :: t()
  def new(%MachineState{macrostep: macrostep, microstep: microstep, round: round}, fields) do
    struct!(
      __MODULE__,
      Keyword.merge(fields, macrostep: macrostep, microstep: microstep, round: round)
    )
  end
end
