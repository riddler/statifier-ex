defmodule Statifier.Interpreter.Content do
  @moduledoc """
  The block runner - spec 4.9's rule for a block of executable content,
  ported once here rather than at each of `Statifier.Interpreter.ExitEntry`'s
  four call sites (plan Decision 5): a block runs its nodes in document
  order; if a node errors, the rest of the block does not run, and the error
  becomes `error.execution` on the internal queue (plan Decision 8) - the
  errors-are-events conversion happens here and only here, never in a leaf
  node's own `Statifier.ExecutableContent.execute/2` implementation. Other
  blocks are unaffected: a block that errors leaves every other block -
  another `<onentry>` on the same state, an `<onexit>`, a transition's own
  content - to run exactly as if nothing had happened, since each call to
  `execute_block/3` is independent.

  ## Ordering and the trace (plan Decision 9)

  Unlike `Statifier.Effect.Trace.ExitSet`/`EntrySet` - computed before acting
  and therefore emitted first (st-wju.4 Decision 13) - `Trace.ContentExecuted`
  reports what *ran*, which is only known once the block has finished, so it
  is appended after the block's own effects rather than emitted first. Its
  `c_indexes` are the nodes that actually executed, in execution order: on
  the happy path that is the whole block; on an error it is a prefix ending
  at (and including) the failing node - the failing node did execute, it
  just returned `{:error, _}` rather than succeeding, so it is not absent
  from the trace, only absent from the effect list. An empty block
  (`c_indexes: []`) returns `{machine_state, []}` immediately, before the
  trace gate is even considered: nothing ran, so there is nothing to report,
  and the untraced hot path stays the cheapest possible shape.

  `Effect.trace/3` is called with the block's *final* `machine_state` -
  st-wju.4 Decision 12 established the same choice for `execute_block/3`'s
  stub `@spec`, and it holds here because no node in a block calls
  `MachineState.begin_macrostep/1` or `begin_microstep/1` (plan Decision 12),
  so the counters at the block's start and end are identical either way.
  `Effect.trace/3`'s own macro binds a local `machine_state` inside a
  hygienic quote (st-wju.4 Decision 13's hygiene note), so passing this
  function's own `machine_state` local is never shadowed by the macro's
  expansion.

  ## Errors-are-events, once (plan Decision 8)

  A node's `Statifier.ExecutableContent.execute/2` returns `{:error, reason}`
  with `reason` a bare `term()` - never a `Statifier.Event`, per
  ADR-0003's error model ("only the interpreter raises `error.execution`").
  This module is that interpreter boundary: on the first `{:error, reason}`
  from a node at `c_index`, the fold halts and
  `Statifier.MachineState.raise_platform/4` raises `"error.execution"` with
  cause origin `{:content, c_index, owner}` and `data: reason` -
  `raise_platform/4` rather than `raise_internal/4` because spec 5.10.1
  classifies `error.*` as a platform event (st-wju.4 Decision 8), even though
  the origin still names the content node the platform is raising about.
  Nodes that already ran keep the effects they already produced, in order;
  the failing node contributes none of its own (it returned an error, not a
  partial success).
  """

  alias Statifier.Effect
  alias Statifier.ExecutableContent
  alias Statifier.ExecutableContent.Context
  alias Statifier.Machine
  alias Statifier.Machine.Content
  alias Statifier.MachineState

  require Statifier.Effect, as: Effect

  @doc """
  Runs the block of content nodes named by `c_indexes`, in document order,
  stopping at the first error - `executeContent(content)` (Appendix D),
  wrapped with the `Trace.ContentExecuted` emission (plan Decision 9). See
  the moduledoc for the full block-semantics contract.
  """
  @spec execute_block(
          machine_state :: MachineState.t(),
          owner :: Content.owner(),
          c_indexes :: [non_neg_integer()]
        ) :: {MachineState.t(), [Effect.t()]}
  def execute_block(machine_state, _owner, []), do: {machine_state, []}

  def execute_block(machine_state, owner, c_indexes) do
    context = %Context{machine_state: machine_state, owner: owner}

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
  # `c_index` and `reason` carried in the accumulator's last slot.
  @spec run_nodes(context :: Context.t(), c_indexes :: [non_neg_integer()]) ::
          {Context.t(), [Effect.t()], [non_neg_integer()], {non_neg_integer(), term()} | nil}
  defp run_nodes(context, c_indexes) do
    Enum.reduce_while(
      c_indexes,
      {context, [], [], nil},
      fn c_index, {context, effects, executed, _error} ->
        case execute_one(context, c_index) do
          {:ok, new_context, node_effects} ->
            {:cont, {new_context, effects ++ node_effects, executed ++ [c_index], nil}}

          {:error, reason} ->
            {:halt, {context, effects, executed ++ [c_index], {c_index, reason}}}
        end
      end
    )
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

  # The errors-are-events conversion (plan Decision 8): `raise_platform/4`,
  # not `raise_internal/4`, since spec 5.10.1 classifies `error.*` as a
  # platform event regardless of what raised it.
  @spec raise_execution_error(
          machine_state :: MachineState.t(),
          owner :: Content.owner(),
          c_index :: non_neg_integer(),
          reason :: term()
        ) :: MachineState.t()
  defp raise_execution_error(machine_state, owner, c_index, reason) do
    MachineState.raise_platform(machine_state, "error.execution", {:content, c_index, owner},
      data: reason
    )
  end
end
