defmodule Statifier.Invoke.TypesTest do
  use ExUnit.Case, async: true

  alias Statifier.Invoke.Types
  alias Statifier.Send.Target

  describe "new/1" do
    # sabotage: `new/1`'s `Keyword.get(opts, :types, MapSet.new())` is
    # changed to always ignore `opts` and use `MapSet.new()` -> a `MapSet`
    # passed as `:types` would be dropped, and this equality assertion
    # reddens
    test "builds from a MapSet" do
      assert Types.new(types: MapSet.new(["a", "b"])) == %Types{types: MapSet.new(["a", "b"])}
    end

    # sabotage: same mutation as above - `new/1` ignores `opts` -> a list
    # passed as `:types` would be dropped, and this equality assertion
    # reddens. This fixture also proves `new/1` accepts any `Enum`, not only
    # a `MapSet`.
    test "builds from a list" do
      assert Types.new(types: ["a", "b"]) == %Types{types: MapSet.new(["a", "b"])}
    end

    # sabotage: n/a - this only pins the default value, which the two
    # positive fixtures above already exercise the non-default path for.
    test "defaults to an empty set" do
      assert Types.new() == %Types{types: MapSet.new()}
    end
  end

  describe "registered?/2 with a nil snapshot" do
    # sabotage: `registered?(nil, type)`'s clause is deleted, falling
    # through to the struct clause -> a `nil` snapshot would raise
    # `FunctionClauseError` instead of answering, reddening every case
    # below
    test "answers exactly what Target.supported_invoke_type?/1 answers today" do
      for type <- [nil, "scxml", Target.scxml_invoke_type()] do
        assert Types.registered?(nil, type) == Target.supported_invoke_type?(type)
        assert Types.registered?(nil, type)
      end

      refute Types.registered?(nil, "http://www.w3.org/TR/scxml/#SCXMLEventProcessor")
      refute Types.registered?(nil, "http://example.com/BasicHTTPEventProcessor")
    end
  end

  describe "registered?/2 with a declared set" do
    # sabotage: `registered?/2`'s struct clause drops the
    # `MapSet.member?(types, type)` disjunct, leaving only
    # `Target.supported_invoke_type?(type)` -> a declared type would no
    # longer be recognized, and this assertion reddens
    test "a declared set adds to the built-ins rather than replacing them" do
      types = Types.new(types: ["myapp:authorize"])

      assert Types.registered?(types, "myapp:authorize")
      # built-ins still answer true - declaring does not replace them
      assert Types.registered?(types, nil)
      assert Types.registered?(types, "scxml")
      assert Types.registered?(types, Target.scxml_invoke_type())
      # an undeclared, non-built-in type is still unregistered
      refute Types.registered?(types, "myapp:unknown")
    end
  end
end
