defmodule Statifier.Machine.Content.Foreach do
  @moduledoc """
  A compiled `<foreach>` executable-content node (spec 4.6) - the interned
  counterpart to `Statifier.Document.Foreach`. `array` is the compiled
  `Machine.expr()` the iteration source evaluates once, before any
  iteration (spec 4.6.3's shallow copy - see step 3 in `execute/2`'s doc
  below for why one evaluation is enough). `item`/`index` are the raw
  attribute strings - bare variable names by 4.6.2, so neither is compiled
  or resolved any earlier than `execute/2`. `content` is the dense,
  document-order `c_index` list of `<foreach>`'s own body, resolved through
  `Statifier.Machine.content/2` at runtime rather than carried inline
  (`Statifier.Compiler`'s Decision 2).

  4.6.3's three MUST sentences this node implements (the platform's own
  execution-failure notification - ADR-0003 - is what "place the error ...
  in the internal event queue" below becomes, one layer up from this file;
  see the "no dispatcher anywhere else" note at the end of this moduledoc
  for why that conversion never happens here):

  > If the SCXML processor does not support the type of the array or if the
  > evaluation of the array expression fails, the SCXML processor MUST
  > terminate execution of the `<foreach>` element ... and place the error
  > in the internal event queue.
  >
  > Modifications to the collection during the execution of `<foreach>`
  > MUST NOT affect the iteration behavior. ... If a shallow copy of the
  > collection is possible, the iteration is done on the copy. Otherwise
  > the iteration is done in such a way that iteration behavior is
  > consistent with the use of a shallow copy.
  >
  > If the SCXML processor encounters an error while evaluating [the
  > `<foreach>` element's `item` binding], it MUST cease execution of the
  > `<foreach>` element **and the block that contains it**, and it MUST
  > place the error in the internal event queue.

  ## Why this node's `execute/2` does not recurse through the block runner,
  and does not write through `<assign>`'s path machinery

  See `Statifier.Machine.Content.If`'s moduledoc for the four reasons a
  composite node's `execute/2` folds its own children directly rather than
  calling back into `Statifier.Interpreter.Content`'s block runner - they
  apply here unchanged, and reason 1 is *more* binding for `<foreach>`,
  since a write to `item`/`index` (or a body `<assign>`) in iteration `n`
  MUST be visible in iteration `n + 1` within the same `<foreach>`.

  `item`/`index` are declared and written directly against the raw
  `machine_state.datamodel` with `Map.put_new/3` / `Map.put/3` - never
  through `Predicator.ContextLocation.put/3`, the machinery
  `Statifier.Machine.Content.Assign` uses. `<assign>`'s `check_root/3` would
  *refuse* the very write 4.6.3 requires (an undeclared `item`/`index`
  becoming declared is the whole point of the corpus's `test150`/`test151`),
  and `item`/`index` are always bare names by Decision 1 below, so there is
  no path to resolve in the first place.

  ## Decision 5: the shallow copy is free

  `array` is evaluated exactly once, before the first iteration
  (`evaluate_array/1` below), and the resulting value becomes the iteration
  source for the whole loop. In an immutable language this already *is*
  the shallow copy 4.6.3 asks for: an Elixir list is a value, so simply not
  re-evaluating `array` per iteration satisfies "modifications to the
  collection during the execution of `<foreach>` MUST NOT affect the
  iteration behavior" with no copy step of its own. Do not move this
  evaluation into the loop, and do not add a defensive `Enum.to_list/1` or
  similar around it - both would be redundant work solving a problem this
  language does not have.

  ## Two-element versus three-element error forms

  Steps 1-4 of `execute/2` (item legality, index legality, array
  evaluation, iterability) run *before* anything is declared or written, so
  a failure there returns the plain two-element `{:error, reason}` form -
  there is nothing yet to preserve. Step 6 (the loop itself) has, by the
  time any iteration's body can fail, already declared `item`/`index` and
  possibly written earlier iterations' mutations into
  `machine_state.datamodel`; 4.6.3 requires those to survive a later
  iteration's failure (the corpus's `test156`), so a body failure returns
  the three-element `{:error, context, reason}` form instead, carrying the
  context as it stood at the moment of failure. This is the single subtlest
  line in this file - do not collapse the two forms into one.

  Its `Statifier.ExecutableContent` implementation lives right below the
  struct: this file is the whole node, top to bottom, with no dispatcher
  anywhere else in the tree.
  """

  alias Statifier.Evaluator
  alias Statifier.ExecutableContent
  alias Statifier.ExecutableContent.Context
  alias Statifier.Machine
  alias Statifier.Machine.Content.Foreach
  alias Statifier.Parser.Location

  @enforce_keys [:c_index, :location, :array, :item]
  defstruct [
    :c_index,
    :location,
    :array,
    :item,
    array_location: nil,
    item_location: nil,
    index: nil,
    index_location: nil,
    content: []
  ]

  @type t :: %__MODULE__{
          c_index: non_neg_integer(),
          location: Location.t(),
          array: Machine.expr(),
          array_location: Location.t() | nil,
          item: String.t(),
          item_location: Location.t() | nil,
          index: String.t() | nil,
          index_location: Location.t() | nil,
          content: [non_neg_integer()]
        }

  defimpl Statifier.ExecutableContent do
    @moduledoc false

    # Decision 1: the intersection of the ECMAScript identifier grammar
    # (minus `$` and Unicode, which nothing in the corpus or predicator's
    # own bare-identifier shape uses) and predicator's own bare-identifier
    # shape - rejects a quoted string literal (`'continue'`, a *value* not
    # a variable), and rejects a dotted path (`foo.bar`, spec 4.6.2's
    # "variable name" versus `<assign location>`'s path).
    @name_regex ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

    @spec execute(node :: Foreach.t(), context :: Context.t()) :: ExecutableContent.result()
    def execute(%Foreach{} = node, %Context{} = context) do
      with :ok <- check_name(node.item, {:illegal_item_name, node.item}),
           :ok <- check_index(node.index),
           {:ok, collection} <- evaluate_array(node, context),
           {:ok, collection} <- check_iterable(collection) do
        context = declare(node, context)
        run_loop(node, collection, context)
      end
    end

    # Step 1/2 (Decision 1): `item` is always checked - 4.6.3 names an
    # illegal `item` name as a termination-and-error condition in as many
    # words. `index` is checked only when the author wrote one, and failing
    # on it is this engine's own strictness rather than something the spec
    # demands: 4.6.3's error sentence names only `item`, and 4.6.2's
    # attribute table constrains `index` to "Any variable name that is
    # valid in the specified data model" without saying what a processor
    # does when it is not. No corpus document exercises an illegal `index`.
    #
    # Both share the same legality regex and the same `_`-prefix
    # system-variable rejection
    # `Statifier.Machine.Content.Assign.check_system_variable/1` performs
    # for the same spec-5.10 reason, reported with the same
    # `{:system_variable, name}` tag so a diagnostic consumer sees one
    # vocabulary regardless of which element wrote the illegal name.
    @spec check_name(name :: String.t(), illegal_reason :: term()) ::
            :ok | {:error, term()}
    defp check_name(name, illegal_reason) do
      cond do
        String.starts_with?(name, "_") -> {:error, {:system_variable, name}}
        Regex.match?(@name_regex, name) -> :ok
        true -> {:error, illegal_reason}
      end
    end

    @spec check_index(index :: String.t() | nil) :: :ok | {:error, term()}
    defp check_index(nil), do: :ok
    defp check_index(index), do: check_name(index, {:illegal_index_name, index})

    # Step 3 (Decision 5): `array` is evaluated exactly once, here, before
    # any iteration - see the moduledoc's "the shallow copy is free"
    # section for why this single evaluation is 4.6.3's shallow copy in an
    # immutable language, and why re-evaluating inside the loop would be
    # wrong.
    @spec evaluate_array(node :: Foreach.t(), context :: Context.t()) ::
            {:ok, term()} | {:error, term()}
    defp evaluate_array(%Foreach{array: array}, %Context{datamodel_context: datamodel_context}) do
      case Evaluator.evaluate(datamodel_context, array) do
        {:ok, value} -> {:ok, value}
        {:error, %Evaluator.Error{} = error} -> {:error, error}
      end
    end

    # Step 4 (Decision 5): a list is the only iterable Predicator value type
    # with a defined iteration order - a map has no order 4.6.3's "iteration
    # order that is defined for the collection" could name, and no corpus
    # document iterates one.
    @spec check_iterable(value :: term()) :: {:ok, list()} | {:error, {:not_iterable, term()}}
    defp check_iterable(value) when is_list(value), do: {:ok, value}
    defp check_iterable(value), do: {:error, {:not_iterable, value}}

    # Step 5 (Decision 2/6): declares `item` (and, when present, `index`)
    # with `Map.put_new/3` on the *raw* `machine_state.datamodel` - never
    # through `<assign>`'s path machinery, and never onto the normalized
    # `%Predicator.Context{}` (st-af3.4's Decision 2's `nil`-versus-
    # `:undefined` round-trip). This runs even for an empty collection, so
    # `item`/`index` are bound (to `nil`, matching
    # `Statifier.Interpreter.Datamodel.seed/2`'s own `<data>`-with-no-value
    # shape) whether or not the loop body ever runs. ADR-0028: the block's
    # threaded datamodel context gets the same two names bound into it with
    # `Evaluator.bind/3` rather than a full rebuild - `item`/`index` are
    # each their own datamodel root, so a bind is the canonical shape here
    # too.
    @spec declare(node :: Foreach.t(), context :: Context.t()) :: Context.t()
    defp declare(%Foreach{item: item, index: index}, %Context{} = context) do
      datamodel =
        context.machine_state.datamodel
        |> Map.put_new(item, nil)
        |> maybe_put_new(index)

      bind_names(context, datamodel, item, index)
    end

    @spec maybe_put_new(datamodel :: map(), index :: String.t() | nil) :: map()
    defp maybe_put_new(datamodel, nil), do: datamodel
    defp maybe_put_new(datamodel, index), do: Map.put_new(datamodel, index, nil)

    # Step 6: one iteration per element of the array evaluated in step 3.
    # Each iteration writes `item` (and, when present, the 0-based `index`)
    # with `Map.put/3`, rebuilds the block's `datamodel_context` **once**
    # per iteration (Decision 3 - not once per write, since nothing runs
    # between the two writes), then folds `node.content` exactly as
    # `Statifier.Machine.Content.If`'s `run_partition/2` does: resolve each
    # `c_index` through `Statifier.Machine.content/2`, dispatch through
    # `Statifier.ExecutableContent.execute/2`, accumulate effects in
    # document order, and halt on the first failure, wrapping it as
    # `{:nested_content, c_index, reason}` (Decision 4, byte-identical to
    # `<if>`'s own wrapper) - the two-versus-three-element split is what
    # keeps the datamodel mutations already made surviving a later
    # iteration's failure.
    @spec run_loop(node :: Foreach.t(), collection :: list(), context :: Context.t()) ::
            ExecutableContent.result()
    defp run_loop(%Foreach{} = node, collection, %Context{} = context) do
      Enum.reduce_while(
        Enum.with_index(collection),
        {:ok, context, []},
        fn {value, index}, {:ok, context, effects} ->
          context = write_iteration(node, value, index, context)

          case run_content(node.content, context) do
            {:ok, new_context, node_effects} ->
              {:cont, {:ok, new_context, effects ++ node_effects}}

            {:error, new_context, reason} ->
              {:halt, {:error, new_context, reason}}
          end
        end
      )
    end

    # ADR-0028: `item` and, when declared, `index` are each bound into the
    # block's threaded context with `Evaluator.bind/3` - two single-root
    # writes, the canonical `bind/3` shape - instead of a full
    # `Evaluator.context/1` rebuild. This is the multiplicative rebuild site
    # the benchmark measured (`bench/results/260814-macrostep.md`'s
    # `<foreach>` sweep), so it is also the largest share of the win.
    @spec write_iteration(
            node :: Foreach.t(),
            value :: term(),
            index :: non_neg_integer(),
            context :: Context.t()
          ) :: Context.t()
    defp write_iteration(
           %Foreach{item: item, index: index_name},
           value,
           index,
           %Context{} = context
         ) do
      datamodel =
        context.machine_state.datamodel
        |> Map.put(item, value)
        |> maybe_put_index(index_name, index)

      bind_names(context, datamodel, item, index_name)
    end

    @spec maybe_put_index(
            datamodel :: map(),
            index_name :: String.t() | nil,
            index :: non_neg_integer()
          ) ::
            map()
    defp maybe_put_index(datamodel, nil, _index), do: datamodel
    defp maybe_put_index(datamodel, index_name, index), do: Map.put(datamodel, index_name, index)

    # Shared by `declare/2` and `write_iteration/4`: swaps in the new raw
    # `datamodel` and binds `item`'s (and, when present, `index_name`'s)
    # freshly written value into the block's existing threaded
    # `datamodel_context`, rather than rebuilding it from the whole
    # datamodel. Each bind reads its value back off `datamodel` - not off
    # the caller's already-normalized value - so `declare/2`'s `nil` default
    # and `write_iteration/4`'s real value both go through
    # `Evaluator.bind/3`'s own `nil` -> `:undefined` normalization
    # identically.
    @spec bind_names(
            context :: Context.t(),
            datamodel :: map(),
            item :: String.t(),
            index_name :: String.t() | nil
          ) :: Context.t()
    defp bind_names(%Context{} = context, datamodel, item, index_name) do
      machine_state = %{context.machine_state | datamodel: datamodel}

      datamodel_context =
        context.datamodel_context
        |> Evaluator.bind(item, Map.fetch!(datamodel, item))
        |> maybe_bind_index(index_name, datamodel)

      %{context | machine_state: machine_state, datamodel_context: datamodel_context}
    end

    @spec maybe_bind_index(
            datamodel_context :: Predicator.Context.t(),
            index_name :: String.t() | nil,
            datamodel :: map()
          ) :: Predicator.Context.t()
    defp maybe_bind_index(datamodel_context, nil, _datamodel), do: datamodel_context

    defp maybe_bind_index(datamodel_context, index_name, datamodel),
      do: Evaluator.bind(datamodel_context, index_name, Map.fetch!(datamodel, index_name))

    # The body's own fold - see the moduledoc's "why this node does not
    # recurse through the block runner" section. `{:error, new_context,
    # reason}` (a nested composite node failing) and `{:error, reason}`
    # (any other node failing) both halt the same way, wrapping the inner
    # node's own `c_index` so a cause diagnostic does not collapse to just
    # this `<foreach>`'s own `c_index`.
    @spec run_content(content :: [non_neg_integer()], context :: Context.t()) ::
            ExecutableContent.result()
    defp run_content(content, context) do
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
