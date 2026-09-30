defmodule Mix.Statifier.BasicHTTPFrontTest do
  use ExUnit.Case, async: true

  # ADR-0075 end to end over a real socket: the loopback front answers by
  # the decoder's status rule (decision 5), and the default `:httpc`
  # transport (decision 6) delivers a session's send to its own location.

  import Statifier.Testing.Case, only: [test_scxml: 5]

  alias Mix.Statifier.BasicHTTPFront
  alias Statifier.Send.BasicHTTP
  alias Statifier.Send.BasicHTTP.Transport.Httpc

  @uri "http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"

  setup_all do
    {:ok, front} = BasicHTTPFront.start()
    on_exit(fn -> BasicHTTPFront.stop(front) end)
    %{front: front}
  end

  defp send_types(%{base_url: base_url}),
    do: %{@uri => {BasicHTTP, base_url: base_url}, "basichttp" => {BasicHTTP, base_url: base_url}}

  defp start_idle!(front) do
    {:ok, machine} =
      Statifier.compile("""
          <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
            <state id="idle"/>
          </scxml>
      """)

    {:ok, session} = Statifier.start_session(machine, send_types: send_types(front))
    on_exit(fn -> if Process.alive?(session), do: Statifier.Session.stop(session) end)
    {session, Statifier.Session.snapshot(session).datamodel["_sessionid"]}
  end

  # A raw request through `:httpc`, answering the status and the headers.
  defp request(method, url, body \\ "") do
    request =
      if method == :post,
        do: {String.to_charlist(url), [], ~c"application/x-www-form-urlencoded", body},
        else: {String.to_charlist(url), []}

    {:ok, {{_version, status, _reason}, headers, _body}} = :httpc.request(method, request, [], [])
    {status, headers}
  end

  describe "a session's send reaches its own location" do
    # sabotage: `BasicHTTPFront.answer/2` answers 204 without
    # `Session.send_event/2` -> the event never arrives and the chart
    # stays in `s`. Confirmed red and reverted.
    test "the event and its data arrive through the front", %{front: front} do
      test_scxml(
        """
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry>
                  <send type="basichttp" event="loop"
                        targetexpr="_ioprocessors['basichttp']['location']">
                    <param name="n" expr="2"/>
                  </send>
                </onentry>
                <transition event="loop" cond="_event.data.n == 2" target="pass"/>
                <transition event="*" target="fail"/>
              </state>
              <final id="pass"/>
              <final id="fail"/>
            </scxml>
        """,
        "a send to the session's own location",
        ["pass"],
        [],
        send_types: send_types(front)
      )
    end

    # sabotage: `decode/1` names every nameless event `"HTTP"` -> the
    # transition on `HTTP.POST` never matches. Confirmed red and reverted.
    test "a POST with no _scxmleventname arrives as HTTP.POST", %{front: front} do
      test_scxml(
        """
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry>
                  <send type="#{@uri}"
                        targetexpr="_ioprocessors['#{@uri}']['location']">
                    <param name="n" expr="1"/>
                  </send>
                </onentry>
                <transition event="HTTP.POST" target="pass"/>
                <transition event="*" target="fail"/>
              </state>
              <final id="pass"/>
              <final id="fail"/>
            </scxml>
        """,
        "a nameless send",
        ["pass"],
        [],
        send_types: send_types(front)
      )
    end
  end

  describe "the front's status rule" do
    # sabotage: `answer/2` answers 200 after enqueueing -> the status
    # reads 200 and the equality reddens. Confirmed red and reverted.
    test "204 once the event is enqueued", %{front: front} do
      {_session, session_id} = start_idle!(front)

      assert {204, _headers} =
               request(:post, front.base_url <> "/" <> session_id, "_scxmleventname=hello")
    end

    # sabotage: `head/1`'s 405 clause drops `allow` -> the header is
    # missing and the match reddens. Confirmed red and reverted.
    test "405 with Allow: POST for another method", %{front: front} do
      {_session, session_id} = start_idle!(front)

      assert {405, headers} = request(:get, front.base_url <> "/" <> session_id)
      assert {~c"allow", ~c"POST"} in headers
    end

    # sabotage: `answer/2`'s `{:error, _}` arm answers 204 -> the status
    # reads 204 and the equality reddens. Confirmed red and reverted.
    test "400 for a request that forms no event", %{front: front} do
      {_session, session_id} = start_idle!(front)

      assert {400, _headers} = request(:post, front.base_url <> "/" <> session_id, "a=%FF")
    end

    # sabotage: `answer/2` answers 204 for `:no_session` -> the unknown id
    # reads 204 and the first match reddens. Confirmed red and reverted.
    test "404 for a location that names no live session", %{front: front} do
      assert {404, _headers} = request(:post, front.base_url <> "/sess_nobody", "")
      assert {404, _headers} = request(:post, String.replace(front.base_url, "/basichttp", "/x"))
    end
  end

  describe "the default :httpc transport" do
    # sabotage: `Httpc.post/3` answers `{:ok, 204}` without requesting ->
    # the unknown-session POST reads 204, not the front's 404. Confirmed red
    # and reverted.
    test "answers the status the front answered", %{front: front} do
      assert Httpc.post(front.base_url <> "/sess_nobody", [{"content-type", "text/plain"}], "x") ==
               {:ok, 404}
    end

    # sabotage: `request/2`'s `{:error, reason}` arm answers `{:ok, 204}`
    # -> the refused connection reads as a status and the first match
    # reddens. Confirmed red and reverted.
    test "answers an error when nothing listens, over http and https" do
      assert {:error, _reason} = Httpc.post("http://127.0.0.1:1/x", [], "")
      assert {:error, _reason} = Httpc.post("https://127.0.0.1:1/x", [], "")
    end
  end
end
