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

  All four functions land in this module: `compile/2` (with `compile/1`'s
  default `opts \\ []`) runs the parse pipeline; `initialize/2`,
  `send_event/2`, and `active_leaf_states/1` wrap `Statifier.Interpreter`.
  """

  alias Statifier.{Compiler, Effect, Event, Interpreter, Lowering}
  alias Statifier.Compiler.FunctionCalls
  alias Statifier.Evaluator.Functions
  alias Statifier.{Machine, MachineState, Parser, Session, Validator}
  alias Statifier.Machine.Identity

  @typedoc """
  The union of every error struct any pipeline stage `compile/2` runs can
  produce.
  """
  @type error ::
          Statifier.Parser.ParseError.t()
          | Statifier.Lowering.Error.t()
          | Statifier.Validator.Error.t()
          | Statifier.Compiler.Error.t()

  # The closed set of `compile/2` options persisted onto the Machine and, from
  # there, into a `Statifier.Chart` blob. Closed rather than open: `:safe`
  # decoding refuses to create atoms a blob names, so an embedder's own
  # unrecognized option key could make a blob this library wrote undecodable.
  # Every option this function recognizes is either listed here or provably
  # inert for compilation - adding a recognized option means deciding which
  # it is. See ADR-0052. `:function_providers` is the one recognized option
  # persisted in another form: as the `:function_names` it declares, strings
  # a `:safe` decode can read (ADR-0078).
  @persisted_compile_opts [:invoke_content_markup, :chart_name, :chart_version, :function_names]

  @doc """
  Compiles SCXML source into a `Statifier.Machine`.

  Runs the full pipeline - `Statifier.Parser.parse/1`,
  `Statifier.Lowering.lower/2`, `Statifier.Validator.validate/3`,
  `Statifier.Compiler.compile/1` - in that order, stopping at the first stage
  that fails. `Statifier.Parser.parse/1` is the one stage that reports a
  single error rather than a list; this function wraps it so every failure
  from every stage has one shape: `{:error, [error()]}`.

  `Validator.validate/3` returns three elements on both arms (ADR-0033). On
  success its warnings ride onto the returned `Machine.t()`'s `warnings`
  field rather than a third element of this function's own return, so a
  document with warnings still compiles and the caller finds the findings on
  the machine (`Statifier.Machine`'s moduledoc explains why they live there).
  Its error arm's extra element is collapsed back to this function's own
  `{:error, [error()]}` shape so this stage's failure looks like every other
  stage's.

  `opts` defaults to `[]`, so every existing `compile/1` call keeps its exact
  behavior. The one recognized option today is `invoke_content_markup:
  true` (ADR-0042): it relaxes `Statifier.Validator.Checks.Boilerplate`'s
  root-namespace check (spec 3.2.1's `xmlns` requirement) to accept a root
  that declares no namespace at all, the same leniency
  `Statifier.Lowering.Namespace.scxml_vocabulary?/1` already applies to
  lowering dispatch. It exists to compile the verbatim source slice
  `Statifier.Invoke.Source.resolve/2` extracts from an `<invoke><content>`
  element - G.6 (informative) places an undeclared-namespace child of
  `<content>` in the SCXML namespace by ordinary XML scoping, a fact the
  slice's standalone compile can no longer see for itself. It is not a
  general validation off-switch: a root that declares a namespace other than
  SCXML's still fails, in this mode and without it alike, and `version` must
  still be `"1.0"` either way.

  Two more recognized options, `:chart_name` and `:chart_version`, ride
  straight through to `Statifier.Machine.Identity.of_source/2` and are
  ignored by every pipeline stage before it: `Validator.Context.build/3`
  reads only `:invoke_content_markup` from this same `opts`, so the two
  identity options pass through the pipeline untouched and no stage needs a
  change to carry them. They stamp the returned `Machine.t()`'s `identity`
  field (`Statifier.Machine.identity/1`) alongside the content hash
  `compile/2` always takes over `source`.

  Two options declare the functions a chart's expressions may call beyond
  `In/1` and predicator's builtins (ADR-0078). `:function_providers` is a
  list of `Predicator.FunctionProvider` modules; each name their
  `functions/0` answers is declared. `:function_names` is a list of name
  strings, declared as they are, for a caller that knows the names but
  does not load the modules (a tool that only checks a chart). Every
  `["call", name, arity]` instruction in the compiled chart must name a
  declared function, `In`, or a builtin; any other name fails the compile
  with a `Statifier.Compiler.Error` whose reason is
  `{:unknown_function, name, source}`
  (`Statifier.Compiler.FunctionCalls.check/2`). A provider list that does
  not resolve, or that names a function `In/1` or a builtin answers to, is
  host misuse and raises `ArgumentError`
  (`Statifier.Evaluator.Functions.from_providers/1`). The names declared by
  both options are persisted together, sorted, as `:function_names`, so a
  `Statifier.Chart` blob recompiles without the provider modules. These
  options only declare names: a session evaluates the chart with the
  functions its own `:function_providers` option stamps
  (`Statifier.Session.start_link/2`, `Statifier.MachineState.new/2`).

  A successful compile also stamps `source` (the exact bytes passed in) and
  `compile_opts` (`opts` filtered through the closed
  `@persisted_compile_opts` allowlist, in the allowlist's own order) onto the
  returned `Machine.t()`, so it can reproduce itself later - see
  `Statifier.Machine`'s moduledoc for the invariant this keeps with
  `identity`.
  """
  @spec compile(source :: binary(), opts :: keyword()) :: {:ok, Machine.t()} | {:error, [error()]}
  def compile(source, opts \\ []) when is_binary(source) and is_list(opts) do
    opts = declare_function_names(opts)

    with {:ok, root} <- parse(source),
         {:ok, document} <- Lowering.lower(root, source),
         {:ok, document, warnings} <- Validator.validate(document, source, opts),
         {:ok, machine} <- Compiler.compile(document),
         :ok <- check_function_calls(machine, opts) do
      {:ok,
       %Machine{
         machine
         | warnings: warnings,
           identity: Identity.of_source(source, opts),
           source: source,
           compile_opts: persisted_opts(opts)
       }}
    else
      {:error, errors, _warnings} -> {:error, errors}
      other -> other
    end
  end

  # `:function_providers` and `:function_names` both declare names a chart
  # may call; this folds them into one sorted `:function_names` list, the
  # form the check below reads and the form `compile_opts` persists, and
  # drops the key when nothing is declared, so a chart compiled without
  # either option persists exactly the options it did before ADR-0078.
  @spec declare_function_names(opts :: keyword()) :: keyword()
  defp declare_function_names(opts) do
    provider_names =
      case Functions.provider_names(Keyword.get(opts, :function_providers)) do
        {:ok, names} ->
          names

        {:error, reason} ->
          raise ArgumentError, "invalid :function_providers: #{inspect(reason)}"
      end

    case Enum.uniq(Enum.sort(provider_names ++ checked_function_names(opts))) do
      [] -> Keyword.delete(opts, :function_names)
      names -> Keyword.put(opts, :function_names, names)
    end
  end

  @spec checked_function_names(opts :: keyword()) :: [String.t()]
  defp checked_function_names(opts) do
    case Keyword.get(opts, :function_names, []) do
      names when is_list(names) ->
        if Enum.all?(names, &is_binary/1),
          do: names,
          else: raise(ArgumentError, "invalid :function_names: #{inspect(names)}")

      other ->
        raise ArgumentError, "invalid :function_names: #{inspect(other)}"
    end
  end

  @spec check_function_calls(machine :: Machine.t(), opts :: keyword()) ::
          :ok | {:error, [Compiler.Error.t()]}
  defp check_function_calls(machine, opts) do
    known = MapSet.new(Functions.base_names() ++ Keyword.get(opts, :function_names, []))

    case FunctionCalls.check(machine, known) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @spec persisted_opts(opts :: keyword()) :: keyword()
  defp persisted_opts(opts),
    do: for(key <- @persisted_compile_opts, Keyword.has_key?(opts, key), do: {key, opts[key]})

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
