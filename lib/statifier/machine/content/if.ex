defmodule Statifier.Machine.Content.If do
  @moduledoc """
  A compiled `<if>` executable-content node (spec 4.3, 4.4, 4.5) - the
  interned counterpart to `Statifier.Document.If`. `branches` is the
  document-order partition list: each `Statifier.Machine.Content.If.Branch`
  holds its compiled `cond` (`nil` for the `<else>` branch - spec 4.5.1:
  "`<else>` ... is equivalent to an `<elseif>` with a 'cond' that always
  evaluates to true"), the diagnostic span that `cond` compiled against, and
  the dense `c_index` list assigned to that partition's own content
  (`Statifier.Compiler`'s Decision 2), resolved through
  `Statifier.Machine.content/2` at runtime rather than carried inline.

  ## Why this node's `execute/2` does not recurse through the block runner

  `Statifier.Interpreter.Content`'s block-running function is not called
  from here, for four reasons:

  1. That function returns a bare `Statifier.MachineState.t()`, not a
     `Statifier.ExecutableContent.Context.t()` - it builds a *fresh*
     evaluator context for its own call and discards it on return, so an
     `<assign>` inside a selected partition could never thread its rebuilt
     datamodel context back to a node after the `</if>` in the same
     enclosing block. SCION's `if_else/test0` requires exactly that
     visibility, so recursing through that function would be wrong here,
     not merely inelegant.
  2. That function is the sole site that turns a node's bare `{:error, _}`
     into the platform's own execution-failure notification (ADR-0003).
     Recursing through it would make this file an indirect raiser of that
     notification, which the structural sweep in
     `content_acceptance_test.exs` exists to catch - this file must never
     mention that notification's own name, nor construct one of the structs
     the platform uses to carry it.
  3. That function emits one trace effect per call, carrying an `owner` -
     an `<if>` is not a block owner and has no `owner` value of its own to
     give it.
  4. It would make this file depend on `Statifier.Interpreter`, reentering
     the very protocol dispatch this file is itself a leaf of.

  So `execute/2` folds the selected branch's own `c_index` list directly:
  resolve each through `Statifier.Machine.content/2`, dispatch through
  `Statifier.ExecutableContent.execute/2` - the same two-line
  resolve-then-dispatch shape the block runner's own per-node step takes -
  accumulating effects in document order and halting on the first failure.
  This ~dozen-line fold is deliberately duplicated rather than shared: every
  candidate shared home either reintroduces reason 4's layering inversion or
  turns a runner-only helper into one whose only other caller is a leaf.

  Its `Statifier.ExecutableContent` implementation lives right below the
  struct: this file is the whole node, top to bottom, with no dispatcher
  anywhere else in the tree.
  """

  alias Statifier.Evaluator
  alias Statifier.ExecutableContent
  alias Statifier.ExecutableContent.Context
  alias Statifier.Machine
  alias Statifier.Machine.Content.If
  alias Statifier.Parser.Location

  @enforce_keys [:c_index, :location]
  defstruct [:c_index, :location, branches: []]

  @type t :: %__MODULE__{
          c_index: non_neg_integer(),
          location: Location.t(),
          branches: [If.Branch.t()]
        }

  defmodule Branch do
    @moduledoc """
    One compiled `<if>`/`<elseif>`/`<else>` partition - a small struct
    alongside `Statifier.Machine.Content.If` (Decision 8 of the plan cited on
    the parent module), parallel to `Statifier.Document.If.Branch` without
    being identical to it: this struct carries no `c_index` of its own (a
    branch is not itself a dispatchable content node, only its own content
    is), and its `cond` is already compiled.

    `cond` is `nil` for the `<else>` branch and for a branch with no `cond`
    at all - spec 4.5.1. `cond_location` is the diagnostic span
    `Statifier.Compiler.Expressions.compile/3` used (or would have used) for
    `cond`, `nil` exactly when `cond` is. `content` is the branch's own
    dense, document-order `c_index` list - never a list of inline nodes -
    resolved through `Statifier.Machine.content/2` at runtime.
    """

    alias Statifier.Machine
    alias Statifier.Parser.Location

    defstruct [:cond, :cond_location, content: []]

    @type t :: %__MODULE__{
            cond: Machine.expr() | nil,
            cond_location: Location.t() | nil,
            content: [non_neg_integer()]
          }
  end

  defimpl Statifier.ExecutableContent do
    @moduledoc false

    # spec 4.3.2/4.5.1: scan `branches` in document order, run the first
    # selected partition, run nothing if none is selected ("Otherwise it
    # MUST NOT execute any of the executable content"). Every reason a
    # branch's `cond` could not be trusted (spec 5.9.1) is accumulated into
    # `pending_errors` regardless of which branch - or none - ends up
    # selected; a nested `<if>` may already have put reasons of its own
    # there, so they are appended, never replaced.
    @spec execute(node :: If.t(), context :: Context.t()) :: ExecutableContent.result()
    def execute(%If{branches: branches}, %Context{} = context) do
      {selected, reasons} = select(branches, context.datamodel_context)
      context = %{context | pending_errors: context.pending_errors ++ Enum.reverse(reasons)}

      case selected do
        nil -> {:ok, context, []}
        %If.Branch{content: content} -> run_partition(content, context)
      end
    end

    # The branch scan itself, mirroring
    # `Statifier.Interpreter.Selection`'s own port of spec 5.9.1 for a
    # transition's `cond` (`lib/statifier/interpreter/selection.ex:294-311`,
    # its own "D1" comment) clause for clause, including the
    # `{:non_boolean_cond, other}` reason's exact spelling, so a diagnostic
    # consumer sees one vocabulary for a failed cond regardless of which
    # element it came from. A `nil` cond (the `<else>` branch, or any branch
    # with none written) selects unconditionally - spec 4.5.1's "always
    # evaluates to true". Reasons accumulate in reverse (each one prepended)
    # and are reversed once by the caller, keeping this recursion a plain
    # accumulator fold.
    @spec select(branches :: [If.Branch.t()], datamodel_context :: Predicator.Context.t()) ::
            {If.Branch.t() | nil, [term()]}
    defp select(branches, datamodel_context), do: select(branches, datamodel_context, [])

    @spec select(
            branches :: [If.Branch.t()],
            datamodel_context :: Predicator.Context.t(),
            reasons :: [term()]
          ) :: {If.Branch.t() | nil, [term()]}
    defp select([], _datamodel_context, reasons), do: {nil, reasons}

    defp select([%If.Branch{cond: nil} = branch | _rest], _datamodel_context, reasons) do
      {branch, reasons}
    end

    defp select([%If.Branch{cond: cond_expr} = branch | rest], datamodel_context, reasons) do
      case Evaluator.evaluate(datamodel_context, cond_expr) do
        {:ok, true} ->
          {branch, reasons}

        {:ok, false} ->
          select(rest, datamodel_context, reasons)

        {:ok, other} ->
          select(rest, datamodel_context, [{:non_boolean_cond, other} | reasons])

        {:error, %Evaluator.Error{} = error} ->
          select(rest, datamodel_context, [error | reasons])
      end
    end

    # The selected partition's own fold - see the moduledoc's "why this node
    # does not recurse through the block runner" section for the reasoning.
    # `{:error, new_context, reason}` (a nested `<if>` failing) and
    # `{:error, reason}` (any other node failing) both halt the same way,
    # keeping the inner node's own identity in the wrapped reason so a cause
    # diagnostic does not collapse to just this `<if>`'s own `c_index`.
    @spec run_partition(content :: [non_neg_integer()], context :: Context.t()) ::
            ExecutableContent.result()
    defp run_partition(content, context) do
      Enum.reduce_while(content, {:ok, context, []}, fn c_index, {:ok, context, effects} ->
        node = Machine.content(context.machine_state.machine, c_index)

        case ExecutableContent.execute(node, context) do
          {:ok, new_context, node_effects} ->
            {:cont, {:ok, new_context, effects ++ node_effects}}

          {:error, new_context, reason} ->
            {:halt, {:error, new_context, {:nested_content, c_index, reason}}}

          {:error, reason} ->
            {:halt, {:error, context, {:nested_content, c_index, reason}}}
        end
      end)
    end
  end
end
