defmodule Statifier.Session.Timers do
  @moduledoc """
  The pending delayed-send timers, as a value.

  Spec 6.3: "If multiple delayed events have this sendid, the Processor will
  cancel them all" - so a send id maps to a *list* of references, in
  scheduling order, not to one. A send scheduled with no id is tracked for
  termination cleanup but cannot be cancelled: `<cancel>` names a sendid, and
  there is none to name.

  Spec 6.2 requires that a session terminating before a delay elapses discard
  the message without delivering it, which is what `refs/1` exists for: the
  caller cancels every reference it returns.

  Nothing here calls `Process.send_after/3` or `Process.cancel_timer/1`. This
  module decides which references are affected; `Statifier.Session` performs
  the cancellation.
  """

  @enforce_keys [:by_id, :live]
  defstruct [:by_id, :live]

  @opaque t :: %__MODULE__{by_id: %{String.t() => [reference()]}, live: MapSet.t(reference())}

  @doc "An empty timer table."
  @spec new() :: t()
  def new, do: %__MODULE__{by_id: %{}, live: MapSet.new()}

  @doc """
  Tracks `ref` as live, and appends it to `send_id`'s list when `send_id` is
  not `nil` - scheduling order preserved, so a later `take/2` returns the
  refs in the order they were scheduled.
  """
  @spec put(timers :: t(), send_id :: String.t() | nil, ref :: reference()) :: t()
  def put(%__MODULE__{by_id: by_id, live: live}, nil, ref) do
    %__MODULE__{by_id: by_id, live: MapSet.put(live, ref)}
  end

  def put(%__MODULE__{by_id: by_id, live: live}, send_id, ref) when is_binary(send_id) do
    %__MODULE__{
      by_id: Map.update(by_id, send_id, [ref], &(&1 ++ [ref])),
      live: MapSet.put(live, ref)
    }
  end

  @doc """
  Removes and returns every reference under `send_id`, in scheduling order.
  An unknown id returns `{[], timers}` - spec 6.3 makes that a no-op, not an
  error.
  """
  @spec take(timers :: t(), send_id :: String.t()) :: {[reference()], t()}
  def take(%__MODULE__{by_id: by_id, live: live} = timers, send_id) when is_binary(send_id) do
    case Map.pop(by_id, send_id) do
      {nil, ^by_id} ->
        {[], timers}

      {refs, rest_by_id} ->
        {refs, %__MODULE__{by_id: rest_by_id, live: MapSet.difference(live, MapSet.new(refs))}}
    end
  end

  @doc """
  Drops a reference that has already fired: removed from the live set and
  from whichever `send_id` list still names it.
  """
  @spec forget(timers :: t(), ref :: reference()) :: t()
  def forget(%__MODULE__{by_id: by_id, live: live}, ref) do
    rest_by_id =
      by_id
      |> Enum.map(fn {id, refs} -> {id, List.delete(refs, ref)} end)
      |> Enum.reject(fn {_id, refs} -> refs == [] end)
      |> Map.new()

    %__MODULE__{by_id: rest_by_id, live: MapSet.delete(live, ref)}
  end

  @doc "Every live reference, `nil`-id sends included - what a terminating session cancels."
  @spec refs(timers :: t()) :: [reference()]
  def refs(%__MODULE__{live: live}), do: MapSet.to_list(live)

  @doc "The number of live references."
  @spec count(timers :: t()) :: non_neg_integer()
  def count(%__MODULE__{live: live}), do: MapSet.size(live)
end
