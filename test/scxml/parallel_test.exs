defmodule ParallelTest do
  use ExUnit.Case
  import MachineHelpers

  test_machines "parallel", "test0"
  test_machines "parallel", "test1"
end
