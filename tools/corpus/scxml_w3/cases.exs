# Emits one Statifier.Case test module per W3C IRP case, in the v2 shape:
#
#   elixir tools/corpus/scxml_w3/cases.exs <out_root> <in_root> <case.scxml>...
#
# Plain `elixir`, not `mix run`: this script needs xmerl, which Mix prunes
# from the code path (see manifest.exs).
#
# in_root  - the scratch dir corpus:transform populated, laid out as
#            <in_root>/<conformance>/<spec>/<name>.{scxml,description}.
# out_root - test/scxml_tests, mirroring that as <conformance>/<spec>/<name>_test.exs,
#            one module per file (SCXMLTest.<Spec>.<Name>).
#
# Three filters apply before a case is emitted:
#
#   - datamodel: only inputs conf_predicator.xsl transformed to
#     datamodel="predicator" are emitted. The datamodel-specific optional
#     suites (ecma-profile, ...) test literal ECMAScript/XPath behavior the
#     XSL leaves untouched, so they carry their original datamodel and are
#     out of scope for this datamodel commitment (docs/datamodel.md). These
#     do not count toward the "excluded" tally below - that count is
#     manifest-driven only, matching the SCION emitter's behavior.
#   - exclusions.exs: tests with no predicator equivalent (ADR-0004), skipped
#     with the reason recorded there.
#   - sub_documents.exs: manifest <dep> documents an <invoke> loads at
#     runtime, not standalone conformance tests. Emitting one would assert
#     its parent's expected configuration against a document that never
#     reaches it on its own (st-rbp).
#
# required_features tags come from Statifier.FeatureDetector, loaded directly
# since this runs outside Mix and test/support is not compiled in.

Code.require_file(Path.join([__DIR__, "..", "..", "..", "test/support/feature_detector.ex"]))
Code.require_file(Path.join([__DIR__, "..", "normalize.exs"]))
Code.require_file(Path.join([__DIR__, "sub_documents.exs"]))

defmodule Cases.XmlFormat do
  @moduledoc """
  Re-serializes a transformed .scxml with 4-space indentation and no comments,
  matching the corpus's committed test shape (docs/testing.md).
  """

  import Record

  extract_all(from_lib: "xmerl/include/xmerl.hrl")
  |> Enum.each(fn {name, kvs} -> defrecord(name, kvs) end)

  @indent "    "
  @dropped_attrs [:"xmlns:conf"]

  @spec format(String.t()) :: {String.t(), String.t() | nil}
  def format(xml) do
    {doc, _rest} = :xmerl_scan.string(String.to_charlist(xml), comments: false)
    formatted = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" <> render(doc, 0) <> "\n"
    {formatted, datamodel(doc)}
  end

  defp datamodel(xmlElement(attributes: attrs)) do
    Enum.find_value(attrs, fn attr ->
      if xmlAttribute(attr, :name) == :datamodel, do: to_string(xmlAttribute(attr, :value))
    end)
  end

  defp render(xmlElement(name: name, attributes: attrs, content: content), depth) do
    indent = String.duplicate(@indent, depth)
    tag = to_string(name)
    attr_str = render_attrs(attrs)
    {texts, elements} = content |> significant() |> Enum.split_with(&match?(xmlText(), &1))

    cond do
      texts == [] and elements == [] ->
        "#{indent}<#{tag}#{attr_str} />"

      elements == [] ->
        text = texts |> Enum.map_join("", &text_value/1) |> String.trim() |> escape_text()
        "#{indent}<#{tag}#{attr_str}>#{text}</#{tag}>"

      true ->
        inner = elements |> Enum.map_join("\n", &render(&1, depth + 1))
        "#{indent}<#{tag}#{attr_str}>\n#{inner}\n#{indent}</#{tag}>"
    end
  end

  defp text_value(xmlText(value: value)), do: to_string(value)

  defp render_attrs(attrs) do
    attrs
    |> Enum.reject(&(xmlAttribute(&1, :name) in @dropped_attrs))
    |> Enum.map_join("", fn attr ->
      " #{xmlAttribute(attr, :name)}=\"#{escape_attr(xmlAttribute(attr, :value))}\""
    end)
  end

  defp significant(content) do
    Enum.filter(content, fn
      xmlElement() -> true
      xmlText(value: value) -> String.trim(to_string(value)) != ""
      _other -> false
    end)
  end

  defp escape_attr(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace("\"", "&quot;")
  end

  defp escape_text(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
  end
end

defmodule Cases.Emit do
  @spec emit_case(String.t(), String.t(), String.t(), String.t(), String.t(), String.t()) ::
          :emitted | :skipped
  def emit_case(out_root, input, conformance, spec, normalized_spec, normalized_name) do
    name = Path.basename(input, ".scxml")
    {formatted_xml, datamodel} = input |> File.read!() |> Cases.XmlFormat.format()

    if datamodel == "predicator" do
      description =
        input
        |> Path.rootname()
        |> Kernel.<>(".description")
        |> File.read!()
        |> String.split()
        |> Enum.join(" ")

      features =
        formatted_xml
        |> Statifier.FeatureDetector.detect_features()
        |> Enum.sort()
        |> Enum.map_join(", ", &inspect/1)

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
      defmodule #{inspect(module)} do
        use Statifier.Case, async: true

        @moduletag :scxml_w3
        @tag required_features: [#{features}]
        @tag conformance: #{inspect(conformance)}, spec: #{inspect(spec)}
        test #{inspect(name)} do
          xml = \"\"\"
      #{xml_body}\"\"\"

          description = #{inspect(description)}

          test_scxml(xml, description, ["pass"], [])
        end
      end
      """

      out = Path.join([out_root, conformance, normalized_spec, normalized_name <> "_test.exs"])
      out |> Path.dirname() |> File.mkdir_p!()
      File.write!(out, Code.format_string!(source) |> IO.iodata_to_binary() |> Kernel.<>("\n"))
      :emitted
    else
      :skipped
    end
  end
end

exclusions_path = Path.join(__DIR__, "exclusions.exs")
{exclusions, _bindings} = Code.eval_file(exclusions_path)

[out_root, in_root | inputs] = System.argv()

manifest_path = Path.join(in_root, "manifest.xml")

if !File.exists?(manifest_path) do
  IO.puts(:stderr, "missing #{manifest_path}; run `mise run corpus:fetch:w3` first")
  System.halt(1)
end

sub_documents = Cases.SubDocuments.ids(manifest_path)

{matched, emitted, excluded, sub_document} =
  Enum.reduce(inputs, {MapSet.new(), 0, 0, 0}, fn input,
                                                  {matched, emitted, excluded, sub_document} ->
    rel = Path.relative_to(input, in_root)
    [conformance, spec | _rest] = Path.split(rel)
    name = Path.basename(rel, ".scxml")

    normalized_spec = Cases.Normalize.identifier(spec)
    normalized_name = Cases.Normalize.identifier(name)

    cond do
      Map.has_key?(exclusions, name) ->
        {MapSet.put(matched, name), emitted, excluded + 1, sub_document}

      MapSet.member?(sub_documents, name) ->
        {matched, emitted, excluded, sub_document + 1}

      true ->
        case Cases.Emit.emit_case(
               out_root,
               input,
               conformance,
               spec,
               normalized_spec,
               normalized_name
             ) do
          :emitted -> {matched, emitted + 1, excluded, sub_document}
          :skipped -> {matched, emitted, excluded, sub_document}
        end
    end
  end)

stale = Map.keys(exclusions) -- MapSet.to_list(matched)

if stale != [] do
  IO.puts(
    :stderr,
    "stale scxml_w3 exclusions.exs entries (matched nothing): #{Enum.join(stale, ", ")}"
  )

  System.halt(1)
end

IO.puts(
  "emitted #{emitted} W3C case(s), excluded #{excluded}, skipped #{sub_document} sub-document(s)"
)
