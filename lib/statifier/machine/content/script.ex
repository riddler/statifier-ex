defmodule Statifier.Machine.Content.Script do
  @moduledoc """
  A compiled `<script>` executable-content node (spec 5.8, ADR-0026) - the
  interned counterpart to `Statifier.Document.Script`.

  `program` is `Statifier.Machine.program()` - a compiled predicator
  *statement* program, `Machine.expr()`'s sibling and never one of its
  arms - or `{:invalid, Compiler.Error.t()}` when the body failed to
  compile (`Statifier.Compiler.build_content_node/2`'s `%Document.Script{}`
  clause, Decision 1 of
  `docs/plans/260814-st-af3.17-script-statement-bodies.md`): compilation
  happens once at load, but a body outside predicator's statement grammar
  (an ECMAScript body this engine cannot parse) defers its failure to
  `execute/2`, exactly the way `Statifier.Machine.Content.Assign`'s
  `value` field and `Statifier.Machine.Data`'s `value` field already defer
  theirs, rather than rejecting the whole document at load time.
  `node_location` is this node's own `Statifier.Parser.Location` span.

  ## Why a `<script>` may create a new top-level root, unlike `<assign>`

  `Statifier.Machine.Content.Assign`'s `check_root/3`
  (`assign.ex:162-173`) refuses to write a root no `<datamodel>` already
  declares - `<assign>`'s `location` attribute is a *reference* to a
  location the document must already have (spec 5.9.2's "cannot be
  evaluated to yield a valid location"). A predicator assignment
  *statement*, by contrast, is a declaration and a write in one: `x = 1`
  inside a `<script>` body both introduces `x` and gives it a value, the
  same way a bare assignment does in the languages spec 5.8 anticipates.
  W3C `test302` and `test304` assert exactly this - `Var1` appears in no
  `<datamodel>` in either document, and the pass state is reached anyway.
  `execute/2` below therefore gets no `check_root/3` equivalent: this is a
  deliberate asymmetry with `<assign>`, not an oversight, and
  `Statifier.Evaluator.execute/2`'s own moduledoc records the same
  reasoning on the write side.

  Its `Statifier.ExecutableContent` implementation lives right below the
  struct: this file is the whole node, top to bottom, with no dispatcher
  anywhere else in the tree.
  """

  alias Statifier.Compiler.Error, as: CompilerError
  alias Statifier.Evaluator
  alias Statifier.ExecutableContent.Context
  alias Statifier.Machine
  alias Statifier.Machine.Content.Script
  alias Statifier.Parser.Location

  @enforce_keys [:c_index, :program, :node_location]
  defstruct [:c_index, :program, :node_location]

  @type program :: Machine.program() | {:invalid, CompilerError.t()}

  @type t :: %__MODULE__{
          c_index: non_neg_integer(),
          program: program(),
          node_location: Location.t()
        }

  defimpl Statifier.ExecutableContent do
    @moduledoc false

    # ADR-0026 decision 1: a program that never compiled has nothing to run
    # and no partial context of its own to keep, so this is the two-element
    # `{:error, reason}` form (a leaf, not a composite node) - `error` is
    # already a `Statifier.Compiler.Error.t()`, the same shape
    # `Statifier.Machine.Content.Assign.evaluate_value/2` short-circuits
    # `{:invalid, error}` into.
    @spec execute(node :: Script.t(), context :: Context.t()) ::
            {:ok, Context.t(), []} | {:error, term()}
    def execute(%Script{program: {:invalid, error}}, %Context{}), do: {:error, error}

    # `Statifier.Evaluator.execute/2` runs `program` against the block's
    # machine state, merging its writes into the raw datamodel (Decisions
    # 3/4 there) - `rebind/2` below is what carries the mutated
    # `machine_state` and a freshly rebuilt `datamodel_context` back onto
    # this block's `Context.t()`, the same "rebuild the block's context so a
    # later node in the same block sees the write" step
    # `Statifier.Machine.Content.Assign.execute/2` takes for its own single
    # write, done here for the whole program's writes at once. A mid-program
    # failure still returns the three-element `{:error, context, error}`
    # form (ADR-0026 decision 1: keep the partial context), which
    # `Statifier.Interpreter.Content`'s runner already treats as "keep
    # `new_context`, then convert the failure into the runner's usual
    # execution-failure platform notification" with no protocol change
    # (this plan's Key Discoveries).
    def execute(%Script{program: program}, %Context{} = context) do
      case Evaluator.execute(context.machine_state, program) do
        {:ok, machine_state} ->
          {:ok, rebind(context, machine_state), []}

        {:error, machine_state, error} ->
          {:error, rebind(context, machine_state), error}
      end
    end

    @spec rebind(context :: Context.t(), machine_state :: Statifier.MachineState.t()) ::
            Context.t()
    defp rebind(%Context{} = context, machine_state) do
      %{
        context
        | machine_state: machine_state,
          datamodel_context: Evaluator.context(machine_state)
      }
    end
  end
end
