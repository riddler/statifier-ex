defmodule Statifier.Effect.Trace.ContentExecuted do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted when a block of
  executable content ran (`docs/observability.md` constraint 2's "content
  executed" row). `c_indexes` are the run content nodes' identities
  (constraint 3), in execution order.

  `owner` names which block ran, since a state may write several `<onentry>`
  or `<onexit>` elements and `Statifier.Machine.State.onentry`/`onexit` are
  lists of `Statifier.Machine.Block.t()` with no index of their own - the
  `ordinal` is the block's position in that list:

  - `{:onentry, state_index, ordinal}` - an `<onentry>` block
  - `{:onexit, state_index, ordinal}` - an `<onexit>` block
  - `{:transition, t_index}` - a transition's own executable content

  Built with `new/2`, never a struct literal, so `macrostep`/`microstep`
  are always stamped from the `Statifier.MachineState` at hand (Decision 4).
  """

  alias Statifier.MachineState

  @typedoc "Which block of executable content produced `c_indexes`."
  @type owner ::
          {:onentry, non_neg_integer(), non_neg_integer()}
          | {:onexit, non_neg_integer(), non_neg_integer()}
          | {:transition, non_neg_integer()}

  @enforce_keys [:owner, :c_indexes, :macrostep, :microstep]
  defstruct [:owner, :c_indexes, :macrostep, :microstep]

  @type t :: %__MODULE__{
          owner: owner(),
          c_indexes: [non_neg_integer()],
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }

  @doc """
  Stamps `macrostep`/`microstep` from `machine_state` and sets `fields`
  (`:owner`, `:c_indexes`).
  """
  @spec new(machine_state :: MachineState.t(), fields :: keyword()) :: t()
  def new(%MachineState{macrostep: macrostep, microstep: microstep}, fields) do
    struct!(__MODULE__, Keyword.merge(fields, macrostep: macrostep, microstep: microstep))
  end
end
