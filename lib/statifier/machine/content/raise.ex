defmodule Statifier.Machine.Content.Raise do
  @moduledoc """
  A compiled `<raise>` executable-content node (spec 4.2) - the interned
  counterpart to `Statifier.Document.Raise`. `event` is the literal event
  name being enqueued - never tokenized, unlike a `<transition>`'s `event`
  attribute (`lib/statifier/document/raise.ex:6-13`).

  Its `Statifier.ExecutableContent` implementation lives right below the
  struct: this file is the whole node, top to bottom, with no dispatcher
  anywhere else in the tree.
  """

  alias Statifier.ExecutableContent.Context
  alias Statifier.Machine.Content.Raise
  alias Statifier.MachineState
  alias Statifier.Parser.Location

  @enforce_keys [:c_index, :event, :location]
  defstruct [:c_index, :event, :location]

  @type t :: %__MODULE__{
          c_index: non_neg_integer(),
          event: String.t(),
          location: Location.t()
        }

  defimpl Statifier.ExecutableContent do
    @moduledoc false

    # spec 4.2's <raise>: enqueue one internal event named by `event`, cause
    # stamped from this node and its owning block. No effect is emitted -
    # the queued event is core state, not an effect.
    @spec execute(node :: Raise.t(), context :: Context.t()) :: {:ok, Context.t(), []}
    def execute(%Raise{c_index: c_index, event: event}, %Context{} = context) do
      machine_state =
        MachineState.raise_internal(
          context.machine_state,
          event,
          {:content, c_index, context.owner}
        )

      {:ok, %{context | machine_state: machine_state}, []}
    end
  end
end
