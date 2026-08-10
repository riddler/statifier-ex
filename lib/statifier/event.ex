defmodule Statifier.Event do
  @moduledoc """
  The value every queue holds and every selection round matches against -
  spec 5.10.1's event, `name` plus `data` plus `type`, with the
  constraint-4 cause slot (`docs/observability.md`) for events the platform
  raised itself.

  ## `type` is provenance, not routing

  `type :: :external | :internal | :platform` mirrors spec 5.10.1's three
  event types exactly. `:platform` events (`error.execution`,
  `error.communication`, `done.state.*`, and friends) are enqueued on the
  *internal* queue exactly like `:internal` ones - there is no third queue.
  `type` only records where the event came from, so a consumer that cares
  (a log, a trace payload, `error.execution`'s own message) can tell a
  platform-raised error apart from a document-raised `<raise>` without
  guessing from the name.

  ## `cause` is `nil` unless the platform raised it

  `cause` is a `Statifier.Event.Cause.t()` for `:internal` and `:platform`
  events - `Statifier.MachineState.raise_internal/4` builds one from the
  raising node's identity and the current counters - and always `nil` for
  `:external` events, since nothing in this engine raised those; they
  arrived from outside.

  ## What is deliberately absent

  - `_event`, spec 5.10's system variable holding the last processed event,
    is datamodel content and lands in the datamodel slot once that
    evaluation work exists. It is not a field here.
  - `origin` and `sendid` (spec 5.10.1's remaining event fields) are left
    out rather than carried dead: they matter to `<send>`/`<invoke>`
    round-tripping, which the not-yet-implemented session support handles.
    They get added once that caller exists.
  """

  alias Statifier.Event.Cause

  @enforce_keys [:name, :type]
  defstruct [:name, :type, data: nil, cause: nil]

  @typedoc "Spec 5.10.1's three event types - provenance, not queue routing."
  @type type :: :external | :internal | :platform

  @type t :: %__MODULE__{
          name: String.t(),
          data: term(),
          type: type(),
          cause: Cause.t() | nil
        }

  @doc """
  An externally received event - always `cause: nil`, since nothing in this
  engine raised it. `data` defaults to `nil` ("no data"), distinct from
  `%{}` ("data, empty").
  """
  @spec external(name :: String.t(), opts :: keyword()) :: t()
  def external(name, opts \\ []) do
    %__MODULE__{name: name, type: :external, data: Keyword.get(opts, :data)}
  end

  @doc """
  An event raised by executable content in the document - spec 5.10.1
  restricts `type: :internal` to `<raise>` and `<send>` with
  `target="#_internal"`; a `<send>` with no `target` goes to the sending
  session's *external* queue and is `type: :external` instead, not this
  constructor. `cause` travels through unchanged from the caller, which
  built it from the raising node's identity and the current counters.
  """
  @spec internal(name :: String.t(), cause :: Cause.t(), opts :: keyword()) :: t()
  def internal(name, %Cause{} = cause, opts \\ []) do
    %__MODULE__{name: name, type: :internal, cause: cause, data: Keyword.get(opts, :data)}
  end

  @doc """
  An event the platform itself raised (`error.execution`,
  `error.communication`, `done.state.*`) - rides the internal queue exactly
  like `internal/3`; `type: :platform` only distinguishes its
  provenance for a consumer that cares.
  """
  @spec platform(name :: String.t(), cause :: Cause.t(), opts :: keyword()) :: t()
  def platform(name, %Cause{} = cause, opts \\ []) do
    %__MODULE__{name: name, type: :platform, cause: cause, data: Keyword.get(opts, :data)}
  end
end
