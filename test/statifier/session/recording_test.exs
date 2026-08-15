defmodule Statifier.Session.RecordingTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Effect.Log
  alias Statifier.Event
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Parser
  alias Statifier.Session.Recording
  alias Statifier.Validator

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
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp event(name), do: Event.external(name)

  describe "new/2" do
    # sabotage: `new/2`'s default for `:max_macrostep_rounds` changed from
    # `10_000` to `1_000` -> the defaulted-options assertion reddens
    test "normalizes and defaults the four options, sorted by key" do
      recording = Recording.new(compile!(), [])

      assert Recording.opts(recording) == [
               datamodel: %{},
               max_macrostep_rounds: 10_000,
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

    # sabotage: `new/2` keeps every key `opts` was called with instead of
    # `Keyword.take/2`-ing the normalized four -> this assertion reddens on
    # the stray `:name` key surviving into `opts/1`
    test "drops any option outside the normalized four" do
      recording = Recording.new(compile!(), name: :ignored, session_id: "sess_x")

      refute Keyword.has_key?(Recording.opts(recording), :name)
    end
  end

  describe "put_event/2, put_cancel/1, put_timer/3, put_interpret/2, entries/1" do
    # sabotage: `entries/1` drops the `Enum.reverse/1` call -> this assertion
    # reddens because the four kinds come back in reverse append order
    test "entries come back in append order across all four kinds interleaved" do
      log_effect = {:log, %Log{label: "l", value: nil, macrostep: 0, microstep: 0}}

      recording =
        compile!()
        |> Recording.new()
        |> Recording.put_event(event("a"))
        |> Recording.put_cancel()
        |> Recording.put_timer("s1", event("b"))
        |> Recording.put_interpret([log_effect])
        |> Recording.put_event(event("c"))

      assert Recording.entries(recording) == [
               {:event, event("a")},
               :cancel,
               {:timer, "s1", event("b")},
               {:interpret, [log_effect]},
               {:event, event("c")}
             ]
    end

    # sabotage: `put_interpret/2` splits `effects` into one entry per effect
    # instead of storing the whole list under one `{:interpret, effects}`
    # entry -> this assertion reddens on the entry count
    test "a multi-effect interpret/2 batch stays one entry" do
      effects = [
        {:log, %Log{label: "one", value: nil, macrostep: 0, microstep: 0}},
        {:log, %Log{label: "two", value: nil, macrostep: 0, microstep: 0}}
      ]

      recording =
        compile!()
        |> Recording.new()
        |> Recording.put_interpret(effects)

      assert Recording.entries(recording) == [{:interpret, effects}]
    end
  end

  describe "size/1" do
    # sabotage: `size/1` returns `0` unconditionally instead of
    # `length/1` on `entries` -> this assertion reddens
    test "counts every recorded entry" do
      recording =
        compile!()
        |> Recording.new()
        |> Recording.put_event(event("a"))
        |> Recording.put_cancel()

      assert Recording.size(recording) == 2
      assert Recording.size(Recording.new(compile!())) == 0
    end
  end

  describe "term_to_binary/1 and binary_to_term/1" do
    # sabotage: n/a - this test only checks that `%Recording{}` carries no
    # pid/ref/port/fun that would break a term round trip, not a specific
    # `lib/` behavior a mutation could redden
    test "round-trips a populated recording to an equal term" do
      %Machine{} = machine = compile!()

      recording =
        machine
        |> Recording.new(session_id: "sess_rt", trace: true)
        |> Recording.put_event(event("a"))
        |> Recording.put_cancel()
        |> Recording.put_timer(nil, event("b"))
        |> Recording.put_interpret([
          {:log, %Log{label: "l", value: nil, macrostep: 0, microstep: 0}}
        ])

      round_tripped =
        recording
        |> :erlang.term_to_binary()
        |> :erlang.binary_to_term()

      assert round_tripped == recording
    end
  end
end
