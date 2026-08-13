defmodule Statifier.Evaluator.SystemVariablesTest do
  use ExUnit.Case, async: true

  alias Statifier.Compiler
  alias Statifier.Evaluator
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Event
  alias Statifier.Event.Cause
  alias Statifier.Lowering
  alias Statifier.MachineState
  alias Statifier.Parser
  alias Statifier.Validator

  @document """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="s1">
      <state id="s1"/>
      <state id="s2"/>
  </scxml>
  """

  defp compile!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, document} = Validator.validate(document, xml)
    {:ok, machine} = Compiler.compile(document)
    machine
  end

  defp machine, do: compile!(@document)

  defp compiled_expr(source) do
    {:ok, compiled} = Predicator.compile_with_spans(source)
    {:compiled, compiled, source}
  end

  describe "initial/2" do
    # sabotage: `initial/2` writes `"_ioprocessors"` as an empty map instead
    # of the SCXML event-processor entry -> the pattern match below no
    # longer matches, reddening this test.
    test "carries the three session-lifetime system variables" do
      m = machine()

      assert %{
               "_sessionid" => "sess_abc",
               "_name" => nil,
               "_ioprocessors" => %{
                 "http://www.w3.org/TR/scxml/#SCXMLEventProcessor" => %{"location" => "sess_abc"}
               }
             } = SystemVariables.initial(m, "sess_abc")
    end

    # sabotage: `initial/2` reads `machine.id` instead of `machine.name` ->
    # this assertion reddens because `<scxml>` here writes no `name`.
    test "_name is nil when <scxml> writes no name attribute" do
      m = machine()
      assert SystemVariables.initial(m, "sess_abc")["_name"] == nil
    end
  end

  describe "event/1" do
    # sabotage: `event/1` writes `"data" => event.data || %{}` instead of
    # `event.data` verbatim -> a `nil` data field becomes `%{}` here,
    # reddening the equality assertion (the map-shape check, not yet the
    # end-to-end undefined check below).
    test "maps an event with no data to a map whose \"data\" is nil" do
      result = SystemVariables.event(Event.external("go"))

      assert result == %{
               "name" => "go",
               "type" => "external",
               "sendid" => nil,
               "origin" => nil,
               "origintype" => nil,
               "invokeid" => nil,
               "data" => nil
             }
    end

    # sabotage: `event/1` writes `"data" => event.data` but the field key is
    # changed from `"data"` to `"content"` -> the map fetch below raises a
    # `KeyError`/mismatch instead of finding the payload.
    test "maps an event with data to a map carrying that data verbatim" do
      result = SystemVariables.event(Event.external("go", data: %{"x" => 1}))
      assert result["data"] == %{"x" => 1}
    end

    # sabotage: `event/1` hardcodes `"type" => "external"` regardless of
    # `event.type` -> the internal/platform cases below no longer differ
    # from the external one, reddening the equality assertions.
    test ~s(type is "external", "internal", or "platform" for the three constructors) do
      cause = Cause.new({:state, 1}, 1, 1, 1)

      assert SystemVariables.event(Event.external("go"))["type"] == "external"
      assert SystemVariables.event(Event.internal("go", cause))["type"] == "internal"

      assert SystemVariables.event(Event.platform("done.state.s1", cause))["type"] ==
               "platform"
    end
  end

  describe "absent event data evaluates as :undefined, not %{} (conf:emptyEventData)" do
    # sabotage: `event/1`'s `"data" => event.data` clause is changed to
    # `"data" => event.data || %{}` -> `Predicator.Context.new/2` no longer
    # has a `nil` to normalize, `_event.data` evaluates to `{:ok, %{}}`
    # instead of `{:ok, :undefined}`, reddening this assertion - this is
    # the bead's own `conf:emptyEventData` acceptance criterion, tested at
    # evaluation time rather than by inspecting the map.
    test "_event.data and _event.data.foo evaluate as :undefined for an event with no data" do
      ms =
        machine()
        |> MachineState.new()
        |> MachineState.put_event(Event.external("go"))

      context = Evaluator.context(ms)

      assert Evaluator.evaluate(context, compiled_expr("_event.data")) == {:ok, :undefined}
      assert Evaluator.evaluate(context, compiled_expr("_event.data.foo")) == {:ok, :undefined}
    end

    # sabotage: same clause as above; this pins the contrasting case so the
    # two cannot be confused - data: nil and data: %{} must evaluate
    # differently, and only the previous test's mutation would make them
    # collapse together.
    test "_event.data.x resolves for an event that does carry data" do
      ms =
        machine()
        |> MachineState.new()
        |> MachineState.put_event(Event.external("go", data: %{"x" => 1}))

      context = Evaluator.context(ms)
      assert Evaluator.evaluate(context, compiled_expr("_event.data.x")) == {:ok, 1}
    end
  end
end
