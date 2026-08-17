defmodule Statifier.Interpreter.Content do
  @moduledoc """
  The block runner - spec 4.9's rule for a block of executable content,
  ported once here rather than at each of `Statifier.Interpreter.ExitEntry`'s
  four call sites: a block runs its nodes in document order; if a node
  errors, the rest of the block does not run, and the error becomes
  `error.execution` on the internal queue - the errors-are-events conversion
  happens here and only here, never in a leaf node's own
  `Statifier.ExecutableContent.execute/2` implementation. Other blocks are
  unaffected: a block that errors leaves every other block - another
  `<onentry>` on the same state, an `<onexit>`, a transition's own content -
  to run exactly as if nothing had happened, since each call to
  `execute_block/3` is independent.

  ## Ordering and the trace

  Unlike `Statifier.Effect.Trace.ExitSet`/`EntrySet` - computed before acting
  and therefore emitted first - `Trace.ContentExecuted` reports what *ran*,
  which is only known once the block has finished, so it is appended after
  the block's own effects rather than emitted first. Its `c_indexes` are the
  nodes that actually executed, in execution order: on the happy path that
  is the whole block; on an error it is a prefix ending at (and including)
  the failing node - the failing node did execute, it just returned
  `{:error, _}` rather than succeeding, so it is not absent from the trace,
  only absent from the effect list. An empty block still goes through the
  trace gate: with tracing on it emits one `Trace.ContentExecuted` carrying
  the block's owner and `c_indexes: []`, because a trace consumer cannot
  otherwise tell an `<onentry/>` that ran with no content apart from an
  `<onentry>` that never ran at all - the effect stream would be identical
  either way. With tracing off the empty-block clause still costs nothing:
  it calls `Effect.trace/3` directly rather than building a `Context` and
  running the fold, so it keeps the cheapest possible shape on the untraced
  hot path.

  `Effect.trace/3` is called with the block's *final* `machine_state`: no
  node in a block calls `MachineState.begin_macrostep/1` or
  `begin_microstep/1`, so the counters at the block's start and end are
  identical either way. `Effect.trace/3`'s own macro binds a local
  `machine_state` inside a hygienic quote, so passing this function's own
  `machine_state` local is never shadowed by the macro's expansion.

  ## The datamodel context, built once per block

  `execute_block/3` builds one `Statifier.Evaluator.context/1` value up
  front and hands it to every node in the block through
  `Statifier.ExecutableContent.Context`'s `datamodel_context` field - the
  "never per expression" commitment `docs/datamodel.md` makes, kept at the
  tightest interval that stays correct (see that struct's own moduledoc for
  why per-block rather than per-macrostep). This module builds that context
  exactly once, before any node in the block runs, and never rebuilds it
  itself - the seam named here is taken in
  `Statifier.Machine.Content.Assign`'s own `execute/2`, never in this runner
  (`docs/architecture.md:112-114`'s "never a change to the runner"). A node
  that does *not* rebuild the context - every node but
  `<assign>` today - still sees the block's original snapshot for the rest of
  the block, datamodel writes included.

  ## Errors-are-events, once

  A node's `Statifier.ExecutableContent.execute/2` returns `{:error, reason}`
  with `reason` a bare `term()` - never a `Statifier.Event`, per
  ADR-0003's error model ("only the interpreter raises `error.execution`").
  This module is that interpreter boundary: on the first `{:error, reason}`
  from a node at `c_index`, the fold halts and
  `Statifier.MachineState.raise_platform/4` raises `"error.execution"` with
  cause origin `{:content, c_index, owner}` and `data: reason` -
  `raise_platform/4` rather than `raise_internal/4` because spec 5.10.1
  classifies `error.*` as a platform event (the `type` VALUE), while spec
  3.12.2 is what requires the error to go on the internal queue at all.
  `raise_internal/4` and `raise_platform/4`
  (`lib/statifier/machine_state.ex:240`, `:272`) enqueue identically and
  differ only in the `type` stamp, so 3.12.2 is satisfied either way and
  only 5.10.1 decides between them - the origin still names the content
  node the platform is raising about. Nodes that already ran keep the
  effects they already produced, in order; the failing node contributes
  none of its own (it returned an error, not a partial success).

  ## A node may name a send id

  ADR-0047 widens the runner's error model: a node may name the send id
  its failure belongs to, and 5.10.1's MUST ("in the case of error events
  triggered by a failed attempt to send an event, the Processor MUST set
  this field to the send id of the triggering `<send>` element") is
  unconditional, so the id travels as an event field rather than only
  inside `data`. `raise_execution_error/4` gains a clause matching
  `{:send_rejected, send_id, reason}`, destructuring it into `data: reason`
  and `sendid: send_id`; the inner `reason` is still what a consumer reading
  `data` sees, the same shape as any other content failure.

  This clause is reachable from the fatal arm only: 5.9.1's
  `pending_errors` drain (below) is the non-fatal channel, and no node ever
  puts a `{:send_rejected, _, _}` reason there - deliberately, since a
  drained error does not abort the block, and 4.9's abort is the whole
  point of the ADR-0047 rejection.

  ## Non-fatal errors, drained here too

  Spec 5.9.1: "If a conditional expression cannot be evaluated as a boolean
  value ('true' or 'false') or if its evaluation causes an error, the SCXML
  Processor MUST treat the expression as if it evaluated to 'false' **and**
  MUST place the error 'error.execution' in the internal event queue." A
  leaf node cannot raise that itself (ADR-0003's error model, and
  `content_acceptance_test.exs`'s structural sweep mechanically enforces
  it), so it records the reason in `context.pending_errors` instead and
  keeps going. `run_nodes/2` drains that list after *every* node it runs -
  on the success path and on the failure path alike - through
  `raise_execution_error/4`, the same function the fatal path uses, so the
  origin stamp stays `{:content, c_index, owner}` and there is still exactly
  one site in this tree that names `"error.execution"` for content.

  **Ordering caveat.** Because the drain happens after the node returns, a
  pending error is queued *after* any event the node's own execution (e.g.
  an `<if>`'s selected partition) already raised, whereas spec 5.9.1 reads
  as queuing it at the moment the cond is evaluated - i.e. before. Getting
  the order right would require either the leaf to raise (ADR-0003) or a
  second protocol round-trip per node; neither is justified by any corpus
  document today, and no corpus file distinguishes this window.

  Spec 4.9's closing sentence mitigates the consequence without sanctioning
  the deviation: "error events will not be removed from the queue and
  processed until all events preceding them in the queue have been
  processed". That establishes FIFO processing of a queued error event; it
  says nothing about which queue *position* the error may be inserted at,
  so it is not license to insert later than 5.9.1 requires. What it does
  establish is that the event is still eventually processed, which bounds
  how much the wrong position can cost.
  """

  alias Statifier.Effect
  alias Statifier.Evaluator
  alias Statifier.ExecutableContent
  alias Statifier.ExecutableContent.Context
  alias Statifier.Machine
  alias Statifier.Machine.Content
  alias Statifier.MachineState

  require Statifier.Effect, as: Effect

  @doc """
  Runs the block of content nodes named by `c_indexes`, in document order,
  stopping at the first error - `executeContent(content)` (Appendix D),
  wrapped with the `Trace.ContentExecuted` emission. See the moduledoc for
  the full block-semantics contract.
  """
  @spec execute_block(
          machine_state :: MachineState.t(),
          owner :: Content.owner(),
          c_indexes :: [non_neg_integer()]
        ) :: {MachineState.t(), [Effect.t()]}
  def execute_block(machine_state, owner, []) do
    {machine_state,
     Effect.trace(machine_state, Effect.Trace.ContentExecuted, owner: owner, c_indexes: [])}
  end

  def execute_block(machine_state, owner, c_indexes) do
    context = %Context{
      machine_state: machine_state,
      owner: owner,
      datamodel_context: Evaluator.context(machine_state)
    }

    {context, effects, executed, error} = run_nodes(context, c_indexes)

    machine_state =
      case error do
        nil ->
          context.machine_state

        {failed_c_index, reason} ->
          raise_execution_error(context.machine_state, owner, failed_c_index, reason)
      end

    trace_effects =
      Effect.trace(machine_state, Effect.Trace.ContentExecuted, owner: owner, c_indexes: executed)

    {machine_state, effects ++ trace_effects}
  end

  # The fold itself: each `c_index` resolved through `Machine.content/2` and
  # dispatched through `execute_one/2`, accumulating effects and executed
  # `c_indexes` in order; `{:error, reason}` halts the fold with the failing
  # `c_index` and `reason` carried in the accumulator's last slot. A
  # three-element `{:error, new_context, reason}` halts the same way but
  # keeps `new_context` - the context the node had already produced,
  # `pending_errors` included - instead of discarding it back to the
  # fold's pre-call `context` (see `drain_pending/2`, below).
  @spec run_nodes(context :: Context.t(), c_indexes :: [non_neg_integer()]) ::
          {Context.t(), [Effect.t()], [non_neg_integer()], {non_neg_integer(), term()} | nil}
  defp run_nodes(context, c_indexes) do
    Enum.reduce_while(
      c_indexes,
      {context, [], [], nil},
      fn c_index, {context, effects, executed, _error} ->
        case execute_one(context, c_index) do
          {:ok, new_context, node_effects} ->
            new_context = drain_pending(new_context, c_index)
            {:cont, {new_context, effects ++ node_effects, executed ++ [c_index], nil}}

          {:error, new_context, reason} ->
            new_context = drain_pending(new_context, c_index)
            {:halt, {new_context, effects, executed ++ [c_index], {c_index, reason}}}

          {:error, reason} ->
            {:halt, {context, effects, executed ++ [c_index], {c_index, reason}}}
        end
      end
    )
  end

  # Drains `context.pending_errors` (spec 5.9.1's non-fatal channel - see the
  # moduledoc's "Non-fatal errors, drained here too" section for the full
  # rationale and the ordering caveat) through `raise_execution_error/4` in
  # document order, then clears the list. Runs on both the `{:ok, _, _}` and
  # `{:error, context, _}` arms of `run_nodes/2`'s fold, since a composite
  # node's partial context can carry pending errors even when the node
  # itself ultimately fails (Decision 4/5).
  @spec drain_pending(context :: Context.t(), c_index :: non_neg_integer()) :: Context.t()
  defp drain_pending(%Context{pending_errors: []} = context, _c_index), do: context

  defp drain_pending(%Context{pending_errors: pending, owner: owner} = context, c_index) do
    machine_state =
      Enum.reduce(pending, context.machine_state, fn reason, machine_state ->
        raise_execution_error(machine_state, owner, c_index, reason)
      end)

    %{context | machine_state: machine_state, pending_errors: []}
  end

  # One node: resolve its compiled struct through `Machine.content/2`, then
  # dispatch it through the protocol.
  @spec execute_one(context :: Context.t(), c_index :: non_neg_integer()) ::
          ExecutableContent.result()
  defp execute_one(%Context{machine_state: machine_state} = context, c_index) do
    machine_state.machine
    |> Machine.content(c_index)
    |> ExecutableContent.execute(context)
  end

  # The errors-are-events conversion: `raise_platform/4`, not
  # `raise_internal/4`, since spec 5.10.1 classifies `error.*` as a
  # platform event regardless of what raised it; spec 3.12.2 is what
  # requires the error on the internal queue at all, and both functions
  # satisfy that identically - only 5.10.1 decides between them.
  @spec raise_execution_error(
          machine_state :: MachineState.t(),
          owner :: Content.owner(),
          c_index :: non_neg_integer(),
          reason :: term()
        ) :: MachineState.t()

  # ADR-0047's widening of the runner's error model: a node may name the
  # send id its failure belongs to, and 5.10.1's MUST ("in the case of
  # error events triggered by a failed attempt to send an event, the
  # Processor MUST set this field to the send id of the triggering
  # <send> element") is unconditional, so the id travels as an event field
  # rather than only inside `data`. The inner reason is still what `data`
  # carries, so a consumer reading `data` sees the same shape it would for
  # any other content failure.
  defp raise_execution_error(machine_state, owner, c_index, {:send_rejected, send_id, reason}) do
    MachineState.raise_platform(machine_state, "error.execution", {:content, c_index, owner},
      data: reason,
      sendid: send_id
    )
  end

  defp raise_execution_error(machine_state, owner, c_index, reason) do
    MachineState.raise_platform(machine_state, "error.execution", {:content, c_index, owner},
      data: reason
    )
  end
end
