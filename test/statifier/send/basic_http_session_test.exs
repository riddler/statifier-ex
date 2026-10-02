defmodule Statifier.Send.BasicHTTPSessionTest do
  use ExUnit.Case, async: false

  # ADR-0075 through a live `Statifier.Session`: the two `_ioprocessors`
  # keys and their one location (decision 3), the refusal of a registration
  # without `:base_url` (decision 8, point b), a send's POST, C.2.2's
  # `error.communication` for a missing target, a failed delivery reaching
  # the sender through `failed_send/3` (decision 8, point d), and a delayed
  # send and its cancel (decision 9). Every POST goes through
  # `Statifier.BasicHTTPTestTransport`, which this test process registers
  # under its own name to receive them, so the tests are `async: false`.

  import Statifier.Testing.Case, only: [test_scxml: 5]

  alias Statifier.{BasicHTTPTestTransport, Session}
  alias Statifier.Send.BasicHTTP

  @uri "http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"
  @base_url "http://front.test/basichttp"
  @opts [base_url: @base_url, transport: BasicHTTPTestTransport]
  @send_types %{@uri => {BasicHTTP, @opts}, "basichttp" => {BasicHTTP, @opts}}

  setup do
    Process.register(self(), BasicHTTPTestTransport)
    :ok
  end

  defp start!(xml, send_types \\ @send_types) do
    {:ok, machine} = Statifier.compile(xml)
    {:ok, session} = Statifier.start_session(machine, send_types: send_types)
    on_exit(fn -> if Process.alive?(session), do: Session.stop(session) end)
    session
  end

  @idle """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="idle">
        <state id="idle"/>
      </scxml>
  """

  describe "the _ioprocessors entry (C.2.3)" do
    # sabotage: `SystemVariables.initial/3` keeps the `/1` entry for every
    # type (`session_entry/5` returns `entry`) -> both keys read `%{}` and
    # the equality reddens. Confirmed red and reverted.
    test "both registered keys carry one location: the base URL and the session id" do
      session = start!(@idle)
      %{datamodel: datamodel} = Session.snapshot(session)
      location = %{"location" => @base_url <> "/" <> datamodel["_sessionid"]}

      assert Map.take(datamodel["_ioprocessors"], [@uri, "basichttp"]) == %{
               @uri => location,
               "basichttp" => location
             }
    end

    # sabotage: `init_accepted/4`'s fresh clause boots whatever
    # `rejected_registration/1` answers -> `ioprocessors_entry/2` raises,
    # the start answers the `ArgumentError` shape and the match reddens.
    # Confirmed red and reverted.
    test "a registration without :base_url is refused by name when the session starts" do
      {:ok, machine} = Statifier.compile(@idle)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error,
                  {:send_types,
                   {:invalid_registration, "basichttp", {:missing_option, :base_url}}}} =
                   Statifier.start_session(machine, send_types: %{"basichttp" => BasicHTTP})
        end)

      assert log == ""
    end

    # sabotage: `init_accepted/4`'s resume clause asks
    # `rejected_registration/1` as a fresh start does -> the resume is
    # refused and the `{:ok, _}` match reddens. Confirmed red and reverted.
    test "a resume whose registration lacks :base_url is not refused, and keeps its entry" do
      {:ok, machine} = Statifier.compile(@idle)
      first = start!(@idle)
      started = Session.snapshot(first)
      {:ok, blob} = Statifier.Position.to_binary(started)
      :ok = Session.stop(first)

      assert {:ok, resumed} =
               Statifier.start_session(machine,
                 resume: blob,
                 send_types: %{"basichttp" => BasicHTTP}
               )

      on_exit(fn -> if Process.alive?(resumed), do: Session.stop(resumed) end)

      assert Session.snapshot(resumed).datamodel["_ioprocessors"]["basichttp"] ==
               started.datamodel["_ioprocessors"]["basichttp"]
    end
  end

  describe "an outbound send" do
    # sabotage: `perform/2`'s `{:post, _}` clause returns `:ok` without
    # calling the transport -> no POST reaches this process and
    # `assert_receive` reddens. Confirmed red and reverted.
    test "POSTs the event name and parameters to the target" do
      start!("""
          <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
            <datamodel><data id="Var1" expr="2"/></datamodel>
            <state id="s">
              <onentry>
                <send type="basichttp" event="ping" target="http://sink.test/in" namelist="Var1">
                  <param name="p" expr="'x'"/>
                </send>
              </onentry>
            </state>
          </scxml>
      """)

      assert_receive {:basichttp_post, "http://sink.test/in", headers, body}

      assert {"content-type", "application/x-www-form-urlencoded"} in headers
      assert URI.decode_query(body) == %{"_scxmleventname" => "ping", "Var1" => "2", "p" => "x"}
    end

    # sabotage: `deliver/3`'s nil-target clause raises `error.execution`
    # instead -> the chart takes the catch-all to `fail` and the
    # configuration assertion reddens. Confirmed red and reverted.
    test "a send with no target raises error.communication with the send id" do
      test_scxml(
        """
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry><send type="basichttp" event="ping" id="lost"/></onentry>
                <transition event="error.communication" cond="_event.sendid == 'lost'" target="pass"/>
                <transition event="*" target="fail"/>
              </state>
              <final id="pass"/>
              <final id="fail"/>
            </scxml>
        """,
        "no target",
        ["pass"],
        [],
        send_types: @send_types
      )
    end

    for {what, target} <- [
          {"a transport error", "http://sink.test/answer/error"},
          {"a status outside 2xx", "http://sink.test/answer/500"}
        ] do
      # sabotage: `post_now/2` answers `:ok` for every transport answer ->
      # no miss is reported, no error.communication is raised, and the
      # chart never reaches `pass`. Confirmed red and reverted.
      test "#{what} reaches the sender as error.communication through failed_send/3" do
        test_scxml(
          """
              <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
                <state id="s">
                  <onentry>
                    <send type="basichttp" event="ping" id="missed" target="#{unquote(target)}"/>
                  </onentry>
                  <transition event="error.communication" cond="_event.sendid == 'missed'"
                              target="pass"/>
                  <transition event="*" target="fail"/>
                </state>
                <final id="pass"/>
                <final id="fail"/>
              </scxml>
          """,
          unquote(what),
          ["pass"],
          [],
          send_types: @send_types
        )
      end
    end

    # sabotage: `report/3` returns `:ok` when no session is registered ->
    # the miss is swallowed and the equality reddens. Confirmed red and
    # reverted.
    test "with no live session under the sender's id, a miss is returned only" do
      post = %{
        url: "http://sink.test/answer/503",
        headers: [],
        body: "",
        transport: BasicHTTPTestTransport,
        send: %Statifier.Effect.Send{
          send_id: "gone",
          event: "e",
          macrostep: 1,
          microstep: 1,
          round: 0
        }
      }

      assert BasicHTTP.perform({:post, post}, %{session_id: "sess_nobody"}) ==
               {:error, {:http_status, 503}}
    end
  end

  describe "a delayed send and its cancel" do
    # sabotage: `hold/4`'s `after` arm discards instead of POSTing -> no
    # POST arrives and `assert_receive` reddens. Confirmed red and reverted.
    test "a delayed send POSTs once its delay has passed" do
      start!("""
          <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
            <state id="s">
              <onentry>
                <send type="basichttp" event="later" delay="50ms" target="http://sink.test/later"/>
              </onentry>
            </state>
          </scxml>
      """)

      refute_received {:basichttp_post, _url, _headers, _body}

      assert_receive {:basichttp_post, "http://sink.test/later", _headers,
                      "_scxmleventname=later"}
    end

    # sabotage: `perform/2`'s `{:cancel, _}` clause returns `:ok` without
    # messaging the timers -> the POST fires and `refute_receive` reddens.
    # Confirmed red and reverted.
    test "a cancel before the delay passes stops the POST" do
      start!("""
          <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
            <state id="s">
              <onentry>
                <send type="basichttp" event="later" id="t" delay="100ms"
                      target="http://sink.test/cancelled"/>
                <cancel sendid="t"/>
              </onentry>
            </state>
          </scxml>
      """)

      refute_receive {:basichttp_post, _url, _headers, _body}, 300
    end

    # sabotage: `hold/4` POSTs at fire time without the `running?/1` check
    # -> the halted session's send fires and `refute_receive` reddens.
    # Confirmed red and reverted.
    test "a session that has halted discards a delayed send it still holds" do
      start!("""
          <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
            <state id="s">
              <onentry>
                <send type="basichttp" event="later" delay="50ms" target="http://sink.test/late"/>
              </onentry>
              <transition target="done"/>
            </state>
            <final id="done"/>
          </scxml>
      """)

      refute_receive {:basichttp_post, _url, _headers, _body}, 250
    end

    # sabotage: `hold/4`'s `{:DOWN, ...}` arm is deleted -> the timer
    # outlives its stopped session, and `Process.alive?/1` reads true.
    # Confirmed red and reverted.
    test "a timer ends when the session holding it stops" do
      session =
        start!("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry>
                  <send type="basichttp" event="later" id="t" delay="10s"
                        target="http://sink.test/never"/>
                </onentry>
              </state>
            </scxml>
        """)

      # A call is answered only after the session has performed its start.
      _status = Session.status(session)
      {:dictionary, dictionary} = Process.info(session, :dictionary)
      {_key, [timer]} = List.keyfind(dictionary, {BasicHTTP, "t"}, 0)
      ref = Process.monitor(timer)
      Session.stop(session)
      assert_receive {:DOWN, ^ref, :process, ^timer, _reason}
    end
  end
end
