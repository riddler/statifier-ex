# Walks a transformed W3C cases root, extracts every datamodel-bearing
# attribute, and asserts it compiles under predicator (ADR-0004) - except the
# handful of values the W3C tests deliberately require to be invalid.
#
# Usage: mix run tools/corpus/scxml_w3/check_exprs.exs <cases_root>
#
# `tools/` is not on elixirc_paths, so the module below is not compiled by
# `mix compile`; test/corpus/check_exprs_test.exs loads this file with
# Code.require_file/1 to reach it. The top-level script body is guarded on
# Mix.env() so requiring the file for its module does not also run the CLI.

defmodule Corpus.CheckExprs do
  @moduledoc false

  @expression_attrs ~w(cond expr eventexpr targetexpr typeexpr delayexpr sendidexpr srcexpr array)
  @location_attrs ~w(location item idlocation)

  # Keyed by {kind, exact attribute value}. Predicator.compile/1 and
  # Predicator.context_location/3 are syntactic checks, not evaluators:
  # `return` (conf:illegalExpr) compiles as a plain variable load and
  # `foo.bar.baz ` (conf:invalidLocation) resolves as an ordinary location
  # path - both need a bound context or an evaluation step to fail, which the
  # W3C tests get from `error.execution` at runtime, not from a compile
  # failure. Verified empirically against the full mandatory corpus: the only
  # checked-family value that fails to compile/resolve is `'continue'`
  # (conf:illegalItem, test152), a quoted string literal that is not an
  # assignable location.
  @allowlist %{
    {:location, "'continue'"} => {"conf:illegalItem", ["test152"]}
  }

  def allowlist, do: @allowlist

  def expression_attr?(name), do: name in @expression_attrs
  def location_attr?(name), do: name in @location_attrs

  def attribute_kind(name) do
    cond do
      expression_attr?(name) -> :expression
      location_attr?(name) -> :location
      true -> nil
    end
  end

  @doc "Extracts every {kind, attribute_name, value} triple from an .scxml document."
  def collect_attributes(xml) when is_binary(xml) do
    {:ok, simple_form} = Saxy.SimpleForm.parse_string(xml)
    collect_attributes(simple_form)
  end

  def collect_attributes({_tag, attrs, children}) do
    here =
      for {name, value} <- attrs,
          kind = attribute_kind(name),
          not is_nil(kind),
          do: {kind, name, value}

    Enum.reduce(children, here, fn
      {_tag, _attrs, _children} = element, acc -> acc ++ collect_attributes(element)
      _text_or_cdata, acc -> acc
    end)
  end

  def check(:expression, value), do: Predicator.compile(value)
  def check(:location, value), do: Predicator.context_location(value, %{})

  def test_id(path), do: Path.basename(path, ".scxml")

  @doc "Checks one file's expression/location attributes against the allowlist."
  def check_file(path, allowlist \\ @allowlist) do
    attrs = path |> File.read!() |> collect_attributes()

    Enum.reduce(attrs, %{checked: 0, expected: [], unexpected: []}, fn {kind, name, value}, acc ->
      acc = %{acc | checked: acc.checked + 1}

      case check(kind, value) do
        {:ok, _} ->
          acc

        {:error, _reason} ->
          if Map.has_key?(allowlist, {kind, value}) do
            %{acc | expected: [{kind, name, value} | acc.expected]}
          else
            %{acc | unexpected: [{kind, name, value} | acc.unexpected]}
          end
      end
    end)
  end

  @doc "Loads exclusions.exs into a test-id -> {reason, note} map."
  def load_exclusions(path) do
    {map, _bindings} = Code.eval_file(path)
    map
  end

  @doc """
  Walks `cases_root` for .scxml files, skips excluded tests, checks the rest,
  and reports unexpected failures plus any allowlist entry that never fired.
  """
  def run(cases_root, exclusions_path, allowlist \\ @allowlist) do
    exclusions = load_exclusions(exclusions_path)

    all_files =
      cases_root
      |> Path.join("**/*.scxml")
      |> Path.wildcard()
      |> Enum.sort()

    {skipped, checked} = Enum.split_with(all_files, &Map.has_key?(exclusions, test_id(&1)))

    file_reports = Enum.map(checked, &{&1, check_file(&1, allowlist)})

    expressions_checked = file_reports |> Enum.map(fn {_path, r} -> r.checked end) |> Enum.sum()

    expected_failures =
      Enum.flat_map(file_reports, fn {path, r} ->
        Enum.map(r.expected, fn {kind, name, value} -> {path, kind, name, value} end)
      end)

    unexpected_failures =
      Enum.flat_map(file_reports, fn {path, r} ->
        Enum.map(r.unexpected, fn {kind, name, value} -> {path, kind, name, value} end)
      end)

    fired_keys =
      expected_failures |> Enum.map(fn {_p, kind, _n, value} -> {kind, value} end) |> MapSet.new()

    stale_allowlist = Enum.reject(Map.keys(allowlist), &(&1 in fired_keys))

    %{
      files_checked: length(checked),
      files_skipped: length(skipped),
      expressions_checked: expressions_checked,
      expected_failures: expected_failures,
      unexpected_failures: unexpected_failures,
      stale_allowlist: stale_allowlist
    }
  end

  def ok?(report), do: report.unexpected_failures == [] and report.stale_allowlist == []

  def summary(report) do
    """
    files checked:       #{report.files_checked}
    files skipped:       #{report.files_skipped}
    expressions checked: #{report.expressions_checked}
    expected failures:   #{length(report.expected_failures)}
    """
  end
end

if Mix.env() != :test do
  case System.argv() do
    [cases_root] ->
      exclusions_path = Path.join(Path.dirname(__ENV__.file), "exclusions.exs")
      report = Corpus.CheckExprs.run(cases_root, exclusions_path)

      IO.puts(Corpus.CheckExprs.summary(report))

      if report.unexpected_failures != [] do
        IO.puts("Unexpected failures:")

        Enum.each(report.unexpected_failures, fn {path, kind, name, value} ->
          IO.puts("  #{path} [#{kind}] #{name}=#{inspect(value)}")
        end)

        IO.puts("")
      end

      if report.stale_allowlist != [] do
        IO.puts("Allowlist entries that no longer fire:")
        Enum.each(report.stale_allowlist, &IO.inspect/1)
        IO.puts("")
      end

      if Corpus.CheckExprs.ok?(report) do
        IO.puts("corpus:check OK")
      else
        System.halt(1)
      end

    _other ->
      IO.puts(:stderr, "usage: mix run tools/corpus/scxml_w3/check_exprs.exs <cases_root>")
      System.halt(1)
  end
end
