defmodule Statifier.Event.Cause do
  @moduledoc """
  Why an internally raised event exists - `docs/observability.md` constraint
  4. `origin` is a constraint-3 identity, never a struct; `macrostep`/
  `microstep` are the counters as they stood when the event was raised, per
  `Statifier.MachineState`'s counter contract.

  Cause travels *with* the event so a consumer - `Statifier.Interpreter.Content`'s
  `error.execution` message is the first one - resolves it through
  `Statifier.Machine.content/2` and the retained `Location`, with no global
  lookup and no ambient step context.

  ## `origin` names both the node and its owning block (post-review correction)

  The original shape (`{:transition, t_index} | {:content, c_index}`) could
  not actually produce the `error.execution` message constraint 4's own
  exemplar promises - "raised by the `<assign>` at line 42, transition 7,
  microstep 3" - because a bare `c_index` resolves to the content node's own
  `Location` but names nothing about *which* onentry/onexit block or
  transition it lives in. `Statifier.Effect.Trace.ContentExecuted` already
  carries exactly that owning-block identity as its `owner` field
  (`Statifier.Machine.Content.owner/0`), proven known at emission time; this
  cause now carries the same identity instead of leaving it unrecorded.
  """

  alias Statifier.Machine.Content

  @enforce_keys [:origin, :macrostep, :microstep]
  defstruct [:origin, :macrostep, :microstep]

  @typedoc """
  Which node raised the event, and where it lives:

  - `{:content, c_index, owner}` - a content node (`<raise>`, or any other
    executable-content node once one can fail) raised it; `c_index` resolves
    through `Statifier.Machine.content/2`, `owner` (`Statifier.Machine.Content.owner/0`)
    names the `<onentry>`/`<onexit>` block or transition the node lives in,
    exactly as `Statifier.Effect.Trace.ContentExecuted` already names it for
    the same block.
  - `{:state, state_index}` - the platform itself raised the event with no
    content node behind it (`done.state.*` on entering a final state names
    the state whose entry triggered it, not a content node - there is no
    `<raise>` or block to point to).
  - `{:transition, t_index}` - the platform raised the event about a
    transition's own `cond`, with no content node behind it. `t_index`
    resolves through `Statifier.Machine.transition/2`, and the transition it
    names carries both `cond` and `cond_location`, which is how an ADR-0014
    item 4 diagnostic reaches the failing expression's span in the document
    without this cause duplicating the location itself. This is distinct
    from the `Content.owner()` value `{:transition, t_index}` that can appear
    *nested inside* a `{:content, _, _}` origin above - that shape names the
    transition owning a content node (a `<raise>` living in the transition's
    block); this arm has no content node at all. The moduledoc's own history
    note above (`:14-23`) refers to that older, different two-arm shape, not
    to this one.
  - `{:data, d_index}` - the platform raised the event about a `<data>`
    element that could not be bound (`Statifier.Interpreter.Datamodel`), with
    no content node behind it - the same shape as the `{:transition,
    t_index}` arm above, one level down. `d_index` resolves through
    `Statifier.Machine.data/2`, and the resolved `%Statifier.Machine.Data{}`
    carries `id`, `value`, `location`, and `value_location`, so this cause
    never duplicates the location itself (ADR-0014 item 4's committed field
    set, reached with no new struct).

  Never a struct - every index resolves through `Statifier.Machine`.
  """
  @type origin ::
          {:content, non_neg_integer(), Content.owner()}
          | {:state, non_neg_integer()}
          | {:transition, non_neg_integer()}
          | {:data, non_neg_integer()}

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
