defmodule Statifier.Event.Cause do
  @moduledoc """
  Why an internally raised event exists - `docs/observability.md` constraint
  4. `origin` is a constraint-3 identity, never a struct; `macrostep`/
  `microstep`/`round` are the counters as they stood when the event was
  raised, per `Statifier.MachineState`'s counter contract.

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
  (`t:Statifier.Machine.Content.owner/0`), proven known at emission time; this
  cause now carries the same identity instead of leaving it unrecorded.
  """

  alias Statifier.Machine.Content

  @enforce_keys [:origin, :macrostep, :microstep, :round]
  defstruct [:origin, :macrostep, :microstep, :round]

  @typedoc """
  Which node raised the event, and where it lives:

  - `{:content, c_index, owner}` - a content node (`<raise>`, or any other
    executable-content node once one can fail) raised it; `c_index` resolves
    through `Statifier.Machine.content/2`, `owner` (`t:Statifier.Machine.Content.owner/0`)
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

  - `{:donedata_param, state_index, param_index}` - the platform raised the
    event about one `<param>` under a `<final>`'s `<donedata>` that could not
    be evaluated, with no content node behind it. `state_index` resolves
    through `Statifier.Machine.at/2` and `param_index` indexes that state's
    `donedata.params` in document order, so the resolved
    `%Statifier.Machine.Param{}` carries `name`, `kind`, `expr` and
    `expr_location` - ADR-0014 item 4's committed field set, reached with no
    new struct, the same way the `{:data, d_index}` arm reaches a `<data>`.

    **Why this is not `{:state, state_index}`.** Spec 5.7 makes each
    `<param>` fail independently ("MUST ignore the name and value" - one
    failure does not abort its siblings), so a `<donedata>` with several
    `<param>` children can raise several `error.execution` events in one
    step. A bare `{:state, state_index}` is identical across all of them,
    which leaves `docs/observability.md` constraint 4's "identity of what
    raised them" unsatisfied at the granularity the failure actually has:
    the reason's `source` string narrows it only when the siblings'
    expressions differ, and two `<param>` elements may legitimately share
    one expression while differing in `name`.

  - `{:global_script, index}` - the platform raised the event about a
    top-level `<script>` (spec 5.8) that could not be run at document load
    time (`Statifier.Interpreter.initialize/2`), with no content node and
    no block behind it - a top-level script is never in `contents` at all
    (`Statifier.Machine`'s own "why `global_scripts` is different"
    moduledoc section), so this is the same shape as the `{:data, d_index}`
    arm above, one level down, addressed the same way
    `t:Statifier.Compiler.Expressions.owner_ref/0`'s own `{:global_script,
    _}` arm is: `index` is the script's position in `document.scripts` /
    `machine.global_scripts`, in document order, resolved by rereading that
    list rather than through any `Statifier.Machine` accessor - there is no
    `d_index`-style lookup function for a list with no dense-tuple
    counterpart.

  - `{:invoke, state_index, invoke_index}` - the platform raised the event
    about one of an `<invoke>` element's own arguments (`type`/`typeexpr`,
    `src`/`srcexpr`, `id`/`idlocation`, a `<param>`'s `expr`/`location`, a
    `namelist` location, or `<content expr>`) that could not be evaluated
    (ADR-0031), with no content node behind it - the same
    `{owning_element, sub_index}` shape the `{:donedata_param, _, _}` arm
    above uses, for the same reason: 6.4's failure is per-element, so a
    state with several `<invoke>` children can raise several
    `error.execution` events in one pass, and a bare `{:state, state_index}`
    would stamp all of them identically. `state_index` resolves through
    `Statifier.Machine.at/2` and `invoke_index` indexes that state's
    `invoke` list in document order, so the resolved
    `%Statifier.Machine.Invoke{}` carries every attribute and its own
    `attribute_locations` - ADR-0014 item 4's committed field set, reached
    with no new struct.

  - `{:finalize, state_index, invoke_index}` - the platform raised the event
    about an **empty** `<finalize>`'s own auto-assign write (spec 6.5), which
    fails outside any block and so has no content node behind it either -
    the same `{owning_element, sub_index}` shape the `{:invoke, _, _}` arm
    above uses, one level down: a failed write for one namelist entry or
    `<param location>` does not abort the others (each is an independent
    `<assign>`-as-if write, 6.5's own wording), so a state whose invocation's
    empty finalize has several targets can raise several `error.execution`
    events from one applyFinalize call. `state_index`/`invoke_index` resolve
    exactly as the `{:invoke, _, _}` arm's do; a **populated** `<finalize>`'s
    own failures go through the ordinary `{:content, c_index, owner}` arm
    instead, `owner` being `t:Statifier.Machine.Content.owner/0`'s own
    `{:finalize, state_index, invoke_index}` shape - that block runs through
    `Statifier.Interpreter.Content.execute_block/3` like any other block, and
    this arm exists only for the empty case's block-less write.

  Never a struct - every index resolves through `Statifier.Machine`.
  """
  @type origin ::
          {:content, non_neg_integer(), Content.owner()}
          | {:state, non_neg_integer()}
          | {:transition, non_neg_integer()}
          | {:data, non_neg_integer()}
          | {:donedata_param, non_neg_integer(), non_neg_integer()}
          | {:global_script, non_neg_integer()}
          | {:invoke, non_neg_integer(), non_neg_integer()}
          | {:finalize, non_neg_integer(), non_neg_integer()}

  @type t :: %__MODULE__{
          origin: origin(),
          macrostep: non_neg_integer(),
          microstep: non_neg_integer(),
          round: non_neg_integer()
        }

  @doc """
  Builds a cause from the raising node's identity and the counters as they
  stood at the moment of the raise (`Statifier.MachineState`'s counter
  contract - stamped after the step's own `begin_*` call).
  """
  @spec new(
          origin :: origin(),
          macrostep :: non_neg_integer(),
          microstep :: non_neg_integer(),
          round :: non_neg_integer()
        ) :: t()
  def new(origin, macrostep, microstep, round) do
    %__MODULE__{origin: origin, macrostep: macrostep, microstep: microstep, round: round}
  end
end
