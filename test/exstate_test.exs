
defmodule ExstateTest do
  use ExUnit.Case
  doctest Exstate

  test "parses scxml test" do
    path = "../scxml-test-framework/test/basic/basic0.scxml"
    machine = Exstate.parse_scxml path
    assert machine.initial_state() == "a"
  end
end
