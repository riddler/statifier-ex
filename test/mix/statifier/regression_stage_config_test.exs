defmodule Mix.Statifier.RegressionStageConfigTest do
  use ExUnit.Case, async: true

  # Registering the stage wrong is itself a `.quality.exs` change the gate
  # guard would flag - but only while the guard still runs. This test makes a
  # miswired entry turn the Tests stage red as well, so the two checks cover
  # each other.
  # sabotage: change the regression entry's kind: to :writer -> red
  test ".quality.exs registers the regression ratchet as a custom stage" do
    {config, _bindings} = Code.eval_file(".quality.exs")

    assert [entry] = Enum.filter(config[:custom] || [], &(&1[:key] == :regression))

    assert %{name: "Regression ratchet", command: "mix", kind: :reader} = Map.new(entry)

    assert "test.regression" in entry[:args]
  end

  # `stages:` in a profile is an allow-list (ExQuality.Config), so the loop
  # profile keeps :regression out simply by not naming it - there is no
  # separate skip to remove. If a future edit added it back, the loop profile
  # would stop being the fast inner-loop path this test protects.
  # sabotage: add :regression to the loop profile's stages: list -> red
  test "the loop profile's stages allow-list excludes the regression ratchet" do
    {config, _bindings} = Code.eval_file(".quality.exs")

    loop_stages = get_in(config, [:profiles, :loop, :stages]) || []

    refute :regression in loop_stages
  end
end
