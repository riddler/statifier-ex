defmodule AppendixD do
  @moduledoc """
  Extracts the "Algorithm for SCXML Interpretation" appendix from the fetched
  W3C SCXML REC into a plain-text file: one block per datatype/procedure/
  function, in document order, with its explanatory prose and its pseudocode
  preserved verbatim (indentation carries the block structure, so it is not
  reflowed). The output is a local reading aid for comparing a ported
  function against its pseudocode; it is never committed.

  Plain `elixir`, not `mix run`: this script needs xmerl, which Mix prunes
  from the code path, and nothing from the project.
  """

  import Record

  extract_all(from_lib: "xmerl/include/xmerl.hrl")
  |> Enum.each(fn {name, kvs} -> defrecord(name, kvs) end)

  # A handful of the procedure/function names the appendix is known to
  # define. If any of these go missing after extraction, the REC's markup
  # has changed shape and the extractor needs a look rather than silently
  # emitting a truncated file.
  @known_names ~w(enterStates exitStates selectTransitions getChildStates isDescendant)
  @min_blocks 20

  def run(html_path, out_path) do
    doc = parse(html_path)

    section =
      find_appendix_d(doc) ||
        raise "could not find the \"Algorithm for SCXML Interpretation\" " <>
                "heading in #{html_path} - the REC's structure may have changed"

    blocks = extract_blocks(section)
    check_sanity!(blocks)

    body = Enum.map_join(blocks, "\n\n", &render_block/1)
    File.write!(out_path, header() <> body <> "\n")
  end

  defp parse(html_path) do
    xml =
      html_path
      |> File.read!()
      # &nbsp; appears only in the table of contents, indenting section
      # numbers; appendix D itself uses plain text. xmerl has no DTD to
      # resolve named entities against, so swap it for a literal space
      # before parsing rather than teaching xmerl the XHTML entity set for
      # one character that never shows up in the content being extracted.
      |> String.replace("&nbsp;", " ")

    # A byte list, not String.to_charlist/1's decoded Unicode codepoints:
    # the document declares encoding="UTF-8" in its XML prologue, and xmerl
    # decodes multi-byte characters itself once it has seen that. Handing it
    # already-decoded codepoints instead makes it misread the multi-byte
    # sequences and reject legal characters.
    {doc, _rest} = :xmerl_scan.string(:binary.bin_to_list(xml), quiet: true)
    doc
  end

  # The REC wraps each top-level section in <div class="div1">; Appendix D's
  # div is the one whose content holds the matching <h2>. Search depth-first
  # rather than assuming a fixed nesting depth, since Tidy-generated markup
  # is not something this project controls.
  defp find_appendix_d(xmlElement(name: :div, content: content) = el) do
    if Enum.any?(content, &appendix_d_heading?/1) do
      el
    else
      Enum.find_value(content, &find_appendix_d/1)
    end
  end

  defp find_appendix_d(xmlElement(content: content)) do
    Enum.find_value(content, &find_appendix_d/1)
  end

  defp find_appendix_d(_node), do: nil

  defp appendix_d_heading?(xmlElement(name: :h2) = el) do
    # The heading text line-wraps mid-phrase in the source markup, so match
    # against the whitespace-collapsed form rather than the raw text.
    clean_text(el) =~ "Algorithm for SCXML Interpretation"
  end

  defp appendix_d_heading?(_node), do: false

  # Appendix D's div has no further nested <div>s: the datatype, global
  # variable, predicate, procedure, and function headings are flat siblings
  # of the paragraphs and <pre> blocks that belong to them, in document
  # order. Walking that sibling list once, carrying the most recent heading
  # and the prose paragraphs seen since the last <pre>, pairs each block
  # with its own heading and description without needing to know the
  # section's exact nesting.
  defp extract_blocks(xmlElement(content: content)) do
    {blocks, state} =
      Enum.reduce(content, {[], new_heading(nil, nil, nil)}, fn
        xmlElement(name: :h3) = el, {blocks, state} ->
          {flush(blocks, state), new_heading(:h3, attr(el, :id), clean_text(el))}

        xmlElement(name: :h4) = el, {blocks, state} ->
          {flush(blocks, state), new_heading(:h4, attr(el, :id), clean_text(el))}

        xmlElement(name: :p) = el, {blocks, state} ->
          {blocks, %{state | prose: state.prose ++ [clean_text(el)]}}

        xmlElement(name: :pre) = el, {blocks, state} ->
          block = state |> Map.put(:code, pre_text(el)) |> Map.delete(:pending?)
          {[block | blocks], %{state | prose: [], pending?: false}}

        _node, acc ->
          acc
      end)

    blocks
    |> flush(state)
    |> Enum.reverse()
  end

  defp new_heading(kind, id, heading),
    do: %{kind: kind, id: id, heading: heading, prose: [], pending?: true}

  # A few functions in this appendix are simple enough that the REC gives
  # only a prose description and no pseudocode block (getProperAncestors,
  # isDescendant, getChildStates). Their heading is otherwise about to be
  # discarded the moment the next heading or the section boundary is
  # reached, so flush whatever prose it collected, without a code block,
  # before moving on. A heading whose description ends in a <pre> instead
  # has already been flushed there and is not re-emitted here.
  defp flush(blocks, %{kind: nil}), do: blocks
  defp flush(blocks, %{pending?: false}), do: blocks
  defp flush(blocks, state), do: [Map.put(state, :code, nil) | blocks]

  defp check_sanity!(blocks) do
    procedure_ids =
      for %{kind: :h4, id: id} <- blocks, is_binary(id), do: id

    missing = @known_names -- procedure_ids

    cond do
      length(procedure_ids) < @min_blocks ->
        raise "expected at least #{@min_blocks} Appendix D procedure/function " <>
                "blocks, found #{length(procedure_ids)} - the REC's markup may " <>
                "have changed; refusing to write a possibly-truncated file"

      missing != [] ->
        raise "Appendix D extraction is missing expected procedures: " <>
                "#{Enum.join(missing, ", ")} - the REC's markup may have changed; " <>
                "refusing to write a possibly-truncated file"

      true ->
        :ok
    end
  end

  defp render_block(%{kind: kind, heading: heading, prose: prose, code: code}) do
    marker = if kind == :h4, do: "###", else: "##"
    parts = ["#{marker} #{heading}"] ++ prose ++ List.wrap(code)
    Enum.join(parts, "\n\n")
  end

  defp flatten_text(xmlText(value: v)), do: List.to_string(v)
  defp flatten_text(xmlElement(content: c)), do: Enum.map_join(c, "", &flatten_text/1)
  defp flatten_text(_node), do: ""

  defp clean_text(el) do
    el |> flatten_text() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  # Preserve the pseudocode's indentation exactly - it carries the block
  # structure and is the thing a reader diffs against a ported function.
  # Only trailing whitespace per line and leading/trailing blank lines are
  # trimmed.
  defp pre_text(el) do
    el
    |> flatten_text()
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    |> String.trim("\n")
  end

  defp attr(xmlElement(attributes: attrs), name) do
    Enum.find_value(attrs, fn
      xmlAttribute(name: ^name, value: value) -> List.to_string(value)
      _other -> nil
    end)
  end

  defp header do
    """
    Appendix D: Algorithm for SCXML Interpretation
    Extracted from the W3C SCXML REC (https://www.w3.org/TR/scxml/) for local
    diffing against this codebase's port. Not vendored: this file lives only
    in the gitignored scratch area and regenerates with `mise run spec:fetch`.

    """
  end
end

case System.argv() do
  [html_path, out_path] ->
    AppendixD.run(html_path, out_path)

  _other ->
    IO.puts(:stderr, "usage: elixir extract_appendix_d.exs <html-path> <out-path>")
    System.halt(1)
end
