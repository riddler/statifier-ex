defmodule ExstateTest do
  use ExUnit.Case
  doctest Exstate

  test "scxml test basic0" do
    scxml_path = "./test/fixtures/scxml/basic/basic0.scxml"
    test_path = "./test/fixtures/scxml/basic/basic0.json"
    {:ok, test_contents} = File.read Path.expand test_path
    {:ok, test_config} = Poison.decode test_contents

    configuration_literal = Exstate.machine_from_file(scxml_path)
      |> Exstate.Machine.configuration_literal
    assert configuration_literal == test_config["initialConfiguration"]
  end

  test "scxml test basic1" do
    scxml_path = "./test/fixtures/scxml/basic/basic1.scxml"
    test_path = "./test/fixtures/scxml/basic/basic1.json"
    {:ok, test_contents} = File.read Path.expand test_path
    {:ok, test_config} = Poison.decode test_contents

    machine = Exstate.machine_from_file(scxml_path)
    configuration_literal = machine
      |> Exstate.Machine.configuration_literal

    assert configuration_literal == test_config["initialConfiguration"]

    Enum.each(test_config["events"], fn test_case ->
      machine = machine |> Exstate.Machine.send(test_case["event"]["name"])
      assert (machine |> Exstate.Machine.configuration_literal) == test_case["nextConfiguration"]
    end)
  end

  #test "scxml test basic2" do
  #  scxml_path = "./test/fixtures/scxml/basic/basic2.scxml"
  #  test_path = "./test/fixtures/scxml/basic/basic2.json"
  #  machine = Exstate.parse_file scxml_path
  #  {:ok, test_contents} = File.read Path.expand test_path
  #  {:ok, test_config} = Poison.decode test_contents

  #  [ expected_initial_state | _tail ] = test_config["initialConfiguration"]

  #  assert machine.initial == expected_initial_state

  #  guide = Exstate.Guide.new(machine)
  #          |> Exstate.Guide.on_transition!(fn (state) -> IO.inspect(state) end)

  #  Enum.each(test_config["events"], fn test_case ->
  #    guide = guide |> Exstate.Guide.send(test_case["event"]["name"])
  #    [ expected_next_state | _tail ] = test_case["nextConfiguration"]
  #    assert guide.journey.current_state.id == expected_next_state
  #  end)
  #end
end
