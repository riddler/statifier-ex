defmodule Mix.Statifier.GateGuardConfigTest do
  use ExUnit.Case, async: true

  # Removing the registration is itself a `.quality.exs` change the guard would
  # flag - but only while the guard still runs. This test makes the removal turn
  # the Tests stage red as well, so the two checks cover each other.
  # sabotage: delete the gate_guard entry from .quality.exs's custom: block -> red
  test ".quality.exs still registers the gate guard as a custom stage" do
    {config, _bindings} = Code.eval_file(".quality.exs")

    assert [entry] = Enum.filter(config[:custom] || [], &(&1[:key] == :gate_guard))

    assert %{name: "Gate guard", command: "mix", kind: :reader, skip_exit_code: 2} =
             Map.new(entry)

    assert "gate.check" in entry[:args]
  end
end
