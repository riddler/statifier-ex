defmodule Statifier.Compiler.LocationTest do
  use ExUnit.Case, async: true

  alias Statifier.{Compiler, Lowering, Machine, Parser, Validator}
  alias Statifier.Parser.Location

  # In the style of `test/statifier/lowering/location_test.exs:17-42`, itself
  # in the style of `test/statifier/parser/location_accuracy_test.exs:13-37`:
  # the Machine-layer member of the location-accuracy family, one layer below
  # the Document sweep. Every tokenized field is written with a value equal
  # to its own rendered form so plain slice-equality holds without reversing
  # any tokenization.
  @source """
  <scxml initial="s1" name="root" datamodel="null" binding="late" version="1.0" xmlns="http://www.w3.org/2005/07/scxml">
      <state id="s1">
          <initial>
              <transition target="s1a" type="internal"/>
          </initial>
          <state id="s1a"/>
          <history id="h1" type="deep">
              <transition target="s1a" type="internal"/>
          </history>
          <transition target="s1a" event="e4" cond="x &gt; 2" type="internal"/>
          <transition target="s1a" event="e5"/>
      </state>
  </scxml>
  """

  defp compile! do
    {:ok, root} = Parser.parse(@source)
    {:ok, document} = Lowering.lower(root, @source)
    {:ok, document, _warnings} = Validator.validate(document, @source)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  # An `attribute_locations` entry on a *compiled* node slices back to
  # exactly the text the author wrote inside the quotes - the Document
  # layer's own property (test/statifier/lowering/location_test.exs:59-65),
  # re-asserted one layer down to prove compilation carried the map rather
  # than rebuilding or dropping it.
  defp assert_attribute_location(attribute_locations, key, expected) do
    location = Map.fetch!(attribute_locations, key)
    assert Location.slice(location, @source) == expected
  end

  describe "Machine.Transition carries attribute_locations" do
    # sabotage: `Statifier.Compiler.build_transition/3` drops
    # `attribute_locations: transition.attribute_locations` from the
    # `%Machine.Transition{}` struct literal -> every assertion below
    # reddens on `KeyError` (the field falls back to the struct default
    # `%{}`, and `Map.fetch!/2` raises on the missing keys).
    test "every attribute of a fully-written transition slices back to its own text" do
      machine = compile!()
      {:ok, s1_index} = Machine.index(machine, "s1")

      plain_t_index = Machine.at(machine, s1_index).transitions |> Enum.min()
      transition = Machine.transition(machine, plain_t_index)

      assert_attribute_location(transition.attribute_locations, :target, "s1a")
      assert_attribute_location(transition.attribute_locations, :event, "e4")
      assert_attribute_location(transition.attribute_locations, :cond, "x &gt; 2")
      assert_attribute_location(transition.attribute_locations, :type, "internal")
    end

    # sabotage: same mutation as above, applied to the two other transition
    # roles `build_transition/3` also builds -> both assertions redden.
    test "an <initial> element's transition and a history's default transition each carry their own map" do
      machine = compile!()
      {:ok, s1_index} = Machine.index(machine, "s1")
      {:ok, h1_index} = Machine.index(machine, "h1")

      s1 = Machine.at(machine, s1_index)
      h1 = Machine.at(machine, h1_index)

      initial_transition = Machine.transition(machine, s1.initial_transition)
      history_transition = Machine.transition(machine, h1.history_default)

      assert_attribute_location(initial_transition.attribute_locations, :target, "s1a")
      assert_attribute_location(initial_transition.attribute_locations, :type, "internal")

      assert_attribute_location(history_transition.attribute_locations, :target, "s1a")
      assert_attribute_location(history_transition.attribute_locations, :type, "internal")
    end

    # sabotage: same mutation as the first test above (dropping
    # `attribute_locations: transition.attribute_locations` from
    # `build_transition/3`) -> the `assert Map.has_key?/2` clause on the
    # typed transition reddens (the carried map falls back to `%{}`).
    test "key presence survives compilation: no type written means no :type key" do
      machine = compile!()
      {:ok, s1_index} = Machine.index(machine, "s1")

      untyped_t_index = Machine.at(machine, s1_index).transitions |> Enum.max()
      untyped_transition = Machine.transition(machine, untyped_t_index)

      assert untyped_transition.type == :external
      refute Map.has_key?(untyped_transition.attribute_locations, :type)

      typed_t_index = Machine.at(machine, s1_index).transitions |> Enum.min()
      typed_transition = Machine.transition(machine, typed_t_index)

      assert typed_transition.type == :internal
      assert Map.has_key?(typed_transition.attribute_locations, :type)
    end

    # sabotage: `Statifier.Compiler.build_transition/3`'s
    # `cond_location: cond_location(transition)` is hardcoded to
    # `cond_location: nil` -> the first assertion (non-nil where cond was
    # written) reddens.
    test "cond_location is unchanged and still non-nil exactly when cond is written" do
      machine = compile!()
      {:ok, s1_index} = Machine.index(machine, "s1")

      with_cond_t_index = Machine.at(machine, s1_index).transitions |> Enum.min()
      without_cond_t_index = Machine.at(machine, s1_index).transitions |> Enum.max()

      with_cond = Machine.transition(machine, with_cond_t_index)
      without_cond = Machine.transition(machine, without_cond_t_index)

      refute with_cond.cond_location == nil
      assert without_cond.cond_location == nil
    end
  end
end
