defmodule Statifier.MachineStateTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Event
  alias Statifier.Event.Cause
  alias Statifier.Lowering
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Validator

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
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
    test "counters start at zero" do
      ms = new_machine_state()
      assert ms.macrostep == 0
      assert ms.microstep == 0
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

    # sabotage: `MachineState.new/2`'s `Map.merge/2` call has its arguments
    # swapped (`SystemVariables.initial/2` over `author_datamodel` becomes
    # `author_datamodel` over `SystemVariables.initial/2`) -> the seeded
    # system variables no longer land in `datamodel`, reddening this
    # assertion.
    test "datamodel defaults to exactly the four seeded system variables and no author data" do
      ms = new_machine_state()

      assert %{
               "_sessionid" => session_id,
               "_name" => nil,
               "_event" => nil,
               "_ioprocessors" => %{
                 "http://www.w3.org/TR/scxml/#SCXMLEventProcessor" => %{"location" => session_id}
               }
             } = ms.datamodel

      assert is_binary(session_id)
      assert map_size(ms.datamodel) == 4
    end

    # sabotage: `SystemVariables.initial/2` drops its `"_event" => nil` entry
    # -> `_event` is absent rather than present-and-nil, so `Map.has_key?/2`
    # reddens. The pair matters: an absent key and a key bound to `nil` are
    # the same to `ms.datamodel["_event"]` and different to every evaluation
    # built on top of it, which is what the evaluator test below covers.
    test "_event is seeded as a present key bound to nil, not left absent" do
      ms = new_machine_state()

      assert Map.has_key?(ms.datamodel, "_event")
      assert ms.datamodel["_event"] == nil
    end

    # sabotage: `MachineState.new/2` hardcodes `trace: false` and ignores
    # the `:trace` option -> this assertion reddens.
    test "trace defaults to false, and the :trace option is honored" do
      assert new_machine_state().trace == false
      assert new_machine_state(trace: true).trace == true
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

    # sabotage: `MachineState.new/2`'s `Keyword.get_lazy(opts, :session_id,
    # ...)` is changed to `Keyword.get(opts, :session_id, "ignored")` ->
    # the caller-supplied `:session_id` value is dropped in favor of the
    # generated default, reddening the equality assertion.
    test "a supplied :session_id option wins over the generated default" do
      ms = new_machine_state(session_id: "sess_fixed")
      assert ms.datamodel["_sessionid"] == "sess_fixed"

      assert ms.datamodel["_ioprocessors"]["http://www.w3.org/TR/scxml/#SCXMLEventProcessor"][
               "location"
             ] == "sess_fixed"
    end

    # sabotage: `MachineState.new/2`'s generated `:session_id` default is
    # changed from `UXID.generate!(prefix: "sess")` to
    # `UXID.generate!(prefix: "usr")` -> the prefix assertion reddens.
    test "the generated default :session_id carries the sess_ prefix (ADR-0008)" do
      ms = new_machine_state()
      assert String.starts_with?(ms.datamodel["_sessionid"], "sess_")
    end

    # sabotage: `SystemVariables.initial/2` reads `machine.id` instead of
    # `machine.name` -> `_name` no longer reflects the `<scxml name>`
    # attribute, reddening this assertion.
    test "_name is the <scxml name> attribute" do
      {:ok, root} =
        Parser.parse("""
        <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" name="my-machine" initial="a">
            <state id="a"/>
        </scxml>
        """)

      {:ok, document} = Lowering.lower(root)
      {:ok, document} = Validator.validate(document, "")
      {:ok, named_machine} = Compiler.compile(document)

      ms = MachineState.new(named_machine)
      assert ms.datamodel["_name"] == "my-machine"
    end
  end

  describe "put_event/2" do
    # sabotage: `put_event/2`'s `Map.put/3` is changed to write under the
    # key `"event"` instead of `"_event"` -> the lookup below finds
    # nothing, reddening the pattern match.
    test "writes datamodel[\"_event\"] to the event's system-variable shape" do
      ms = new_machine_state()
      event = Event.external("go", data: %{"x" => 1})

      result = MachineState.put_event(ms, event)

      assert %{
               "name" => "go",
               "type" => "external",
               "sendid" => nil,
               "origin" => nil,
               "origintype" => nil,
               "invokeid" => nil,
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
        |> MachineState.put_event(Event.internal("done", Cause.new({:state, idx(:a)}, 1, 1)))

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
    # sabotage: `MachineState.raise_internal/4` builds the `Cause` with
    # `Cause.new(origin, 0, 0)` instead of the machine_state's actual
    # counters -> this assertion reddens.
    test "stamps the current counters and given origin onto the queued event" do
      ms =
        new_machine_state()
        |> MachineState.begin_macrostep()
        |> MachineState.begin_microstep()

      origin = {:content, 4, {:transition, 7}}
      ms = MachineState.raise_internal(ms, "done.state.a", origin)

      assert [%Event{type: :internal, name: "done.state.a", cause: cause}] =
               MachineState.internal_events(ms)

      assert cause == Cause.new(origin, ms.macrostep, ms.microstep)
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
  end
end
