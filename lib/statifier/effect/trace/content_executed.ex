defmodule Statifier.Effect.Trace.ContentExecuted do
  @moduledoc """
  Trace payload for `{:trace, %__MODULE__{}}` - emitted when a block of
  executable content ran (`docs/observability.md` constraint 2's "content
  executed" row). `c_indexes` are the run content nodes' identities
  (constraint 3), in execution order.

  `owner` names which block ran, since a state may write several `<onentry>`
  or `<onexit>` elements and `Statifier.Machine.State.onentry`/`onexit` are
  lists of `Statifier.Machine.Block.t()` with no index of their own - the
  `ordinal` is the block's position in that list. Most of the type lives on
  `Statifier.Machine.Content.owner/0` (it describes where a content node
  lives, so that module is its natural home); this module widens it with one
  case of its own rather than redefining the shared part, and
  `Statifier.Event.Cause.origin/0` embeds `Content.owner/0` unwidened for its
  `:content` case (post-review correction):

  - `{:onentry, state_index, ordinal}` - an `<onentry>` block
  - `{:onexit, state_index, ordinal}` - an `<onexit>` block
  - `{:transition, t_index}` - a transition's own executable content
  - `{:global_script, index}` - a top-level `<script>` (spec 5.8), run at
    load time by `Statifier.Interpreter.run_global_script/3`. This case is
    added here, not on `Content.owner/0` itself: a top-level script has no
    `c_index` and belongs to no block at all (`Statifier.Machine`'s "why
    `global_scripts` is different" moduledoc section), so it would be a
    category error inside `Content.owner/0`, whose whole point is naming the
    block a content node lives *in*. `Statifier.Event.Cause.origin/0` already
    drew the same line: `{:global_script, index}` is that type's own
    top-level arm, not nested inside its `{:content, c_index, owner}` case,
    for the identical reason. `index` is the script's position in
    `document.scripts`/`machine.global_scripts`, the same identity
    `Statifier.Compiler.Expressions.owner_ref/0` mints and
    `Statifier.Event.Cause.origin/0`'s own `{:global_script, index}` bullet
    already documents.

  Built with `new/2`, never a struct literal, so `macrostep`/`microstep`/
  `round` are always stamped from the `Statifier.MachineState` at hand.
  """

  alias Statifier.Machine.Content
  alias Statifier.MachineState

  @typedoc """
  Which block of executable content (or, for `{:global_script, index}`, which
  load-time script) produced `c_indexes` - `Statifier.Machine.Content.owner/0`
  widened with the one case that module cannot carry. See the moduledoc for
  why the widening lives here instead of there.
  """
  @type owner :: Content.owner() | {:global_script, non_neg_integer()}

  @enforce_keys [:owner, :c_indexes, :macrostep, :microstep, :round]
  defstruct [:owner, :c_indexes, :macrostep, :microstep, :round]

  @type t :: %__MODULE__{
          owner: owner(),
          c_indexes: [non_neg_integer()],
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }

  @doc """
  Stamps `macrostep`/`microstep`/`round` from `machine_state` and sets
  `fields` (`:owner`, `:c_indexes`).
  """
  @spec new(machine_state :: MachineState.t(), fields :: keyword()) :: t()
  def new(%MachineState{macrostep: macrostep, microstep: microstep, round: round}, fields) do
    struct!(
      __MODULE__,
      Keyword.merge(fields, macrostep: macrostep, microstep: microstep, round: round)
    )
  end
end
