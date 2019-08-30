defmodule HierarchyTest do
  use ExUnit.Case

  test "scxml test hier0" do
    scxml_path = "./test/fixtures/scxml/hierarchy/hier0.scxml"
    test_path = "./test/fixtures/scxml/hierarchy/hier0.json"
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

  #test "scxml test basic1" do
  #  scxml_path = "./test/fixtures/scxml/basic/basic1.scxml"
  #  test_path = "./test/fixtures/scxml/basic/basic1.json"
  #  {:ok, test_contents} = File.read Path.expand test_path
  #  {:ok, test_config} = Poison.decode test_contents

  #  machine = Exstate.machine_from_file(scxml_path)
  #  configuration_literal = machine
  #    |> Exstate.Machine.configuration_literal

  #  assert configuration_literal == test_config["initialConfiguration"]

  #  Enum.each(test_config["events"], fn test_case ->
  #    machine = machine |> Exstate.Machine.send(test_case["event"]["name"])
  #    assert (machine |> Exstate.Machine.configuration_literal) == test_case["nextConfiguration"]
  #  end)
  #end
end
