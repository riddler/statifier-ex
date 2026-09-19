defmodule Statifier.Send.TypesTest do
  use ExUnit.Case, async: true

  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Send.{Target, Types}

  defmodule EntryProcessor do
    @moduledoc false

    @spec ioprocessors_entry(type :: String.t()) :: term()
    def ioprocessors_entry("myapp:sink"), do: %{"location" => "myapp:sink/joined_records"}
    def ioprocessors_entry("myapp:atom"), do: %{"nested" => %{location: "x"}}
    def ioprocessors_entry("myapp:list"), do: ["location"]
  end

  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  describe "from_send_types/1" do
    # sabotage: `from_send_types/1`'s non-empty clause builds its set from
    # `Map.values/1` instead of `Map.keys/1` -> the set holds the module
    # atom rather than the type string, and this equality assertion
    # reddens. Confirmed red and reverted.
    test "derives the registered set from the map's own keys" do
      assert %Types{types: types} =
               Types.from_send_types(%{"myapp:sink" => SinkProcessor, "myapp:execution" => Exec})

      assert types == MapSet.new(["myapp:sink", "myapp:execution"])
    end

    # sabotage: `entry!/2` always returns `%{}` (the callback is never
    # called) -> the sink's entry reads `%{}`, and this equality reddens.
    # Confirmed red and reverted.
    test "reads each type's _ioprocessors entry from its processor" do
      assert %Types{entries: entries} =
               Types.from_send_types(%{"myapp:sink" => EntryProcessor, "myapp:execution" => Exec})

      assert entries == %{
               "myapp:sink" => %{"location" => "myapp:sink/joined_records"},
               "myapp:execution" => %{}
             }
    end

    # sabotage: `entry!/2`'s `unless` check is deleted -> an atom-keyed map
    # is accepted, nothing raises, and `assert_raise` reddens. Confirmed red
    # and reverted.
    test "refuses an entry that is not a string-keyed map" do
      assert_raise ArgumentError, ~r/must return a map string-keyed at every level/, fn ->
        Types.from_send_types(%{"myapp:atom" => EntryProcessor})
      end

      assert_raise ArgumentError, ~r/must return a map string-keyed at every level/, fn ->
        Types.from_send_types(%{"myapp:list" => EntryProcessor})
      end
    end

    # sabotage: `from_send_types/1`'s empty-map clause is deleted, so an
    # empty map falls through to the non-empty clause -> it returns
    # `%Types{types: MapSet.new()}` instead of `nil`, and this assertion
    # reddens. Confirmed red and reverted.
    test "an empty map is no declaration: nil" do
      assert Types.from_send_types(%{}) == nil
    end
  end

  describe "classify/2" do
    # sabotage: `classify/2`'s first `cond` clause
    # (`Target.supported_type?(type) -> :built_in`) is deleted -> every
    # built-in spelling falls through to `:unsupported` with a nil set, and
    # the built-in assertions below redden. Confirmed red and reverted.
    test "with no declaration: the built-in set is built_in, everything else unsupported" do
      for type <- [nil, "scxml", SystemVariables.scxml_event_processor()] do
        assert Target.supported_type?(type)
        assert Types.classify(nil, type) == :built_in
      end

      assert Types.classify(nil, "myapp:sink") == :unsupported
      assert Types.classify(nil, "http://example.com/BasicHTTPEventProcessor") == :unsupported
    end

    # sabotage: `declared?/2`'s struct clause is changed to always return
    # `false` -> a declared type classifies as `:unsupported`, and the first
    # assertion reddens. Confirmed red and reverted.
    test "a declared type is registered; a built-in stays built_in; others stay unsupported" do
      types = Types.from_send_types(%{"myapp:sink" => SinkProcessor})

      assert Types.classify(types, "myapp:sink") == :registered
      assert Types.classify(types, "scxml") == :built_in
      assert Types.classify(types, nil) == :built_in
      assert Types.classify(types, "myapp:other") == :unsupported
    end

    # sabotage: `classify/2`'s first two `cond` clauses are swapped (declared
    # membership checked before built-in membership) -> a set that names
    # `"scxml"` classifies it as `:registered`, redirecting a built-in send,
    # and this assertion reddens. Confirmed red and reverted.
    test "a built-in spelling in the set still classifies as built_in" do
      types = %Types{types: MapSet.new(["scxml"])}

      assert Types.classify(types, "scxml") == :built_in
    end

    # sabotage: `declared?/2`'s `is_binary(type) and` guard is dropped -> this
    # set's atom member matches the atom type (as a `typeexpr` could
    # resolve to), and this `:unsupported` assertion reddens. Confirmed red
    # and reverted.
    test "a non-string resolved type is never registered" do
      types = %Types{types: MapSet.new([:sink])}

      assert Types.classify(types, :sink) == :unsupported
    end
  end

  describe "unsupported_sends/2 (the pre-start check)" do
    @chart """
    <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <datamodel>
            <data id="typ" expr="'myapp:dynamic'"/>
        </datamodel>
        <state id="a">
            <onentry>
                <send event="impression.joined" type="myapp:sink" target="joined_records"/>
                <send event="click.recorded" type="myapp:execution" target="click_attribution"/>
                <send event="e"/>
                <send event="e" type="scxml"/>
                <send event="e" typeexpr="typ"/>
            </onentry>
            <transition event="go" target="b">
                <if cond="true">
                    <send event="late" type="myapp:ledger" target="ledger" delay="1s"/>
                </if>
            </transition>
        </state>
        <state id="b"/>
    </scxml>
    """

    # sabotage: `unsupported_sends/2`'s comprehension filter is changed to
    # `classify(types, type) != :built_in` -> a registered type is reported
    # too, and the list equality below reddens (it gains `"myapp:sink"`).
    # Confirmed red and reverted.
    test "lists every literal-type <send> outside the set, with its location, nested ones included" do
      machine = compile!(@chart)
      types = Types.from_send_types(%{"myapp:sink" => SinkProcessor})

      found = Types.unsupported_sends(machine, types)

      assert Enum.map(found, & &1.type) == ["myapp:execution", "myapp:ledger"]

      [execution, ledger] = found
      assert execution.location.start_line == 8
      assert ledger.location.start_line == 15
    end

    # sabotage: the comprehension's generator pattern is loosened from
    # `%Content.Send{type: {:static, type}}` to `%Content.Send{type: type}`
    # -> the `typeexpr` send's compiled expression (and every static
    # tuple) is classified as `:unsupported` and reported, and this list
    # equality reddens. Confirmed red and reverted.
    test "ignores a typeexpr and the built-in spellings; with no declaration every host type is listed" do
      machine = compile!(@chart)

      assert machine |> Types.unsupported_sends(nil) |> Enum.map(& &1.type) ==
               ["myapp:sink", "myapp:execution", "myapp:ledger"]
    end

    # sabotage: `unsupported_sends/2`'s comprehension filter
    # `classify(types, type) == :unsupported` is dropped -> every
    # literal-type send is listed, and the `== []` assertion reddens.
    # Confirmed red and reverted.
    test "a chart whose every literal type is registered or built-in lists nothing" do
      machine = compile!(@chart)

      types =
        Types.from_send_types(%{
          "myapp:sink" => SinkProcessor,
          "myapp:execution" => SinkProcessor,
          "myapp:ledger" => SinkProcessor
        })

      assert Types.unsupported_sends(machine, types) == []
    end

    # sabotage: n/a - a placement claim, not behaviour: it pins that the
    # pre-start check is not a `Statifier.Validator` function (ADR-0069
    # decision 3 places it outside), and no mutation of `lib/` short of
    # moving the function could redden it.
    test "the pre-start check lives outside Statifier.Validator" do
      refute function_exported?(Statifier.Validator, :unsupported_sends, 2)
      assert function_exported?(Types, :unsupported_sends, 2)
    end
  end
end
