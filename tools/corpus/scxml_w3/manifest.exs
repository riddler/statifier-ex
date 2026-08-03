defmodule Fetch do
  import Record

  extract_all(from_lib: "xmerl/include/xmerl.hrl")
  |> Enum.each(fn {name, kvs} ->
    defrecord(name, kvs)
  end)

  def run(manifest, touchfile, host) do
    dir = Path.dirname(touchfile)
    {doc, _misc} = :xmerl_scan.file(manifest)

    doc
    |> children()
    |> Enum.flat_map(fn
      xmlElement(name: :assert) = assert ->
        spec = get_attr(assert, :specid) |> to_string() |> String.replace("#", "")
        [description, test] = children(assert)
        description = to_string(xmlText(description, :value))

        if get_attr(test, :manual) == ~c"false" do
          conformance = get_attr(test, :conformance) |> to_string()

          test
          |> children()
          |> Stream.map(&get_attr(&1, :uri))
          |> Stream.filter(&(Path.extname(&1) == ".txml"))
          |> Enum.map(fn uri ->
            id = Path.basename(uri, ".txml")
            {"#{host}/#{uri}", id, conformance, spec, description}
          end)
        else
          []
        end

      xmlText() ->
        []
    end)
    |> Enum.map(fn {uri, id, conformance, spec, description} ->
      name = "#{dir}/#{conformance}/#{spec}/#{id}"
      template = "#{name}.txml"

      if !File.exists?(template) do
        name |> Path.dirname() |> File.mkdir_p!()
        File.write!("#{name}.description", description)
        IO.puts("curl #{uri} -o #{template}")
        download!(uri, template)
        # Pace the run: w3.org 429s a few hundred back-to-back requests.
        Process.sleep(500)
      end
    end)

    File.touch!(touchfile)
  end

  # curl rather than an HTTP client dep: the generator is a build tool and should
  # not pull runtime deps into the library's mix.exs. www.w3.org rate-limits a
  # few hundred sequential fetches with a 429, so back off and retry; the caller
  # skips templates already on disk, making a resumed run cheap.
  defp download!(uri, template, attempt \\ 1) do
    case System.cmd("curl", ["-fsSL", uri, "-o", template], stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, status} when attempt < 8 ->
        delay = min(attempt * 30_000, 240_000)

        IO.puts(
          "  retry #{attempt} in #{div(delay, 1000)}s (exit #{status}): #{String.trim(out)}"
        )

        File.rm(template)
        Process.sleep(delay)
        download!(uri, template, attempt + 1)

      {out, status} ->
        File.rm(template)
        raise "curl #{uri} failed after #{attempt} attempts (exit #{status}): #{out}"
    end
  end

  defp get_attr(xmlElement(attributes: attrs), name) do
    Enum.find_value(attrs, fn
      xmlAttribute(name: ^name, value: value) ->
        value

      _ ->
        false
    end)
  end

  defp children(xmlElement(content: content)) do
    content
    |> Enum.filter(fn
      xmlElement() -> true
      # (xmlText(type: :cdata)) -> true
      xmlText(value: value) -> length(value) > 10
      _ -> false
    end)
  end
end

[manifest, touchfile, host] = System.argv()
Fetch.run(manifest, touchfile, host)
