# Emits one test module per W3C IRP case.
#
#   mix run tools/corpus/scxml_w3/cases.exs <out_root> <in_root> <case.scxml>...
#
# in_root  - the scratch dir the manifest fetcher populated, laid out as
#            <in_root>/<conformance>/<spec>/<name>.scxml (+ the .description).
# out_root - test/scxml_tests, mirroring that as <name>_test.exs.
#
# NOTE: the module shape emitted below is still ex_statechart's. Rewriting it to
# the v2 `Statifier.Case` shape is st2-00p.7.

[out_root, in_root | inputs] = System.argv()

Enum.each(inputs, fn input ->
  rel = Path.relative_to(input, in_root)
  [conformance, spec | _rest] = Path.split(rel)
  name = Path.basename(rel, ".scxml")

  description = Path.join(in_root, Path.rootname(rel) <> ".description")
  out = Path.join([out_root, conformance, spec, name <> "_test.exs"])

  module = Module.concat(["Test.StateChart.W3", Macro.camelize(spec), Macro.camelize(name)])

  bin =
    quote do
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

  out |> Path.dirname() |> File.mkdir_p!()
  File.write!(out, bin)
end)
