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

  ## The binary contract

  `to_binary/1` and `from_binary/1` (ADR-0057) give a recording a versioned
  binary envelope: `{:statifier_recording, format_version, chart_blob, opts,
  entries}`. Five slots -

    - `format_version` - this module's own version tag, checked before the
      nested chart is touched (ADR-0057 decision 4): a future format this
      build cannot read reports as a version mismatch rather than failing
      confusingly further in.
    - `chart_blob` - `machine` travels as a nested `Statifier.Chart.to_binary/1`
      blob, never a compiled term (ADR-0014 item 2, ADR-0052 decision 3).
      `from_binary/1` recompiles it through `Chart.from_binary/1`, which
      checks its own format version and its own recompiled identity in its
      own order - a chart-format bump is therefore never forced to be a
      recording-format bump, or the reverse (ADR-0057 decision 3). A nested
      chart failure surfaces wrapped as `{:error, {:chart, reason}}` rather
      than flattened, so the caller always knows which decoder refused.
    - `opts` - the normalized session options, with `:invoke_handlers`
      written as module name strings rather than atoms.
    - `entries` - written in `entries/1`'s append order, not the struct
      field's internal reversed order; that reversal is a prepend-list
      storage optimization this module alone knows about (decision 1 is what
      makes restoring it on decode legal), and a blob that copied the raw
      field would bake that implementation detail into the format.

  `:invoke_handlers` cross the boundary as strings, never as atoms, because
  `:safe` decoding refuses to create atoms a blob names and a module's atom
  exists on a node only once that module is loaded (ADR-0052's Consequences,
  ADR-0057 decision 5). `from_binary/1` resolves every string back with
  `String.to_existing_atom/1`, collecting every failure - not just the first
  - into `{:error, {:unknown_handler_modules, names}}`, sorted, so a host
  learns the whole set of modules it needs to load in one round trip.

  What the codec does not, and cannot, verify: that a resolved handler
  module's planning callbacks (ADR-0051 decision 4) behave the way they did
  when the recording was made. Replay's determinism depends on that
  equivalence for any recording naming a handler, and ADR-0057 decision 5
  records it as an accepted environmental limit - the same class as
  ADR-0034's OTP `MapSet`-iteration caveat - rather than something a codec
  could check. `perform/2`, the impure half of a handler, is never called by
  replay at all (`lib/statifier/replay.ex`), so it needs no equivalence.
  """

  alias Statifier.{Chart, Effect, Event, Machine}
  alias Statifier.Event.Cause
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

  @normalized_opts [
    :session_id,
    :trace,
    :datamodel,
    :max_macrostep_rounds,
    :routes,
    :invoke_types,
    :invoke_handlers
  ]

  @format_version 1

  # `@sobelow_skip` is read out of this file's AST by Sobelow, never at
  # runtime, so the compiler sees an attribute that is set and never used and
  # rejects the build under `--warnings-as-errors`. Registering it as
  # persisted is what makes it a declaration rather than dead code; see its
  # one use site below, and .sobelow-conf for the mechanism (the same one
  # `lib/statifier/chart.ex` already uses).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc """
  Starts an empty recording over `machine`, normalizing `opts` to exactly
  `:session_id`, `:trace`, `:datamodel`, `:max_macrostep_rounds`, `:routes`,
  `:invoke_types`, and `:invoke_handlers` (`Statifier.MachineState.new/2`'s
  own options, plus `Statifier.Session.start_link/2`'s `:invoke_handlers`),
  defaulted the same way those are defaulted, and sorted by key so two
  recordings of the same run compare equal regardless of the order their
  options were supplied in. `:routes` defaults to `nil` - the
  session-start initialization's snapshot (see the moduledoc's "route
  snapshot" section). `:invoke_types` defaults to `nil` too - ADR-0051's
  registered-type set, recorded once as a normalized option rather than per
  entry, since it is fixed for the session's whole lifetime rather than
  re-stamped per drive the way `:routes` is. `:invoke_handlers` defaults to
  `%{}`, matching `start_link/2`'s own default - it joins `:invoke_types`
  here (ADR-0051 decision 4) so a type registered during recording is not
  re-classified as unregistered on replay: `Statifier.Replay`'s plan
  context is built from this recorded map, not from an empty one.

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
      |> Keyword.put_new(:invoke_types, nil)
      |> Keyword.put_new(:invoke_handlers, %{})
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

  @doc """
  The version tag `to_binary/1` writes and `from_binary/1` checks. A bare
  integer, so a future format change is a version bump here rather than an
  inference from the blob's shape.
  """
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc """
  Encodes `recording` as a tagged, versioned binary envelope carrying its
  chart as a nested `Statifier.Chart.to_binary/1` blob, its normalized
  `opts` (with `:invoke_handlers` written as module name strings), and its
  `entries/1` in append order - never a compiled term (see the moduledoc's
  "The binary contract" section).

  Returns `{:error, :unidentified_chart}` exactly when `Chart.to_binary/1`
  refuses `recording`'s `machine` - a recording made over a `Machine` built
  without `Statifier.compile/2` (so carrying no `identity` and no `source`)
  has nothing for a future `from_binary/1` to recompile from or check
  against, so no blob is produced for it at all. Recording and replaying
  such a session in memory is unaffected; only persistence is refused.
  """
  @spec to_binary(recording :: t()) :: {:ok, binary()} | {:error, :unidentified_chart}
  def to_binary(%__MODULE__{machine: machine, opts: opts} = recording) do
    with {:ok, chart_blob} <- Chart.to_binary(machine) do
      {:ok,
       :erlang.term_to_binary(
         {:statifier_recording, @format_version, chart_blob, encode_opts(opts),
          entries(recording)}
       )}
    end
  end

  @doc """
  Decodes a `to_binary/1` envelope back into a `t()`.

  Checks run in this order: the envelope's own format version, then the
  nested chart (recompiled and identity-checked by `Chart.from_binary/1`),
  then handler-module resolution - version first because it is checked
  before the nested chart is touched (ADR-0057 decision 4), chart before
  handlers by this project's own plan default (OQ-1).

  `{:error, {:chart, reason}}` carries `Chart.from_binary/1`'s own error
  tuple unflattened - two envelopes means two version namespaces, and an
  unwrapped `{:unsupported_format_version, v}` would not say which decoder
  refused.

  `{:error, {:unknown_handler_modules, names}}` collects every unresolvable
  handler-module name in one round trip, sorted - not just the first - so a
  host learns the whole set of modules it must load before it can decode
  this blob.

  Returns `{:error, :not_a_statifier_blob}` for anything that is not this
  module's tagged envelope - a foreign `term_to_binary` blob, garbage bytes,
  or a well-formed envelope whose `chart_blob` is not a binary or whose
  `opts`/`entries` are not lists.
  """
  @spec from_binary(blob :: binary()) ::
          {:ok, t()}
          | {:error, :not_a_statifier_blob}
          | {:error, {:unsupported_format_version, term()}}
          | {:error, {:chart, term()}}
          | {:error, {:unknown_handler_modules, [String.t()]}}
  def from_binary(blob) when is_binary(blob) do
    case safe_decode(blob) do
      {:ok, {:statifier_recording, version, chart_blob, opts, entries}}
      when is_binary(chart_blob) and is_list(opts) and is_list(entries) ->
        with :ok <- check_version(version),
             {:ok, machine} <- decode_chart(chart_blob),
             {:ok, opts} <- decode_opts(opts) do
          {:ok, %__MODULE__{machine: machine, opts: opts, entries: Enum.reverse(entries)}}
        end

      _other ->
        {:error, :not_a_statifier_blob}
    end
  end

  @spec check_version(version :: term()) :: :ok | {:error, {:unsupported_format_version, term()}}
  defp check_version(@format_version), do: :ok
  defp check_version(version), do: {:error, {:unsupported_format_version, version}}

  @spec decode_chart(chart_blob :: binary()) :: {:ok, Machine.t()} | {:error, {:chart, term()}}
  defp decode_chart(chart_blob) do
    case Chart.from_binary(chart_blob) do
      {:ok, machine} -> {:ok, machine}
      {:error, reason} -> {:error, {:chart, reason}}
    end
  end

  defp encode_opts(opts) do
    Keyword.replace_lazy(opts, :invoke_handlers, fn handlers ->
      Map.new(handlers, fn {type, module} -> {type, Atom.to_string(module)} end)
    end)
  end

  @spec decode_opts(opts :: keyword()) ::
          {:ok, keyword()} | {:error, {:unknown_handler_modules, [String.t()]}}
  defp decode_opts(opts) do
    case Keyword.fetch(opts, :invoke_handlers) do
      {:ok, handlers} -> resolve_handlers(opts, handlers)
      :error -> {:ok, opts}
    end
  end

  @spec resolve_handlers(opts :: keyword(), handlers :: map()) ::
          {:ok, keyword()} | {:error, {:unknown_handler_modules, [String.t()]}}
  defp resolve_handlers(opts, handlers) do
    {resolved, unknown} =
      Enum.reduce(handlers, {%{}, []}, fn {type, name}, {resolved, unknown} ->
        case existing_atom(name) do
          {:ok, module} -> {Map.put(resolved, type, module), unknown}
          :error -> {resolved, [handler_name(name) | unknown]}
        end
      end)

    case unknown do
      [] -> {:ok, Keyword.put(opts, :invoke_handlers, resolved)}
      names -> {:error, {:unknown_handler_modules, Enum.sort(names)}}
    end
  end

  # `String.to_existing_atom/1` has no non-raising variant, so the rescue is
  # function-level here - the same shape `safe_decode/1` below uses, rather
  # than a `try` block inline in the reduce. This is not a rescue-to-default
  # at a leaf (CLAUDE.md): `:error` is collected into a named error arm, never
  # silently substituted for a value.
  defp existing_atom(name) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  defp existing_atom(_name), do: :error

  # Keeps `{:unknown_handler_modules, [String.t()]}` honest for a doctored
  # blob whose handler map holds a non-binary value.
  defp handler_name(name) when is_binary(name), do: name
  defp handler_name(name), do: inspect(name)

  # Same rationale as `Statifier.Chart`'s own `safe_decode/1`
  # (`lib/statifier/chart.ex:162-181`): `:safe` refuses to create atoms a
  # blob names, so a hostile or corrupt blob cannot grow the atom table, and
  # `:erlang.binary_to_term/2` raises `ArgumentError` on a blob it cannot
  # decode at all, which collapses to `:error` here rather than escaping as
  # an exception.
  #
  # Sobelow's Misc.BinToTerm fires on every `binary_to_term` call site,
  # `:safe` or not, because `:safe` still decodes a fun term. Nothing here
  # ever calls what it decodes: the result is matched against one literal
  # five-tuple shape and used only as data, and anything else becomes
  # `:not_a_statifier_blob`. The skip is per-function and named, so the rest
  # of this module stays scanned - see .sobelow-conf for why the file is not
  # excluded by path instead.
  @sobelow_skip ["Misc.BinToTerm"]
  defp safe_decode(blob) do
    {:ok, :erlang.binary_to_term(blob, [:safe])}
  rescue
    ArgumentError -> :error
  end
end
