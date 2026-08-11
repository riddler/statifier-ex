defmodule Statifier do
  @moduledoc """
  The public entry point for statifier-ex.

  This module is the library's four-function surface (ADR-0006), the only
  place a caller needs to import: compile a document, initialize a state
  chart, send an event synchronously, and read the active leaf states. Every
  layer beneath it - `Statifier.Document`, `Statifier.Machine`,
  `Statifier.MachineState` - stays reachable for tooling, but a caller who
  only wants to run a state chart never has to name them.

  Two boundaries hold at every function in this module:

  - **String ids only at this boundary, and nowhere deeper** (ADR-0005).
    Below `Statifier`, states and transitions are addressed by interned
    integer index; this module is where a caller's string ids go in and
    where they come back out.
  - **Effects are returned, never interpreted** (ADR-0003). Every function
    that can produce `Statifier.Effect.t()` values hands them back as data;
    none of them is inspected, logged, or executed here. A caller that wants
    to act on `:log`, `:done`, or a `:trace` effect does so itself.

  Only `compile/1` lands in this phase; `initialize/2`, `send_event/2`, and
  `active_leaf_states/1` complete the four-function surface in a later phase.
  """

  alias Statifier.Compiler
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.Parser
  alias Statifier.Validator

  @typedoc """
  The union of every error struct any pipeline stage `compile/1` runs can
  produce.
  """
  @type error ::
          Statifier.Parser.ParseError.t()
          | Statifier.Lowering.Error.t()
          | Statifier.Validator.Error.t()
          | Statifier.Compiler.Error.t()

  @doc """
  Compiles SCXML source into a `Statifier.Machine`.

  Runs the full pipeline - `Statifier.Parser.parse/1`,
  `Statifier.Lowering.lower/1`, `Statifier.Validator.validate/2`,
  `Statifier.Compiler.compile/1` - in that order, stopping at the first stage
  that fails. `Statifier.Parser.parse/1` is the one stage that reports a
  single error rather than a list; this function wraps it so every failure
  from every stage has one shape: `{:error, [error()]}`.
  """
  @spec compile(source :: binary()) :: {:ok, Machine.t()} | {:error, [error()]}
  def compile(source) when is_binary(source) do
    with {:ok, root} <- parse(source),
         {:ok, document} <- Lowering.lower(root),
         {:ok, document} <- Validator.validate(document, source) do
      Compiler.compile(document)
    end
  end

  defp parse(source) do
    case Parser.parse(source) do
      {:ok, root} -> {:ok, root}
      {:error, error} -> {:error, [error]}
    end
  end
end
