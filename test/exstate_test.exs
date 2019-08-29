defmodule ExstateTest do
  use ExUnit.Case
  doctest Exstate

  test "scxml test basic0" do
    scxml_path = "./test/fixtures/scxml/basic/basic0.scxml"
    test_path = "./test/fixtures/scxml/basic/basic0.json"
    machine = Exstate.parse_scxml scxml_path
    {:ok, test_contents} = File.read Path.expand test_path
    {:ok, test_config} = Poison.decode test_contents

    [ expected_initial_state | _tail ] = test_config["initialConfiguration"]

    assert machine.initial == expected_initial_state
  end

  test "scxml test basic1" do
    scxml_path = "./test/fixtures/scxml/basic/basic1.scxml"
    test_path = "./test/fixtures/scxml/basic/basic1.json"
    machine = Exstate.parse_scxml scxml_path
    {:ok, test_contents} = File.read Path.expand test_path
    {:ok, test_config} = Poison.decode test_contents

    [ expected_initial_state | _tail ] = test_config["initialConfiguration"]

    assert machine.initial == expected_initial_state
  end
end
