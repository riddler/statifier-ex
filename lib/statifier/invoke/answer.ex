defmodule Statifier.Invoke.Answer do
  @moduledoc """
  The two events that end a handler-backed invocation, built as plain
  `Statifier.Event.t()` values by whoever is driving the chart.

  An invocation started by `<invoke>` ends exactly two ways, and each way has
  one event: `done.invoke.<invoke_id>` when the service finished
  (ADR-0051 decision 5, spec 6.4.3), and
  `error.communication.invoke.<invoke_id>` when the host's own retry policy
  is exhausted and no done event will ever follow (ADR-0068). This module is
  their single construction site.

  ## Why this is public

  `Statifier.Session.done_invocation/3` and
  `Statifier.Session.failed_invocation/3` are doors: they take a live
  session, build the matching event here, and deliver it on an
  invocation-tagged inbox entry. A host driving `Statifier.Interpreter`
  directly against a persisted `%Statifier.MachineState{}`, with no
  `Statifier.Session` process at all - `docs/persistence.md`'s supported
  process-less path - has no session to hand those doors, so it had no way to
  answer an invocation it started. Its next drive of the interpreter takes an
  event, and this module is where that event comes from.

  Both builders are pure: same arguments, same event, no process, no clock,
  no id minting. `session_id` is the process-less host's own `_sessionid`
  (spec 5.10) for the run - the same value it stamped onto the
  `%MachineState{}` it is driving - and it appears only in `origin`, per C.1.

  ## Both halves or neither

  These ship as a pair on purpose. ADR-0068 exists to remove the asymmetry
  between an invocation that can report success and one that cannot report
  failure, and its own "what would reopen this record" bullet names exactly
  this gap for both events at once. A process-less host that could build one
  and not the other would have the asymmetry back in a different place.

  ## What the caller still owns

  The event is built here; nothing else is. A process-less host has no
  invocation table for the library to pop and no drain to discard against, so
  6.4.3's late-arrival discard - a done event for an invocation the chart
  already cancelled - is the host's own check against its own record of which
  invocations are live, exactly as `docs/durable-timers.md`'s Route B already
  says for a timer that fires after its cancel. Feed the returned event to
  the next drive only if the invocation is still live by the host's own
  reckoning.

  `caller_context` (ADR-0063) is deliberately absent here: whether a
  driver-built answer event inherits the invoking event's correlation term is
  a separate open question, tracked on ADR-0068's 2026-09-02 decision note,
  and is not decided by this module.
  """

  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Event

  @doc """
  `done.invoke.<invoke_id>`: the invocation finished and `donedata` is what
  it produced.

  `donedata` is spec 6.4's own shape - the service's `<donedata>`, or
  whatever a process-less host's equivalent is; 6.4's MUST there is on the
  *service*, not this engine, which only builds the event and documents what
  arrives in it. It reaches the chart as `_event.data`, and defaults to
  `nil`.

  The event carries `invokeid: invoke_id` (spec 5.10.1) so a chart reading
  `_event.invokeid` sees which invocation answered, and `origin` /
  `origintype` per C.1, exactly as `Statifier.Session.done_invocation/3`
  builds them - the two paths call this same function, so their events are
  byte-identical for the same arguments.

      iex> event = Statifier.Invoke.Answer.done("sess_1", "inv_3", %{"outcome" => "approved"})
      iex> {event.name, event.type, event.data, event.invokeid}
      {"done.invoke.inv_3", :external, %{"outcome" => "approved"}, "inv_3"}
  """
  @spec done(session_id :: String.t(), invoke_id :: String.t(), donedata :: term()) :: Event.t()
  def done(session_id, invoke_id, donedata \\ nil)
      when is_binary(session_id) and is_binary(invoke_id) do
    Event.external("done.invoke." <> invoke_id,
      data: donedata,
      invokeid: invoke_id,
      origin: SystemVariables.scxml_location(session_id),
      origintype: SystemVariables.scxml_event_processor()
    )
  end

  @doc """
  `error.communication.invoke.<invoke_id>`: the invocation failed
  permanently and no `done.invoke.<invoke_id>` will ever follow.

  The name is spec 3.12.1's blessed suffix extension of the
  `error.communication` ADR-0051 decision 1's table already assigns to "a
  registered handler fails to reach its service", so a chart transitioning on
  `error.communication` (or on `error`) catches it by the descriptor prefix
  rule with no edit, while a chart naming
  `error.communication.invoke.<invoke_id>` parks that one invocation alone
  (ADR-0068 decision 1).

  `failure` is a keyword list read for three optional keys, none of which
  this library interprets (ADR-0068 decision 2). The payload is a
  string-keyed map, and an unsupplied key is `:undefined` (ADR-0037's unbound
  spelling) rather than `nil`, which is distinct from a host that supplied a
  zero or a null:

    * `:reason` - a host-chosen string naming the failure class, read from a
      chart as `_event.data.reason`. Defaults to `"unknown"`.
    * `:attempts` - how many attempts the host made before giving up.
    * `:detail` - any further host term, uninterpreted.

  It is `Event.external/2` rather than `Event.platform/3` for decision 5's
  reason: the processor detects nothing here, a host reports on an external
  service's behalf, and the queue follows the arrival rather than the
  `error.` prefix.

      iex> event = Statifier.Invoke.Answer.failed("sess_1", "inv_3", reason: "exhausted", attempts: 5)
      iex> {event.name, event.data}
      {"error.communication.invoke.inv_3",
       %{"reason" => "exhausted", "attempts" => 5, "detail" => :undefined}}
  """
  @spec failed(session_id :: String.t(), invoke_id :: String.t(), failure :: keyword()) ::
          Event.t()
  def failed(session_id, invoke_id, failure \\ [])
      when is_binary(session_id) and is_binary(invoke_id) and is_list(failure) do
    data = %{
      "reason" => Keyword.get(failure, :reason, "unknown"),
      "attempts" => Keyword.get(failure, :attempts, :undefined),
      "detail" => Keyword.get(failure, :detail, :undefined)
    }

    Event.external("error.communication.invoke." <> invoke_id,
      data: data,
      invokeid: invoke_id,
      origin: SystemVariables.scxml_location(session_id),
      origintype: SystemVariables.scxml_event_processor()
    )
  end
end
