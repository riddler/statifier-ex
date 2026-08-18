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
          <state id="s2" initial="s2a">
              <state id="s2a">
                  <state/>
              </state>
          </state>
          <history id="h1" type="deep">
              <transition target="s1a" type="internal"/>
          </history>
          <history id="h2">
              <transition target="s1a"/>
          </history>
          <transition target="s1a" event="e4" cond="x &gt; 2" type="internal"/>
          <transition target="s1a" event="e5"/>
      </state>
      <parallel id="p1"/>
      <final id="f1"/>
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

  describe "Machine.State carries attribute_locations" do
    # sabotage: `Statifier.Compiler.compile/1` drops
    # `attribute_locations: dstate.attribute_locations` from the general
    # state-interning walk's `%Machine.State{}` literal (around :390) ->
    # every assertion below on a non-root state reddens on `KeyError`.
    test "every written attribute on a compound state, a parallel, a final, and a history slices back to its own text" do
      machine = compile!()
      {:ok, s2_index} = Machine.index(machine, "s2")
      {:ok, p1_index} = Machine.index(machine, "p1")
      {:ok, f1_index} = Machine.index(machine, "f1")
      {:ok, h1_index} = Machine.index(machine, "h1")

      s2 = Machine.at(machine, s2_index)
      p1 = Machine.at(machine, p1_index)
      f1 = Machine.at(machine, f1_index)
      h1 = Machine.at(machine, h1_index)

      assert_attribute_location(s2.attribute_locations, :id, "s2")
      assert_attribute_location(s2.attribute_locations, :initial, "s2a")

      assert_attribute_location(p1.attribute_locations, :id, "p1")
      assert_attribute_location(f1.attribute_locations, :id, "f1")

      assert_attribute_location(h1.attribute_locations, :id, "h1")
      assert_attribute_location(h1.attribute_locations, :type, "deep")
    end

    # sabotage: `Statifier.Compiler.compile/1` drops
    # `attribute_locations: document.attribute_locations` from the root
    # `%Machine.State{}` literal (around :225) -> every assertion below
    # reddens on `KeyError`, while the non-root case above stays green
    # (it goes through the other construction site).
    test "the root state carries the <scxml> element's own spans" do
      machine = compile!()
      root = Machine.at(machine, 0)

      assert_attribute_location(root.attribute_locations, :initial, "s1")
      assert_attribute_location(root.attribute_locations, :name, "root")
      assert_attribute_location(root.attribute_locations, :datamodel, "null")
      assert_attribute_location(root.attribute_locations, :binding, "late")
      assert_attribute_location(root.attribute_locations, :version, "1.0")

      assert_attribute_location(
        root.attribute_locations,
        :xmlns,
        "http://www.w3.org/2005/07/scxml"
      )
    end

    # sabotage: same mutation as the first test above (dropping
    # `attribute_locations: dstate.attribute_locations` at :390) -> the
    # `assert Map.has_key?/2` clause on `h1` and the `[:id]` keys assertion
    # on `s1a` both redden (the carried map falls back to `%{}`).
    test "key presence survives compilation: a defaulted history type carries no :type key" do
      machine = compile!()
      {:ok, h2_index} = Machine.index(machine, "h2")
      {:ok, h1_index} = Machine.index(machine, "h1")
      {:ok, s1a_index} = Machine.index(machine, "s1a")

      h2 = Machine.at(machine, h2_index)
      h1 = Machine.at(machine, h1_index)
      s1a = Machine.at(machine, s1a_index)

      assert h2.history_type == :shallow
      refute Map.has_key?(h2.attribute_locations, :type)

      assert h1.history_type == :deep
      assert Map.has_key?(h1.attribute_locations, :type)

      assert Map.keys(s1a.attribute_locations) == [:id]
    end

    # sabotage: `Statifier.Compiler.compile/1`'s general walk hardcodes
    # `attribute_locations: Map.put(dstate.attribute_locations, :bogus, nil)`
    # instead of carrying the map as-is -> `assert bare_child.attribute_locations
    # == %{}` reddens (the empty-map case above catches dropping the carry
    # entirely, since that would also produce `%{}`; this mutation targets
    # carrying the map itself, verbatim, rather than falling back to a
    # default that happens to look the same on an empty node).
    test "a state whose element wrote no attributes at all compiles to an empty map" do
      machine = compile!()
      {:ok, s2a_index} = Machine.index(machine, "s2a")
      s2a = Machine.at(machine, s2a_index)

      [bare_child_index] = s2a.children
      bare_child = Machine.at(machine, bare_child_index)

      assert bare_child.id == nil
      assert bare_child.attribute_locations == %{}
    end
  end
end
