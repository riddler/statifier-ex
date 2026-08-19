defmodule Statifier.MachineStateTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Event, Lowering, MachineState, Parser, Validator}
  alias Statifier.Event.Cause
  alias Statifier.Invoke.Types, as: InvokeTypes
  alias Statifier.Send.Routes

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root, xml)
    {:ok, document, _warnings} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # Hand-drawn from `@document`, depth-first, document order:
  #
  #  0 scxml (root, children [1,5,11])
  #  1   a                (children [2,3], last 3)
  #  2     b               (children [3], last 3)
  #  3       c              (atomic)
  #  4   p                (parallel, children [5,7], last 8)
  #  5     p1              (children [6], last 6)
  #  6       p1a
  #  7     p2              (children [8], last 8)
  #  8       p2a
  #  9   f                (final)
  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
      <state id="a">
          <state id="b">
              <state id="c"/>
          </state>
      </state>
      <parallel id="p">
          <state id="p1">
              <state id="p1a"/>
          </state>
          <state id="p2">
              <state id="p2a"/>
          </state>
      </parallel>
      <final id="f"/>
  </scxml>
  """

  @indexes %{
    a: 1,
    b: 2,
    c: 3,
    p: 4,
    p1: 5,
    p1a: 6,
    p2: 7,
    p2a: 8,
    f: 9
  }

  defp machine, do: compile!(@document)
  defp idx(name), do: Map.fetch!(@indexes, name)

  defp new_machine_state(opts \\ []), do: MachineState.new(machine(), opts)

  describe "new/2" do
    # sabotage: `MachineState.new/2` sets `macrostep: 1` instead of `0` ->
    # this assertion reddens; zero must mean "no macrostep has begun yet".
    # sabotage: `MachineState.new/2` sets `round: 1` instead of `0` -> the
    # round assertion reddens the same way.
    test "counters start at zero" do
      ms = new_machine_state()
      assert ms.macrostep == 0
      assert ms.microstep == 0
      assert ms.round == 0
    end

    # sabotage: `MachineState.new/2` sets `running: false` -> this
    # assertion reddens.
    test "running is true and status is :running" do
      ms = new_machine_state()
      assert ms.running == true
      assert ms.status == :running
    end

    # sabotage: `MachineState.new/2` seeds `configuration` with the
    # machine's initial indexes instead of an empty set -> this assertion
    # reddens, since entering the initial configuration is the not-yet-
    # implemented `initialize/2`'s job, not `new/2`'s.
    test "configuration starts empty" do
      ms = new_machine_state()
      assert MapSet.size(ms.configuration) == 0
    end

    # sabotage: `MachineState.new/2` seeds `internal_queue` by enqueuing a
    # sentinel event instead of `:queue.new/0` -> this assertion reddens.
    test "internal queue starts empty" do
      ms = new_machine_state()
      assert MachineState.internal_events(ms) == []
    end

    # sabotage: `MachineState.new/2` defaults `history_values` to a map
    # seeded with an unrelated key instead of `%{}` -> this assertion
    # reddens.
    test "history_values defaults to an empty map" do
      ms = new_machine_state()
      assert ms.history_values == %{}
    end

    # sabotage: `MachineState.new/2` seeds `entered_states` with
    # `MapSet.new([0])` (as if the root were already entered) instead of
    # `MapSet.new()` -> this assertion reddens, since entering the initial
    # configuration - and therefore recording any first entry - is
    # `Statifier.Interpreter.initialize/2`'s job, not `new/2`'s.
    test "entered_states starts empty" do
      ms = new_machine_state()
      assert MapSet.size(ms.entered_states) == 0
    end

    # sabotage: `MachineState.new/2`'s `Map.merge/2` call has its arguments
    # swapped (`SystemVariables.initial/2` over `author_datamodel` becomes
    # `author_datamodel` over `SystemVariables.initial/2`) -> the seeded
    # system variables no longer land in `datamodel`, reddening this
    # assertion.
    # sabotage: `scxml_location/1` returns the bare session id -> the
    # "location" assertion reddens, since it no longer carries the
    # `#_scxml_` prefix.
    test "datamodel defaults to exactly the four seeded system variables and no author data" do
      ms = new_machine_state()
      session_id = ms.datamodel["_sessionid"]

      assert %{
               "_sessionid" => ^session_id,
               "_name" => :undefined,
               "_event" => :undefined,
               "_ioprocessors" => %{
                 "http://www.w3.org/TR/scxml/#SCXMLEventProcessor" => %{
                   "location" => "#_scxml_" <> ^session_id
                 }
               }
             } = ms.datamodel

      assert is_binary(session_id)
      assert map_size(ms.datamodel) == 4
    end

    # sabotage: `SystemVariables.initial/2` drops its `"_event" => :undefined`
    # entry -> `_event` is absent rather than present-and-undefined, so
    # `Map.has_key?/2` reddens. The pair matters: an absent key and a key
    # bound to `:undefined` are the same to `ms.datamodel["_event"]` and
    # different to every evaluation built on top of it, which is what the
    # evaluator test below covers.
    test "_event is seeded as a present key bound to :undefined, not left absent" do
      ms = new_machine_state()

      assert Map.has_key?(ms.datamodel, "_event")
      assert ms.datamodel["_event"] == :undefined
    end

    # sabotage: `MachineState.new/2` hardcodes `trace: false` and ignores
    # the `:trace` option -> this assertion reddens.
    test "trace defaults to false, and the :trace option is honored" do
      assert new_machine_state().trace == false
      assert new_machine_state(trace: true).trace == true
    end

    # sabotage: `MachineState.new/2` hardcodes `max_macrostep_rounds: 10_000`
    # and ignores the option -> the `:infinity` and explicit-integer
    # assertions redden.
    test "max_macrostep_rounds defaults to 10_000, and the option is honored" do
      assert new_machine_state().max_macrostep_rounds == 10_000
      assert new_machine_state(max_macrostep_rounds: 25).max_macrostep_rounds == 25
      assert new_machine_state(max_macrostep_rounds: :infinity).max_macrostep_rounds == :infinity
    end

    # sabotage: `MachineState.new/2` hardcodes `routes: nil` and ignores the
    # `:routes` option -> this assertion reddens.
    test "routes defaults to nil, and the :routes option is honored" do
      assert new_machine_state().routes == nil

      routes = Routes.new(parent?: true)
      assert new_machine_state(routes: routes).routes == routes
    end

    # sabotage: `MachineState.new/2` ignores the `:datamodel` option and
    # always stores `%{}` -> this assertion reddens.
    test "the :datamodel option is honored, merged under the seeded system variables" do
      ms = new_machine_state(datamodel: %{"x" => 1})
      assert ms.datamodel["x"] == 1
      assert is_binary(ms.datamodel["_sessionid"])
    end

    # sabotage: `MachineState.new/2` merges `SystemVariables.initial/2`
    # *under* the author's datamodel instead of over it (arguments to
    # `Map.merge/2` swapped) -> an author-supplied `_sessionid` survives
    # instead of being overwritten, reddening this assertion.
    test "a system variable in the :datamodel option can never shadow the real one" do
      ms = new_machine_state(datamodel: %{"_sessionid" => "author-supplied"})
      refute ms.datamodel["_sessionid"] == "author-supplied"
    end

    # sabotage: `checked_datamodel!/1` returns `datamodel` without calling
    # `check_keys!/2` at all -> the option is read and merged unchecked,
    # exactly the pre-change behavior, and this assertion reddens (no raise).
    test "a top-level atom key in :datamodel raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        new_machine_state(datamodel: %{x: 1})
      end
    end

    # sabotage: `check_keys!/2`'s map clause stops recursing (the
    # `check_keys!(value, [key | path])` call is dropped) -> the top-level
    # test above stays green, but this test and the two below it redden
    # together, since none of the three offending keys sits at the top level.
    test "an atom key inside a nested map raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        new_machine_state(datamodel: %{"user" => %{name: "Ada"}})
      end
    end

    # sabotage: same recursion-stop mutation as above (`check_keys!/2`'s map
    # clause dropping its recursive call) -> reddens together with the other
    # two nested-level tests, since a map inside a list is a nesting level
    # the same recursion is responsible for reaching.
    test "an atom key inside a map held in a list raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        new_machine_state(datamodel: %{"rows" => [%{id: 1}]})
      end
    end

    # sabotage: same recursion-stop mutation again -> reddens together with
    # the other two nested-level tests; this one proves the walk is
    # recursive rather than stopping two levels deep, since the offending
    # key sits three levels down through a mixed map/list/map nest.
    test "an atom key at a deep mixed map/list nest raises ArgumentError" do
      assert_raise ArgumentError, fn ->
        new_machine_state(datamodel: %{"a" => %{"b" => [%{"c" => %{d: 1}}]}})
      end
    end

    # sabotage: `key_message/2` drops the path from the message and names
    # only the key -> this assertion reddens, since the message would no
    # longer mention "user".
    test "the raised message names the offending key and its path" do
      error =
        assert_raise ArgumentError, fn ->
          new_machine_state(datamodel: %{"user" => %{name: "Ada"}})
        end

      assert error.message =~ ":name"
      assert error.message =~ "user"
    end

    # sabotage: `duration_hint/1`'s guard clause `key in @duration_unit_keys`
    # is changed to `key == :bogus_key_never_matches` -> this reddens, since
    # the hint text never gets appended for `:milliseconds`.
    test "the raised message names Predicator.Duration as a plausible cause for a duration-shaped key" do
      duration = Predicator.Duration.new(seconds: 1, milliseconds: 500)

      error =
        assert_raise ArgumentError, fn ->
          new_machine_state(datamodel: %{"timeout" => duration})
        end

      assert error.message =~ "Predicator.Duration"
    end

    # sabotage: `duration_hint/1`'s catch-all clause is changed from
    # `defp duration_hint(_key), do: ""` to always return the duration hint
    # text regardless of key -> this reddens, since an unrelated atom key
    # would then also mention "Predicator.Duration".
    test "the raised message says nothing about durations for an unrelated atom key" do
      error =
        assert_raise ArgumentError, fn ->
          new_machine_state(datamodel: %{"user" => %{name: "Ada"}})
        end

      refute error.message =~ "Predicator.Duration"
    end

    # sabotage: `offending_key?/1` inverts to `is_binary(key)` -> a
    # well-formed string-keyed map is refused, reddening this assertion
    # (a raise where none is expected).
    test "a well-formed string-keyed nested :datamodel is accepted" do
      ms = new_machine_state(datamodel: %{"ok" => %{"nested" => [%{"deep" => 1}]}})
      assert ms.datamodel["ok"] == %{"nested" => [%{"deep" => 1}]}
    end

    # sabotage: `offending_key?/1` drops its `not is_boolean(key)` term,
    # reddening the boolean-key half of this assertion; separately,
    # widening it to `not is_binary(key)` reddens the integer-key half.
    # Both were run, each against its own half.
    test "boolean and integer keys in :datamodel are accepted" do
      ms = new_machine_state(datamodel: %{"flags" => %{true => 1}, "lookup" => %{1 => "a"}})
      assert ms.datamodel["flags"] == %{true => 1}
      assert ms.datamodel["lookup"] == %{1 => "a"}
    end

    # sabotage: `check_keys!/2`'s `%_struct{}` clause is removed, so the walk
    # falls through to the map clause and tries to `Enum.each/2` over the
    # struct -> this assertion reddens (`Protocol.UndefinedError`, since
    # `Date` has no `Enumerable` impl), because a struct is no longer stopped
    # at rather than walked.
    test "a struct value in :datamodel is not walked" do
      ms = new_machine_state(datamodel: %{"d" => ~D[2026-08-15]})
      assert ms.datamodel["d"] == ~D[2026-08-15]
    end

    # sabotage: `MachineState.new/2`'s `Keyword.get_lazy(opts, :session_id,
    # ...)` is changed to `Keyword.get(opts, :session_id, "ignored")` ->
    # the caller-supplied `:session_id` value is dropped in favor of the
    # generated default, reddening the equality assertion.
    # sabotage: `scxml_location/1` returns the bare session id -> the
    # "location" assertion reddens, since it no longer carries the
    # `#_scxml_` prefix.
    test "a supplied :session_id option wins over the generated default" do
      ms = new_machine_state(session_id: "sess_fixed")
      assert ms.datamodel["_sessionid"] == "sess_fixed"

      assert ms.datamodel["_ioprocessors"]["http://www.w3.org/TR/scxml/#SCXMLEventProcessor"][
               "location"
             ] == "#_scxml_sess_fixed"
    end

    # sabotage: `generate_session_id/0`'s "sess_" literal is changed to
    # "usr_" -> the prefix assertion reddens.
    test "the generated default :session_id carries the sess_ prefix (ADR-0008)" do
      ms = new_machine_state()
      assert String.starts_with?(ms.datamodel["_sessionid"], "sess_")
    end

    # sabotage: `crockford32/1` is changed to `Base.encode32/2` (uppercase
    # RFC 4648, which emits `A-Z2-7`) -> the alphabet assertion reddens on
    # the uppercase letters.
    test "the generated :session_id body is 26 hyphen-free lowercase Crockford chars (ADR-0008)" do
      "sess_" <> body = new_machine_state().datamodel["_sessionid"]

      assert String.length(body) == 26
      refute String.contains?(body, "-")
      assert body =~ ~r/\A[0123456789abcdefghjkmnpqrstvwxyz]{26}\z/
    end

    # sabotage: the `System.os_time(:millisecond)::48` prefix in
    # `generate_session_id/0` is replaced with a constant `0::48` -> the two
    # ids no longer order by creation time and the comparison reddens.
    test "generated :session_ids sort by creation millisecond (ADR-0008)" do
      earlier = new_machine_state().datamodel["_sessionid"]
      Process.sleep(2)
      later = new_machine_state().datamodel["_sessionid"]

      assert earlier < later
      assert earlier != later
    end

    # sabotage: `SystemVariables.initial/2` reads `machine.id` instead of
    # `machine.name` -> `_name` no longer reflects the `<scxml name>`
    # attribute, reddening this assertion.
    test "_name is the <scxml name> attribute" do
      xml = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" name="my-machine" initial="a">
          <state id="a"/>
      </scxml>
      """

      {:ok, root} = Parser.parse(xml)

      {:ok, document} = Lowering.lower(root, xml)
      {:ok, document, _warnings} = Validator.validate(document, "")
      {:ok, named_machine} = Compiler.compile(document)

      ms = MachineState.new(named_machine)
      assert ms.datamodel["_name"] == "my-machine"
    end
  end

  describe "put_routes/2" do
    # sabotage: `put_routes/2` is changed to `do: machine_state` (ignoring
    # its `routes` argument) -> this assertion reddens.
    test "sets the routes field" do
      routes = Routes.new(sessions: ["sess_a"])
      ms = new_machine_state() |> MachineState.put_routes(routes)

      assert ms.routes == routes
    end

    # sabotage: `put_routes/2`'s map update `%{machine_state | routes: routes}`
    # is changed to `%{machine_state | routes: machine_state.routes || routes}`
    # (a previously-set snapshot survives a later `put_routes/2` call
    # instead of being replaced) -> the second assertion below, which
    # clears a previously-set snapshot back to nil, reddens.
    test "clears a previously-set snapshot back to nil" do
      routes = Routes.new(parent?: true)

      ms = new_machine_state() |> MachineState.put_routes(routes)
      assert ms.routes == routes

      ms = MachineState.put_routes(ms, nil)
      assert ms.routes == nil
    end
  end

  describe "put_invoke_types/2" do
    # sabotage: `put_invoke_types/2` is changed to `do: machine_state`
    # (ignoring its `invoke_types` argument) -> this assertion reddens.
    test "sets the invoke_types field" do
      invoke_types = InvokeTypes.new(types: ["custom"])
      ms = new_machine_state() |> MachineState.put_invoke_types(invoke_types)

      assert ms.invoke_types == invoke_types
    end

    # sabotage: `put_invoke_types/2`'s map update
    # `%{machine_state | invoke_types: invoke_types}` is changed to
    # `%{machine_state | invoke_types: machine_state.invoke_types || invoke_types}`
    # (a previously-set snapshot survives a later `put_invoke_types/2` call
    # instead of being replaced) -> the second assertion below, which
    # clears a previously-set snapshot back to nil, reddens.
    test "clears a previously-set snapshot back to nil" do
      invoke_types = InvokeTypes.new(types: ["custom"])

      ms = new_machine_state() |> MachineState.put_invoke_types(invoke_types)
      assert ms.invoke_types == invoke_types

      ms = MachineState.put_invoke_types(ms, nil)
      assert ms.invoke_types == nil
    end
  end

  describe "put_event/2" do
    # sabotage: `put_event/2`'s `Map.put/3` is changed to write under the
    # key `"event"` instead of `"_event"` -> the lookup below finds
    # nothing, reddening the pattern match.
    #
    # sabotage: `SystemVariables.event/1`'s `absent/1` helper is changed to
    # `defp absent(value), do: value` (identity, no translation) -> the four
    # absent string fields redden against `:undefined`, since they would
    # come back `nil` instead.
    test "writes datamodel[\"_event\"] to the event's system-variable shape" do
      ms = new_machine_state()
      event = Event.external("go", data: %{"x" => 1})

      result = MachineState.put_event(ms, event)

      assert %{
               "name" => "go",
               "type" => "external",
               "sendid" => :undefined,
               "origin" => :undefined,
               "origintype" => :undefined,
               "invokeid" => :undefined,
               "data" => %{"x" => 1}
             } = result.datamodel["_event"]
    end

    # sabotage: `put_event/2` is changed to `Map.merge/2` the event's shape
    # into `datamodel` at the top level instead of nesting it under
    # `"_event"` -> `_sessionid` (a sibling key) is clobbered, reddening the
    # equality assertion.
    test "does not disturb the session-lifetime system variables already seeded" do
      ms = new_machine_state()
      session_id = ms.datamodel["_sessionid"]

      result = MachineState.put_event(ms, Event.external("go"))

      assert result.datamodel["_sessionid"] == session_id
    end

    # sabotage: `put_event/2`'s `%{machine_state | datamodel: ...}` update
    # is changed to build a fresh `%{"_event" => ...}` map instead of
    # `Map.put/3`-ing into the existing `datamodel` -> `_sessionid` stays
    # stable across the *first* `put_event/2` call but a second call would
    # have nothing to preserve it against; more directly, this assertion
    # reddens because `_sessionid` disappears from the result entirely.
    test "_sessionid stays stable across several put_event/2 calls" do
      ms = new_machine_state()
      session_id = ms.datamodel["_sessionid"]

      result =
        ms
        |> MachineState.put_event(Event.external("go"))
        |> MachineState.put_event(Event.internal("done", Cause.new({:state, idx(:a)}, 1, 1, 1)))

      assert result.datamodel["_sessionid"] == session_id
      assert result.datamodel["_event"]["name"] == "done"
    end
  end

  describe "active_leaf_states/1" do
    # sabotage: `MachineState.active_leaf_states/1` drops the `atomic?`
    # filter and returns the whole configuration unchanged -> the
    # ancestors (`a`, `b`, `p`) survive into the view, reddening this
    # assertion.
    test "returns only the atomic members of a nested compound + parallel configuration" do
      ms = %{
        new_machine_state()
        | configuration:
            MapSet.new([
              idx(:a),
              idx(:b),
              idx(:c),
              idx(:p),
              idx(:p1),
              idx(:p1a),
              idx(:p2),
              idx(:p2a)
            ])
      }

      assert MachineState.active_leaf_states(ms) ==
               MapSet.new([idx(:c), idx(:p1a), idx(:p2a)])
    end

    # sabotage: `Machine.atomic?/2` (which this view is built on) checks
    # `kind != :final` instead of `children == []` -> a `:final` reads
    # non-atomic and this assertion reddens.
    test "a :final in the configuration is in the view" do
      ms = %{new_machine_state() | configuration: MapSet.new([idx(:f)])}
      assert MachineState.active_leaf_states(ms) == MapSet.new([idx(:f)])
    end

    # sabotage: `MachineState.active_leaf_states/1` special-cases an empty
    # `configuration` by falling back to every atomic state in the whole
    # machine (a well-meaning "show something" default) instead of staying
    # empty -> this assertion reddens with the machine's other atomic
    # states (`c`, `p1a`, `p2a`, `f`).
    test "an empty configuration has an empty view" do
      ms = new_machine_state()
      assert MachineState.active_leaf_states(ms) == MapSet.new()
    end
  end

  describe "enqueue_internal/2 and dequeue_internal/1" do
    # sabotage: `MachineState.enqueue_internal/2` calls `:queue.in_r/2`
    # (pushes on the front) instead of `:queue.in/2` -> the dequeue order
    # below comes back reversed, reddening this assertion.
    test "three enqueues dequeue in FIFO order" do
      e1 = Event.external("one")
      e2 = Event.external("two")
      e3 = Event.external("three")

      ms =
        new_machine_state()
        |> MachineState.enqueue_internal(e1)
        |> MachineState.enqueue_internal(e2)
        |> MachineState.enqueue_internal(e3)

      {:ok, out1, ms} = MachineState.dequeue_internal(ms)
      {:ok, out2, ms} = MachineState.dequeue_internal(ms)
      {:ok, out3, ms} = MachineState.dequeue_internal(ms)

      assert [out1.name, out2.name, out3.name] == ["one", "two", "three"]
      assert MachineState.dequeue_internal(ms) == :empty
    end

    # sabotage: `MachineState.dequeue_internal/1` matches `{:empty, _}` as
    # `{:ok, nil, machine_state}` instead of returning `:empty` -> this
    # assertion reddens.
    test "dequeue on an empty queue is :empty" do
      assert MachineState.dequeue_internal(new_machine_state()) == :empty
    end

    # sabotage: `MachineState.enqueue_internal/2` or `dequeue_internal/1`
    # uses a plain list with `++`/`hd` in a way that loses interleaving
    # order (e.g. always appending to a captured original list) -> this
    # interleaved sequence reddens where a naive three-in-three-out test
    # would not catch it.
    test "internal_events/1 reflects order after an interleaved enqueue/dequeue sequence" do
      ms = new_machine_state()

      ms = MachineState.enqueue_internal(ms, Event.external("one"))
      ms = MachineState.enqueue_internal(ms, Event.external("two"))
      {:ok, out1, ms} = MachineState.dequeue_internal(ms)
      ms = MachineState.enqueue_internal(ms, Event.external("three"))
      {:ok, out2, ms} = MachineState.dequeue_internal(ms)
      ms = MachineState.enqueue_internal(ms, Event.external("four"))

      assert out1.name == "one"
      assert out2.name == "two"
      assert Enum.map(MachineState.internal_events(ms), & &1.name) == ["three", "four"]
    end
  end

  describe "raise_internal/4" do
    # sabotage: `MachineState.raise_internal/4` swaps the `microstep`/
    # `round` arguments in its `Cause.new/4` call -> the cause's
    # `microstep`/`round` fields land swapped (0/1 here), reddening this
    # assertion.
    test "stamps the current counters and given origin onto the queued event" do
      ms =
        new_machine_state()
        |> MachineState.begin_macrostep()
        |> MachineState.begin_microstep()

      origin = {:content, 4, {:transition, 7}}
      ms = MachineState.raise_internal(ms, "done.state.a", origin)

      assert [%Event{type: :internal, name: "done.state.a", cause: cause}] =
               MachineState.internal_events(ms)

      assert cause == Cause.new(origin, ms.macrostep, ms.microstep, ms.round)
    end
  end

  describe "begin_macrostep/1 and begin_microstep/1" do
    # sabotage: `MachineState.begin_macrostep/1` leaves `microstep`
    # unchanged instead of resetting it to `0` -> this assertion reddens.
    test "begin_macrostep/1 increments macrostep and zeroes microstep" do
      ms =
        new_machine_state()
        |> MachineState.begin_macrostep()
        |> MachineState.begin_microstep()
        |> MachineState.begin_microstep()

      assert ms.macrostep == 1
      assert ms.microstep == 2

      ms = MachineState.begin_macrostep(ms)
      assert ms.macrostep == 2
      assert ms.microstep == 0
    end

    # sabotage: `MachineState.begin_microstep/1` also increments
    # `macrostep` -> this assertion reddens.
    test "begin_microstep/1 increments microstep and leaves macrostep alone" do
      ms = new_machine_state() |> MachineState.begin_macrostep() |> MachineState.begin_microstep()

      assert ms.macrostep == 1
      assert ms.microstep == 1
    end

    # sabotage: `MachineState.begin_microstep/1` also increments `round` ->
    # this assertion reddens.
    test "begin_microstep/1 leaves round alone" do
      ms =
        new_machine_state()
        |> MachineState.begin_macrostep()
        |> MachineState.begin_round()
        |> MachineState.begin_microstep()

      assert ms.round == 1
    end

    # sabotage: `MachineState.begin_macrostep/1` drops its `round: 0`
    # reset -> this assertion reddens.
    test "begin_macrostep/1 resets a non-zero round to zero" do
      ms =
        new_machine_state()
        |> MachineState.begin_macrostep()
        |> MachineState.begin_round()
        |> MachineState.begin_round()

      assert ms.round == 2

      ms = MachineState.begin_macrostep(ms)
      assert ms.round == 0
    end
  end

  describe "begin_round/1" do
    # sabotage: `MachineState.begin_round/1` returns `machine_state`
    # unchanged -> this assertion reddens.
    test "increments round by one and leaves macrostep/microstep alone" do
      ms =
        new_machine_state()
        |> MachineState.begin_macrostep()
        |> MachineState.begin_microstep()

      ms = MachineState.begin_round(ms)
      assert ms.round == 1
      assert ms.macrostep == 1
      assert ms.microstep == 1

      ms = MachineState.begin_round(ms)
      assert ms.round == 2
      assert ms.macrostep == 1
      assert ms.microstep == 1
    end
  end
end
