# Emits one test module per SCION case.
#
#   mix run tools/corpus/scion/cases.exs <out_root> <in_root> <case.json>...
#
# in_root  - the scratch dir holding the cloned framework's `test` tree, laid
#            out as <in_root>/<spec>/<name>.json (+ the sibling .scxml).
# out_root - test/scion_tests, mirroring that as <spec>/<name>_test.exs.
#
# NOTE: the module shape emitted below is still ex_statechart's. Rewriting it to
# the v2 `Statifier.Case` shape is st2-00p.6.

[out_root, in_root | inputs] = System.argv()

Enum.each(inputs, fn input ->
  rel = Path.relative_to(input, in_root)
  spec_dir = Path.dirname(rel)
  name = Path.basename(rel, ".json")

  xml = Path.join(in_root, Path.rootname(rel) <> ".scxml")
  out = Path.join([out_root, spec_dir, name <> "_test.exs"])

  spec = String.replace(spec_dir, "-", "_")

  module = Module.concat(["Test.StateChart.Scion", Macro.camelize(spec), Macro.camelize(name)])

  %{"initialConfiguration" => conf, "events" => events} =
    input |> File.read!() |> Jason.decode!()

  events =
    Enum.map(events, fn %{"event" => e, "nextConfiguration" => conf} ->
      {e, conf}
    end)

  bin =
    quote do
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

  out |> Path.dirname() |> File.mkdir_p!()
  File.write!(out, bin)
end)
