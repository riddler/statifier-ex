# Emits one Statifier.Case test module per SCION case, in the v2 shape:
#
#   mix run tools/corpus/scion/cases.exs <out_root> <in_root> <case.json>...
#
# in_root  - the scratch dir holding the cloned framework's `test` tree, laid
#            out as <in_root>/<spec>/<name>.json (+ the sibling .scxml).
# out_root - test/scion_tests, mirroring that as <spec>/<name>_test.exs,
#            one module per file (SCIONTest.<Spec>.<Name>Test).
#
# required_features tags come from Statifier.FeatureDetector, loaded directly
# since `mix run` defaults to MIX_ENV=dev and test/support is not compiled in.
#
# exclusions.exs: cases with no predicator equivalent, or that duplicate the
# separately-generated W3C corpus (ADR-0004), skipped with the reason recorded
# there. Keyed on the raw (pre-normalization) spec_dir, or "spec_dir/name" for
# a single-case exclusion.

Code.require_file(Path.join([__DIR__, "..", "..", "..", "test/support/feature_detector.ex"]))
Code.require_file(Path.join([__DIR__, "..", "normalize.exs"]))

defmodule Cases.Emit do
  def emit_case(out_root, in_root, input) do
    rel = Path.relative_to(input, in_root)
    spec_dir = Path.dirname(rel)
    name = Path.basename(rel, ".json")

    normalized_spec = Cases.Normalize.identifier(spec_dir)
    normalized_name = Cases.Normalize.identifier(name)

    xml_path = Path.join(in_root, Path.rootname(rel) <> ".scxml")
    xml = File.read!(xml_path)

    %{"initialConfiguration" => conf, "events" => events} =
      input |> File.read!() |> Jason.decode!()

    events =
      Enum.map(events, fn %{"event" => e, "nextConfiguration" => next_conf} ->
        {e, next_conf}
      end)

    features =
      xml
      |> Statifier.FeatureDetector.detect_features()
      |> Enum.sort()
      |> Enum.map_join(", ", &inspect/1)

    xml_body =
      xml
      |> String.replace("\\", "\\\\")
      |> String.replace("\#{", "\\\#{")
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    module =
      Module.concat([
        "SCIONTest",
        Macro.camelize(normalized_spec),
        Macro.camelize(normalized_name) <> "Test"
      ])

    source = """
    defmodule #{inspect(module)} do
      use Statifier.Case, async: true

      @moduletag :scion
      @tag required_features: [#{features}]
      @tag spec: #{inspect(spec_dir)}
      test #{inspect(name)} do
        xml = \"\"\"
    #{xml_body}\"\"\"

        test_scxml(xml, "", #{inspect(conf)}, #{inspect(events)})
      end
    end
    """

    out = Path.join([out_root, normalized_spec, normalized_name <> "_test.exs"])
    out |> Path.dirname() |> File.mkdir_p!()
    File.write!(out, Code.format_string!(source) |> IO.iodata_to_binary() |> Kernel.<>("\n"))
  end
end

exclusions_path = Path.join(__DIR__, "exclusions.exs")
{exclusions, _bindings} = Code.eval_file(exclusions_path)

[out_root, in_root | inputs] = System.argv()

{matched, emitted, excluded} =
  Enum.reduce(inputs, {MapSet.new(), 0, 0}, fn input, {matched, emitted, excluded} ->
    rel = Path.relative_to(input, in_root)
    spec_dir = Path.dirname(rel)
    name = Path.basename(rel, ".json")

    cond do
      Map.has_key?(exclusions, spec_dir) ->
        {MapSet.put(matched, spec_dir), emitted, excluded + 1}

      Map.has_key?(exclusions, "#{spec_dir}/#{name}") ->
        {MapSet.put(matched, "#{spec_dir}/#{name}"), emitted, excluded + 1}

      true ->
        Cases.Emit.emit_case(out_root, in_root, input)
        {matched, emitted + 1, excluded}
    end
  end)

stale = Map.keys(exclusions) -- MapSet.to_list(matched)

if stale != [] do
  IO.puts(
    :stderr,
    "stale scion exclusions.exs entries (matched nothing): #{Enum.join(stale, ", ")}"
  )

  System.halt(1)
end

IO.puts("emitted #{emitted} SCION case(s), excluded #{excluded}")
