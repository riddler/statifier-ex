defmodule Statifier.Machine.Content.Assign do
  @moduledoc """
  A compiled `<assign>` executable-content node (spec 5.4, 5.9.2) - the
  interned counterpart to `Statifier.Document.Assign`.

  `location` is the raw, uncompiled SCXML `location` attribute (a path
  expression such as `"foo.bar.baz"` or `"items[0]"`) - it cannot be resolved
  any earlier than `execute/2` even in principle, since a bracket key such as
  `items[i]` reads `i` against the *pre-assignment* datamodel (Decision 6,
  `docs/plans/260813-st-af3.4-assign-deep-path-vivification.md`). `node_location`
  is this node's own `Statifier.Parser.Location` span - named apart from
  `location` for exactly the reason `Statifier.Document.Assign`'s moduledoc
  gives, so the raw path string and the element's own span are never
  confused. `location_location` is `attribute_locations[:location]`'s value
  span (the `location` attribute's own span, `nil` only if somehow never
  written - spec 5.4.2 requires it), following `expr_location`'s "caller's
  choice" convention every other compiled node uses.

  `value` is the value-source ladder's compiled result: `{:static, nil}` when
  `<assign>` writes no `expr` (Phase 3 adds the child-content rungs),
  otherwise `Machine.expr()` or - Decision 6's deferral, the same mechanism
  `Statifier.Machine.Data.value` already uses for `<data expr>` - `{:invalid,
  Compiler.Error.t()}` when `expr` failed to compile. `expr_location` is
  `nil` exactly when `expr` was never written.

  Its `Statifier.ExecutableContent` implementation lives right below the
  struct: this file is the whole node, top to bottom, with no dispatcher
  anywhere else in the tree. The location-resolution, system-variable,
  root-existence, and write mechanics (spec 5.4.2/5.9.2/5.10) live in
  `Statifier.Interpreter.Datamodel.write_location/4` - extracted so
  `idlocation` (6.4.1) and the empty-`<finalize>` auto-assign (6.5) can call
  the same mechanics without duplicating them here.
  """

  alias Statifier.Compiler.Error, as: CompilerError
  alias Statifier.Evaluator
  alias Statifier.ExecutableContent.Context
  alias Statifier.Interpreter.Datamodel
  alias Statifier.Machine
  alias Statifier.Machine.Content.Assign
  alias Statifier.Parser.Location

  @enforce_keys [:c_index, :location, :node_location]
  defstruct [
    :c_index,
    :location,
    :node_location,
    value: {:static, nil},
    location_location: nil,
    expr_location: nil
  ]

  @type value :: Machine.expr() | {:invalid, CompilerError.t()}

  @type t :: %__MODULE__{
          c_index: non_neg_integer(),
          location: String.t(),
          node_location: Location.t(),
          value: value(),
          location_location: Location.t() | nil,
          expr_location: Location.t() | nil
        }

  defimpl Statifier.ExecutableContent do
    @moduledoc false

    # spec 5.4.2/5.9.2's <assign>: evaluate the value, then delegate
    # `location`'s resolution, the "_"-rooted system-variable rejection
    # (Decision 5, spec 5.10), the root-existence check (Decision 4 -
    # vivification never creates an undeclared top-level variable), the
    # write into the *raw* `machine_state.datamodel`, and the rebind of the
    # written root into the block's threaded datamodel context (ADR-0028) to
    # `Statifier.Interpreter.Datamodel.write_location/4` - the seam
    # `Statifier.Interpreter.Content`'s moduledoc names as taken here, in
    # the node, never in the runner. Every predicator failure becomes
    # `{:error, reason}`, never a raise and never a platform notification of
    # its own - the runner is the sole conversion site for that (ADR-0003).
    @spec execute(node :: Assign.t(), context :: Context.t()) ::
            {:ok, Context.t(), []} | {:error, term()}
    def execute(%Assign{location: location} = node, %Context{} = context) do
      with {:ok, value} <- evaluate_value(node, context),
           {:ok, machine_state, datamodel_context} <-
             Datamodel.write_location(
               context.machine_state,
               context.datamodel_context,
               location,
               value
             ) do
        {:ok, %{context | machine_state: machine_state, datamodel_context: datamodel_context}, []}
      end
    end

    # Step 1: the value to write. `{:invalid, error}` is Decision 6's
    # deferred compile failure and short-circuits without ever reaching the
    # evaluator - the same shape `Statifier.Interpreter.Datamodel.bind_value/4`
    # gives `<data expr>`. Anything else is a real `Machine.expr()`,
    # evaluated against the block's context exactly as every other
    # expression-bearing node would.
    @spec evaluate_value(node :: Assign.t(), context :: Context.t()) ::
            {:ok, term()} | {:error, term()}
    defp evaluate_value(%Assign{value: {:invalid, error}}, %Context{}), do: {:error, error}

    defp evaluate_value(%Assign{value: value}, %Context{datamodel_context: datamodel_context}) do
      Evaluator.evaluate(datamodel_context, value)
    end
  end
end
