# Emits one Statifier.Case test module per SCION case in the committed
# conformance corpus, in the v2 shape:
#
#   elixir tools/corpus/scion/cases.exs <out_root> <corpus_root>
#
# corpus_root - the committed conformance/ directory: corpus/scion.json holds
#               the cases (written by `mix statifier.corpus`, ADR-0070) and
#               manifest.json names the upstream suite and its licence.
# out_root    - test/scion_tests, one module per case as
#               <spec>/<name>_test.exs (SCIONTest.<Spec>.<Name>Test).
#
# The corpus is the source: this reads no upstream tree, and applies no filter
# of its own. The exclusions (exclusions.exs, ADR-0004) are applied when the
# corpus is written, so every case in corpus/scion.json gets a module. A
# corpus file with no cases is refused rather than emitting nothing.
#
# Each module opens with a header comment naming its corpus case, the upstream
# document it runs, and the licence notice under conformance/LICENSES/; a case
# whose `upstream.modified` says the fetch changed its document carries that
# notice too. The document itself goes into the heredoc exactly as the corpus
# holds it (with the upstream's own licence comment, where it has one), and
# `required_features` is the case's own field.
#
# Plain `elixir`, not `mix run`: nothing here needs the project compiled.

Code.require_file(Path.join([__DIR__, "..", "normalize.exs"]))

defmodule Cases.Emit do
  @suite "scion"

  def read!(corpus_root) do
    path = Path.join([corpus_root, "corpus", @suite <> ".json"])

    cases =
      case path |> File.read!() |> JSON.decode!() do
        %{"suite" => @suite, "cases" => [_first | _rest] = cases} -> cases
        %{"suite" => @suite, "cases" => []} -> halt("#{path} has no cases; refusing to emit none")
        _other -> halt("#{path} is not a #{@suite} corpus file")
      end

    upstream =
      Path.join(corpus_root, "manifest.json")
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("upstreams")
      |> Enum.find(&(&1["suite"] == @suite)) ||
        halt("#{corpus_root}/manifest.json names no #{@suite} upstream")

    {cases, upstream}
  end

  def emit_case(out_root, corpus_case, upstream) do
    %{
      "id" => id,
      "spec" => spec_dir,
      "required_features" => features,
      "source" => xml,
      "initial_configuration" => conf,
      "steps" => steps
    } = corpus_case

    name = Path.basename(id)
    normalized_spec = Cases.Normalize.identifier(spec_dir)
    normalized_name = Cases.Normalize.identifier(name)

    events =
      Enum.map(steps, fn %{"event" => e, "configuration" => next_conf} -> {e, next_conf} end)

    features = Enum.map_join(features, ", ", &inspect(String.to_atom(&1)))

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
    #{header(corpus_case, upstream)}
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

  defp header(%{"id" => id, "upstream" => case_upstream}, upstream) do
    %{"document" => document, "license" => license, "notice" => notice} = case_upstream

    lines =
      [
        "Generated from conformance/corpus/#{@suite}.json, case #{id}, by " <>
          "tools/corpus/scion/cases.exs. Regenerate with `mise run corpus:emit`; " <>
          "never edit by hand.",
        "",
        "The document in this test is #{document} from the #{upstream["name"]} " <>
          "(#{upstream["url"]}), licensed under #{license}; the licence text is " <>
          "conformance/#{notice}."
      ] ++ modified(case_upstream)

    Enum.map_join(lines, "\n", &comment/1)
  end

  defp modified(%{"modified" => notice}), do: ["", notice]
  defp modified(_upstream), do: []

  # One paragraph as `#` comment lines wrapped at 78 columns; "" is a bare `#`.
  defp comment(""), do: "#"

  defp comment(paragraph) do
    paragraph
    |> String.split(" ")
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [line | rest] when byte_size(line) + 1 + byte_size(word) <= 76 ->
        [line <> " " <> word | rest]

      word, lines ->
        [word | lines]
    end)
    |> Enum.reverse()
    |> Enum.map_join("\n", &("# " <> &1))
  end

  defp halt(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end
end

[out_root, corpus_root] = System.argv()

{cases, upstream} = Cases.Emit.read!(corpus_root)
Enum.each(cases, &Cases.Emit.emit_case(out_root, &1, upstream))

IO.puts("emitted #{length(cases)} SCION case(s) from #{corpus_root}/corpus/scion.json")
