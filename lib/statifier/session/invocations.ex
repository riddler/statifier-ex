defmodule Statifier.Session.Invocations do
  @moduledoc """
  The parent-held invocation table, as a value (ADR-0027 decision 3):
  `invokeid -> {child_session_id, pid, monitor_ref}`, plus the `autoforward`
  flag the delivery half (`{:forward, invoke_id, event}`) reads. A reverse
  index, `pid -> invoke_id`, is carried alongside so a child's own `:DOWN`
  can be resolved with no scan.

  ## A handler-backed entry (ADR-0051)

  Not every live invocation is a child session. An `<invoke>` dispatched to
  a non-`scxml` `Statifier.Invoke.Handler` (ADR-0051 decision 4) has no
  process of its own, so its entry carries `session_id: nil`, `pid: nil`,
  and `monitor_ref: nil` - there is no child to identify, hand a pid for,
  or monitor. It still carries `type` (needed to route a later
  `cancel_invoke`/`autoforward` effect back to the same handler) and
  `autoforward`, exactly like a child-session entry. `put/3` skips the
  `by_pid` reverse index for such an entry (there is no pid to index under),
  and `pop/2` skips the matching `by_pid` delete symmetrically;
  `pop_by_pid/2` needs no change at all - a pid-less entry was never
  reachable through it.

  ## Not `Statifier.MachineState.active_invocations`

  `MachineState.active_invocations` (`lib/statifier/machine_state.ex:60-87`)
  holds the *core's* view of a live invocation: `{state_index, invoke_index}
  => invoke_id`, immutable compiled-document identity, no pid, no monitor
  ref, no session id. This module holds the *session's* view: process
  identity the core never touches and never needs to. `Statifier.Session`
  builds this table on top of that one, not in place of it - the two answer
  different questions ("which invocations does Appendix D's `cancelInvoke`
  walk still see" versus "which OS process does invocation `i1` currently
  run as, and who is watching it").

  ## Pure by design (Decision 3)

  Every function here is a pure map transformation - no `Process.monitor/1`,
  no `send/2`, no `DynamicSupervisor` call. That keeps
  `Mix.Statifier.AdrGuard`'s `@effect_interpreter_paths` at exactly two
  entries: `lib/statifier/session.ex` makes every process call this table's
  data describes, and reads the result back through this module's API,
  exactly the split `Statifier.Session.Timers` and `Statifier.Session.Inbox`
  already model for delayed sends and the external queue.

  `seed_datamodel/2` lives in this module rather than a sibling for the same
  reason: it is pure, it is read only from the `{:start_child, _, _}`
  performer that also writes this table, and a third pure module for one
  function would be structure without a second caller.
  """

  alias Statifier.Machine

  @typedoc """
  What the table remembers about one live invocation - process identity the
  core never holds. `session_id` is the child's own `sess_` UXID, read back
  once the child has started; `pid`/`monitor_ref` are the parent's own
  handle on it; `autoforward` is the `<invoke autoforward>` attribute,
  copied off `Statifier.Effect.Invoke` at start time; `type` is the
  `<invoke type>` value itself - `Statifier.Session` writes it into every
  entry it records, a built-in `scxml` entry included, so an
  `invoke_handlers` map that explicitly overrides the literal `"scxml"`
  type is honored on cancel/forward the same way it already is on start.
  The key can still be absent (`optional/1`) on an entry built by older
  code or by hand in a test; `Statifier.Session.Effects.plan_one`'s own
  dispatch treats that the same as an unrecorded type, defaulting to the
  built-in handler. `session_id`, `pid`, and `monitor_ref` are `nil` for a
  handler-backed entry (see the moduledoc's "A handler-backed entry"
  section) - there is no child process behind it. `caller_context` is
  ADR-0063's opaque host slot as the `%Statifier.Effect.Invoke{}` that
  started this invocation carried it - the invoking event's own term,
  copied off the effect at record time and handed back, unread, on the
  answer events `Statifier.Invoke.Answer` builds (ADR-0063's 2026-09-02
  decision note). Like `:type`, the key can be absent on an entry built by
  older code or by hand in a test, which `caller_context/2` reads the same
  as an attached `nil`.
  """
  @type entry :: %{
          optional(:type) => String.t() | nil,
          optional(:caller_context) => term(),
          session_id: String.t() | nil,
          pid: pid() | nil,
          monitor_ref: reference() | nil,
          autoforward: boolean()
        }

  @enforce_keys [:entries, :by_pid]
  defstruct [:entries, :by_pid]

  @opaque t :: %__MODULE__{
            entries: %{String.t() => entry()},
            by_pid: %{pid() => String.t()}
          }

  @doc "An empty invocation table."
  @spec new() :: t()
  def new, do: %__MODULE__{entries: %{}, by_pid: %{}}

  @doc """
  Records `entry` under `invoke_id`, and indexes it under `entry.pid` in the
  reverse map - skipped when `entry.pid` is `nil` (a handler-backed entry,
  see the moduledoc's "A handler-backed entry" section), since there is no
  pid to index under. A second `put/3` for the same `invoke_id` (an
  author-written `id` on a re-entered `<invoke>`, Decision 6's residual)
  overwrites the first entry in both maps rather than merging with it.
  """
  @spec put(invocations :: t(), invoke_id :: String.t(), entry :: entry()) :: t()
  def put(%__MODULE__{entries: entries, by_pid: by_pid}, invoke_id, %{pid: pid} = entry)
      when is_binary(invoke_id) do
    by_pid = if pid, do: Map.put(by_pid, pid, invoke_id), else: by_pid
    %__MODULE__{entries: Map.put(entries, invoke_id, entry), by_pid: by_pid}
  end

  @doc "Looks up `invoke_id`'s entry, `:error` when it names nothing live."
  @spec fetch(invocations :: t(), invoke_id :: String.t()) :: {:ok, entry()} | :error
  def fetch(%__MODULE__{entries: entries}, invoke_id), do: Map.fetch(entries, invoke_id)

  @doc """
  Removes `invoke_id`'s entry from both maps, returning it (`nil` when it
  named nothing live) alongside the table with it gone. The `by_pid` delete
  is skipped, symmetrically with `put/3`, when the popped entry's `pid` is
  `nil` (a handler-backed entry never occupied `by_pid` to begin with).
  """
  @spec pop(invocations :: t(), invoke_id :: String.t()) :: {entry() | nil, t()}
  def pop(%__MODULE__{entries: entries, by_pid: by_pid} = invocations, invoke_id) do
    case Map.pop(entries, invoke_id) do
      {nil, ^entries} ->
        {nil, invocations}

      {%{pid: nil} = entry, rest_entries} ->
        {entry, %__MODULE__{entries: rest_entries, by_pid: by_pid}}

      {%{pid: pid} = entry, rest_entries} ->
        {entry, %__MODULE__{entries: rest_entries, by_pid: Map.delete(by_pid, pid)}}
    end
  end

  @doc """
  Removes whichever entry `pid` names, by the reverse index, returning
  `{invoke_id, entry}` (`nil` when `pid` names nothing live) alongside the
  table with it gone. What a child's own `:DOWN` resolves through.
  """
  @spec pop_by_pid(invocations :: t(), pid :: pid()) ::
          {{String.t(), entry()} | nil, t()}
  def pop_by_pid(%__MODULE__{by_pid: by_pid} = invocations, pid) do
    case Map.pop(by_pid, pid) do
      {nil, ^by_pid} ->
        {nil, invocations}

      {invoke_id, rest_by_pid} ->
        {entry, rest_entries} = Map.pop(invocations.entries, invoke_id)
        {{invoke_id, entry}, %__MODULE__{entries: rest_entries, by_pid: rest_by_pid}}
    end
  end

  @doc "Whether `invoke_id` names a live invocation - the discard predicate a later phase drains against."
  @spec live?(invocations :: t(), invoke_id :: String.t()) :: boolean()
  def live?(%__MODULE__{entries: entries}, invoke_id), do: Map.has_key?(entries, invoke_id)

  @doc "Every live invoke id, in no particular order."
  @spec invoke_ids(invocations :: t()) :: [String.t()]
  def invoke_ids(%__MODULE__{entries: entries}), do: Map.keys(entries)

  @doc "The whole `invoke_id => entry` map."
  @spec entries(invocations :: t()) :: %{String.t() => entry()}
  def entries(%__MODULE__{entries: entries}), do: entries

  @doc """
  `invoke_id`'s inherited caller context, `nil` when the id names nothing
  live or when its entry predates the key (ADR-0063's 2026-09-02 decision
  note). Both misses read the same because both mean the same thing to a
  caller: no context is attached, which ADR-0063 decision 1 makes an
  ordinary value rather than an error. A resumed session's table is rebuilt
  empty (ADR-0060), so an answer delivered after a resume reads `nil` here
  too, and a host that wants the term across a resume threads it itself,
  the process-less way `docs/persistence.md` describes.
  """
  @spec caller_context(invocations :: t(), invoke_id :: String.t()) :: term()
  def caller_context(%__MODULE__{entries: entries}, invoke_id) do
    case Map.fetch(entries, invoke_id) do
      {:ok, entry} -> Map.get(entry, :caller_context)
      :error -> nil
    end
  end

  @doc """
  Every live invocation's own `type`, `invoke_id => type` - what
  `Statifier.Session.Effects.plan_one` looks a `cancel_invoke`/
  `autoforward` effect's handler module up in (ADR-0051 decision 6). Every
  entry `Statifier.Session` writes carries `type` (a built-in `scxml`
  entry's own literal `type` string included, not omitted - so an
  `invoke_handlers` map that explicitly overrides `"scxml"` is still
  honored on cancel/forward, not just on start), but an entry built by
  older code or by hand in a test can still leave the key off; such an
  entry is left out of this projection entirely rather than included with
  a `nil` value, so the caller's own `Map.get(_, invoke_id,
  ScxmlHandler)`-shaped default does the same work either way.
  """
  @spec types(invocations :: t()) :: %{String.t() => String.t()}
  def types(%__MODULE__{entries: entries}) do
    for {invoke_id, %{} = entry} <- entries,
        type = Map.get(entry, :type),
        not is_nil(type),
        into: %{},
        do: {invoke_id, type}
  end

  @typedoc """
  The public projection of one live invocation - `invoke_id` plus the child's
  own session id and pid, and deliberately not the parent's `monitor_ref` or
  the `<invoke autoforward>` flag (ADR-0050 decision 1).
  """
  @type public_entry :: %{invoke_id: String.t(), session_id: String.t(), pid: pid()}

  @doc """
  Every live invocation as its public projection, sorted by `invoke_id` - a
  stable order across reads, which `invoke_ids/1`'s map-key order is not
  (ADR-0050 decision 1).
  """
  @spec list(invocations :: t()) :: [public_entry()]
  def list(%__MODULE__{entries: entries}) do
    entries
    |> Enum.map(fn {invoke_id, %{session_id: session_id, pid: pid}} ->
      %{invoke_id: invoke_id, session_id: session_id, pid: pid}
    end)
    |> Enum.sort_by(& &1.invoke_id)
  end

  @doc "The number of live invocations."
  @spec count(invocations :: t()) :: non_neg_integer()
  def count(%__MODULE__{entries: entries}), do: map_size(entries)

  @doc """
  6.4.3's name-matched seeding: keeps only those keys of `params` (the
  `Statifier.Effect.Invoke` struct's already-coerced `<param>`/namelist map)
  that match a top-level `<data>` id of `child_machine`, and drops the rest -
  "If the names do not match, the Processor MUST NOT add the value."

  `params` is `:undefined` - "no data", ADR-0037's sentinel - when the
  invocation carried no `<param>`/namelist at all
  (`Statifier.EventData.coerce({:params, []})`'s own empty-is-`:undefined`
  rule). That seeds nothing, the same as an empty map would. `nil` is
  accepted for the same outcome but means predicator's *null* rather than
  absence, and no coercion produces it here.
  """
  @spec seed_datamodel(params :: map() | :undefined | nil, child_machine :: Machine.t()) :: map()
  def seed_datamodel(:undefined, %Machine{}), do: %{}
  def seed_datamodel(nil, %Machine{}), do: %{}

  def seed_datamodel(params, %Machine{} = child_machine) when is_map(params) do
    data_ids =
      child_machine
      |> Machine.at(0)
      |> Map.fetch!(:data)
      |> Enum.map(&Machine.data(child_machine, &1).id)
      |> MapSet.new()

    Map.filter(params, fn {name, _value} -> MapSet.member?(data_ids, name) end)
  end
end
