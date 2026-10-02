defmodule Statifier.Send.BasicHTTPTest do
  use ExUnit.Case, async: true

  # ADR-0075: the Basic HTTP Event I/O Processor's pure halves - the
  # outbound mapping `deliver/3` plans (decision 4), the `_ioprocessors`
  # entry (decision 3), the cancel plan, and the inbound decoder
  # (decision 5). The performing half runs in
  # `Statifier.Send.BasicHTTPSessionTest`.

  alias Statifier.Effect.{Cancel, Send, SendDelayed}
  alias Statifier.Event
  alias Statifier.Send.BasicHTTP
  alias Statifier.Send.BasicHTTP.Transport.Httpc

  @uri "http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"
  @target "http://127.0.0.1:1/basichttp/sess_receiver"
  @form "application/x-www-form-urlencoded"

  defp send_effect(fields) do
    struct!(
      %Send{
        event: "ping",
        type: @uri,
        target: @target,
        data: :undefined,
        send_id: "send_1",
        c_index: 3,
        owner: {:onentry, 2, 0},
        macrostep: 1,
        microstep: 1,
        round: 0,
        ordinal: 1
      },
      fields
    )
  end

  defp ctx(opts \\ nil) do
    base = %{session_id: "sess_sender"}
    if opts, do: Map.put(base, :opts, opts), else: base
  end

  # The one `{:post, request}` payload `deliver/3` plans for `effect`.
  defp planned(effect, ctx \\ ctx()) do
    assert {:ok, [{:handler, BasicHTTP, {:post, post}}]} =
             BasicHTTP.deliver(effect, Event.external("ignored"), ctx)

    post
  end

  defp content_type(post), do: post.headers |> List.keyfind("content-type", 0) |> elem(1)
  defp send_key(post), do: post.headers |> List.keyfind("scxml-send-key", 0) |> elem(1)

  describe "deliver/3: the outbound mapping (C.2.2)" do
    # sabotage: `post/2` leaves `_scxmleventname` out of `named` -> the body
    # carries the params alone and the equality reddens. Confirmed red and
    # reverted.
    test "event, namelist and params are form parameters in a POST body" do
      post = planned(send_effect(data: %{"Var1" => 2, "name" => "two words"}))

      assert post.url == @target
      assert content_type(post) == @form

      assert URI.decode_query(post.body) == %{
               "_scxmleventname" => "ping",
               "Var1" => "2",
               "name" => "two words"
             }
    end

    # sabotage: the `:undefined` arm of `post/2` sends `text/plain` with an
    # empty body -> the content type and the decoded body both differ and
    # the match reddens. Confirmed red and reverted.
    test "a send with no parameters and no content sends the event name alone" do
      post = planned(send_effect(data: :undefined))

      assert content_type(post) == @form
      assert post.body == "_scxmleventname=ping"
    end

    # sabotage: `with_query/2` returns the URL unchanged -> the event name is
    # lost and the URL equality reddens. Confirmed red and reverted.
    test "a content body is the body, and the event name goes in the query string" do
      post = planned(send_effect(data: "some content"))

      assert post.url == @target <> "?_scxmleventname=ping"
      assert content_type(post) == "text/plain"
      assert post.body == "some content"
    end

    # sabotage: `with_query/2` always uses `?` -> the URL carries two `?`
    # and the equality reddens. Confirmed red and reverted.
    test "the event name joins a query string the target already carries" do
      post = planned(send_effect(target: @target <> "?a=1", data: "x"))

      assert post.url == @target <> "?a=1&_scxmleventname=ping"
    end

    # sabotage: `post/2` always names the event, with an empty name when the
    # send has none -> the target gains a query and the equality reddens.
    # Confirmed red and reverted.
    test "a content body without an event name leaves the target alone" do
      post = planned(send_effect(event: nil, data: 42))

      assert post.url == @target
      assert post.body == "42"
    end

    # sabotage: `encode/1`'s `:undefined` clause returns `"undefined"` ->
    # the decoded `unbound` value reads "undefined" and the equality
    # reddens. Confirmed red and reverted.
    test "parameter values are written as text" do
      post =
        planned(
          send_effect(
            data: %{"null" => nil, "unbound" => :undefined, "flag" => true, "list" => [1, 2]}
          )
        )

      assert URI.decode_query(post.body) == %{
               "_scxmleventname" => "ping",
               "null" => "null",
               "unbound" => "",
               "flag" => "true",
               "list" => "[1, 2]"
             }
    end

    # sabotage: the `deliver/3` clause for a nil target is deleted -> a
    # `{:handler, ...}` POST is planned instead of the raise and the match
    # reddens. Confirmed red and reverted.
    test "a send with no target plans error.communication and no request" do
      effect = send_effect(target: nil)

      assert BasicHTTP.deliver(effect, Event.external("ping"), ctx()) ==
               {:ok,
                [
                  {:raise, :platform, "error.communication", {:content, 3, {:onentry, 2, 0}},
                   sendid: "send_1"}
                ]}
    end

    # sabotage: `post/2` reads the transport from `ctx` without the
    # `:opts` key (always the default) -> the injected module is lost and
    # the first equality reddens. Confirmed red and reverted.
    test "the transport is the registration's :transport option, else the httpc adapter" do
      assert planned(send_effect([]), ctx(transport: SomeTransport)).transport == SomeTransport
      assert planned(send_effect([]), ctx(base_url: "x")).transport == Httpc
      assert planned(send_effect([]), ctx()).transport == Httpc
    end

    # sabotage: the `SendDelayed` clause of `deliver/3` plans `{:post, _}`
    # -> no delay travels with the payload and the match reddens. Confirmed
    # red and reverted.
    test "a delayed send plans its delay with the request" do
      delayed = struct!(SendDelayed, Map.from_struct(send_effect([])) |> Map.put(:delay_ms, 250))

      assert {:ok, [{:handler, BasicHTTP, {:post_after, 250, %{url: @target, send: ^delayed}}}]} =
               BasicHTTP.deliver(delayed, Event.external("ping"), ctx())
    end

    # sabotage: `send_key/2` leaves out `ordinal` -> the value has seven
    # fields and both equalities redden. Confirmed red and reverted.
    test "every POST carries the send's dedup key, form body or content body" do
      key = "sess_sender/send_1/1/1/0/3/onentry.2.0/1"

      assert send_key(planned(send_effect(data: %{"a" => 1}))) == key
      assert send_key(planned(send_effect(data: "some content"))) == key
    end

    # sabotage: `escape/1` returns the value unencoded -> the send id's
    # `/` and space survive and the equality reddens. Confirmed red and
    # reverted.
    test "the key escapes the session scope and send id and spells a transition owner" do
      effect =
        send_effect(
          send_id: "a/b c",
          owner: {:transition, 4},
          macrostep: 7,
          microstep: 2,
          round: 1,
          ordinal: 9
        )

      assert send_key(planned(effect, %{session_id: "sess/x"})) ==
               "sess%2Fx/a%2Fb%20c/7/2/1/3/transition.4/9"
    end

    # sabotage: the `SendDelayed` clause of `deliver/3` builds its request
    # with `headers: []` -> no key travels and the membership assertion
    # reddens. Confirmed red and reverted.
    test "a delayed send's POST carries its key too" do
      delayed =
        struct!(
          SendDelayed,
          Map.from_struct(send_effect(owner: {:onexit, 5, 1}, ordinal: 4))
          |> Map.put(:delay_ms, 250)
        )

      assert {:ok, [{:handler, BasicHTTP, {:post_after, 250, post}}]} =
               BasicHTTP.deliver(delayed, Event.external("ping"), ctx())

      assert {"scxml-send-key", "sess_sender/send_1/1/1/0/3/onexit.5.1/4"} in post.headers
    end

    # sabotage: `cancel/2` returns `{:ok, []}` -> no cancel instruction is
    # planned and the equality reddens. Confirmed red and reverted.
    test "a cancel plans the cancellation of the timers held under its send id" do
      assert BasicHTTP.cancel(
               %Cancel{send_id: "send_1", macrostep: 1, microstep: 1, round: 0, ordinal: 2},
               ctx()
             ) ==
               {:ok, [{:handler, BasicHTTP, {:cancel, "send_1"}}]}
    end
  end

  describe "ioprocessors_entry/2 (C.2.3)" do
    # sabotage: the location drops the `/` between the base URL and the
    # session id -> the equality reddens. Confirmed red and reverted.
    test "the location is the base URL, a slash, and the session id" do
      assert BasicHTTP.ioprocessors_entry(@uri, %{
               session_id: "sess_1",
               opts: [base_url: "http://h/b"]
             }) ==
               %{"location" => "http://h/b/sess_1"}
    end

    # sabotage: the missing-option clause returns `%{}` instead of raising
    # -> `assert_raise` reddens. Confirmed red and reverted.
    test "a registration without :base_url is refused" do
      assert_raise ArgumentError, ~r/needs a :base_url option/, fn ->
        BasicHTTP.ioprocessors_entry("basichttp", %{session_id: "sess_1", opts: []})
      end
    end
  end

  describe "check_registration/2" do
    # sabotage: `check_registration/2`'s string `:base_url` arm answers
    # `{:error, {:missing_option, :base_url}}` -> the `== :ok` assertion
    # reddens. Confirmed red and reverted.
    test "a registration with a string :base_url is accepted" do
      assert BasicHTTP.check_registration("basichttp", base_url: "http://front.test/in") == :ok
    end

    # sabotage: `check_registration/2`'s missing-option arm answers `:ok` -> the
    # `==` assertion reddens. Confirmed red and reverted.
    test "a registration without a string :base_url names the missing option" do
      for opts <- [
            [],
            [transport: Statifier.BasicHTTPTestTransport],
            [base_url: :front],
            [1, 2],
            [{:a, 1} | :improper]
          ] do
        assert BasicHTTP.check_registration("basichttp", opts) ==
                 {:error, {:missing_option, :base_url}}
      end
    end
  end

  describe "decode/1: the inbound half (C.2.1)" do
    defp request(fields),
      do: Map.merge(%{method: "POST", content_type: @form, body: "", query: nil}, fields)

    # sabotage: `decode/1` reads the name from the last `_scxmleventname`
    # instead of the first -> the body's name wins and the equality
    # reddens. Confirmed red and reverted.
    test "the event name is the first _scxmleventname, the query string before the body" do
      assert {:ok, %Event{name: "from.query"}} =
               BasicHTTP.decode(
                 request(%{
                   query: "_scxmleventname=from.query",
                   body: "_scxmleventname=from.body&_scxmleventname=again"
                 })
               )

      assert {:ok, %Event{name: "from.body"}} =
               BasicHTTP.decode(request(%{body: "_scxmleventname=from.body&_scxmleventname=x"}))
    end

    # sabotage: the no-name arm returns `"HTTP." <> method` without
    # upcasing -> a lower-case `post` method yields `HTTP.post` and the
    # match reddens. Confirmed red and reverted.
    test "without _scxmleventname the event is named for the method" do
      assert {:ok, %Event{name: "HTTP.POST", data: :undefined}} =
               BasicHTTP.decode(request(%{method: "post"}))
    end

    # sabotage: `data/2` skips `text/1` and keeps each value a string ->
    # `Var1` reads "2" and the equality reddens. Confirmed red and reverted.
    test "a form body's other parameters become the data, each through the text rung" do
      assert {:ok, event} =
               BasicHTTP.decode(
                 request(%{query: "q=yes", body: "_scxmleventname=e&Var1=2&name=two+words"})
               )

      assert event.data == %{"q" => "yes", "Var1" => 2, "name" => "two words"}
      assert event.type == :external
      assert event.origintype == @uri
    end

    # sabotage: `form?/1` answers true for every content type -> the text
    # body is read as a form, `data` is a one-key map, and the equality
    # reddens. Confirmed red and reverted.
    test "a body of another content type becomes the data through the text rung" do
      assert {:ok, %Event{name: "e", data: 42}} =
               BasicHTTP.decode(
                 request(%{content_type: "text/plain", body: " 42 ", query: "_scxmleventname=e"})
               )

      assert {:ok, %Event{name: "HTTP.POST", data: "plain words"}} =
               BasicHTTP.decode(request(%{content_type: nil, body: "plain   words"}))
    end

    # sabotage: `decode/1` sets the event's `sendid` from the key's second
    # field -> the generated `send_3` reaches `sendid` and the first match
    # reddens. Confirmed red and reverted.
    test "a well-formed scxml-send-key sets no event field: sendid stays nil" do
      assert {:ok, %Event{sendid: nil}} =
               BasicHTTP.decode(request(%{send_key: "sess_1/send_3/1/1/0/3/onentry.2.0/1"}))

      assert {:ok, %Event{sendid: nil}} = BasicHTTP.decode(request(%{send_key: nil}))
      assert {:ok, %Event{sendid: nil}} = BasicHTTP.decode(request(%{}))
    end

    # sabotage: `check_send_key/1` accepts any field count (the `with` pattern
    # matches `[_scope, send_id | _rest]`) -> the short key decodes and
    # the equality reddens. Confirmed red and reverted.
    test "a malformed scxml-send-key is refused" do
      assert BasicHTTP.decode(request(%{send_key: "sess_1/x/1"})) ==
               {:error, {:malformed_send_key, "sess_1/x/1"}}

      assert BasicHTTP.decode(request(%{send_key: "s/%FF/1/1/0/3/transition.1/1"})) ==
               {:error, {:malformed_send_key, "s/%FF/1/1/0/3/transition.1/1"}}
    end

    # sabotage: `post_only/1` answers `:ok` for every method -> a GET
    # decodes and the match reddens. Confirmed red and reverted.
    test "a method other than POST is refused as method_not_allowed" do
      assert BasicHTTP.decode(request(%{method: "GET"})) ==
               {:error, {:method_not_allowed, "GET"}}
    end

    # sabotage: `pairs/2` checks the values only -> the query string's
    # non-UTF-8 key decodes and the second equality reddens. Confirmed red
    # and reverted.
    test "a query string or a body that is not UTF-8 once decoded is refused" do
      assert BasicHTTP.decode(request(%{body: "a=%FF"})) == {:error, {:not_utf8, :body}}
      assert BasicHTTP.decode(request(%{query: "%FF=1"})) == {:error, {:not_utf8, :query}}

      assert BasicHTTP.decode(request(%{content_type: "text/plain", body: <<0xFF>>})) ==
               {:error, {:not_utf8, :body}}
    end
  end
end
