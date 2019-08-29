
defmodule ExstateTest do
  use ExUnit.Case
  doctest Exstate

  test "parses scxml test" do
    scxml_path = "./test/fixtures/scxml/basic/basic0.scxml"
    test_path = "./test/fixtures/scxml/basic/basic0.json"
    machine = Exstate.parse_scxml scxml_path
    {:ok, test_contents} = File.read Path.expand test_path
    {:ok, test_config} = Poison.decode test_contents

    [ expected_initial_state | _tail ] = test_config["initialConfiguration"]

    assert machine.initial_state() == expected_initial_state
  end
end
