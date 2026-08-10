defmodule Statifier.Compiler.Error do
  @moduledoc """
  The compiler's own error shape: `{reason, message, location}`,
  character-identical in style to `Statifier.Lowering.Error`
  (`lib/statifier/lowering/error.ex:21-36`).

  This union is deliberately small. `Statifier.Validator` owns every
  non-expression failure mode exclusively (checks 1-11 at
  `lib/statifier/validator.ex:47-59`): every id `Statifier.Compiler` looks
  up is guaranteed present by the time it gets there, so an unresolved
  reference reaching the compiler is a validator bug, left to raise rather
  than converted into a value of this type. The one failure mode that *is*
  the compiler's own - a `cond`/`expr`/`<content>` source that fails to
  compile - is `:expression_compile_error`, built by
  `Statifier.Compiler.Expressions.compile/3` on its failure path.
  """

  alias Predicator.Errors.ParseError
  alias Statifier.Compiler.Expressions
  alias Statifier.Parser.Location

  @typedoc """
  Closed reason union. `:expression_compile_error` names the owning node
  (`Statifier.Compiler.Expressions.owner_ref/0` - a transition, a content
  node, or a final state's donedata), the raw expression `source`, and
  predicator's own `%Predicator.Errors.ParseError{}` verbatim, in
  predicator's own `{line, column}` coordinate space - the translation into
  document columns happens at reporting time, not here.
  """
  @type reason ::
          {:expression_compile_error, Expressions.owner_ref(), source :: String.t(),
           ParseError.t()}

  @enforce_keys [:reason, :message, :location]
  defstruct [:reason, :message, :location]

  @type t :: %__MODULE__{
          reason: reason(),
          message: binary(),
          location: Location.t()
        }

  @doc """
  A `cond`/`expr`/`<content>` source that failed to compile. `location` is
  the caller's choice - the attribute *value* span
  (`attribute_locations[:cond]` / `[:expr]`) when the author wrote the
  attribute, the owning node's own `location` when
  `Statifier.Lowering.Attributes.put_location/4` produced no entry
  (`lib/statifier/lowering/attributes.ex:76-98`) - never derived here, since
  this module has no access to the node the caller is compiling from.

  The message names the source, predicator's message, and predicator's own
  position, so a human can find the character in the file from the message
  alone even before consulting `location`.
  """
  @spec expression_compile_error(
          owner :: Expressions.owner_ref(),
          source :: String.t(),
          parse_error :: ParseError.t(),
          location :: Location.t()
        ) :: t()
  def expression_compile_error(
        owner,
        source,
        %ParseError{position: {line, column}} = parse_error,
        %Location{} = location
      )
      when is_tuple(owner) and is_binary(source) do
    %__MODULE__{
      reason: {:expression_compile_error, owner, source, parse_error},
      message:
        "failed to compile expression #{inspect(source)}: #{parse_error.message} " <>
          "(predicator line #{line}, column #{column})",
      location: location
    }
  end
end
