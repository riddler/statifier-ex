ExUnit.start()

defmodule MachineHelpers do
  defmacro test_machines(folder, file) do
    quote do
      test "conforms to SCXML test #{unquote(folder)} - #{unquote(file)}" do
        folder = unquote(folder)
        file = unquote(file)
        scxml_path = "./test/fixtures/scxml/#{folder}/#{file}.scxml"
        test_path = "./test/fixtures/scxml/#{folder}/#{file}.json"
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
    end
  end
end
