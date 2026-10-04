defmodule Statifier.Send.BasicHTTP do
  @moduledoc """
  The W3C Basic HTTP Event I/O Processor (SCXML appendix C.2), a
  `Statifier.Send.Processor` a host registers like any other send type
  (ADR-0069, ADR-0075).

  ## Registering it

  Register it under the spec's processor URI and its short form
  `basichttp`, with the base URL the host's own front answers at:

      base = "https://example.org/scxml"

      Statifier.Session.start_link(chart,
        send_types: %{
          "http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor" =>
            {Statifier.Send.BasicHTTP, base_url: base},
          "basichttp" => {Statifier.Send.BasicHTTP, base_url: base}
        }
      )

  Neither string is a built-in spelling, so the registration redirects no
  built-in send (ADR-0075 decision 2). The options:

    - `:base_url` (required) - the address the host's front answers at.
      The session's `_ioprocessors` carries an entry under each registered
      string, both holding the same `"location"`: this URL, `/`, and the
      session's `_sessionid` (C.2.3, ADR-0075 decision 3). A registration
      from which no entry can be built (no `:base_url`, or a value that
      is not a string) is refused when the session starts fresh, with
      `{:error, {:send_types, {:invalid_registration, type,
      {:missing_option, :base_url}}}}`, before any session process is
      spawned and so with no crash report (`check_registration/2`). A
      resumed session is not refused: its
      position carries the entries it started with.
    - `:transport` - a `Statifier.Send.BasicHTTP.Transport` module the
      POSTs go through. Default `Statifier.Send.BasicHTTP.Transport.Httpc`,
      on OTP's `:httpc`; this package adds no dependency for it
      (ADR-0075 decision 6).

  ## Outbound (C.2.2)

  `deliver/3` plans and `perform/2` POSTs, the split every processor has
  (`Statifier.Send.Processor`). The mapping (ADR-0075 decision 4):

    - `event` becomes the form parameter `_scxmleventname`, and each
      `namelist` entry and `<param>` a form parameter, in an
      `application/x-www-form-urlencoded` body.
    - A `<content>` child is the body, sent as `text/plain`; when the send
      also names an `event`, `_scxmleventname` travels as a query parameter
      of the target URL.
    - The two are told apart by `data`'s shape: a map that is not a
      struct is form-encoded, `:undefined` sends `_scxmleventname` alone
      as a form body, and any other value is the body. A `<content expr>`
      that evaluates to a map is therefore form-encoded, and one that
      evaluates to a struct (a `Date`, for example) is the body, its
      `inspect/1` text sent as `text/plain`.
    - A send with neither `target` nor `targetexpr` raises C.2.2's
      `error.communication` on the sender's internal queue, carrying the
      send id, and makes no request.

  A parameter value is written as text: a string as it is, a number or a
  boolean as its literal, `nil` as `null`, `:undefined` as the empty
  string. A list or a map is written as JSON text through Elixir's `JSON`
  (`[1,2]`, `{"title":"Dune"}`), and `:undefined` inside it as JSON
  `null`, when every value inside has a JSON form: a string that is
  UTF-8, a number, a boolean, `nil`, `:undefined`, a list, or a map whose
  keys are all strings. A list or a map holding anything else (an atom
  key, a struct such as a `Date`, a tuple) keeps its `inspect/1` text
  whole, as does any other value that is none of these. The same rule
  writes a `<content>` body that is a list, still sent as `text/plain`.

  **One attempt, and a miss reaches the sender.** `perform/2` makes one
  POST. On a transport error, or a status outside 2xx, it reports the miss
  through `Statifier.Session.failed_send/3` to the sending session it finds
  in `Statifier.Registry` under the plan context's `session_id`, so the
  sender sees C.1's `error.communication` carrying the send id, and it
  returns `{:error, reason}`. When no live session is registered under that
  id it returns `{:error, reason}` only, and the dead-letter rule of
  `failed_send/3`'s documentation is the host's (ADR-0075 decision 8, point
  d).

  **At-least-once, deduplicated by the receiver** (ADR-0075's Amendment of
  2026-09-30). The processor keeps no memory across `perform/2` calls, so
  a host that performs the same instruction twice POSTs twice. Every POST
  therefore carries the send's ADR-0054 decision 3 dedup key in the
  `scxml-send-key` header: eight fields joined by `/`, in the record's
  order - the session scope (the plan context's `session_id`), the send
  id, `macrostep`, `microstep`, `round`, `c_index`, `owner` and `ordinal`.
  The session scope and the send id are percent-encoded (every byte outside
  RFC 3986's unreserved set), the counters are decimal, and `owner` is
  spelled `onentry.S.B`, `onexit.S.B`, `transition.T` or `finalize.S.B`
  with its indexes. A receiver that deduplicates on the header sees each
  send once, which is ADR-0069's idempotency MUST end to end; a receiver
  that ignores it sees at-least-once delivery.

  `perform/2` runs in the process that performs the instruction, which for
  `Statifier.Session` is the sending session, so a slow location holds that
  session for the length of the request; the default transport bounds each
  request with a timeout.

  **A delayed send is this processor's timer** (ADR-0069 decision 4). A
  `<send delay>` is held by a timer process `perform/2` starts, and
  `cancel/2` plans the cancellation of every timer held under the send id
  (spec 6.3). The session performing the send keeps the timer through
  `Statifier.Session.HaltNotice` until it ends, and tells it when the
  session halts. When the delay passes, the timer POSTs unless its
  mailbox already holds a cancel, its session's halt notice (`:done`,
  `:cancelled` or `:budget_exhausted`) or its session's end, so a cancel
  the timer has received before the POST always wins, and a session that
  has stopped, or halted, discards the send (spec 6.2). The timer never
  calls the session, so a session busy at fire time does not delay or
  drop the POST. A transport that raises inside the timer is a miss like
  any other: it reaches the sender as `error.communication` through
  `Statifier.Session.failed_send/3`, with the reason `{:raised,
  exception}`. A delayed send performed outside a `Statifier.Session` has
  no session to hold it and is discarded.

  ## Inbound (C.2.1)

  `decode/1` turns one HTTP request into a `%Statifier.Event{}`. It is pure
  and knows no session: a front resolves the location to a session (or to
  an execution, for a durable host), calls it, and enqueues the event as
  an external event. The status rule a front applies (ADR-0075 decision 5):

    - `{:ok, event}` - answer 204 once the event is enqueued, before it is
      processed (a front that has already enqueued a request carrying the
      same `scxml-send-key` answers 204 again and enqueues nothing);
    - `{:error, {:method_not_allowed, method}}` - answer 405 with
      `Allow: POST`;
    - any other `{:error, _}` - answer 400;
    - a location that names no session the front can reach - the front's
      own 404.
  """

  @behaviour Statifier.Send.Processor

  alias Statifier.{Effect, Event, EventData, Session}
  alias Statifier.Send.BasicHTTP.Transport
  alias Statifier.Session.HaltNotice

  @uri "http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"
  @event_name_param "_scxmleventname"
  @form "application/x-www-form-urlencoded"
  @send_key_header "scxml-send-key"

  @typedoc """
  What `decode/1` is handed: the request's method, its content type (`nil`
  when the request carries none), its body, its query string (`nil` when
  the URL has none), and optionally the value of its `scxml-send-key`
  header (`nil` or absent when the request carries none).
  """
  @type request :: %{
          required(:method) => String.t(),
          required(:content_type) => String.t() | nil,
          required(:body) => binary(),
          required(:query) => String.t() | nil,
          optional(:send_key) => String.t() | nil
        }

  @typedoc "Why `decode/1` could not form an event from a request."
  @type decode_error ::
          {:method_not_allowed, String.t()}
          | {:not_utf8, :query | :body}
          | {:malformed_send_key, String.t()}

  @typep post :: %{
           url: String.t(),
           headers: [{String.t(), String.t()}],
           body: binary(),
           transport: module(),
           send: Effect.Send.t() | Effect.SendDelayed.t()
         }

  @doc """
  Answers `:ok` exactly when `ioprocessors_entry/2` would build an entry
  from `opts`: when the one lookup both share finds a string `:base_url`
  (the address the `_ioprocessors` location is built from, C.2.3). Any
  other registration answers `{:error, {:missing_option, :base_url}}`,
  including options whose lookup raises, so this never raises. That one
  reason covers a `:base_url` that is absent and one that is present but
  not a string (an atom, an integer, a charlist): no separate reason
  names a malformed value. A session's fresh start asks it and refuses a
  rejected registration by name (`Statifier.Send.Processor`'s "Refusing a
  registration").
  """
  @impl Statifier.Send.Processor
  @spec check_registration(type :: String.t(), opts :: keyword()) ::
          :ok | {:error, {:missing_option, :base_url}}
  def check_registration(_type, opts) do
    case base_url(opts) do
      {:ok, _base_url} -> :ok
      :error -> {:error, {:missing_option, :base_url}}
    end
  rescue
    _lookup_raised in [ArgumentError, FunctionClauseError] ->
      {:error, {:missing_option, :base_url}}
  end

  @doc """
  The `_ioprocessors` entry for `type`: a `"location"` that is the
  registration's `:base_url`, `/`, and the session's id (C.2.3, ADR-0075
  decision 3). Raises `ArgumentError` when the registration carries no
  `:base_url`; a session's fresh start refuses such a registration through
  `check_registration/2` before this is asked.
  """
  @impl Statifier.Send.Processor
  @spec ioprocessors_entry(
          type :: String.t(),
          context :: Statifier.Send.Processor.entry_context()
        ) ::
          map()
  def ioprocessors_entry(type, %{session_id: session_id, opts: opts}) do
    case base_url(opts) do
      {:ok, base_url} ->
        %{"location" => base_url <> "/" <> session_id}

      :error ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} registered for #{inspect(type)} needs a :base_url " <>
                "option, the address its _ioprocessors location is built from (C.2.3)"
    end
  end

  # The one lookup `check_registration/2` and `ioprocessors_entry/2` share,
  # so the check accepts exactly the registrations the entry can be built
  # from. It raises where `Keyword.fetch/2` does (an improper list whose
  # proper part holds no `:base_url`).
  @spec base_url(opts :: keyword()) :: {:ok, String.t()} | :error
  defp base_url(opts) do
    case Keyword.fetch(opts, :base_url) do
      {:ok, base_url} when is_binary(base_url) -> {:ok, base_url}
      _missing -> :error
    end
  end

  @doc """
  Plans one send (see the moduledoc's "Outbound"). Pure.
  """
  @impl Statifier.Send.Processor
  @spec deliver(
          send :: Effect.Send.t() | Effect.SendDelayed.t(),
          event :: Event.t(),
          ctx :: Statifier.Send.Processor.ctx()
        ) :: {:ok, [Statifier.Send.Processor.instruction()]}
  def deliver(%{target: nil} = send, _event, _ctx) do
    {:ok,
     [
       {:raise, :platform, "error.communication", {:content, send.c_index, send.owner},
        sendid: send.send_id}
     ]}
  end

  def deliver(%Effect.SendDelayed{} = send, _event, ctx),
    do: {:ok, [{:handler, __MODULE__, {:post_after, send.delay_ms, post(send, ctx)}}]}

  def deliver(%Effect.Send{} = send, _event, ctx),
    do: {:ok, [{:handler, __MODULE__, {:post, post(send, ctx)}}]}

  @doc """
  Plans the cancellation of every delayed send this processor holds under
  `cancel.send_id`. Pure.
  """
  @impl Statifier.Send.Processor
  @spec cancel(cancel :: Effect.Cancel.t(), ctx :: Statifier.Send.Processor.ctx()) ::
          {:ok, [Statifier.Send.Processor.instruction()]}
  def cancel(%Effect.Cancel{send_id: send_id}, _ctx),
    do: {:ok, [{:handler, __MODULE__, {:cancel, send_id}}]}

  @doc """
  Performs one instruction `deliver/3` or `cancel/2` planned: a POST, a
  delayed POST's timer, or the cancellation of the timers held under a
  send id (see the moduledoc's "Outbound").
  """
  @impl Statifier.Send.Processor
  @spec perform(payload :: term(), ctx :: Statifier.Send.Processor.ctx()) ::
          :ok | {:error, term()}
  def perform({:post, post}, ctx), do: post_now(post, ctx)

  def perform({:post_after, delay_ms, post}, ctx) do
    owner = self()
    # ADR-0075 decision 9 / ADR-0069 decision 4: the processor owns the delay.
    timer = spawn(fn -> hold(owner, delay_ms, post, ctx) end)

    case HaltNotice.watch({__MODULE__, post.send.send_id}, timer) do
      :ok ->
        :ok

      :not_a_session ->
        # ADR-0075 decision 9: no session will tell the timer of a halt, so
        # the send is discarded (spec 6.2), as it was before the notice.
        send(timer, :cancel)
        :ok
    end
  end

  def perform({:cancel, send_id}, _ctx) do
    # ADR-0075 decision 9: a cancel reaches every timer held under the id.
    {__MODULE__, send_id} |> HaltNotice.take() |> Enum.each(&send(&1, :cancel))
    :ok
  end

  @doc """
  Decodes one HTTP request into an external event (C.2.1, ADR-0075
  decision 5). Pure.

    - The method must be POST; any other is
      `{:error, {:method_not_allowed, method}}`.
    - The event name is the first `_scxmleventname` found, the query string
      before a form body, else `HTTP.` and the method in upper case
      (`HTTP.POST`).
    - A form body's other parameters, with the query string's, become
      `_event.data`, each value through `Statifier.EventData`'s text rung
      (a predicator literal, else the string), so `2` reads as the number 2.
      A body of any other content type becomes `_event.data` through the
      same text rung, and the query string then contributes the event name
      only.
    - `origintype` is the processor URI.
    - `:send_key`, the `scxml-send-key` header's value, sets no event
      field: the front deduplicates on the header's value itself, and the
      event's `sendid` stays unset. A value that is not the header's eight
      fields is `{:error, {:malformed_send_key, value}}`.

  A query string or a body that is not UTF-8 once decoded forms no
  datamodel string, and is `{:error, {:not_utf8, :query | :body}}`.

  A JSON body (`application/json`) is a body of another content type: it
  goes through the text rung like any other, so a JSON object or array
  that is also a predicator literal reads as a map or a list, and anything
  else stays a string. No charset is read: a body that is not UTF-8 is
  `{:error, {:not_utf8, :body}}` whatever charset its content type names.
  """
  @spec decode(request :: request()) :: {:ok, Event.t()} | {:error, decode_error()}
  def decode(%{method: method} = request) do
    with :ok <- post_only(method),
         {:ok, query} <- pairs(Map.get(request, :query), :query),
         {:ok, body, text} <- body(request),
         :ok <- check_send_key(Map.get(request, :send_key)) do
      {names, params} = Enum.split_with(query ++ body, &match?({@event_name_param, _value}, &1))

      name =
        case names do
          [{_key, name} | _rest] -> name
          [] -> "HTTP." <> String.upcase(method)
        end

      {:ok, Event.external(name, data: data(params, text), origintype: @uri)}
    end
  end

  # Checks an `scxml-send-key` value's shape (ADR-0075's Amendment of
  # 2026-09-30); the decoder sets no event field from it.
  @spec check_send_key(send_key :: String.t() | nil) :: :ok | {:error, decode_error()}
  defp check_send_key(nil), do: :ok

  defp check_send_key(send_key) do
    with [_scope, send_id, _macro, _micro, _round, _c_index, _owner, _ordinal] <-
           String.split(send_key, "/"),
         true <- send_id |> URI.decode() |> String.valid?() do
      :ok
    else
      _malformed -> {:error, {:malformed_send_key, send_key}}
    end
  end

  @spec post_only(method :: String.t()) :: :ok | {:error, decode_error()}
  defp post_only(method) do
    if String.upcase(method) == "POST",
      do: :ok,
      else: {:error, {:method_not_allowed, method}}
  end

  # A form body's pairs, or a text body; `text` is `nil` for a form.
  @spec body(request :: request()) ::
          {:ok, [{String.t(), String.t()}], String.t() | nil} | {:error, decode_error()}
  defp body(%{body: body} = request) do
    cond do
      form?(Map.get(request, :content_type)) ->
        with {:ok, pairs} <- pairs(body, :body), do: {:ok, pairs, nil}

      String.valid?(body) ->
        {:ok, [], body}

      true ->
        {:error, {:not_utf8, :body}}
    end
  end

  @spec form?(content_type :: String.t() | nil) :: boolean()
  defp form?(nil), do: false
  defp form?(content_type), do: content_type |> String.downcase() |> String.starts_with?(@form)

  @spec data(params :: [{String.t(), String.t()}], text :: String.t() | nil) :: term()
  defp data(params, nil),
    do: EventData.coerce({:params, Enum.map(params, fn {k, v} -> {k, text(v)} end)})

  defp data(_params, text), do: text(text)

  @spec text(value :: String.t() | nil) :: term()
  defp text(nil), do: :undefined
  defp text(value), do: EventData.coerce({:text, value})

  @spec pairs(encoded :: String.t() | nil, part :: :query | :body) ::
          {:ok, [{String.t(), String.t()}]} | {:error, decode_error()}
  defp pairs(nil, _part), do: {:ok, []}

  defp pairs(encoded, part) do
    pairs = encoded |> URI.query_decoder(:www_form) |> Enum.to_list()

    if Enum.all?(pairs, fn {key, value} -> String.valid?(key) and String.valid?(value) end),
      do: {:ok, pairs},
      else: {:error, {:not_utf8, part}}
  end

  # The request one send becomes (ADR-0075 decision 4).
  @spec post(send :: Effect.Send.t() | Effect.SendDelayed.t(), ctx :: map()) :: post()
  defp post(send, ctx) do
    named = if send.event, do: [{@event_name_param, send.event}], else: []

    {url, content_type, body} =
      case send.data do
        # A struct is a map but never form parameters: it falls to the
        # text/plain arm below, as its `inspect/1` text.
        data when is_map(data) and not is_struct(data) ->
          {send.target, @form, form(named ++ Enum.map(data, fn {k, v} -> {k, encode(v)} end))}

        :undefined ->
          {send.target, @form, form(named)}

        content ->
          {with_query(send.target, named), "text/plain", encode(content)}
      end

    %{
      url: url,
      headers: [{"content-type", content_type}, {@send_key_header, send_key(send, ctx)}],
      body: body,
      transport: ctx |> Map.get(:opts, []) |> Keyword.get(:transport, Transport.Httpc),
      send: send
    }
  end

  # The ADR-0054 decision 3 dedup key, spelled as ADR-0075's Amendment of
  # 2026-09-30 states (see the moduledoc's "At-least-once").
  @spec send_key(send :: Effect.Send.t() | Effect.SendDelayed.t(), ctx :: map()) :: String.t()
  defp send_key(send, %{session_id: session_id}) do
    Enum.join(
      [
        escape(session_id),
        escape(send.send_id),
        field(send.macrostep),
        field(send.microstep),
        field(send.round),
        field(send.c_index),
        owner(send.owner),
        field(send.ordinal)
      ],
      "/"
    )
  end

  @spec escape(value :: String.t() | nil) :: String.t()
  defp escape(nil), do: ""
  defp escape(value), do: URI.encode(value, &URI.char_unreserved?/1)

  @spec field(value :: non_neg_integer() | nil) :: String.t()
  defp field(nil), do: ""
  defp field(value), do: Integer.to_string(value)

  @spec owner(owner :: Statifier.Machine.Content.owner() | nil) :: String.t()
  defp owner({kind, state, block}), do: "#{kind}.#{state}.#{block}"
  defp owner({:transition, transition}), do: "transition.#{transition}"
  defp owner(nil), do: ""

  @spec form(pairs :: [{String.t(), String.t()}]) :: String.t()
  defp form(pairs), do: URI.encode_query(pairs, :www_form)

  @spec with_query(url :: String.t(), pairs :: [{String.t(), String.t()}]) :: String.t()
  defp with_query(url, []), do: url

  defp with_query(url, pairs) do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> form(pairs)
  end

  @spec encode(value :: term()) :: String.t()
  defp encode(value) when is_binary(value), do: value
  defp encode(nil), do: "null"
  defp encode(:undefined), do: ""
  defp encode(value) when is_number(value) or is_boolean(value), do: to_string(value)

  defp encode(value) when is_list(value) or is_map(value) do
    case json(value) do
      {:ok, json} -> JSON.encode!(json)
      :error -> inspect(value)
    end
  end

  defp encode(value), do: inspect(value)

  # The JSON form of a map or a list (ADR-0075's Amendment on non-scalar
  # values): `:undefined` becomes `nil` (JSON `null`), a map must be
  # string-keyed (a struct never is: its `:__struct__` key is an atom), a
  # string must be UTF-8, and a value with no JSON form anywhere inside
  # answers `:error`, so the whole value keeps its `inspect/1` text.
  @spec json(value :: term()) :: {:ok, term()} | :error
  defp json(:undefined), do: {:ok, nil}
  defp json(value) when is_nil(value) or is_boolean(value) or is_number(value), do: {:ok, value}

  defp json(value) when is_binary(value),
    do: if(String.valid?(value), do: {:ok, value}, else: :error)

  defp json(value) when is_list(value), do: json_list(value, [])
  defp json(value) when is_map(value), do: json_map(Map.to_list(value), [])
  defp json(_value), do: :error

  @spec json_list(list :: maybe_improper_list(), acc :: [term()]) :: {:ok, [term()]} | :error
  defp json_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp json_list([value | rest], acc) do
    case json(value) do
      {:ok, json} -> json_list(rest, [json | acc])
      :error -> :error
    end
  end

  defp json_list(_improper_tail, _acc), do: :error

  @spec json_map(pairs :: [{term(), term()}], acc :: [{String.t(), term()}]) ::
          {:ok, %{String.t() => term()}} | :error
  defp json_map([], acc), do: {:ok, Map.new(acc)}

  defp json_map([{key, value} | rest], acc) when is_binary(key) do
    with true <- String.valid?(key),
         {:ok, json} <- json(value) do
      json_map(rest, [{key, json} | acc])
    else
      _no_json_form -> :error
    end
  end

  defp json_map(_pairs, _acc), do: :error

  # One attempt; a miss goes to the sender through `failed_send/3`
  # (ADR-0075 decision 8, point d).
  @spec post_now(post :: post(), ctx :: map()) :: :ok | {:error, term()}
  defp post_now(post, ctx) do
    case post.transport.post(post.url, post.headers, post.body) do
      {:ok, status} when status in 200..299 -> :ok
      {:ok, status} -> report(post.send, ctx, {:http_status, status})
      {:error, reason} -> report(post.send, ctx, reason)
    end
  end

  @spec report(send :: Effect.Send.t() | Effect.SendDelayed.t(), ctx :: map(), reason :: term()) ::
          {:error, term()}
  defp report(send, %{session_id: session_id}, reason) do
    case whereis(session_id) do
      nil -> :ok
      pid -> Session.failed_send(pid, send, reason: reason)
    end

    {:error, reason}
  end

  # `Registry.lookup/2` raises `ArgumentError` when `Statifier.Registry`
  # itself is not running, which is the "no live session registered" case.
  @spec whereis(session_id :: String.t()) :: pid() | nil
  defp whereis(session_id) do
    case Registry.lookup(Statifier.Registry, session_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # A delayed send's timer process: POSTs after `delay_ms` unless it is
  # cancelled first, its owner halts (`HaltNotice`) or its owner stops
  # (spec 6.2's discard at termination).
  @spec hold(owner :: pid(), delay_ms :: non_neg_integer(), post :: post(), ctx :: map()) ::
          :ok | {:error, term()}
  defp hold(owner, delay_ms, post, ctx) do
    # ADR-0075 decision 9: the timer ends when the session that owns it does.
    ref = Process.monitor(owner)

    # ADR-0075 decision 9: a cancel, the owner's halt or end, or the delay, first.
    receive do
      :cancel -> :ok
      {:statifier_halted, ^owner, _reason} -> :ok
      {:DOWN, ^ref, :process, ^owner, _reason} -> :ok
    after
      delay_ms -> if stopped?(owner, ref), do: :ok, else: post_later(post, ctx)
    end
  end

  # The fire-time check, which reads the mailbox and never calls the
  # session: a stop that arrived after the delay passed, but before the
  # POST, still wins.
  @spec stopped?(owner :: pid(), ref :: reference()) :: boolean()
  defp stopped?(owner, ref) do
    # ADR-0075 decision 9: the same three stops as `hold/4`, without waiting.
    receive do
      :cancel -> true
      {:statifier_halted, ^owner, _reason} -> true
      {:DOWN, ^ref, :process, ^owner, _reason} -> true
    after
      0 -> false
    end
  end

  # A delayed POST runs in the timer, where a raise would end the process
  # with nobody told: a raising transport is reported as a miss instead.
  @spec post_later(post :: post(), ctx :: map()) :: :ok | {:error, term()}
  defp post_later(post, ctx) do
    post_now(post, ctx)
  rescue
    exception -> report(post.send, ctx, {:raised, exception})
  end
end
