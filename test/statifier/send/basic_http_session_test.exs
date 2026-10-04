defmodule Statifier.Send.BasicHTTPSessionTest.Blocker do
  @moduledoc false
  # A send processor whose `perform/2` holds the session performing it until
  # the test process registered in its options sends `:release`, so a test
  # can keep a live session busy for as long as it needs.

  @behaviour Statifier.Send.Processor

  @impl Statifier.Send.Processor
  def deliver(_send, _event, ctx),
    do: {:ok, [{:handler, __MODULE__, {:block, Keyword.fetch!(ctx.opts, :test)}}]}

  @impl Statifier.Send.Processor
  def cancel(_cancel, _ctx), do: {:ok, []}

  @impl Statifier.Send.Processor
  def perform({:block, test}, _ctx) do
    send(test, {:blocked, self()})

    receive do
      :release -> :ok
    end
  end
end

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

  alias Statifier.{BasicHTTPTestTransport, CrashReportProbe, Session}
  alias Statifier.Send.BasicHTTP
  alias Statifier.Send.BasicHTTPSessionTest.Blocker
  alias Statifier.Session.HaltNotice

  @uri "http://www.w3.org/TR/scxml/#BasicHTTPEventProcessor"
  @base_url "http://front.test/basichttp"
  @opts [base_url: @base_url, transport: BasicHTTPTestTransport]
  @send_types %{@uri => {BasicHTTP, @opts}, "basichttp" => {BasicHTTP, @opts}}

  setup do
    Process.register(self(), BasicHTTPTestTransport)
    :ok
  end

  # A bare `Session.start_link/2` for one Basic HTTP registration, with a
  # raise in the caller caught into a value, so a check that raises fails
  # the caller's match rather than the test run.
  defp bare_start(machine, opts) do
    Session.start_link(machine, send_types: %{"basichttp" => {BasicHTTP, opts}})
  rescue
    exception -> {:raised_in_caller, exception.__struct__}
  end

  defp start!(xml, send_types \\ @send_types) do
    {:ok, machine} = Statifier.compile(xml)
    {:ok, session} = Statifier.start_session(machine, send_types: send_types)
    on_exit(fn -> if Process.alive?(session), do: Session.stop(session) end)
    session
  end

  # The processes the session keeps for halt notices (`HaltNotice.watch/2`),
  # read off its process dictionary, as `%{monitor_ref => {key, pid}}`.
  defp watched(session) do
    {:dictionary, dictionary} = Process.info(session, :dictionary)

    case List.keyfind(dictionary, {HaltNotice, :watched}, 0) do
      nil -> %{}
      {_key, watched} -> watched
    end
  end

  # The one timer the session holds under the send id `send_id`.
  defp timer!(session, send_id) do
    # A call is answered only after the session has performed its start.
    _status = Session.status(session)
    [timer] = for {_ref, {{BasicHTTP, ^send_id}, pid}} <- watched(session), do: pid
    timer
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

    # sabotage: the refusal moved back into `init/1` (`start_link/2` skips
    # `rejected_registration/1` and `init_registered/3` stops with the same
    # value) -> the named reason still comes back, but the spawned process's
    # `{:proc_lib, :crash}` report reaches the probe and `refute_receive`
    # reddens. Confirmed red and reverted.
    test "a registration without :base_url is refused by name when the session starts" do
      {:ok, machine} = Statifier.compile(@idle)
      CrashReportProbe.attach()

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error,
                {:send_types, {:invalid_registration, "basichttp", {:missing_option, :base_url}}}} =
                 Statifier.start_session(machine, send_types: %{"basichttp" => BasicHTTP})
      end)

      refute_receive {:crash_report, _report}, 200
    end

    # sabotage: `check_registration/2` asks `Keyword.keyword?/1` before its
    # lookup -> the four starting shapes are refused by name and the
    # `{:ok, _}` match reddens. Also red: dropping its `rescue` (the improper
    # list without the key answers `init/1`s raise instead of the named
    # refusal). Confirmed red and reverted.
    test "a bare start refuses exactly the registrations the entry cannot be built from" do
      # A bare start links the caller to the process it spawns; trapping
      # exits lets a refusal from `init/1` be read as a value.
      Process.flag(:trap_exit, true)
      {:ok, machine} = Statifier.compile(@idle)

      # Shapes `ioprocessors_entry/2` builds an entry from: each starts.
      for opts <- [
            [{:base_url, @base_url} | :improper],
            [{"a", 1}, {:base_url, @base_url}],
            [{:base_url, @base_url}, :junk],
            [{:base_url, @base_url}, {:a, 1, 2}]
          ] do
        assert {:ok, session} = bare_start(machine, opts)
        :ok = Session.stop(session)
      end

      # Shapes it cannot build one from: each is refused by name.
      for opts <- [[], [base_url: :front], [1, 2], [{:a, 1} | :improper]] do
        assert {:error,
                {:send_types, {:invalid_registration, "basichttp", {:missing_option, :base_url}}}} =
                 bare_start(machine, opts)
      end
    end

    # sabotage: `Session`'s `rejected_registration/1` ignores `:resume` ->
    # the resume is refused and the `{:ok, _}` match reddens. Confirmed red
    # and reverted.
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

    # sabotage: `encode/1`'s list-or-map clause is deleted, so a map and a
    # list fall through to `inspect/1` -> both parameters read as Elixir
    # terms and the equality reddens. Confirmed red and reverted.
    test "a map or a list in the datamodel reaches the target as JSON text" do
      start!("""
          <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
            <datamodel>
              <data id="loan" expr="{title: 'Dune', due: undefined}"/>
              <data id="holds" expr="['Dune', 2]"/>
            </datamodel>
            <state id="s">
              <onentry>
                <send type="basichttp" event="loaned" target="http://sink.test/in"
                      namelist="loan holds"/>
              </onentry>
            </state>
          </scxml>
      """)

      assert_receive {:basichttp_post, "http://sink.test/in", _headers, body}
      assert %{"loan" => loan, "holds" => ~s(["Dune",2])} = URI.decode_query(body)
      assert JSON.decode!(loan) == %{"title" => "Dune", "due" => nil}
    end

    # sabotage: `post/2`'s form arm drops `not is_struct/1` -> the `Date`
    # takes the form arm and raises in the session, no POST reaches this
    # process and `assert_receive` reddens. Confirmed red and reverted.
    test "a content expression that evaluates to a struct POSTs its inspect text as text/plain" do
      session =
        start!("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <transition event="loaned">
                  <send type="basichttp" event="due" target="http://sink.test/in">
                    <content expr="_event.data"/>
                  </send>
                </transition>
              </state>
            </scxml>
        """)

      Session.send_event(session, Statifier.Event.external("loaned", data: ~D[2026-10-16]))

      assert_receive {:basichttp_post, "http://sink.test/in?_scxmleventname=due", headers, body}
      assert {"content-type", "text/plain"} in headers
      assert body == inspect(~D[2026-10-16])
      assert Process.alive?(session)
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

    # sabotage: the session's halt path drops `HaltNotice.halted/1` -> the
    # `:done` session's timer is never told, the send fires and
    # `refute_receive` reddens. Confirmed red and reverted.
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

      timer = timer!(session, "t")
      ref = Process.monitor(timer)
      Session.stop(session)
      assert_receive {:DOWN, ^ref, :process, ^timer, _reason}
    end

    # sabotage: `hold/4`'s `after` arm POSTs without the `stopped?/2`
    # mailbox check -> the cancel waiting in the woken timer's mailbox is
    # ignored, the POST arrives and `refute_receive` reddens. Confirmed red
    # and reverted.
    test "a cancel the timer receives after its delay passes, but before the POST, wins" do
      session =
        start!("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry>
                  <send type="basichttp" event="later" id="t" delay="50ms"
                        target="http://sink.test/raced"/>
                </onentry>
                <transition event="stop_it"><cancel sendid="t"/></transition>
              </state>
            </scxml>
        """)

      # The timer is held still while its delay passes, so it wakes past the
      # delay with the cancel already in its mailbox: the fire-time window.
      timer = timer!(session, "t")
      :erlang.suspend_process(timer)
      Process.sleep(100)
      Session.send_event(session, "stop_it")
      # Answered only once the session has performed the cancel.
      _status = Session.status(session)
      :erlang.resume_process(timer)

      refute_receive {:basichttp_post, _url, _headers, _body}, 300
    end

    # sabotage: `hold/4`'s fire-time check also asks `Session.status/1`
    # for `:running` (the call it made before) -> the timer waits on the
    # blocked session, no POST arrives within the second and `assert_receive`
    # reddens. Confirmed red and reverted.
    test "a live session busy when the delay passes still has its delayed send POSTed" do
      start!(
        """
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry>
                  <send type="basichttp" event="later" delay="50ms" target="http://sink.test/busy"/>
                  <send type="blocker" target="anywhere"/>
                </onentry>
              </state>
            </scxml>
        """,
        Map.put(@send_types, "blocker", {Blocker, test: self()})
      )

      # The session is held inside `Blocker.perform/2` until `:release`.
      assert_receive {:blocked, session}
      assert_receive {:basichttp_post, "http://sink.test/busy", _headers, _body}, 1_000
      send(session, :release)
    end

    # sabotage: the session's halt path drops `HaltNotice.halted/1` -> the
    # cancelled session's timer is never told, the POST fires and
    # `refute_receive` reddens. Confirmed red and reverted.
    test "a session halted :cancelled discards a delayed send it still holds" do
      session =
        start!("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry>
                  <send type="basichttp" event="later" delay="100ms" target="http://sink.test/late"/>
                </onentry>
              </state>
            </scxml>
        """)

      _status = Session.status(session)
      :ok = Session.cancel(session)
      assert Session.status(session).status == :cancelled
      assert Process.alive?(session)

      refute_receive {:basichttp_post, _url, _headers, _body}, 300
    end

    # sabotage: the session's halt path drops `HaltNotice.halted/1` -> the
    # budget-halted session's timers are never told, the POSTs fire and
    # `refute_receive` reddens. Confirmed red and reverted.
    test "a session halted :budget_exhausted discards the delayed sends it still holds" do
      {:ok, machine} =
        Statifier.compile("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
              <state id="a">
                <onentry>
                  <send type="basichttp" event="later" delay="100ms" target="http://sink.test/late"/>
                </onentry>
                <transition target="a"/>
              </state>
            </scxml>
        """)

      {:ok, session} =
        Statifier.start_session(machine, send_types: @send_types, max_macrostep_rounds: 5)

      on_exit(fn -> if Process.alive?(session), do: Session.stop(session) end)

      assert Session.status(session).status == :budget_exhausted
      refute_receive {:basichttp_post, _url, _headers, _body}, 300
    end

    # sabotage: `perform/2`'s `:not_a_session` arm answers `:ok` without
    # sending the timer `:cancel` -> the timer POSTs at fire time and
    # `refute_receive` reddens. Confirmed red and reverted.
    test "a delayed send performed outside a session is discarded, with no call made" do
      post = %{
        url: "http://sink.test/no-session",
        headers: [],
        body: "",
        transport: BasicHTTPTestTransport,
        send: %Statifier.Effect.SendDelayed{
          send_id: "solo",
          event: "e",
          delay_ms: 20,
          macrostep: 1,
          microstep: 1,
          round: 0,
          ordinal: 0
        }
      }

      assert BasicHTTP.perform({:post_after, 20, post}, %{session_id: "sess_none"}) == :ok
      refute_receive {:basichttp_post, _url, _headers, _body}, 200
      refute_received {:"$gen_call", _from, _request}
      assert Process.get({HaltNotice, :watched}) == nil
    end

    # sabotage: `post_later/2` loses its `rescue` -> the raise ends the
    # timer with nobody told, the chart never leaves `s` and the `{:halted,
    # :done}` `assert_receive` reddens. Confirmed red and reverted.
    test "a delayed send whose transport raises reaches the sender as error.communication" do
      {:ok, machine} =
        Statifier.compile("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry>
                  <send type="basichttp" event="later" id="boom" delay="20ms"
                        target="http://sink.test/answer/raise"/>
                </onentry>
                <transition event="error.communication" cond="_event.sendid == 'boom'"
                            target="pass"/>
                <transition event="*" target="fail"/>
              </state>
              <final id="pass"/>
              <final id="fail"/>
            </scxml>
        """)

      {:ok, session} =
        Statifier.start_session(machine, send_types: @send_types, subscribers: [self()])

      on_exit(fn -> if Process.alive?(session), do: Session.stop(session) end)
      session_id = Session.session_id(session)

      assert_receive {:basichttp_post, "http://sink.test/answer/raise", _headers, _body}
      assert_receive {:statifier, ^session_id, {:halted, :done}}, 1_000
      assert Session.status(session).configuration == MapSet.new(["pass"])
    end

    # sabotage: the session's `:DOWN` fallback stops calling
    # `HaltNotice.forget/1` -> the fired timer's entry stays and the `%{}`
    # equality reddens. Confirmed red and reverted.
    test "a fired timer leaves no entry in the session's dictionary" do
      session =
        start!("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry>
                  <send type="basichttp" event="later" id="t" delay="50ms"
                        target="http://sink.test/fired"/>
                </onentry>
              </state>
            </scxml>
        """)

      timer = timer!(session, "t")
      ref = Process.monitor(timer)
      assert_receive {:basichttp_post, "http://sink.test/fired", _headers, _body}
      assert_receive {:DOWN, ^ref, :process, ^timer, _reason}
      # Answered only after the session has taken the timer's `:DOWN`.
      _status = Session.status(session)

      assert watched(session) == %{}
      {:dictionary, dictionary} = Process.info(session, :dictionary)
      refute Enum.any?(dictionary, &match?({{BasicHTTP, _send_id}, _value}, &1))
    end

    # sabotage: `HaltNotice.take/1` puts the whole table back instead of
    # the entries it kept (and has demonitored the taken one) -> the entry
    # stays and the `%{}` equality reddens. Confirmed red and reverted.
    test "a cancelled timer leaves no entry in the session's dictionary" do
      session =
        start!("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry>
                  <send type="basichttp" event="later" id="t" delay="10s"
                        target="http://sink.test/never"/>
                </onentry>
                <transition event="stop_it"><cancel sendid="t"/></transition>
              </state>
            </scxml>
        """)

      timer = timer!(session, "t")
      ref = Process.monitor(timer)
      Session.send_event(session, "stop_it")
      assert_receive {:DOWN, ^ref, :process, ^timer, _reason}
      _status = Session.status(session)

      assert watched(session) == %{}
    end

    # sabotage: `HaltNotice.mark_session/0` also writes an empty watched
    # table -> a session that registers nothing gains the entry and the
    # `refute` reddens. Confirmed red and reverted.
    test "a session that registers nothing keeps nothing for halt notices and keeps its own delayed send" do
      {:ok, machine} =
        Statifier.compile("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry><send event="tick" delay="20ms"/></onentry>
                <transition event="tick" target="pass"/>
              </state>
              <final id="pass"/>
            </scxml>
        """)

      {:ok, session} = Statifier.start_session(machine, subscribers: [self()])
      on_exit(fn -> if Process.alive?(session), do: Session.stop(session) end)
      session_id = Session.session_id(session)

      assert_receive {:statifier, ^session_id, {:halted, :done}}, 1_000
      assert Session.status(session).configuration == MapSet.new(["pass"])

      {:dictionary, dictionary} = Process.info(session, :dictionary)
      refute List.keymember?(dictionary, {HaltNotice, :watched}, 0)
    end

    # sabotage: `EventData.coerce/1`'s params rung writes a list value as
    # JSON text (`Map.put(acc, name, JSON.encode!(value))` for a list) -> the
    # internal event's `holds` is a string, `holds[0]` reads undefined, and
    # the chart takes `fail`, so the configuration equality reddens.
    # Confirmed red and reverted.
    test "a session that registers nothing sends a map or a list param as the value itself" do
      {:ok, machine} =
        Statifier.compile("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s">
              <state id="s">
                <onentry>
                  <send event="loaned">
                    <param name="loan" expr="{title: 'Dune', due: undefined}"/>
                    <param name="holds" expr="['Dune', 2]"/>
                  </send>
                </onentry>
                <transition event="loaned"
                            cond="_event.data.loan.title == 'Dune' and _event.data.holds[0] == 'Dune'"
                            target="pass"/>
                <transition event="*" target="fail"/>
              </state>
              <final id="pass"/>
              <final id="fail"/>
            </scxml>
        """)

      {:ok, session} = Statifier.start_session(machine, subscribers: [self()])
      on_exit(fn -> if Process.alive?(session), do: Session.stop(session) end)
      session_id = Session.session_id(session)

      assert_receive {:statifier, ^session_id, {:halted, :done}}, 1_000
      assert Session.status(session).configuration == MapSet.new(["pass"])
    end
  end
end
