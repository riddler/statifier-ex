defmodule Statifier.Send.Event do
  @moduledoc """
  Builds the event a `<send>` delivers, from the send effect the core
  produced (ADR-0069 decision 4). Pure: no process, no clock, no lookup.

  `build/3` is the one construction site. `Statifier.Session` calls it for
  every event a built-in `<send>` delivers to an external queue, and hands
  its result to a registered processor (`Statifier.Send.Processor`) for a
  send of a registered type. A host that drives `Statifier.Interpreter`
  with no session reads the effect off the core and calls it itself.

  What it stamps, per spec 5.10.1 and C.1:

    - `name` is the send's `event`, and `data` its resolved payload;
    - `sendid` is the send id only when the author wrote `id` or
      `idlocation` on the `<send>` (the effect's `id_from_author?`), and
      `nil` otherwise - C.1's empty-`sendid` rule;
    - `caller_context` is a delayed send's opaque host term (ADR-0063),
      and `nil` for an immediate send, which carries none;
    - `origin` defaults to the sender's `#_scxml_<sessionid>` location and
      `origintype` to the SCXML Event I/O Processor URI.

  A processor with its own reply address passes `:origin` and
  `:origintype`, so a receiver that answers "via the Event I/O Processor
  specified in 'origintype'" (5.10.1) reaches that processor rather than
  the sender's session.

  ## Why the default `origintype` is the URI

  C.1's prose says the field MUST have the value `"scxml"`. The W3C
  conformance suite requires the URI instead: test198 sends with no `type`
  attribute and asserts `_event.origintype ==
  'http://www.w3.org/TR/scxml/#SCXMLEventProcessor'`, test352 asserts the
  same for an explicitly typed send, and test253 accepts either spelling.
  No test in the corpus requires `"scxml"`. The default follows the suite.
  It is the URI whatever `type` the author wrote, so `<send type="scxml">`
  also reports the URI where 5.10.1's "equivalent to the 'type' field on
  the `<send>` element" would echo `"scxml"`; test253 accepts both and
  nothing else covers it.
  """

  alias Statifier.Effect.{Send, SendDelayed}
  alias Statifier.Evaluator.SystemVariables

  @typedoc """
  `build/3`'s options: `:origin` (a URI string) and `:origintype` (a type
  string), each replacing its default when given.
  """
  @type option :: {:origin, String.t()} | {:origintype, String.t()}

  @doc """
  The `%Statifier.Event{}` that `send` delivers, sent by the session
  `session_id` (spec 5.10's `_sessionid`). See the moduledoc for each
  field.

  ## Examples

      iex> send = %Statifier.Effect.Send{
      ...>   event: "impression.joined",
      ...>   data: %{"impression_id" => "imp-1"},
      ...>   send_id: "send_1",
      ...>   macrostep: 0,
      ...>   microstep: 0,
      ...>   round: 0
      ...> }
      iex> event = Statifier.Send.Event.build(send, "sess_1")
      iex> {event.name, event.data, event.sendid, event.origin}
      {"impression.joined", %{"impression_id" => "imp-1"}, nil, "#_scxml_sess_1"}
      iex> event = Statifier.Send.Event.build(send, "sess_1", origin: "myapp:reply/7", origintype: "myapp:execution")
      iex> {event.origin, event.origintype}
      {"myapp:reply/7", "myapp:execution"}

  """
  @spec build(send :: Send.t() | SendDelayed.t(), session_id :: String.t(), opts :: [option()]) ::
          Statifier.Event.t()
  def build(send, session_id, opts \\ [])

  def build(%struct{} = send, session_id, opts)
      when struct in [Send, SendDelayed] and is_binary(session_id) and is_list(opts) do
    Statifier.Event.external(send.event,
      data: send.data,
      origin:
        Keyword.get_lazy(opts, :origin, fn -> SystemVariables.scxml_location(session_id) end),
      origintype: Keyword.get_lazy(opts, :origintype, &SystemVariables.scxml_event_processor/0),
      sendid: if(send.id_from_author?, do: send.send_id),
      caller_context: caller_context_of(send)
    )
  end

  # ADR-0063 decision 3's firing-time copy source. Only `%SendDelayed{}`
  # carries the slot; an immediate `%Send{}` is delivered inside the
  # macrostep whose telemetry already carries the context, so it has no
  # field to copy (decision 2) and contributes `nil`. Dispatch is on the
  # struct, never on the value - the library never reads what the slot
  # holds.
  @spec caller_context_of(send :: Send.t() | SendDelayed.t()) :: term()
  defp caller_context_of(%SendDelayed{caller_context: caller_context}), do: caller_context
  defp caller_context_of(%Send{}), do: nil
end
