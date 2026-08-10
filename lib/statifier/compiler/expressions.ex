defmodule Statifier.Compiler.Expressions do
  @moduledoc """
  The expression-compilation seam: compiles raw predicator source - a
  `cond`, an `expr`, or a `<content>` text body - into the single
  `Machine.expr()` sum type, on its own, before either of its two consumers
  (the transition pass's transitions, the executable-content pass's
  content/donedata) so neither lands a raw-string field and changes its type
  afterwards.

  ADR-0014 item 1 commits to spans, not point positions: `compile/3` always
  calls `Predicator.compile_with_spans/1`, never `compile_with_positions/1`.
  Item 2 already settled the compiled shape - `%Predicator.Compiled{}`
  threads its own `positions` table alongside `instructions`, so there is no
  separate table for this module to carry or drop.
  """

  alias Predicator.Errors.ParseError
  alias Statifier.Compiler.Error
  alias Statifier.Machine
  alias Statifier.Parser.Location

  @typedoc """
  Identifies the node a compiled expression belongs to, in the same
  ADR-0012 constraint-3 index space `Statifier.Compiler.Error` names an
  owner by: a transition's `t_index`, a content node's `c_index`, or a
  final state's own index for its `<donedata>`. Nothing calls `compile/3`
  with a real index yet - the transition pass wires transitions, the
  executable-content pass wires content and donedata - so this phase's own
  tests exercise the type directly with placeholder indexes.
  """
  @type owner_ref ::
          {:transition, non_neg_integer()}
          | {:content, non_neg_integer()}
          | {:donedata, non_neg_integer()}

  @doc """
  Compiles `source` into a `Machine.expr()`.

  `owner` identifies the node `source` came from (for the error case only -
  a successful compile carries no owner, since nothing downstream needs one
  until evaluation fails). `location` is the document `Location` a failure
  is reported against: the attribute *value* span
  (`attribute_locations[:cond]` / `[:expr]`) when the author wrote the
  attribute, the owning node's own `location` otherwise - the caller's
  choice, not this function's.

  On success, `compile_with_spans/1`'s `%Predicator.Compiled{}` is stored
  whole - its `positions` table is a span table (ADR-0014 item 1), never
  reduced to point positions and never re-supplied via a `:positions`
  keyword (item 2: passing both to `evaluate/3` raises).

  On failure, `compile_with_spans/1` reports only a formatted string
  (verified against the installed predicator 4.0.0 dependency:
  `deps/predicator/lib/predicator.ex`'s `build_compiled_result/1` private
  clause), so the structured `{line, column}` predicator actually failed at
  is recovered by a second, failure-path-only call to `Predicator.parse/2` -
  `Predicator.parse/2` always returns
  `{:error, message, line, column}` on failure regardless of the `spans:`
  option, since spans are a property of successfully parsed AST nodes, not
  of the error tuple.
  """
  @spec compile(source :: String.t(), owner :: owner_ref(), location :: Location.t()) ::
          {:ok, Machine.expr()} | {:error, Error.t()}
  def compile(source, owner, %Location{} = location)
      when is_binary(source) and is_tuple(owner) do
    case Predicator.compile_with_spans(source) do
      {:ok, %Predicator.Compiled{} = compiled} ->
        {:ok, {:compiled, compiled, source}}

      {:error, _formatted_message} ->
        {:error, parse_error(source, owner, location)}
    end
  end

  @doc """
  Wraps a literal value with no expression to evaluate - the `{:static, v}`
  arm of `Machine.expr()` for a plain `<content>text</content>` body -
  there is no predicator source and nothing to compile.
  """
  @spec static(value :: term()) :: Machine.expr()
  def static(value), do: {:static, value}

  @spec parse_error(source :: String.t(), owner :: owner_ref(), location :: Location.t()) ::
          Error.t()
  defp parse_error(source, owner, location) do
    {:error, message, line, column} = Predicator.parse(source, spans: true)
    Error.expression_compile_error(owner, source, ParseError.new(message, line, column), location)
  end
end
