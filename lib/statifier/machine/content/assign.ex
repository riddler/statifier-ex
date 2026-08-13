defmodule Statifier.Machine.Content.Assign do
  @moduledoc """
  A compiled `<assign>` executable-content node (spec 4.7.1, 5.9.2) - the
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
  anywhere else in the tree.
  """

  alias Statifier.Compiler.Error, as: CompilerError
  alias Statifier.Evaluator
  alias Statifier.ExecutableContent.Context
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

    # spec 4.7.1/5.9.2's <assign>: evaluate the value, resolve `location`
    # against the block's (pre-write) datamodel context, verify the
    # resolved root already exists (Decision 4 - vivification never creates
    # an undeclared top-level variable), then write into the *raw*
    # `machine_state.datamodel` and rebuild the block's datamodel context so
    # a later node in the same block sees the write (Decision 3 - this is
    # the seam `Statifier.Interpreter.Content`'s moduledoc names as taken
    # here, in the node, never in the runner). Every predicator failure
    # becomes `{:error, reason}`, never a raise and never a platform
    # notification of its own - the runner is the sole conversion site for
    # that (ADR-0003).
    @spec execute(node :: Assign.t(), context :: Context.t()) ::
            {:ok, Context.t(), []} | {:error, term()}
    def execute(%Assign{} = node, %Context{} = context) do
      with {:ok, value} <- evaluate_value(node, context),
           {:ok, path} <- resolve_location(node, context),
           :ok <- check_root(node, context, path),
           {:ok, new_datamodel} <- write(node, context, path, value) do
        machine_state = %{context.machine_state | datamodel: new_datamodel}

        {:ok,
         %{
           context
           | machine_state: machine_state,
             datamodel_context: Evaluator.context(machine_state)
         }, []}
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

    # Step 2: resolve `location` into a path. Resolution reads
    # `datamodel_context.data` - the normalized view, so a bracket key such
    # as `items[i]` reads `i` exactly as an expression would (Decision 2) -
    # never the `%Predicator.Context{}` struct itself, which would also
    # satisfy `context_location/3`'s `is_map/1` guard and then look up the
    # wrong keys entirely.
    @spec resolve_location(node :: Assign.t(), context :: Context.t()) ::
            {:ok, Predicator.ContextLocation.location_path()} | {:error, term()}
    defp resolve_location(%Assign{location: location}, %Context{
           datamodel_context: %Predicator.Context{data: data}
         }) do
      case Predicator.context_location(location, data) do
        {:ok, path} -> {:ok, path}
        {:error, error} -> {:error, Evaluator.Error.new(location, error)}
      end
    end

    # Step 3 (Decision 4): the resolved root segment must already be a key
    # of `machine_state.datamodel` - predicator's own `put/3` would happily
    # vivify an undeclared root, but 5.9.2 requires this to fail when a
    # location "cannot be evaluated to yield a valid location", and
    # `docs/datamodel.md`'s scope commitment is auto-vivification of
    # *intermediate* containers, never creation of undeclared top-level
    # variables (`test286_test.exs`).
    @spec check_root(
            node :: Assign.t(),
            context :: Context.t(),
            path :: Predicator.ContextLocation.location_path()
          ) :: :ok | {:error, term()}
    defp check_root(%Assign{location: location}, %Context{machine_state: machine_state}, path) do
      if Map.has_key?(machine_state.datamodel, List.first(path)) do
        :ok
      else
        {:error, {:unbound_location, location}}
      end
    end

    # Step 4: the write itself, against the *raw* `machine_state.datamodel`
    # (`nil`s intact) rather than the normalized context read in step 2 -
    # Decision 2's `nil`-versus-`:undefined` round trip. `context.data`
    # deep-normalizes `nil` to `:undefined`, and nothing in `lib/` reads it
    # back out; writing through the raw map is what keeps an unrelated
    # seeded-but-unbound `<data>` id reading `nil`, not `:undefined`, after
    # this write.
    @spec write(
            node :: Assign.t(),
            context :: Context.t(),
            path :: Predicator.ContextLocation.location_path(),
            value :: term()
          ) :: {:ok, map()} | {:error, term()}
    defp write(%Assign{location: location}, %Context{machine_state: machine_state}, path, value) do
      case Predicator.ContextLocation.put(machine_state.datamodel, path, value) do
        {:ok, new_datamodel} -> {:ok, new_datamodel}
        {:error, error} -> {:error, Evaluator.Error.new(location, error)}
      end
    end
  end
end
