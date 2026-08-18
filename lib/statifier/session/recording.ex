defmodule Statifier.Session.Recording do
  @moduledoc """
  The four-input replay recording (ADR-0029), as a value.

  A recording holds exactly what a replay needs to reconstruct a run:

    - `machine` - the compiled document a session was started over
      (`Statifier.Machine`, the output of `Statifier.compile/1`).
    - `opts` - the normalized options `Statifier.Session.start_link/2` would
      have passed to `Statifier.MachineState.new/2`: `:session_id`, `:trace`,
      `:datamodel`, and `:max_macrostep_rounds`, defaulted and sorted so two
      recordings of the same run compare equal.
    - `entries` - the delivered events, timer firings, cancel markers, and
      `interpret/2` batches, in the session's serialized input order.

  Together, `machine` and the first entry's implicit initialization plus the
  rest of `entries` are the whole of what a run needs to be reproduced -
  nothing else about a session (its pid, its subscribers, its live timer
  references) is part of a recording, because none of it is an input; all of
  it is either derived or process-shaped.

  ## The route snapshot rides on the entry, not as a fifth input

  ADR-0048 decision 2 has the caller stamp a `Statifier.Send.Routes.t()`
  snapshot onto `%MachineState{}` before every core drive; decision 3 has
  each recorded entry that triggers a drive carry the snapshot that drive was
  judged against. This is an *attribute* of an existing entry, not a new
  recording input and not a new entry kind - ADR-0029's four inputs
  (`machine`, `opts`, and the two entry-producing kinds it already named) are
  unchanged in kind. Every `entry()` variant therefore widens by one trailing
  `Statifier.Send.Routes.t() | nil` field, including `:cancel`, which becomes
  `{:cancel, routes}` rather than a bare atom: a cancel drives
  `Statifier.Interpreter.cancel/1`, whose exit walk can run `<onexit>` blocks
  containing `<send>`, so it needs a snapshot exactly as every other drive
  does. `nil` means the driver declared nothing - the same meaning `nil`
  carries on `%MachineState{}.routes` itself - and `opts`'s own `:routes` key
  carries the snapshot in force for the implicit session-start
  initialization, riding where every other `Statifier.MachineState.new/2`
  option already rides.

  ## `:session_id` is resolved, not supplied

  A caller starting a session may never pass `:session_id` at all, letting
  `Statifier.MachineState.new/2` generate a fresh `sess_` id (ADR-0008). A
  recording still needs one concrete value stored, or replaying it would
  regenerate a *different* id and diverge from the run it is meant to
  reproduce. `new/2` therefore takes the id the session actually settled on -
  read back off `machine_state.datamodel["_sessionid"]`, exactly as
  `Statifier.Session.init/1` does - not whatever the caller passed (or did
  not pass) as an option.

  ## A batch is one entry, not several

  An `interpret/2` call hands a session a list of effects to plan and perform
  as one unit, in the same `handle_cast` that serializes every other input.
  Splitting that list into one entry per effect would lose the fact that they
  arrived together, at one position in the input order, rather than as
  several separate calls that happened to be adjacent - a distinction replay
  needs, since `Statifier.Session.Effects.plan/1` and any effect-derived
  routing decisions apply to the batch as `interpret/2` presented it. Storing
  the whole batch as `{:interpret, effects, routes}` preserves that boundary
  exactly.

  ## The timer `ref` is dropped, not recorded

  A live session mints a `make_ref/0` correlation id purely to match a fired
  `:statifier_delayed_send` message back to the `Statifier.Session.Timers`
  entry that scheduled it - a detail of how one process tracks its own
  in-flight timers, with no meaning outside that process and no reproducible
  value across runs (a fresh reference is unequal to every past one, by
  definition). What a recording needs from a firing is only its `send_id`
  (`nil` for an unnamed send) and the `Statifier.Event.t()` it delivered, so
  `put_timer/3` takes exactly those two and no reference ever reaches this
  struct.

  ## Nothing here reads a clock

  Ordering in `entries` is ordinal - each entry's position in the list - and
  that is sufficient: ADR-0034 decided that replay reproduces firing *order*
  and *relative* timing, never re-waiting the original delays, so a
  wall-clock timestamp would be a value replay is obligated to ignore.
  ADR-0029 named the four inputs a sound recording needs, and none of them is
  a clock reading. This module calls no `Process.*` or `System.*` time
  function, and the `Mix.Statifier.AdrGuard` allowlist that lets
  `Statifier.Session` alone touch wall-clock time does not name this file.
  """

  alias Statifier.Effect
  alias Statifier.Event
  alias Statifier.Event.Cause
  alias Statifier.Machine
  alias Statifier.Send.Routes

  @enforce_keys [:machine, :opts, :entries]
  defstruct [:machine, :opts, entries: []]

  @typedoc "One recorded input, in the session's serialized input order."
  @type entry ::
          {:event, Event.t(), Routes.t() | nil}
          | {:invoked_event, invoke_id :: String.t(), Event.t(), Routes.t() | nil}
          | {:cancel, Routes.t() | nil}
          | {:timer, send_id :: String.t() | nil, Event.t(), Routes.t() | nil}
          | {:interpret, [Effect.t()], Routes.t() | nil}
          | {:internal, kind :: :internal | :platform, name :: String.t(), Cause.origin(),
             opts :: keyword(), Routes.t() | nil}

  @opaque t :: %__MODULE__{
            machine: Machine.t(),
            opts: keyword(),
            entries: [entry()]
          }

  @normalized_opts [:session_id, :trace, :datamodel, :max_macrostep_rounds, :routes]

  @doc """
  Starts an empty recording over `machine`, normalizing `opts` to exactly
  `:session_id`, `:trace`, `:datamodel`, `:max_macrostep_rounds`, and
  `:routes` (`Statifier.MachineState.new/2`'s own options), defaulted the
  same way that function defaults them, and sorted by key so two recordings
  of the same run compare equal regardless of the order their options were
  supplied in. `:routes` defaults to `nil` - the session-start
  initialization's snapshot (see the moduledoc's "route snapshot" section).

  `opts[:session_id]` should be the id the session actually resolved to
  (`machine_state.datamodel["_sessionid"]`), not merely whatever the caller
  passed when starting it - see the moduledoc's "`:session_id` is resolved,
  not supplied" section.
  """
  @spec new(machine :: Machine.t(), opts :: keyword()) :: t()
  def new(%Machine{} = machine, opts \\ []) do
    normalized =
      opts
      |> Keyword.take(@normalized_opts)
      |> Keyword.put_new(:session_id, nil)
      |> Keyword.put_new(:trace, false)
      |> Keyword.put_new(:datamodel, %{})
      |> Keyword.put_new(:max_macrostep_rounds, 10_000)
      |> Keyword.put_new(:routes, nil)
      |> Enum.sort()

    %__MODULE__{machine: machine, opts: normalized, entries: []}
  end

  @doc """
  Appends a delivered external event as the next entry, carrying the
  `Statifier.Send.Routes.t()` snapshot (or `nil`) in force for the drive it
  triggers (see the moduledoc's "route snapshot" section).
  """
  @spec put_event(recording :: t(), event :: Event.t(), routes :: Routes.t() | nil) :: t()
  def put_event(%__MODULE__{entries: entries} = recording, %Event{} = event, routes) do
    %{recording | entries: [{:event, event, routes} | entries]}
  end

  @doc """
  Appends an external event one of this session's own invocations delivered,
  keyed by the `invoke_id` that delivered it - the input `Statifier.Replay`
  needs to reproduce 6.4.3's drain-time discard, which reads the entry's
  origin rather than `event.invokeid` (`Statifier.Session.Inbox`'s `entry`
  typedoc) - plus the route snapshot in force for the drive it triggers.
  """
  @spec put_invoked_event(
          recording :: t(),
          invoke_id :: String.t(),
          event :: Event.t(),
          routes :: Routes.t() | nil
        ) :: t()
  def put_invoked_event(
        %__MODULE__{entries: entries} = recording,
        invoke_id,
        %Event{} = event,
        routes
      )
      when is_binary(invoke_id) do
    %{recording | entries: [{:invoked_event, invoke_id, event, routes} | entries]}
  end

  @doc """
  Appends the cancel marker as the next entry, carrying the route snapshot in
  force for the drive it triggers - a cancel drives
  `Statifier.Interpreter.cancel/1`, whose exit walk can run `<onexit>` blocks
  containing `<send>` (see the moduledoc's "route snapshot" section).
  """
  @spec put_cancel(recording :: t(), routes :: Routes.t() | nil) :: t()
  def put_cancel(%__MODULE__{entries: entries} = recording, routes) do
    %{recording | entries: [{:cancel, routes} | entries]}
  end

  @doc """
  Appends a fired delayed-send timer as the next entry - `send_id` (`nil` for
  an unnamed send), the delivered `event`, and the route snapshot in force
  for the drive it triggers, with the live session's own correlation
  reference dropped (see the moduledoc).
  """
  @spec put_timer(
          recording :: t(),
          send_id :: String.t() | nil,
          event :: Event.t(),
          routes :: Routes.t() | nil
        ) :: t()
  def put_timer(%__MODULE__{entries: entries} = recording, send_id, %Event{} = event, routes)
      when is_binary(send_id) or is_nil(send_id) do
    %{recording | entries: [{:timer, send_id, event, routes} | entries]}
  end

  @doc """
  Appends one `interpret/2` batch as a single entry, preserving its boundary
  (see the moduledoc's "A batch is one entry" section), plus the route
  snapshot in force for the drive it triggers.
  """
  @spec put_interpret(recording :: t(), effects :: [Effect.t()], routes :: Routes.t() | nil) ::
          t()
  def put_interpret(%__MODULE__{entries: entries} = recording, effects, routes)
      when is_list(effects) do
    %{recording | entries: [{:interpret, effects, routes} | entries]}
  end

  @doc """
  Appends a `Statifier.Interpreter.deliver_internal/5` call as the next
  entry - `kind`, `name`, `origin` and `opts` exactly as
  `Statifier.Session` passed them to that seam (ADR-0039), plus the route
  snapshot in force for the drive it triggers. This is *not*
  deterministic from the recorded effect stream alone - whether a
  `#_scxml_<sessionid>` target resolved depends on which sessions were
  alive when the sending session performed its effects - so it has to be an
  input in its own right, exactly as a fired timer is (`put_timer/4`
  above). It is also the delivery path for an entirely successful
  `<send target="#_internal">`, not only for the two spec-6.2.4 failures.
  """
  @spec put_internal(
          recording :: t(),
          kind :: :internal | :platform,
          name :: String.t(),
          origin :: Cause.origin(),
          opts :: keyword(),
          routes :: Routes.t() | nil
        ) :: t()
  def put_internal(%__MODULE__{entries: entries} = recording, kind, name, origin, opts, routes)
      when kind in [:internal, :platform] and is_binary(name) and is_list(opts) do
    %{recording | entries: [{:internal, kind, name, origin, opts, routes} | entries]}
  end

  @doc "The compiled document this recording was made over."
  @spec machine(recording :: t()) :: Machine.t()
  def machine(%__MODULE__{machine: machine}), do: machine

  @doc "The normalized session options this recording was made under."
  @spec opts(recording :: t()) :: keyword()
  def opts(%__MODULE__{opts: opts}), do: opts

  @doc "Every recorded entry, in append order."
  @spec entries(recording :: t()) :: [entry()]
  def entries(%__MODULE__{entries: entries}), do: Enum.reverse(entries)

  @doc "The number of recorded entries."
  @spec size(recording :: t()) :: non_neg_integer()
  def size(%__MODULE__{entries: entries}), do: length(entries)
end
