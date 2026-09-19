# Emits one Statifier.Case test module per W3C IRP case in the committed
# conformance corpus, in the v2 shape:
#
#   elixir tools/corpus/scxml_w3/cases.exs <out_root> <corpus_root>
#
# corpus_root - the committed conformance/ directory: corpus/w3c.json holds
#               the cases (written by `mix statifier.corpus`, ADR-0070) and
#               manifest.json names the upstream suite and its licence.
# out_root    - test/scxml_tests, one module per case as
#               <conformance>/<spec>/<name>_test.exs (SCXMLTest.<Spec>.<Name>).
#
# The corpus is the source: this reads no upstream tree, and applies no filter
# of its own. The datamodel filter, the exclusions (exclusions.exs, ADR-0004)
# and the manifest sub-documents (sub_documents.exs) are applied when the
# corpus is written, so every case in corpus/w3c.json gets a module. A corpus
# file with no cases is refused rather than emitting nothing.
#
# Each module opens with a header comment naming its corpus case and the
# upstream test it was transformed from, retaining the W3C copyright notice
# (read from the licence file) and pointing at the licence's conditions and
# disclaimer under conformance/LICENSES/. The document itself goes into the
# heredoc exactly as the corpus holds it - already transformed for the
# predicator datamodel and formatted - and `required_features` is the case's
# own field.
#
# Plain `elixir`, not `mix run`: nothing here needs the project compiled.

Code.require_file(Path.join([__DIR__, "..", "normalize.exs"]))

defmodule Cases.Emit do
  @suite "w3c"

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

  # The copyright notice the licence requires every redistribution to retain,
  # read from the committed licence file rather than restated here.
  def copyright!(corpus_root, notice) do
    path = Path.join(corpus_root, notice)

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "Copyright")) ||
      halt("#{path} carries no copyright line")
  end

  def emit_case(out_root, corpus_case, upstream, copyright) do
    %{
      "id" => id,
      "spec" => spec,
      "conformance" => conformance,
      "description" => description,
      "required_features" => features,
      "source" => formatted_xml,
      "initial_configuration" => conf,
      "steps" => steps
    } = corpus_case

    name = Path.basename(id)
    normalized_spec = Cases.Normalize.identifier(spec)
    normalized_name = Cases.Normalize.identifier(name)

    events =
      Enum.map(steps, fn %{"event" => e, "configuration" => next_conf} -> {e, next_conf} end)

    features = Enum.map_join(features, ", ", &inspect(String.to_atom(&1)))

    xml_body =
      formatted_xml
      |> String.replace("\\", "\\\\")
      |> String.replace("\#{", "\\\#{")

    module =
      Module.concat([
        "SCXMLTest",
        Macro.camelize(normalized_spec),
        Macro.camelize(normalized_name)
      ])

    source = """
    #{header(corpus_case, upstream, copyright)}
    defmodule #{inspect(module)} do
      use Statifier.Case, async: true

      @moduletag :scxml_w3
      @tag required_features: [#{features}]
      @tag conformance: #{inspect(conformance)}, spec: #{inspect(spec)}
      test #{inspect(name)} do
        xml = \"\"\"
    #{xml_body}\"\"\"

        description = #{inspect(description)}

        test_scxml(xml, description, #{inspect(conf)}, #{inspect(events)})
      end
    end
    """

    out = Path.join([out_root, conformance, normalized_spec, normalized_name <> "_test.exs"])
    out |> Path.dirname() |> File.mkdir_p!()
    File.write!(out, Code.format_string!(source) |> IO.iodata_to_binary() |> Kernel.<>("\n"))
  end

  defp header(%{"id" => id, "upstream" => case_upstream}, upstream, copyright) do
    %{"document" => document, "license" => license, "notice" => notice} = case_upstream

    [
      "Generated from conformance/corpus/#{@suite}.json, case #{id}, by " <>
        "tools/corpus/scxml_w3/cases.exs. Regenerate with `mise run corpus:emit`; " <>
        "never edit by hand.",
      "",
      "The document in this test is transformed for the predicator datamodel from " <>
        "#{document} of the #{upstream["name"]} (#{upstream["url"]}).",
      "",
      copyright,
      "",
      "Redistributed under #{license}, the W3C 3-clause BSD License; its conditions " <>
        "and disclaimer are in conformance/#{notice}."
    ]
    |> Enum.map_join("\n", &comment/1)
  end

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
copyright = Cases.Emit.copyright!(corpus_root, upstream["notice"])
Enum.each(cases, &Cases.Emit.emit_case(out_root, &1, upstream, copyright))

IO.puts("emitted #{length(cases)} W3C case(s) from #{corpus_root}/corpus/w3c.json")
