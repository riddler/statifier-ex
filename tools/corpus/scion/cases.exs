System.argv()
|> Enum.each(fn(input) ->

[test_dir, suite, cases, spec, name] = Path.split(input)
name = Path.basename(name, ".json")
out = Path.join([test_dir, suite, cases, spec, name <> "_test.exs"])
xml = Path.join([test_dir, suite, cases, spec, name <> ".scxml"])

spec = spec |> String.replace("-", "_")

module = Module.concat(["Test.StateChart.Scion", Macro.camelize(spec), Macro.camelize(name)])

%{"initialConfiguration" => conf,
  "events" => events} =
  input |> File.read!() |> Jason.decode!()

events = Enum.map(events, fn(%{"event" => e, "nextConfiguration" => conf}) ->
  {e, conf}
end)

bin = quote do
  defmodule unquote(module) do
    use Test.StateChart.Case

    @tag :scion
    @tag spec: unquote(Macro.underscore(spec))
    test unquote(name) do
      xml = unquote(File.read!(xml))

      test_scxml(xml, "", unquote(Macro.escape(conf)), unquote(Macro.escape(events)))
    end
  end
end
|> Macro.to_string()

File.write!(out, bin)

end)
