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
          | {:data, non_neg_integer()}

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
  (verified against the installed predicator 7.0.0 dependency:
  `deps/predicator/lib/predicator.ex`'s `build_compiled_result/1` private
  clause), so the structured `{line, column}` predicator actually failed at
  is recovered by a second, failure-path-only call to `Predicator.parse/2` -
  `Predicator.parse/2` always returns `{:error, message, line, column}` on
  failure regardless of the `spans:` option, since spans are a property of
  successfully parsed AST nodes, not of the error tuple.
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

  @doc """
  Constant-folds a `<data>` element's child text into a `{:static, value}`
  `Machine.expr()` - Decision 8
  (`docs/plans/260812-st-af3.3-datamodel-data-early-late-binding.md`). Spec
  5.3.2 is explicit that `<data>`'s children are "an in-line specification
  of the **value** of the data object", not an expression that reads the
  datamodel, and B.2.1 gives the ECMAScript datamodel a
  parse-then-fall-back-to-string ladder for exactly this reason: "if the
  content is a valid JSON... create the corresponding ECMAScript object...
  Otherwise the Processor MUST treat the content as a space-normalized
  string literal". This is the predicator analogue, one rung shorter than
  B.2.1's (predicator's own literal syntax stands in for JSON; there is no
  XML rung under ADR-0004):

  1. trim `text` - `String.trim/1`'s result doubles as this analogue's
     "space-normalized string literal", the fallback of step 5;
  2. compile the trimmed text with `Predicator.compile_with_spans/1`;
  3. on success, evaluate the compiled result **at compile time**, against
     an *empty* `Predicator.Context.new(%{}, on_unbound: :error)`;
  4. on `{:ok, value}`, return `{:static, value}`;
  5. on any failure at either step, return `{:static, trimmed_text}`.

  The empty, `on_unbound: :error` context in step 3 is what makes the fold
  safe: `<data id="x">hello</data>` compiles to a load of `hello`, which
  fails against a context that holds nothing and errors rather than
  defaulting to `:undefined` - so it falls through to the string literal
  `"hello"` instead of silently becoming a datamodel read. `[1, 2, 3]`
  compiles and evaluates to the list `[1, 2, 3]` directly, with nothing to
  fall back to.

  Consequently this function **never** returns a `{:compiled, ...}` arm:
  child content can never raise `error.execution` at binding time, which is
  why 5.3.2's "empty data element" failure clause never has a child-content
  case to apply to under this datamodel.

  `Statifier.EventData.coerce/1` runs a near-identical parse-or-string
  ladder, and the two are deliberately not merged: this function implements
  B.2.1 (datamodel initialization from `<data>` inline content) at compile
  time, because a `<data>` body is static by construction, while
  `EventData.coerce/1` implements B.2.8.1 (`_event.data` population) at
  event time, because a `<param expr>`'s value is only known then. Same
  shape, different clause, different time - see that module's moduledoc.
  """
  @spec inline_value(text :: String.t()) :: Machine.expr()
  def inline_value(text) when is_binary(text) do
    trimmed = String.trim(text)
    empty_context = Predicator.Context.new(%{}, on_unbound: :error)

    with {:ok, %Predicator.Compiled{} = compiled} <- Predicator.compile_with_spans(trimmed),
         {:ok, value} <- Predicator.evaluate(compiled, empty_context) do
      {:static, value}
    else
      _failure -> {:static, trimmed}
    end
  end

  @doc """
  Compiles a predicator *statement program* - a `<script>` body - into a
  `Machine.program()`, the sibling type `Machine.program()`'s typedoc
  describes: a program is never an arm of `Machine.expr()`, because
  `Predicator.evaluate/3` rejects statement programs outright
  (`deps/predicator/lib/predicator.ex:213-217`), so this function is a
  parallel entry point rather than a third clause of `compile/3`.

  `owner` and `location` carry the same meaning `compile/3`'s docs give
  them - the owning node for the error case, and the `Location` a failure
  is reported against.

  On success, `Predicator.compile_program_with_positions/1`'s
  `%Predicator.Compiled{}` is stored whole, exactly as `compile/3` stores
  `compile_with_spans/1`'s result.

  On failure, the structured `{line, column}` is recovered with a second
  call to `Predicator.parse_program/2`, which - unlike `compile/3`'s
  `Predicator.parse/2` detour through a `spans:` option - already returns
  the structured `{:error, message, line, column}` 4-tuple directly
  (`deps/predicator/lib/predicator.ex:865-871`). The asymmetry with
  `compile/3`'s recovery path is deliberate, not an oversight: a program
  parse failure never carries a span to ask for in the first place.
  """
  @spec compile_program(source :: String.t(), owner :: owner_ref(), location :: Location.t()) ::
          {:ok, Machine.program()} | {:error, Error.t()}
  def compile_program(source, owner, %Location{} = location)
      when is_binary(source) and is_tuple(owner) do
    case Predicator.compile_program_with_positions(source) do
      {:ok, %Predicator.Compiled{} = compiled} -> {:ok, {:program, compiled, source}}
      {:error, _formatted_message} -> {:error, program_parse_error(source, owner, location)}
    end
  end

  @spec parse_error(source :: String.t(), owner :: owner_ref(), location :: Location.t()) ::
          Error.t()
  defp parse_error(source, owner, location) do
    {:error, message, line, column} = Predicator.parse(source, spans: true)
    Error.expression_compile_error(owner, source, ParseError.new(message, line, column), location)
  end

  @spec program_parse_error(source :: String.t(), owner :: owner_ref(), location :: Location.t()) ::
          Error.t()
  defp program_parse_error(source, owner, location) do
    {:error, message, line, column} = Predicator.parse_program(source)
    Error.expression_compile_error(owner, source, ParseError.new(message, line, column), location)
  end
end
