defmodule Statifier.Event.Cause do
  @moduledoc """
  Why an internally raised event exists - `docs/observability.md` constraint
  4. `origin` is a constraint-3 identity (a `t_index` or a `c_index`, never
  a struct); `macrostep`/`microstep` are the counters as they stood when the
  event was raised, per `Statifier.MachineState`'s counter contract.

  Cause travels *with* the event so a consumer - the first of which is
  st-af3's `error.execution` message - resolves it through
  `Statifier.Machine.transition/2` or `content/2` and the retained
  `Location`, with no global lookup and no ambient step context.
  """

  @enforce_keys [:origin, :macrostep, :microstep]
  defstruct [:origin, :macrostep, :microstep]

  @typedoc """
  Which compiled node raised the event: a transition's `t_index` (an
  `<transition>` executing its content raised it) or a content node's
  `c_index` (an `<onentry>`/`<onexit>` block, or a bare `<raise>`/`<send>`,
  raised it). Never a struct - the index resolves through
  `Statifier.Machine.transition/2` or `Statifier.Machine.content/2`.
  """
  @type origin :: {:transition, non_neg_integer()} | {:content, non_neg_integer()}

  @type t :: %__MODULE__{
          origin: origin(),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer()
        }

  @doc """
  Builds a cause from the raising node's identity and the counters as they
  stood at the moment of the raise (`Statifier.MachineState`'s counter
  contract - stamped after the step's own `begin_*` call).
  """
  @spec new(origin :: origin(), macrostep :: non_neg_integer(), microstep :: non_neg_integer()) ::
          t()
  def new(origin, macrostep, microstep) do
    %__MODULE__{origin: origin, macrostep: macrostep, microstep: microstep}
  end
end
