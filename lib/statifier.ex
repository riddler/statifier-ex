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

  All four functions land in this module: `compile/1` runs the parse
  pipeline; `initialize/2`, `send_event/2`, and `active_leaf_states/1` wrap
  `Statifier.Interpreter`.
  """

  alias Statifier.Compiler
  alias Statifier.Effect
  alias Statifier.Event
  alias Statifier.Interpreter
  alias Statifier.Lowering
  alias Statifier.Machine
  alias Statifier.MachineState
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

  `Validator.validate/2` returns three elements on both arms (ADR-0033). On
  success its warnings ride onto the returned `Machine.t()`'s `warnings`
  field rather than a third element of this function's own return, so a
  document with warnings still compiles and the caller finds the findings on
  the machine (`Statifier.Machine`'s moduledoc explains why they live there).
  Its error arm's extra element is collapsed back to this function's own
  `{:error, [error()]}` shape so this stage's failure looks like every other
  stage's.
  """
  @spec compile(source :: binary()) :: {:ok, Machine.t()} | {:error, [error()]}
  def compile(source) when is_binary(source) do
    with {:ok, root} <- parse(source),
         {:ok, document} <- Lowering.lower(root),
         {:ok, document, warnings} <- Validator.validate(document, source),
         {:ok, machine} <- Compiler.compile(document) do
      {:ok, %Machine{machine | warnings: warnings}}
    else
      {:error, errors, _warnings} -> {:error, errors}
      other -> other
    end
  end

  defp parse(source) do
    case Parser.parse(source) do
      {:ok, root} -> {:ok, root}
      {:error, error} -> {:error, [error]}
    end
  end

  @doc """
  Initializes `machine` into its starting `Statifier.MachineState`, running
  the initialization macrostep to quiescence.

  A straight pass-through to `Statifier.Interpreter.initialize/2`, mirroring
  that function's own untagged `{machine_state, [effect]}` pair rather than
  wrapping it in an `{:ok, _, _}` this facade would have to invent: a
  `%Machine{}` is valid by construction, so initialization cannot fail.
  `opts` is `Statifier.MachineState.new/2`'s own option set (`:trace`,
  `:datamodel`, `:max_macrostep_rounds`), passed straight through and
  interpreted by neither this function nor `Interpreter.initialize/2`
  itself.

  The returned effects are data, never performed here (ADR-0003) - a caller
  that wants the initialization log/trace effects has them; a caller that
  does not is free to discard them.
  """
  @spec initialize(machine :: Machine.t(), opts :: keyword()) ::
          {MachineState.t(), [Effect.t()]}
  def initialize(%Machine{} = machine, opts \\ []),
    do: Interpreter.initialize(machine, opts)

  @doc """
  Sends one event to `machine_state`, running a macrostep to quiescence and
  returning the resulting position.

  A straight pass-through to `Statifier.Interpreter.handle_event/2`:
  `{:error, :not_running}` comes back unchanged when `machine_state` has
  already terminated, rather than being reinterpreted into some other
  shape. As with `initialize/2`, the returned effects are handed back as
  data and never inspected, logged, or executed here (ADR-0003).

  `event` may be a `Statifier.Event.t()` or a plain name string; the string
  clause is a convenience over `Statifier.Event.external/2` and carries no
  data of its own - a caller who needs event data builds the `%Event{}`
  directly.
  """
  @spec send_event(machine_state :: MachineState.t(), event :: Event.t() | String.t()) ::
          {:ok, MachineState.t(), [Effect.t()]} | {:error, :not_running}
  def send_event(%MachineState{} = machine_state, name) when is_binary(name),
    do: send_event(machine_state, Event.external(name))

  def send_event(%MachineState{} = machine_state, %Event{} = event),
    do: Interpreter.handle_event(machine_state, event)

  @doc """
  The active leaf states of `machine_state`, as a `MapSet` of string ids.

  `Statifier.MachineState.active_leaf_states/1` returns interned integer
  indexes; this is the boundary ADR-0005 reserves for translating them to
  the ids a caller wrote in the document, and nothing beneath `Statifier`
  ever returns a string id. `Statifier.Machine.id/2` returns `nil` for the
  root and for every nameless state - a state with no id cannot be named by
  any caller's expectation either, so it is dropped rather than raised or
  given a synthetic name that no document actually wrote.
  """
  @spec active_leaf_states(machine_state :: MachineState.t()) :: MapSet.t(String.t())
  def active_leaf_states(%MachineState{machine: machine} = machine_state) do
    machine_state
    |> MachineState.active_leaf_states()
    |> Enum.map(&Machine.id(machine, &1))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end
end
