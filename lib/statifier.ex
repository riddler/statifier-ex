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
  alias Statifier.Session
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

  @doc """
  Starts a `Statifier.Session` for `machine` on `Statifier.SessionSupervisor`,
  under the ADR-0027 session runtime.

  `opts` is `Statifier.Session.start_link/2`'s own option set, passed
  through unchanged. This is the runtime-placed alternative to calling
  `Statifier.Session.start_link/2` directly: a session started here lands
  on `Statifier.SessionSupervisor` (`restart: :temporary`, so a crash is
  never silently restarted into a fresh, unrelated session id - ADR-0027
  decision 4) and registers itself under `Statifier.Registry` during
  `init/1`, so it becomes reachable by other sessions as
  `#_scxml_<sessionid>` (ADR-0027 decision 2). A session started instead by
  a bare `Statifier.Session.start_link/2` call is legal but stays
  unregistered, and therefore unreachable by id from any session but
  itself.

  Requires `Statifier.Supervisor` to already be placed somewhere in the
  embedder's own supervision tree - this library ships no application
  callback (ADR-0027 decision 1), so nothing starts one automatically. The
  return value is `DynamicSupervisor.start_child/2`'s own
  `{:ok, pid} | {:error, term}` (see its docs for what `term` can be, most
  commonly `Statifier.SessionSupervisor` itself not being started).
  """
  @spec start_session(machine :: Machine.t(), opts :: keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_session(%Machine{} = machine, opts \\ []) do
    # `Session.start_link/2` takes two positional arguments (`machine`,
    # `opts`), not the single `init_arg` the `use GenServer`-generated
    # `child_spec/1` expects (`{Session, single_term}` calls
    # `Session.start_link(single_term)`), so a literal `{Session, {machine,
    # opts}}` child-spec tuple would call `start_link/1` with a 2-tuple
    # where it expects a `%Machine{}` and raise. Building the child spec
    # directly, naming the MFA and both arguments, sidesteps that mismatch
    # without touching `Session`'s own `child_spec/1` (still available
    # unchanged for an embedder who places a session directly with a
    # single-argument `{Session, machine}`-style spec).
    spec = %{
      id: Session,
      start: {Session, :start_link, [machine, opts]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(Statifier.SessionSupervisor, spec)
  end
end
