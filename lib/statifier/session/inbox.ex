defmodule Statifier.Session.Inbox do
  @moduledoc """
  The waiting external events, plus Appendix D's `isCancelEvent` check.

  ADR-0002 mechanical deviation, ADR-0003: Appendix D's `mainEventLoop` owns
  both queues and blocks on `externalQueue.dequeue()`, checking
  `isCancelEvent/1` on what it dequeues. `Statifier.MachineState` owns only the
  internal queue, so the waiting external events and the cancel check live
  here, in the driver. The semantics of processing one external event are
  unchanged; only the storage of the waiting ones moves.

  Appendix D's `isCancelEvent` is described by spec 6.4 as platform specific
  ("here we assume it's a special event we receive"). This platform makes the
  cancel a distinct *queue entry* rather than a reserved event name, so no
  document can raise one by writing that name, and `cancel_event?/1` is a
  structural match.
  """

  alias Statifier.Event

  @enforce_keys [:queue]
  defstruct [:queue]

  @typedoc """
  One waiting entry: an external event, an external event one of *this*
  session's own invocations delivered, or the cancel marker.

  `{:invoked_event, invoke_id, event}` is a separate kind rather than a flag
  on `event` because 6.4.3's discard is a property of *where the entry came
  from*, not of the event: 6.4.2 requires an autoforwarded copy to preserve
  every 5.10.1 field, `invokeid` included, so an event forwarded down to a
  child still carries the *sibling* invocation's id in a frame where it
  names nothing. Keying the discard on the entry kind is what keeps a
  forwarded sibling event deliverable while a cancelled invocation's own
  queued events still drop (`Statifier.Session`'s `handle_continue(:drain, _)`).
  """
  @type entry :: {:event, Event.t()} | {:invoked_event, String.t(), Event.t()} | :cancel

  @opaque t :: %__MODULE__{queue: :queue.queue(entry())}

  @doc "An empty inbox."
  @spec new() :: t()
  def new, do: %__MODULE__{queue: :queue.new()}

  @doc "Appends `event` to the back of the inbox, wrapped as an `:event` entry."
  @spec enqueue_event(inbox :: t(), event :: Event.t()) :: t()
  def enqueue_event(%__MODULE__{queue: queue}, %Event{} = event) do
    %__MODULE__{queue: :queue.in({:event, event}, queue)}
  end

  @doc """
  Appends `event` as an entry originating from this session's own invocation
  `invoke_id` - the child-to-parent direction only
  (`<send target="#_parent">`, `done.invoke.<invokeid>`, and its ADR-0068
  failing counterpart `error.communication.invoke.<invokeid>`). Everything else,
  autoforwarded copies included, goes through `enqueue_event/2`.
  """
  @spec enqueue_invoked_event(inbox :: t(), invoke_id :: String.t(), event :: Event.t()) :: t()
  def enqueue_invoked_event(%__MODULE__{queue: queue}, invoke_id, %Event{} = event)
      when is_binary(invoke_id) do
    %__MODULE__{queue: :queue.in({:invoked_event, invoke_id, event}, queue)}
  end

  @doc "Appends the cancel marker to the back of the inbox."
  @spec enqueue_cancel(inbox :: t()) :: t()
  def enqueue_cancel(%__MODULE__{queue: queue}) do
    %__MODULE__{queue: :queue.in(:cancel, queue)}
  end

  @doc """
  Dequeues the front entry, mirroring Appendix D's
  `externalQueue.dequeue()`. `:empty` when nothing is waiting - there is no
  blocking wait here; the caller decides what to do while idle.
  """
  @spec next(inbox :: t()) :: {:ok, entry(), t()} | :empty
  def next(%__MODULE__{queue: queue}) do
    case :queue.out(queue) do
      {{:value, entry}, rest} -> {:ok, entry, %__MODULE__{queue: rest}}
      {:empty, _rest} -> :empty
    end
  end

  @doc "Appendix D's `isCancelEvent/1`: true only for the cancel marker itself."
  @spec cancel_event?(entry :: entry()) :: boolean()
  def cancel_event?(:cancel), do: true
  def cancel_event?({:event, %Event{}}), do: false
  def cancel_event?({:invoked_event, _invoke_id, %Event{}}), do: false

  @doc """
  The waiting events, front to back, cancel markers dropped - the
  `internal_events/1`-shaped inspection view
  (`Statifier.MachineState.internal_events/1`). No code outside this module
  touches `:queue` directly.
  """
  @spec pending_events(inbox :: t()) :: [Event.t()]
  def pending_events(%__MODULE__{queue: queue}) do
    queue
    |> :queue.to_list()
    |> Enum.flat_map(fn
      {:event, event} -> [event]
      {:invoked_event, _invoke_id, event} -> [event]
      :cancel -> []
    end)
  end

  @doc "The number of waiting entries, events and cancel markers both."
  @spec size(inbox :: t()) :: non_neg_integer()
  def size(%__MODULE__{queue: queue}), do: :queue.len(queue)
end
