# The Basic HTTP Event I/O Processor

SCXML appendix C.2 defines the Basic HTTP Event I/O Processor: a `<send>`
whose `type` names it is delivered as an HTTP POST, and a session that runs
it accepts POSTs at an address of its own and raises each one as an
external event. Statifier ships it as `Statifier.Send.BasicHTTP`, a
`Statifier.Send.Processor` a host registers per session like any other send
type (see "The `<send>` half" in [Extending Statifier](extending.md)). A
session that does not register it sees none of this page: no request is
made, nothing is started, and `_ioprocessors` holds the SCXML processor's
entry alone.

The decisions behind the processor are
[ADR-0075](https://github.com/riddler/statifier-ex/blob/main/docs/adr/0075-basichttp-event-io-processor.md)
and its Amendment of 2026-09-30, which adds the `scxml-send-key` header
below.

## Registering it

Register the processor under both of its type strings, the spec's URI and
the short form `basichttp`, with the base URL your own front answers at:

```elixir
base = "https://example.org/scxml"
registration = {Statifier.Send.BasicHTTP, base_url: base}

Statifier.Session.start_link(chart,
  send_types: %{
    "http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor" => registration,
    "basichttp" => registration
  }
)
```

A `:send_types` value is a bare module or `{module, opts}`; this processor
needs the options form. Its options:

- `:base_url` (required) - the address your front answers at. A
  registration from which no entry can be built (no `:base_url`, or a
  value that is not a string) is refused when the session starts fresh,
  with
  `{:error, {:send_types, {:invalid_registration, type, {:missing_option, :base_url}}}}`
  before any session process is spawned, so with no crash report. A
  resumed session is not refused: its position
  carries the `_ioprocessors` entries it started with.
- `:transport` - the module the POSTs go through, a
  `Statifier.Send.BasicHTTP.Transport`. The default is
  `Statifier.Send.BasicHTTP.Transport.Httpc`, on OTP's `:httpc`, which
  verifies TLS peers against the system CA store and bounds each request
  with a timeout. The package adds no dependency for it; the last section
  below shows an adapter on `req`. When `:ssl` or `:public_key` cannot be
  loaded, the default adapter answers
  `{:error, {:not_loadable, module, reason}}` instead of making the
  request, and the processor reports the miss to the sender like any
  other failed delivery.

Neither type string is a built-in spelling, so the registration redirects
no built-in send.

## The location

C.2.3 asks for an `_ioprocessors` entry holding a `location` that external
entities can use to reach the session. The session carries one entry under
each registered string, and both hold the same location: the base URL, a
`/`, and the session's `_sessionid`.

```xml
<send type="http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"
      targetexpr="_ioprocessors['basichttp']['location']"
      event="ping"/>
```

The entries are written once, when the session starts, and persist with
the datamodel, so a resumed session reads the location it started with.

### When the base URL moves, or a location rotates

The library never rewrites the location on its own, and a resume does
not either. Keeping the location current is the host's step, through one
of two calls that recompute every registered entry from the registration
and leave the SCXML entry as it is:

- **Across a resume.** A host whose base URL moved re-stamps the
  position with the new registration and refreshes it before it starts
  the session:

  ```elixir
  {:ok, position} = Statifier.Position.from_binary(blob, machine)
  send_types = %{"basichttp" => {Statifier.Send.BasicHTTP, base_url: new_base_url}}

  {:ok, position} =
    position
    |> Statifier.MachineState.put_send_types(Statifier.Send.Types.from_send_types(send_types))
    |> Statifier.MachineState.refresh_ioprocessors()

  {:ok, session} =
    Statifier.start_session(machine, resume: position, send_types: send_types)
  ```

  The chart then reads the new location. A session started this way with
  `record: true` records the refreshed position as its starting point, so
  a replay reads the same location.

- **On a live session.** `Statifier.Session.refresh_ioprocessors/1` asks
  the processor again from the registration the session holds, for a
  front that rotated a location a processor reads at that moment. It
  answers `:ok`; `{:error, {:missing_option, :base_url}}` when the
  registration has no `:base_url`; `{:error, :not_running}` once the
  session has halted; and `{:error, :recorded_session}` for a session
  started with `record: true`, whose recording has no place for a
  refresh. A registered processor whose entry raises during the refresh
  answers `{:error, {:ioprocessors_entry, type, exception}}`, and the
  session keeps running. Every error changes nothing.

## The front you write around `decode/1`

The library receives nothing on its own. Your host runs the HTTP endpoint
at the base URL, and for each request it:

1. resolves the path after the base URL to a session id, and that id to a
   running session;
2. hands the request to `Statifier.Send.BasicHTTP.decode/1`, a pure
   function that knows no session;
3. unless it has already enqueued a request carrying the same
   `scxml-send-key` header value (next section), enqueues the event the
   decoder answers as an external event, for example with
   `Statifier.Session.send_event/2`;
4. answers by the status rule below.

`decode/1` takes a map of the request's `:method`, `:content_type` (`nil`
when absent), `:body` and `:query` (`nil` when the URL has none), and
optionally `:send_key`, the `scxml-send-key` header's value. It answers
`{:ok, event}` or `{:error, reason}`. The status rule:

| `decode/1` answers | The front answers |
|---|---|
| `{:ok, event}` | 204, once the event is enqueued and before it is processed; 204 again, with nothing enqueued, for a `scxml-send-key` value the front has already enqueued |
| `{:error, {:method_not_allowed, method}}` | 405, with `Allow: POST` |
| `{:error, {:malformed_send_key, value}}` | 400 |
| any other `{:error, _}` | 400 |
| (the path names no session the front can reach) | 404 |

A front on Plug might read (text, not compiled; Plug is not a dependency of
this package):

```elixir
def call(%Plug.Conn{path_info: [session_id]} = conn, _opts) do
  {:ok, body, conn} = Plug.Conn.read_body(conn)

  request = %{
    method: conn.method,
    content_type: conn |> Plug.Conn.get_req_header("content-type") |> List.first(),
    body: body,
    query: if(conn.query_string == "", do: nil, else: conn.query_string),
    send_key: conn |> Plug.Conn.get_req_header("scxml-send-key") |> List.first()
  }

  with {:ok, pid} <- MyApp.Sessions.whereis(session_id),
       {:ok, event} <- Statifier.Send.BasicHTTP.decode(request) do
    # MyApp.Delivered records each key once and answers whether it was new.
    if MyApp.Delivered.first?(session_id, request.send_key),
      do: :ok = Statifier.Session.send_event(pid, event)

    Plug.Conn.send_resp(conn, 204, "")
  else
    :no_session -> Plug.Conn.send_resp(conn, 404, "")
    {:error, {:method_not_allowed, _method}} ->
      conn |> Plug.Conn.put_resp_header("allow", "POST") |> Plug.Conn.send_resp(405, "")
    {:error, _reason} -> Plug.Conn.send_resp(conn, 400, "")
  end
end
```

This repository's own loopback front, which its conformance runs deliver
through, is `Mix.Statifier.BasicHTTPFront`: repository tooling on OTP's
`:inets` httpd, not part of the package, and a small model of the steps
above. It lives only as long as one test run and does not deduplicate.

## At-least-once delivery and the `scxml-send-key` header

The processor makes one POST each time an instruction is performed, and
keeps no memory between performs. A host that performs the same
instruction twice - after a crash and a retry, for example - POSTs
twice, so delivery is at-least-once. To let the receiver deliver each
send once, every POST the processor makes, immediate or delayed and
whatever its body, carries the send's deduplication key in a request
header:

- **Name:** `scxml-send-key`.
- **Value:** eight fields joined by `/`: the session scope (the
  sender's `_sessionid` for a live session), the send id, `macrostep`,
  `microstep`, `round`, `c_index`, `owner` and `ordinal`. The session
  scope and the send id are percent-encoded, so neither carries a `/`;
  the counters are decimal integers; `owner` is spelled `onentry.S.B`,
  `onexit.S.B`, `finalize.S.B` or `transition.T` with its indexes. A
  field the send does not carry is the empty string.

Every field is a deterministic counter or a static position, so a
re-performed send carries a byte-identical value. A front that enqueues
a request only when it has not already enqueued one with the same value
delivers each send once; a front that ignores the header sees
at-least-once delivery. The decoder does not deduplicate: it is pure and
remembers nothing, so the front keeps the record of the values it has
enqueued, and answers a repeat 204 with nothing enqueued.

`decode/1` only checks the value's shape. It sets no field of the event
from it, and a value that is not eight `/`-separated fields whose second
field percent-decodes to UTF-8 is
`{:error, {:malformed_send_key, value}}`, which the front answers 400. A
request without the header decodes as before.

## The mapping, both ways

Outbound, a `<send>` to the processor becomes one POST (C.2.2):

| The `<send>` carries | The request carries |
|---|---|
| `event` | the form parameter `_scxmleventname` |
| `namelist` entries and `<param>` children | one form parameter each, in an `application/x-www-form-urlencoded` body; a repeated name keeps the last value |
| a `<content>` child | the content as the body, sent as `text/plain`; with an `event` too, `_scxmleventname` travels as a query parameter of the target URL |
| no parameters and no content | `_scxmleventname` alone, as a form body |
| a `<content expr>` that evaluates to a map | a form-encoded body, as parameters would be |
| neither `target` nor `targetexpr` | no request: `error.communication` on the sender's internal queue, carrying the send id |

A parameter value is written as text: a string as it is, a number or a
boolean as its literal, `nil` as `null`, and an undefined value as the
empty string. A list or a map is written as JSON text, so the list
`['Dune', 2]` travels as `["Dune",2]` and an undefined value inside it as
`null`, when everything inside it has a JSON form: a UTF-8 string, a
number, a boolean, `nil`, an undefined value, a list, or a map whose keys
are all strings. A list or a map holding anything else, and any other
value, is written as its Elixir `inspect/1` text, whole. A `<content>`
body that is a list is written the same way and still sent as
`text/plain`. ADR-0075's Amendment on list and map values records the
rule. The processor makes one attempt. A transport error, or a
status outside 2xx, reaches the sender as `error.communication` carrying
the send id, through `Statifier.Session.failed_send/3`. Every request also
carries the `scxml-send-key` header above. A `<send delay>` is
held by the processor's own timer, and a `<cancel>` naming the send cancels
it while it has not fired: a cancel the timer has received before its POST
always wins. The timer never calls the session, so a session busy when the
delay passes still has the send POSTed, and a session that has halted
(`:done`, `:cancelled` or `:budget_exhausted`) or stopped discards it. A
delayed send whose transport raises reaches the sender as
`error.communication`, as any other miss does.

Inbound, `decode/1` turns one request into one event (C.2.1):

| The request carries | The event carries |
|---|---|
| one or more `_scxmleventname` parameters | the first as its name, the query string read before the body |
| no `_scxmleventname` | `HTTP.` and the method in upper case as its name (`HTTP.POST`) |
| a form body | every other parameter, query string included, in `_event.data` |
| a body of any other content type | the body as `_event.data`; the query string gives the name only |
| (always) | the processor URI as `origintype`, and no `sendid` or `origin` |

Each value is read as a `<content>` body's text is: a predicator literal
becomes that value, so `2` reads as the number 2, and anything else stays
a string. A JSON body is a body of another content type, so a JSON object
or array that is also a predicator literal reads as a map or a list. A
list or a map parameter this processor writes as JSON is not promised to
read back as the value that was sent: the text rung reads predicator
literals, not JSON. No charset is read: a body or a parameter that is not
UTF-8 is refused as `{:error, {:not_utf8, :body}}` (or `:query`), which
the front answers 400, whatever charset the content type names. A front
whose senders use another charset transcodes the body before it calls
`decode/1`.

## What is not supported

- A charset other than UTF-8 inbound: such a body is refused, not
  transcoded.
- `_event.origin` on an inbound event: the decoder has no address a reply
  could be sent to. A sender that wants a reply puts its own location in a
  parameter, `<param name="replyto"
  expr="_ioprocessors['basichttp']['location']"/>`, and the receiver
  replies with `targetexpr="_event.data.replyto"`.
- `_event.sendid` on an inbound event, even for a send whose author named
  its `id`: the `scxml-send-key` header carries a named id and a generated
  one alike, so the decoder cannot tell them apart. A receiver that needs
  the id gets it in a parameter.
- A location that follows a moved base URL on its own: a resume keeps the
  location the session started with until the host refreshes it, as
  "When the base URL moves, or a location rotates" above shows.
- Authentication of inbound POSTs: C.2 defines none, and a front that
  needs it adds it itself.
- A session that is persisted and not running: the location reaches a
  live registered session only. A durable host's front resolves the
  location to its own execution.

## In the conformance corpus

The W3C documents that need the processor are in the corpus, each with a
`host` object whose `event_io_processors` names the processor's URI; a
runner registers it under both type strings and delivers through a
loopback front (`conformance/RATCHET.md`, "The `host` object"). Eleven of
them are claimed. `test201` is in the corpus and unclaimed: it expects an
event sent through the processor to arrive ahead of a `<send>` the same
step appends to the session's own external queue, and a delivery from
outside the session never can.

## A transport on `req`

A host that already uses `req` writes an adapter of its own and passes it
as `:transport`. As text, not compiled; this package does not depend on
`req`:

```elixir
defmodule MyApp.ReqTransport do
  @behaviour Statifier.Send.BasicHTTP.Transport

  @impl true
  def post(url, headers, body) do
    case Req.post(url, headers: headers, body: body, retry: false) do
      {:ok, %Req.Response{status: status}} -> {:ok, status}
      {:error, exception} -> {:error, exception}
    end
  end
end
```

`retry: false` keeps the one attempt the processor makes: retrying is not
the transport's job, and a status outside 2xx is answered as
`{:ok, status}`, not as an error, so the processor reports it as a miss.

```elixir
registration =
  {Statifier.Send.BasicHTTP, base_url: base, transport: MyApp.ReqTransport}
```
