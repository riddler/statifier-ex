defmodule Statifier.Validator.ContextTest do
  use ExUnit.Case, async: true

  alias Statifier.Lowering
  alias Statifier.Parser
  alias Statifier.Validator.Context

  defp build!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    Context.build(document, xml)
  end

  describe "build/2 - states and ancestors" do
    # sabotage: Context.build/2 drops the `nil` guard in `put_named/2` and
    # puts every state into `states`, keyed by `state.id` (which is `nil`
    # for both) -> `context.states` ends up with a `nil => state` entry
    # instead of staying empty, and this assertion reddens
    test "two anonymous states are absent from states and ancestors" do
      xml = """
      <scxml>
          <state/>
          <state/>
      </scxml>
      """

      context = build!(xml)

      assert context.states == %{}
      assert context.ancestors == %{}
    end

    # sabotage: Context.build/2's `walk/3` passes `ancestor_ids` straight
    # through to children instead of appending `state.id` -> `context.ancestors["b"]`
    # comes back `[]` instead of `["a"]`, and the assertion below reddens
    test "a named state is keyed by its own id in both maps" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
          </state>
      </scxml>
      """

      context = build!(xml)

      assert %{"a" => %{id: "a"}, "b" => %{id: "b"}} = context.states
      assert context.ancestors["a"] == []
      assert context.ancestors["b"] == ["a"]
    end
  end

  describe "descendant?/3" do
    # sabotage: descendant?/3 swaps its `ancestor_id` and `descendant_id`
    # lookup, testing `descendant_id in ancestors[ancestor_id]` -> the
    # third assertion below (a state is not its own descendant's ancestor)
    # reddens
    test "true for a named ancestor, false otherwise" do
      xml = """
      <scxml>
          <state id="a">
              <state id="b"/>
          </state>
          <state id="c"/>
      </scxml>
      """

      context = build!(xml)

      assert Context.descendant?(context, "a", "b")
      refute Context.descendant?(context, "c", "b")
      refute Context.descendant?(context, "b", "a")
    end
  end
end
