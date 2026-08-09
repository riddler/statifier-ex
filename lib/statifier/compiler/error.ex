defmodule Statifier.Compiler.Error do
  @moduledoc """
  The compiler's own error shape: `{reason, message, location}`,
  character-identical in style to `Statifier.Lowering.Error`
  (`lib/statifier/lowering/error.ex:21-36`).

  This union is deliberately small, and starts empty. `Statifier.Validator`
  owns every non-expression failure mode exclusively (checks 1-11 at
  `lib/statifier/validator.ex:47-59`): every id `Statifier.Compiler` looks up
  is guaranteed present by the time it gets there, so an unresolved reference
  reaching the compiler is a validator bug, left to raise rather than
  converted into a value of this type. The one failure mode that *is* the
  compiler's own - a `cond`/`expr`/`<content>` source that fails to
  compile - is Phase 3's `:expression_compile_error`, added there with its
  own constructor; this module exists now, with no reason values
  constructible yet, so Phase 3 extends a shape rather than introducing one.
  """

  alias Statifier.Parser.Location

  @typedoc "Closed reason union. Empty until Phase 3 adds `:expression_compile_error`."
  @type reason :: none()

  @enforce_keys [:reason, :message, :location]
  defstruct [:reason, :message, :location]

  @type t :: %__MODULE__{
          reason: reason(),
          message: binary(),
          location: Location.t()
        }
end
