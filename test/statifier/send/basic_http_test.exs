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
               "list" => "[1,2]"
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

    # sabotage: `send_key/2` writes the send id only when it starts with
    # `send_` and the empty string otherwise -> the author's `hold.ready`
    # leaves the key and the first equality reddens. Confirmed red and
    # reverted.
    test "an author-named send id and a generated one travel in the same key field" do
      assert send_key(planned(send_effect(send_id: "hold.ready"))) ==
               "sess_sender/hold.ready/1/1/0/3/onentry.2.0/1"

      assert send_key(planned(send_effect(send_id: "send_7"))) ==
               "sess_sender/send_7/1/1/0/3/onentry.2.0/1"
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

  describe "deliver/3: a list or a map value is JSON text (ADR-0075's Amendment on non-scalar values)" do
    defp params(post), do: URI.decode_query(post.body)

    # sabotage: `encode/1`'s list-or-map clause is deleted, so a map falls
    # through to `inspect/1` -> `loan` reads `%{"title" => "Dune"}` and the
    # equality reddens. Confirmed red and reverted.
    test "a map param is written as a JSON object" do
      post =
        planned(
          send_effect(
            data: %{"loan" => %{"title" => "Dune"}, "patron" => %{"id" => 7, "cards" => 2}}
          )
        )

      assert %{"loan" => ~s({"title":"Dune"}), "patron" => patron} = params(post)
      assert JSON.decode!(patron) == %{"id" => 7, "cards" => 2}
    end

    # sabotage: `json_list/2`'s empty clause answers `{:ok, acc}` without
    # reversing -> the array is written back to front and the equality
    # reddens. Confirmed red and reverted.
    test "a list param is written as a JSON array, in order" do
      post = planned(send_effect(data: %{"holds" => ["Dune", 2, 1.5, true, nil, [], %{}]}))

      assert params(post)["holds"] == ~s(["Dune",2,1.5,true,null,[],{}])
    end

    # sabotage: `json/1`'s `:undefined` clause answers `{:ok, :undefined}` ->
    # `JSON` writes the atom as the string "undefined" and the equalities
    # redden. Confirmed red and reverted.
    test "an undefined value inside a map or a list is JSON null, and a top-level one stays empty" do
      post =
        planned(
          send_effect(
            data: %{
              "loan" => %{"due" => :undefined},
              "holds" => [:undefined, "Dune"],
              "renewal" => :undefined
            }
          )
        )

      assert params(post) == %{
               "_scxmleventname" => "ping",
               "loan" => ~s({"due":null}),
               "holds" => ~s([null,"Dune"]),
               "renewal" => ""
             }
    end

    # sabotage: `json_map/2`'s catch-all skips a pair with a non-string key
    # instead of answering `:error` -> the atom-keyed map is written `{}`
    # and the equality reddens. Confirmed red and reverted.
    test "a map with a key that is not a string keeps its whole inspect text" do
      post = planned(send_effect(data: %{"loan" => %{"title" => "Dune", copies: 2}}))

      assert params(post)["loan"] == inspect(%{"title" => "Dune", copies: 2})
    end

    # sabotage: `json/1`'s catch-all answers `{:ok, inspect(value)}` -> the
    # tuple is written as a JSON string inside the array and the first
    # equality reddens. Confirmed red and reverted.
    test "a list holding a value with no JSON form keeps its whole inspect text" do
      post =
        planned(send_effect(data: %{"shelf" => ["Dune", {:aisle, 4}], "due" => [~D[2026-10-16]]}))

      assert params(post)["shelf"] == inspect(["Dune", {:aisle, 4}])
      assert params(post)["due"] == inspect([~D[2026-10-16]])

      improper = planned(send_effect(data: %{"shelf" => ["Dune" | "Emma"]}))
      assert params(improper)["shelf"] == inspect(["Dune" | "Emma"])
    end

    # sabotage: `json/1`'s binary clause answers `{:ok, ""}` for a string
    # that is not UTF-8 -> the list is written `[""]` and the equality
    # reddens. Confirmed red and reverted.
    test "a list holding a string that is not UTF-8 keeps its whole inspect text" do
      title = <<"caf", 0xE9>>
      post = planned(send_effect(data: %{"titles" => [title]}))

      assert params(post)["titles"] == inspect([title])

      keyed = planned(send_effect(data: %{"loan" => %{title => "Dune"}}))
      assert params(keyed)["loan"] == inspect(%{title => "Dune"})
    end

    # sabotage: `encode/1`'s list-or-map clause guards `is_map/1` alone ->
    # a list content falls through to `inspect/1` and the body equality
    # reddens. Confirmed red and reverted.
    test "a content body that is a list is JSON text, still sent as text/plain" do
      post = planned(send_effect(data: ["Dune", :undefined]))

      assert content_type(post) == "text/plain"
      assert post.body == ~s(["Dune",null])
    end

    # sabotage: `post/2`'s form arm drops `not is_struct/1` -> a `Date` takes
    # the form arm, mapping over it raises `Protocol.UndefinedError`, the
    # rescue answers `{:raised, _}` and the match reddens. Confirmed red and
    # reverted.
    test "a content body that is a struct is its inspect text, sent as text/plain" do
      # A raise is caught into a value, so it fails the match below.
      planned =
        try do
          BasicHTTP.deliver(send_effect(data: ~D[2026-10-16]), Event.external("ignored"), ctx())
        rescue
          exception -> {:raised, exception.__struct__}
        end

      assert {:ok, [{:handler, BasicHTTP, {:post, post}}]} = planned
      assert post.url == @target <> "?_scxmleventname=ping"
      assert content_type(post) == "text/plain"
      assert post.body == inspect(~D[2026-10-16])
    end

    # sabotage: `post/2`'s form arm drops `not is_struct/1` -> the `MapSet`
    # enumerates as the pair `{"loan", "Dune"}` and is sent as a form body,
    # with the event name in the body, so the URL equality reddens.
    # Confirmed red and reverted.
    test "a content body that is a struct enumerating as pairs is its inspect text too" do
      shelf = MapSet.new([{"loan", "Dune"}])
      post = planned(send_effect(data: shelf))

      assert post.url == @target <> "?_scxmleventname=ping"
      assert content_type(post) == "text/plain"
      assert post.body == inspect(shelf)
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

    # sabotage: `form?/1` answers true for `application/json` too -> the JSON
    # body is read as form pairs, `data` is a one-key map with the whole
    # text as its key, and the equality reddens. Confirmed red and reverted.
    test "a JSON body is a body of another content type: the text rung reads it" do
      assert {:ok, %Event{name: "HTTP.POST", data: %{"title" => "Dune", "copies" => 2}}} =
               BasicHTTP.decode(
                 request(%{
                   content_type: "application/json",
                   body: ~s({"title":"Dune","copies":2})
                 })
               )

      assert {:ok, %Event{data: ~s({"title": Dune})}} =
               BasicHTTP.decode(
                 request(%{
                   content_type: "application/json; charset=utf-8",
                   body: ~s({"title": Dune})
                 })
               )
    end

    # sabotage: `body/1`'s last arm reads a body that is not UTF-8 as
    # Latin-1 (`:unicode.characters_to_binary(body, :latin1)`) instead of
    # refusing it -> the text body decodes as Latin-1 text and the first
    # equality reddens. Confirmed red and reverted.
    test "a body that is not UTF-8 is refused whatever charset it names" do
      latin1 = <<"caf", 0xE9>>

      assert BasicHTTP.decode(
               request(%{content_type: "text/plain; charset=iso-8859-1", body: latin1})
             ) == {:error, {:not_utf8, :body}}

      assert BasicHTTP.decode(
               request(%{
                 content_type: "application/json; charset=iso-8859-1",
                 body: ~s(") <> latin1 <> ~s(")
               })
             ) == {:error, {:not_utf8, :body}}

      assert BasicHTTP.decode(
               request(%{content_type: @form <> "; charset=iso-8859-1", body: "title=caf%E9"})
             ) == {:error, {:not_utf8, :body}}
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

    # sabotage: `decode/1` passes `origin: @uri` to `Event.external/2` beside
    # `origintype` -> every decoded event carries an origin and both
    # matches redden. Confirmed red and reverted.
    test "an inbound event's origin stays unset, and its origintype is the processor URI" do
      assert {:ok, %Event{origin: nil, origintype: @uri}} =
               BasicHTTP.decode(request(%{body: "_scxmleventname=hold.ready&branch=north"}))

      assert {:ok, %Event{origin: nil, origintype: @uri}} =
               BasicHTTP.decode(request(%{content_type: "text/plain", body: "due"}))
    end

    # sabotage: `decode/1` splits `body ++ query` instead of `query ++ body`
    # -> the query's `copies` is the last duplicate and wins, and the
    # equality reddens. Confirmed red and reverted.
    test "beside a form body the query string's other parameters join the data, a body parameter winning a name both carry" do
      assert {:ok, %Event{name: "hold.ready", data: data}} =
               BasicHTTP.decode(
                 request(%{
                   query: "branch=north&copies=1",
                   body: "_scxmleventname=hold.ready&copies=3"
                 })
               )

      assert data == %{"branch" => "north", "copies" => 3}
    end

    # sabotage: `data/2`'s text clause reads `data(params, text) when params
    # != []` and answers `data(params, nil)` -> the query's `branch` becomes
    # a one-key map in the data and the equality reddens. Confirmed red and
    # reverted.
    test "beside a body of another content type the query string gives the event name only" do
      assert {:ok, %Event{name: "hold.ready", data: "due"}} =
               BasicHTTP.decode(
                 request(%{
                   content_type: "text/plain",
                   query: "_scxmleventname=hold.ready&branch=north",
                   body: "due"
                 })
               )
    end
  end
end
