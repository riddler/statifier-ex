defmodule Statifier.Session.RecordingTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Event, Lowering, Machine, Parser, Validator}
  alias Statifier.Effect.Log
  alias Statifier.Send.Routes
  alias Statifier.Session.Recording

  defp compile! do
    xml = """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
            <transition event="go" target="b"/>
        </state>
        <state id="b"/>
    </scxml>
    """

    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp event(name), do: Event.external(name)

  defp routes, do: Routes.new(sessions: ["sess_peer"], parent?: true, invokes: ["inv1"])

  describe "new/2" do
    # sabotage: `new/2`'s default for `:max_macrostep_rounds` changed from
    # `10_000` to `1_000` -> the defaulted-options assertion reddens
    test "normalizes and defaults the five options, sorted by key" do
      recording = Recording.new(compile!(), [])

      assert Recording.opts(recording) == [
               datamodel: %{},
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

    # sabotage: `new/2` drops the `Keyword.put_new(:routes, nil)` call ->
    # `Keyword.get(opts, :routes)` returns `nil` from the missing key rather
    # than the normalized default, indistinguishable by this assertion alone,
    # so the mutation is instead: `new/2`'s `Keyword.take/2` key list drops
    # `:routes` -> a supplied `:routes` value never reaches `opts/1`,
    # reddening the second assertion below.
    test "normalizes :routes into opts/1, defaulting nil" do
      empty = Recording.new(compile!())
      assert Keyword.get(Recording.opts(empty), :routes) == nil

      stamped = Recording.new(compile!(), routes: routes())
      assert Keyword.get(Recording.opts(stamped), :routes) == routes()
    end

    # sabotage: `new/2` keeps every key `opts` was called with instead of
    # `Keyword.take/2`-ing the normalized five -> this assertion reddens on
    # the stray `:name` key surviving into `opts/1`
    test "drops any option outside the normalized five" do
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
end
