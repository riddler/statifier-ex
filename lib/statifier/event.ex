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

  `origin`, `origintype` and `sendid` (spec 5.10.1's remaining event fields)
  are no longer on this list: `Statifier.Session.Effects`' delivery path
  (the `target: nil` `<send>` clauses) became their first reader/writer, the
  same way `Statifier.Interpreter`'s finalize/autoforward pass became
  `invokeid`'s. `origintype` was never named on this list at all before -
  it simply had no field yet.
  """

  alias Statifier.Event.Cause

  @enforce_keys [:name, :type]
  defstruct [
    :name,
    :type,
    data: nil,
    cause: nil,
    invokeid: nil,
    origin: nil,
    origintype: nil,
    sendid: nil
  ]

  @typedoc "Spec 5.10.1's three event types - provenance, not queue routing."
  @type type :: :external | :internal | :platform

  @type t :: %__MODULE__{
          name: String.t(),
          data: term(),
          type: type(),
          cause: Cause.t() | nil,
          invokeid: String.t() | nil,
          origin: String.t() | nil,
          origintype: String.t() | nil,
          sendid: String.t() | nil
        }

  @doc """
  An externally received event - always `cause: nil`, since nothing in this
  engine raised it. `data` defaults to `nil` ("no data"), distinct from
  `%{}` ("data, empty"). `invokeid` (spec 5.10.1) defaults to `nil` - most
  external events arrive from outside any invocation; a caller delivering an
  event from an invoked child's session passes `invokeid: invoke_id`.
  `origin`, `origintype` and `sendid` (spec 5.10.1 / C.1) default to `nil`
  too; `Statifier.Session.Effects`' delivery path is the caller that passes
  them for a `<send>` with no `target`.
  """
  @spec external(name :: String.t(), opts :: keyword()) :: t()
  def external(name, opts \\ []) do
    %__MODULE__{
      name: name,
      type: :external,
      data: Keyword.get(opts, :data),
      invokeid: Keyword.get(opts, :invokeid),
      origin: Keyword.get(opts, :origin),
      origintype: Keyword.get(opts, :origintype),
      sendid: Keyword.get(opts, :sendid)
    }
  end

  @doc """
  An event raised by executable content in the document - spec 5.10.1
  restricts `type: :internal` to `<raise>` and `<send>` with
  `target="#_internal"`; a `<send>` with no `target` goes to the sending
  session's *external* queue and is `type: :external` instead, not this
  constructor. `cause` travels through unchanged from the caller, which
  built it from the raising node's identity and the current counters.
  `origin`/`origintype` are never read from `opts` - 5.10.1: "For internal
  and platform events, the Processor MUST leave [`origin`/`origintype`]
  blank". `sendid` *is* read: it exists for `<send target="#_internal">`,
  whose delivered event C.1 still requires to carry the sending `<send>`'s
  id when the author wrote one - the only caller today
  (`MachineState.raise_internal/4`, for `<raise>`) never has one to pass.
  """
  @spec internal(name :: String.t(), cause :: Cause.t(), opts :: keyword()) :: t()
  def internal(name, %Cause{} = cause, opts \\ []) do
    %__MODULE__{
      name: name,
      type: :internal,
      cause: cause,
      data: Keyword.get(opts, :data),
      sendid: Keyword.get(opts, :sendid)
    }
  end

  @doc """
  An event the platform itself raised (`error.execution`,
  `error.communication`, `done.state.*`) - rides the internal queue exactly
  like `internal/3`; `type: :platform` only distinguishes its
  provenance for a consumer that cares. `origin`/`origintype` are never read
  from `opts` for the same 5.10.1 reason `internal/3`'s `@doc` gives: "For
  internal and platform events, the Processor MUST leave [them] blank".
  `sendid` *is* read, for the same C.1 reason `internal/3` reads it.
  """
  @spec platform(name :: String.t(), cause :: Cause.t(), opts :: keyword()) :: t()
  def platform(name, %Cause{} = cause, opts \\ []) do
    %__MODULE__{
      name: name,
      type: :platform,
      cause: cause,
      data: Keyword.get(opts, :data),
      sendid: Keyword.get(opts, :sendid)
    }
  end
end
