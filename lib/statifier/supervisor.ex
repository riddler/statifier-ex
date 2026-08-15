defmodule Statifier.Supervisor do
  @moduledoc """
  The ADR-0027 session runtime: a module-based supervisor holding the
  library's named session registry and the flat dynamic supervisor sessions
  started through `Statifier.start_session/2` land on.

  ## The embedder places this, the library does not

  Statifier-ex ships no `mod:` application callback (ADR-0027 decision 1). A
  library that started processes on load would tax every host that only
  ever compiles a document, and this module names the seam ADR-0003's
  "embedders can supply their own effect interpreter" already opened: an
  embedder adds `Statifier.Supervisor` (or `{Statifier.Supervisor, []}`) to
  their own supervision tree when they want cross-session
  `#_scxml_<sessionid>` delivery (via `Statifier.start_session/2`), and
  omits it entirely when they do not. A host that never places this
  supervisor starts no session-runtime processes and pays nothing.

  ## Children, in order, under `:rest_for_one`

  1. `{Registry, keys: :unique, name: Statifier.Registry}` - `Session.init/1`
     registers under the `sess_` UXID once it is generated (`Session`'s own
     moduledoc, "`<send>` routing" section).
  2. `{DynamicSupervisor, name: Statifier.SessionSupervisor}` - the flat
     supervisor `Statifier.start_session/2` starts sessions on.

  `:rest_for_one` means a registry crash takes the `DynamicSupervisor` (and
  every session under it) down with it rather than leaving live sessions
  behind a dead registry as unreachable orphans; ADR-0027 decision 1 records
  that those sessions restart fresh rather than continuing as amnesiacs
  (each session is `restart: :temporary`, so "restart" here means the
  embedder's own supervision tree deciding what happens next, not this
  supervisor bringing a session back - see decision 4). A `DynamicSupervisor`
  crash on its own does not take the registry with it, since registrations
  belong to the session processes, not to the supervisor that started them.

  ## One instance, no `:name` option

  ADR-0027 defers multiple named runtime instances as mechanism with no
  caller. `Statifier.Registry` and `Statifier.SessionSupervisor` are fixed,
  module-qualified names; starting a second `Statifier.Supervisor` in the
  same node is a name collision, not a second isolated session population.
  Tests `start_supervised!(Statifier.Supervisor)` the same module rather
  than standing up a bespoke registry/supervisor pair.
  """

  use Supervisor

  @doc """
  Starts the session runtime. `init_arg` is unused and exists only because
  `use Supervisor` expects a `start_link/1` of this shape; pass anything
  (`[]` is conventional) or use the generated `child_spec/1` directly.
  """
  @spec start_link(init_arg :: term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Statifier.Registry},
      {DynamicSupervisor, name: Statifier.SessionSupervisor}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
