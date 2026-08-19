defmodule Statifier.Session.RecordingTest do
  use ExUnit.Case, async: true

  alias Statifier.{
    Compiler,
    Effect,
    Event,
    Interpreter,
    Lowering,
    Machine,
    Parser,
    Position,
    Replay,
    Session,
    Validator
  }

  alias Statifier.Effect.Log
  alias Statifier.Send.Routes
  alias Statifier.Session.Recording

  @xml """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b">
          <transition event="next" target="c"/>
      </state>
      <state id="c"/>
  </scxml>
  """

  # A minimal `Statifier.Invoke.Handler` used only to name a resolvable
  # module in the codec's `:invoke_handlers` opts - modeled on
  # `test/statifier/replay_test.exs:14-27`. Its callbacks are never invoked
  # by anything in this file; only its module atom matters.
  defmodule TestHandler do
    @moduledoc false
    @behaviour Statifier.Invoke.Handler

    @impl Statifier.Invoke.Handler
    def start(%Effect.Invoke{invoke_id: invoke_id}, _ctx),
      do: {:ok, [{:handler, __MODULE__, invoke_id}]}

    @impl Statifier.Invoke.Handler
    def cancel(invoke_id, _ctx), do: {:ok, [{:stop_child, invoke_id}]}

    @impl Statifier.Invoke.Handler
    def forward(invoke_id, event, _ctx), do: {:ok, [{:forward, invoke_id, event}]}
  end

  # A Machine built by the raw pipeline stages rather than `Statifier.compile/2`
  # - carries no `identity` and no `source`, exactly the fixture
  # `to_binary/1`'s `:unidentified_chart` refusal test wants.
  defp compile! do
    {:ok, root} = Parser.parse(@xml)
    {:ok, document} = Lowering.lower(root, @xml)
    {:ok, document, _warnings} = Validator.validate(document, @xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # An identified Machine, built through `Statifier.compile/2` so it carries
  # both `identity` and `source` - what `to_binary/1` needs to produce a blob.
  defp compile_identified!(opts \\ []) do
    {:ok, machine} = Statifier.compile(@xml, opts)
    machine
  end

  defp event(name), do: Event.external(name)

  defp routes, do: Routes.new(sessions: ["sess_peer"], parent?: true, invokes: ["inv1"])

  defp wait_for_status(session, pred, attempts \\ 50)
  defp wait_for_status(_session, _pred, 0), do: flunk("status/1 never satisfied the predicate")

  defp wait_for_status(session, pred, attempts) do
    status = Session.status(session)

    if pred.(status) do
      status
    else
      Process.sleep(5)
      wait_for_status(session, pred, attempts - 1)
    end
  end

  describe "new/2" do
    # sabotage: `new/2`'s default for `:max_macrostep_rounds` changed from
    # `10_000` to `1_000` -> the defaulted-options assertion reddens
    test "normalizes and defaults the seven options, sorted by key" do
      recording = Recording.new(compile!(), [])

      assert Recording.opts(recording) == [
               datamodel: %{},
               invoke_handlers: %{},
               invoke_types: nil,
               max_macrostep_rounds: 10_000,
               routes: nil,
               session_id: nil,
               trace: false
             ]
    end

    # sabotage: `new/2` drops `:session_id` from `Keyword.take/2`'s key list
    # -> this assertion reddens because the resolved id never reaches `opts/1`
    test "resolves :session_id to the supplied value, not the default" do
      recording = Recording.new(compile!(), session_id: "sess_abc", trace: true)

      opts = Recording.opts(recording)
      assert Keyword.get(opts, :session_id) == "sess_abc"
      assert Keyword.get(opts, :trace) == true
    end

    # sabotage: `new/2`'s `Keyword.take/2` key list drops `:routes` -> a
    # supplied `:routes` value never reaches `opts/1`, reddening the second
    # assertion below.
    test "normalizes :routes into opts/1, defaulting nil" do
      empty = Recording.new(compile!())
      assert Keyword.get(Recording.opts(empty), :routes) == nil

      stamped = Recording.new(compile!(), routes: routes())
      assert Keyword.get(Recording.opts(stamped), :routes) == routes()
    end

    # sabotage: `new/2` keeps every key `opts` was called with instead of
    # `Keyword.take/2`-ing the normalized seven -> this assertion reddens on
    # the stray `:name` key surviving into `opts/1`
    test "drops any option outside the normalized seven" do
      recording = Recording.new(compile!(), name: :ignored, session_id: "sess_x")

      refute Keyword.has_key?(Recording.opts(recording), :name)
    end
  end

  describe "put_event/3, put_cancel/2, put_timer/4, put_interpret/3, entries/1" do
    # sabotage: `entries/1` drops the `Enum.reverse/1` call -> this assertion
    # reddens because the four kinds come back in reverse append order
    test "entries come back in append order across all four kinds interleaved" do
      log_effect = {:log, %Log{label: "l", value: nil, macrostep: 0, microstep: 0, round: 0}}

      recording =
        compile!()
        |> Recording.new()
        |> Recording.put_event(event("a"), nil)
        |> Recording.put_cancel(nil)
        |> Recording.put_timer("s1", event("b"), nil)
        |> Recording.put_interpret([log_effect], nil)
        |> Recording.put_event(event("c"), nil)

      assert Recording.entries(recording) == [
               {:event, event("a"), nil},
               {:cancel, nil},
               {:timer, "s1", event("b"), nil},
               {:interpret, [log_effect], nil},
               {:event, event("c"), nil}
             ]
    end

    # sabotage: `put_interpret/3` splits `effects` into one entry per effect
    # instead of storing the whole list under one `{:interpret, effects,
    # routes}` entry -> this assertion reddens on the entry count
    test "a multi-effect interpret/2 batch stays one entry" do
      effects = [
        {:log, %Log{label: "one", value: nil, macrostep: 0, microstep: 0, round: 0}},
        {:log, %Log{label: "two", value: nil, macrostep: 0, microstep: 0, round: 0}}
      ]

      recording =
        compile!()
        |> Recording.new()
        |> Recording.put_interpret(effects, nil)

      assert Recording.entries(recording) == [{:interpret, effects, nil}]
    end
  end

  describe "the route snapshot rides on each entry (ADR-0048 decision 3)" do
    # sabotage: `put_event/3` drops the trailing `routes` argument from the
    # stored tuple (hardcodes `nil` in its place) -> the non-nil snapshot
    # this test stamps never reaches `entries/1`, reddening the match
    test "put_event/3 round-trips a non-nil snapshot at its position" do
      recording =
        compile!()
        |> Recording.new()
        |> Recording.put_event(event("a"), routes())

      assert [{:event, %Event{name: "a"}, snapshot}] = Recording.entries(recording)
      assert snapshot == routes()
    end

    # sabotage: `put_invoked_event/4` drops the trailing `routes` argument
    # from the stored tuple -> the stamped snapshot never reaches
    # `entries/1`, reddening the match
    test "put_invoked_event/4 round-trips a non-nil snapshot at its position" do
      recording =
        compile!()
        |> Recording.new()
        |> Recording.put_invoked_event("inv1", event("a"), routes())

      assert [{:invoked_event, "inv1", %Event{name: "a"}, snapshot}] =
               Recording.entries(recording)

      assert snapshot == routes()
    end

    # sabotage: `put_cancel/2` drops the trailing `routes` argument (stores a
    # bare `{:cancel, nil}` regardless of what was passed) -> the stamped
    # snapshot never reaches `entries/1`, reddening the match
    test "put_cancel/2 round-trips a non-nil snapshot at its position" do
      recording =
        compile!()
        |> Recording.new()
        |> Recording.put_cancel(routes())

      assert [{:cancel, snapshot}] = Recording.entries(recording)
      assert snapshot == routes()
    end

    # sabotage: `put_timer/4` drops the trailing `routes` argument from the
    # stored tuple -> the stamped snapshot never reaches `entries/1`,
    # reddening the match
    test "put_timer/4 round-trips a non-nil snapshot at its position" do
      recording =
        compile!()
        |> Recording.new()
        |> Recording.put_timer("s1", event("b"), routes())

      assert [{:timer, "s1", %Event{name: "b"}, snapshot}] = Recording.entries(recording)
      assert snapshot == routes()
    end

    # sabotage: `put_interpret/3` drops the trailing `routes` argument from
    # the stored tuple -> the stamped snapshot never reaches `entries/1`,
    # reddening the match
    test "put_interpret/3 round-trips a non-nil snapshot at its position" do
      log_effect = {:log, %Log{label: "l", value: nil, macrostep: 0, microstep: 0, round: 0}}

      recording =
        compile!()
        |> Recording.new()
        |> Recording.put_interpret([log_effect], routes())

      assert [{:interpret, [^log_effect], snapshot}] = Recording.entries(recording)
      assert snapshot == routes()
    end

    # sabotage: `put_internal/6` drops the trailing `routes` argument from
    # the stored tuple -> the stamped snapshot never reaches `entries/1`,
    # reddening the match
    test "put_internal/6 round-trips a non-nil snapshot at its position" do
      recording =
        compile!()
        |> Recording.new()
        |> Recording.put_internal(:platform, "error.communication", {:state, 0}, [], routes())

      assert [{:internal, :platform, "error.communication", {:state, 0}, [], snapshot}] =
               Recording.entries(recording)

      assert snapshot == routes()
    end
  end

  describe "size/1" do
    # sabotage: `size/1` returns `0` unconditionally instead of
    # `length/1` on `entries` -> this assertion reddens
    test "counts every recorded entry" do
      recording =
        compile!()
        |> Recording.new()
        |> Recording.put_event(event("a"), nil)
        |> Recording.put_cancel(nil)

      assert Recording.size(recording) == 2
      assert Recording.size(Recording.new(compile!())) == 0
    end
  end

  describe "new/3 and anchor/1" do
    # sabotage: `new/3`'s struct build drops the `anchor:` field (always
    # stores `nil` regardless of the third argument) -> the first assertion
    # below reddens because the supplied blob never reaches `anchor/1`
    test "new/3 stores the supplied anchor; new/2 callers still default to nil" do
      machine = compile_identified!()
      {machine_state, _effects} = Interpreter.initialize(machine, [])
      assert {:ok, anchor_blob} = Position.to_binary(machine_state)

      anchored = Recording.new(machine, [], anchor_blob)
      assert Recording.anchor(anchored) == anchor_blob

      unanchored = Recording.new(machine, [])
      assert Recording.anchor(unanchored) == nil
    end
  end

  describe "term_to_binary/1 and binary_to_term/1" do
    # sabotage: n/a - this test only checks that `%Recording{}` carries no
    # pid/ref/port/fun that would break a term round trip, not a specific
    # `lib/` behavior a mutation could redden
    test "round-trips a populated recording (with snapshots present) to an equal term" do
      %Machine{} = machine = compile!()

      recording =
        machine
        |> Recording.new(session_id: "sess_rt", trace: true, routes: routes())
        |> Recording.put_event(event("a"), routes())
        |> Recording.put_cancel(routes())
        |> Recording.put_timer(nil, event("b"), routes())
        |> Recording.put_interpret(
          [{:log, %Log{label: "l", value: nil, macrostep: 0, microstep: 0, round: 0}}],
          routes()
        )

      round_tripped =
        recording
        |> :erlang.term_to_binary()
        |> :erlang.binary_to_term()

      assert round_tripped == recording
    end
  end

  describe "to_binary/1 then from_binary/1 live round trip" do
    # This is the central test ADR-0057's Consequences owe: a live recorded
    # run, replayed both in memory and after a full encode/decode round
    # trip, must reach the same terminal position and stream.
    #
    # sabotage: `from_binary/1`'s `Enum.reverse(entries)` call is dropped
    # (the decoded struct stores `entries` in the blob's own append order
    # instead of restoring the internal reversed representation) -> this
    # test reddens because the decoded recording replays its entries in
    # reverse order, so its final configuration diverges from the live run's
    test "a live recording and its decoded round trip replay to the same terminal position and stream" do
      machine = compile_identified!()
      {:ok, session} = Session.start_link(machine, record: true)

      Session.send_event(session, "go")
      Session.send_event(session, "next")

      live_status = wait_for_status(session, fn s -> s.configuration == MapSet.new(["c"]) end)

      {:ok, live_recording} = Session.recording(session)
      assert {:ok, live_result} = Replay.run(live_recording)

      assert {:ok, blob} = Recording.to_binary(live_recording)
      assert {:ok, decoded_recording} = Recording.from_binary(blob)
      assert {:ok, decoded_result} = Replay.run(decoded_recording)

      assert decoded_result.stream == live_result.stream
      assert decoded_result.status == live_result.status
      assert decoded_result.machine_state.configuration == live_result.machine_state.configuration

      live_configuration =
        live_result.machine_state.configuration
        |> Enum.map(&Machine.id(machine, &1))
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()

      assert live_configuration == live_status.configuration
    end
  end

  describe "to_binary/1 then from_binary/1 append-order stability" do
    # sabotage: `to_binary/1`'s tuple writes the struct's own reversed
    # `entries` field (via `recording.entries`) instead of calling the
    # public `entries(recording)` accessor -> this test reddens because the
    # decoded recording's entries come back in reverse order relative to the
    # original
    test "entries/1 comes back in the same append order after a round trip" do
      log_effect = {:log, %Log{label: "l", value: nil, macrostep: 0, microstep: 0, round: 0}}

      recording =
        compile_identified!()
        |> Recording.new()
        |> Recording.put_event(event("a"), nil)
        |> Recording.put_cancel(nil)
        |> Recording.put_timer("s1", event("b"), nil)
        |> Recording.put_interpret([log_effect], nil)
        |> Recording.put_event(event("c"), nil)

      assert {:ok, blob} = Recording.to_binary(recording)
      assert {:ok, decoded} = Recording.from_binary(blob)

      assert Recording.entries(decoded) == Recording.entries(recording)
    end
  end

  describe "to_binary/1 then from_binary/1 anchor round trip" do
    # sabotage: `to_binary/1`'s envelope tuple hardcodes `nil` for the
    # trailing anchor slot instead of reading `recording.anchor` -> the
    # decoded recording's `anchor/1` comes back `nil` instead of the
    # original blob, reddening the equality assertion
    test "round-trips a non-nil anchor blob" do
      machine = compile_identified!()
      {machine_state, _effects} = Interpreter.initialize(machine, [])
      assert {:ok, anchor_blob} = Position.to_binary(machine_state)

      recording = Recording.new(machine, [], anchor_blob)

      assert {:ok, blob} = Recording.to_binary(recording)
      assert {:ok, decoded} = Recording.from_binary(blob)

      assert Recording.anchor(decoded) == anchor_blob
    end
  end

  describe "from_binary/1 on a hand-built version-1 envelope" do
    # sabotage: `from_binary/1`'s five-element clause is changed to call
    # `decode_envelope(version, chart_blob, opts, entries, :stray)` instead of
    # `decode_envelope(version, chart_blob, opts, entries, nil)` -> this
    # assertion reddens because the decoded recording's `anchor/1` comes back
    # `:stray` instead of `nil`
    test "decodes with anchor: nil" do
      machine = compile_identified!()
      assert {:ok, chart_blob} = Statifier.Chart.to_binary(machine)

      version_1_envelope =
        :erlang.term_to_binary({:statifier_recording, 1, chart_blob, [], []})

      assert {:ok, decoded} = Recording.from_binary(version_1_envelope)
      assert Recording.anchor(decoded) == nil
    end
  end

  describe "to_binary/1 on an unidentified chart" do
    # sabotage: `to_binary/1`'s `with {:ok, chart_blob} <- Chart.to_binary(machine)`
    # is replaced with an unconditional `{:ok, chart_blob} = Chart.to_binary(machine)`
    # match (bypassing the `with`'s error path) -> this test reddens with a
    # `MatchError` instead of the recording's own `{:error, :unidentified_chart}`
    test "refuses to encode a recording made over an unidentified Machine" do
      recording = Recording.new(compile!())

      assert Recording.to_binary(recording) == {:error, :unidentified_chart}
    end
  end

  describe "from_binary/1 on a wrapped chart identity mismatch" do
    # sabotage: `decode_chart/1`'s `{:error, reason} -> {:error, {:chart, reason}}`
    # clause is changed to `{:error, _reason} -> {:error, :not_a_statifier_blob}`
    # (flattening the nested chart's own error into the recording envelope's
    # generic shape error) -> this test reddens because the returned error no
    # longer matches `{:chart, {:identity_mismatch, _, _}}`
    test "wraps a nested chart identity mismatch as {:chart, {:identity_mismatch, _, _}}" do
      machine = compile_identified!()
      other_machine = compile_identified!(chart_name: "other")

      swapped_chart_blob =
        :erlang.term_to_binary(
          {:statifier_chart, Statifier.Chart.format_version(), Machine.identity(other_machine),
           @xml, []}
        )

      envelope =
        :erlang.term_to_binary(
          {:statifier_recording, Recording.format_version(), swapped_chart_blob, [], []}
        )

      assert {:error, {:chart, {:identity_mismatch, expected, actual}}} =
               Recording.from_binary(envelope)

      assert expected == Machine.identity(other_machine)
      assert actual == Machine.identity(machine)
    end
  end

  describe "from_binary/1 on a wrapped chart version mismatch" do
    # sabotage: `decode_chart/1`'s `{:error, reason} -> {:error, {:chart, reason}}`
    # clause is changed to `{:error, _reason} -> {:error, :not_a_statifier_blob}`
    # (flattening the nested chart's own error into the recording envelope's
    # generic shape error) -> this test reddens because the returned error no
    # longer matches `{:chart, {:unsupported_format_version, 99}}`
    test "wraps a nested chart version mismatch distinctly from the envelope's own version arm" do
      machine = compile_identified!()
      identity = Machine.identity(machine)

      future_chart_blob = :erlang.term_to_binary({:statifier_chart, 99, identity, @xml, []})

      envelope =
        :erlang.term_to_binary(
          {:statifier_recording, Recording.format_version(), future_chart_blob, [], []}
        )

      assert Recording.from_binary(envelope) ==
               {:error, {:chart, {:unsupported_format_version, 99}}}
    end
  end

  describe "from_binary/1 on opts with no :invoke_handlers key" do
    # `Keyword.fetch/2` leaves an opts list with no `:invoke_handlers` key
    # untouched rather than inventing one - see the moduledoc's "The binary
    # contract" section on `from_binary/1` being a restorer, not a
    # normalizer.
    #
    # sabotage: `decode_opts/1`'s `:error -> {:ok, opts}` clause is changed
    # to `:error -> {:error, {:unknown_handler_modules, []}}` -> this test
    # reddens because a well-formed envelope whose `opts` carries no
    # `:invoke_handlers` key at all now fails to decode instead of
    # succeeding with `opts` untouched
    test "decodes successfully, leaving opts without the key" do
      machine = compile_identified!()
      assert {:ok, chart_blob} = Statifier.Chart.to_binary(machine)

      envelope =
        :erlang.term_to_binary(
          {:statifier_recording, Recording.format_version(), chart_blob, [session_id: "sess_x"],
           []}
        )

      assert {:ok, decoded} = Recording.from_binary(envelope)
      opts = Recording.opts(decoded)

      assert Keyword.get(opts, :session_id) == "sess_x"
      refute Keyword.has_key?(opts, :invoke_handlers)
    end
  end

  describe "from_binary/1 on unknown handler modules" do
    # sabotage: `resolve_handlers/2`'s `case unknown do` is changed to
    # `case [] do` (always take the `[]` branch) -> this test reddens
    # because an envelope naming unresolvable handler modules decodes
    # successfully instead of returning `{:error, {:unknown_handler_modules, _}}`
    test "returns every unknown handler module name, sorted, in one round trip" do
      machine = compile_identified!()

      assert {:ok, chart_blob} = Statifier.Chart.to_binary(machine)

      unique = System.unique_integer([:positive])

      handlers = %{
        "b" => "Elixir.Statifier.NoSuchHandler#{unique}B",
        "a" => "Elixir.Statifier.NoSuchHandler#{unique}A"
      }

      envelope =
        :erlang.term_to_binary(
          {:statifier_recording, Recording.format_version(), chart_blob,
           [invoke_handlers: handlers], []}
        )

      assert {:error, {:unknown_handler_modules, names}} = Recording.from_binary(envelope)

      assert names ==
               Enum.sort([
                 "Elixir.Statifier.NoSuchHandler#{unique}A",
                 "Elixir.Statifier.NoSuchHandler#{unique}B"
               ])
    end
  end

  describe "from_binary/1 handler round trip" do
    # sabotage: `existing_atom/1`'s success clause returns `{:ok, name}`
    # (the raw string) instead of `{:ok, String.to_existing_atom(name)}` ->
    # this test reddens because the decoded `:invoke_handlers` map's value
    # comes back as a binary rather than the `TestHandler` module atom.
    # Confirmed: also reddens "returns every unknown handler module name"
    # above for the same reason (no name is ever collected as unknown).
    test "a recording naming TestHandler decodes its :invoke_handlers back to the module atom" do
      machine = compile_identified!()

      recording =
        Recording.new(machine, invoke_handlers: %{"custom" => TestHandler})

      assert {:ok, blob} = Recording.to_binary(recording)
      assert {:ok, decoded} = Recording.from_binary(blob)

      assert Recording.opts(decoded)[:invoke_handlers] == %{"custom" => TestHandler}
    end
  end

  describe "from_binary/1 recording envelope version mismatch" do
    # sabotage: `check_version/1`'s exact-match clause head is widened from
    # `defp check_version(@format_version)` to `defp check_version(_version)`
    # (accept any version) -> this test reddens because a blob whose
    # envelope version is bumped to 99 now proceeds to decode the nested
    # chart instead of returning `{:error, {:unsupported_format_version, 99}}`
    test "a blob whose envelope version is bumped returns {:error, {:unsupported_format_version, 99}} unwrapped" do
      machine = compile_identified!()
      assert {:ok, chart_blob} = Statifier.Chart.to_binary(machine)

      future_envelope =
        :erlang.term_to_binary({:statifier_recording, 99, chart_blob, [], []})

      assert Recording.from_binary(future_envelope) == {:error, {:unsupported_format_version, 99}}
    end
  end

  describe "from_binary/1 on a foreign or malformed blob" do
    # sabotage: `from_binary/1`'s catch-all `_other -> {:error,
    # :not_a_statifier_blob}` clause's returned atom is changed to
    # `:invalid_blob` -> all three assertions below redden because the
    # actual returned error atom no longer matches
    test "a foreign term_to_binary blob returns {:error, :not_a_statifier_blob}" do
      assert Recording.from_binary(:erlang.term_to_binary(:hello)) ==
               {:error, :not_a_statifier_blob}
    end

    # sabotage: same mutation as above (`from_binary/1`'s catch-all clause's
    # returned atom changed to `:invalid_blob`) -> this test reddens too,
    # since a random binary reaches the same catch-all via `safe_decode/1`'s
    # `rescue` clause rather than a non-matching decoded term
    test "a random binary returns {:error, :not_a_statifier_blob} rather than raising" do
      random_binary = :crypto.strong_rand_bytes(64)

      assert Recording.from_binary(random_binary) == {:error, :not_a_statifier_blob}
    end

    # sabotage: `from_binary/1`'s decoded-tuple guard is widened from
    # `is_binary(chart_blob) and is_list(opts) and is_list(entries)` to
    # `true` (accept any shape) -> this test reddens because a `chart_blob`
    # slot carrying an atom instead of a binary now reaches `decode_chart/1`,
    # which raises inside `Chart.from_binary/1`'s own `is_binary/1` guard
    # instead of returning `{:error, :not_a_statifier_blob}`
    test "a well-formed envelope whose chart_blob slot is not a binary returns {:error, :not_a_statifier_blob}" do
      malformed_blob =
        :erlang.term_to_binary(
          {:statifier_recording, Recording.format_version(), :not_a_binary, [], []}
        )

      assert Recording.from_binary(malformed_blob) == {:error, :not_a_statifier_blob}
    end
  end

  describe "format_version/0" do
    # sabotage: `@format_version` is changed from `2` back to `1` -> this
    # reddens directly
    test "returns 2" do
      assert Recording.format_version() == 2
    end

    # sabotage: `format_version/0` is changed to return `@format_version +
    # 1` instead of `@format_version` -> this test reddens because the
    # returned value (2) no longer equals the version tag actually written
    # into every blob by `to_binary/1`
    test "matches the version tag to_binary/1 writes" do
      recording = Recording.new(compile_identified!())

      assert {:ok, blob} = Recording.to_binary(recording)

      assert {:statifier_recording, version, _chart_blob, _opts, _entries, _anchor} =
               :erlang.binary_to_term(blob)

      assert version == Recording.format_version()
    end
  end

  describe "a non-binary handler value in a doctored blob" do
    # sabotage: `handler_name/1`'s catch-all `defp handler_name(name), do:
    # inspect(name)` clause is dropped, leaving only the `is_binary(name)`
    # guarded clause -> this test reddens with an unhandled
    # `FunctionClauseError` on `handler_name(42)` instead of the
    # `{:unknown_handler_modules, ["42"]}` return (confirmed:
    # `existing_atom/1`'s own guard is not what saves this path -
    # `String.to_existing_atom/1` already raises `ArgumentError` for a
    # non-binary argument, which the existing `rescue` clause catches either
    # way)
    test "a non-binary handler value collects as an unknown name rather than raising" do
      machine = compile_identified!()
      assert {:ok, chart_blob} = Statifier.Chart.to_binary(machine)

      envelope =
        :erlang.term_to_binary(
          {:statifier_recording, Recording.format_version(), chart_blob,
           [invoke_handlers: %{"t" => 42}], []}
        )

      assert Recording.from_binary(envelope) == {:error, {:unknown_handler_modules, ["42"]}}
    end
  end

  describe "the blob carries no compiled term" do
    # sabotage: n/a - this test asserts a structural property of
    # `to_binary/1`'s output (no `Predicator.Compiled` byte sequence) rather
    # than a behavior any single mutation of `lib/` code would flip without
    # also breaking the round-trip test above
    test "contains no Predicator.Compiled tag" do
      recording = Recording.new(compile_identified!())

      assert {:ok, blob} = Recording.to_binary(recording)
      assert :binary.match(blob, "Predicator.Compiled") == :nomatch
    end
  end
end
