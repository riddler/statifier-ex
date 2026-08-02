System.argv()
|> Enum.each(fn(input) ->

[test_dir, scxml, cases, conformance, spec, name] = Path.split(input)
name = Path.basename(name, ".scxml")
out = Path.join([test_dir, scxml, cases, conformance, spec, name <> "_test.exs"])
description = Path.join([test_dir, scxml, cases, conformance, spec, name <> ".description"])

module = Module.concat(["Test.StateChart.W3", Macro.camelize(spec), Macro.camelize(name)])

bin = quote do
  defmodule unquote(module) do
    use Test.StateChart.Case

    @tag :scxml_w3
    @tag conformance: unquote(conformance), spec: unquote(spec)
    test unquote(name) do
      xml = unquote(File.read!(input))

      description = unquote(File.read!(description))

      test_scxml(xml, description, ["pass"], [])
    end
  end
end
|> Macro.to_string()

File.write!(out, bin)

end)
