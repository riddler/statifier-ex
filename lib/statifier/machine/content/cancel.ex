defmodule Statifier.Machine.Content.Cancel do
  @moduledoc """
  A compiled `<cancel>` executable-content node (spec 6.3) - the interned
  counterpart to `Statifier.Document.Cancel`.

  `sendid` folds `sendid`/`sendidexpr`'s own mutually exclusive pair into a
  single `Machine.expr() | nil`, exactly as `Statifier.Machine.Content.Send`
  folds each of its own static/expr attribute pairs: `{:static, s}` from a
  literal `sendid`, `{:compiled, ...}` from `sendidexpr`, `nil` when neither
  was written (an already-validated document never writes both - 6.3.1's
  own "exactly one of" constraint).

  `attribute_locations` is `Statifier.Document.Cancel`'s own map, carried
  through unchanged - the same call `Statifier.Machine.Content.Send` makes
  for its own nine source attributes.

  Its `Statifier.ExecutableContent` implementation lives right below the
  struct: this file is the whole node, top to bottom, with no dispatcher
  anywhere else in the tree.
  """

  alias Statifier.{Document, Effect, Evaluator, Machine}
  alias Statifier.ExecutableContent.Context
  alias Statifier.Machine.Content.Cancel
  alias Statifier.Parser.Location

  @enforce_keys [:c_index, :location]
  defstruct [
    :c_index,
    :location,
    sendid: nil,
    attribute_locations: %{}
  ]

  @type t :: %__MODULE__{
          c_index: non_neg_integer(),
          location: Location.t(),
          sendid: Machine.expr() | nil,
          attribute_locations: Document.attribute_locations()
        }

  defimpl Statifier.ExecutableContent do
    @moduledoc false

    # spec 6.3's <cancel>: resolve the one `sendid`/`sendidexpr` expression
    # and emit `{:cancel, %Effect.Cancel{}}` unconditionally - a `send_id`
    # matching nothing pending is the session's own no-op
    # (`lib/statifier/session.ex:550`), never this node's concern (6.3
    # "SHOULD make its best attempt"). `<cancel>` is a leaf, so a resolution
    # failure returns the two-element `{:error, reason}` form; the block
    # runner is the sole execution-failure conversion site (ADR-0003), and
    # this file never names that event itself (the structural check in
    # `test/statifier/interpreter/content_acceptance_test.exs` enforces it).
    @spec execute(node :: Cancel.t(), context :: Context.t()) ::
            {:ok, Context.t(), [{:cancel, Effect.Cancel.t()}]} | {:error, term()}
    def execute(%Cancel{} = node, %Context{} = context) do
      %{owner: owner, datamodel_context: datamodel_context, machine_state: machine_state} =
        context

      with {:ok, send_id} <- resolve_expr(datamodel_context, node.sendid) do
        machine_state = %{machine_state | timer_counter: machine_state.timer_counter + 1}

        effect = %Effect.Cancel{
          send_id: send_id,
          c_index: node.c_index,
          owner: owner,
          macrostep: machine_state.macrostep,
          microstep: machine_state.microstep,
          round: machine_state.round,
          ordinal: machine_state.timer_counter,
          # ADR-0063 decision 3: the current macrostep's opaque caller
          # context, copied at the same site that reads the counters.
          caller_context: machine_state.caller_context
        }

        {:ok, %{context | machine_state: machine_state}, [{:cancel, effect}]}
      end
    end

    # `sendid`/`sendidexpr` - `Evaluator.evaluate/2` already handles both
    # `{:static, _}` and `{:compiled, _, _}`. Mirrors
    # `Statifier.Machine.Content.Send`'s own `resolve_expr/2`; unlike that
    # sibling, `node.sendid` is never `nil` on a validated document (6.3.1
    # requires exactly one of the pair), so this has no `nil` clause of its
    # own to share.
    @spec resolve_expr(datamodel_context :: Predicator.Context.t(), expr :: Machine.expr()) ::
            {:ok, term()} | {:error, term()}
    defp resolve_expr(datamodel_context, expr), do: Evaluator.evaluate(datamodel_context, expr)
  end
end
