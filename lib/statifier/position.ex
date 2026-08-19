defmodule Statifier.Position do
  @moduledoc """
  The versioned binary contract for a *position* - a `Statifier.MachineState.t()`
  with the compiled chart it walks stripped out and its `Statifier.Machine.Identity.t()`
  carried alongside instead.

  This is boundary work, not core work (`docs/architecture.md` principle 2),
  which is why it lives here rather than as `MachineState.to_binary/1`:
  `lib/statifier/machine_state.ex` already carries the 100% Doctor moduledoc
  burden for the core position struct, and encode/decode-with-identity-check
  is a concern of persisting a position across process or machine boundaries,
  not of computing one. The substance the bead asked for - a `to_binary`/
  `from_binary` pair with an explicit format version for a `MachineState` -
  is met exactly; only the module the pair lives on differs.

  `to_binary/1` refuses to encode a `MachineState` whose `Machine` carries no
  identity (`{:error, :unidentified_chart}`): that is the structural
  guarantee that no position blob can exist that `from_binary/2` cannot
  check. `from_binary/2` decodes safely, checks the envelope's tag, checks
  its format version, checks the supplied `Machine`'s identity against the
  blob's, and only then rebuilds the `MachineState`.

  Neither function performs I/O; encoding and decoding a binary in memory is
  not an effect this module's caller has to route around (ADR-0003 does not
  apply to it, and it is not listed in `@effect_interpreter_paths`).

  ## `export/1` and `import/2`: the migration vocabulary

  `to_binary/1`/`from_binary/2` above are the same-revision contract: they
  refuse to cross a chart revision at all. `export/1` and `import/2` are the
  deliberate counterpart - a position in ADR-0005 boundary terms ("string
  IDs appear only at the API", ADR-0005's Consequences) so a host holding a
  position saved against revision A can load it onto revision B *on
  purpose*. `import/2` performs **no identity check**: it does not compare
  `export/1`'s `:identity` key to the target `Machine`'s own identity, and
  the malformed-export check does not require `:identity` to be present or
  well-formed. A host hand-editing an export may update, delete, or leave
  stale that key, and all three import identically - the key is provenance
  for a host that wants to log "migrated from revision X to revision Y", not
  a check this module performs for it.

  The exported map deliberately omits `internal_queue`, `routes`,
  `invoke_types`, and `machine`: `internal_queue` because `export/1` refuses
  a non-empty one outright (below), `routes` and `invoke_types` because both
  are per-drive/per-session snapshots a driver re-stamps before the next
  drive (ADR-0048, ADR-0051) rather than durable position state, and
  `machine` because the whole point of the string-id vocabulary is to let a
  host load the exported map onto a *different* `Machine` than the one that
  produced it. A host reading the map should not conclude any of the four
  was forgotten; `import/2` always sets `internal_queue` to a fresh empty
  queue and `routes`/`invoke_types` to `nil`, leaving both for the driver
  to re-stamp.
  """

  alias Statifier.{Machine, MachineState}
  alias Statifier.Machine.Identity

  # `@sobelow_skip` is read out of this file's AST by Sobelow, never at
  # runtime, so the compiler sees an attribute that is set and never used and
  # rejects the build under `--warnings-as-errors`. Registering it as
  # persisted is what makes it a declaration rather than dead code; see its
  # one use site below, and .sobelow-conf for the mechanism (the same one
  # `lib/statifier/machine/identity.ex` already uses).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @format_version 2

  @doc """
  The version tag `to_binary/1` writes and `from_binary/2` checks. A bare
  integer, so a future format change is a version bump here rather than an
  inference from the blob's shape.
  """
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc """
  Encodes `machine_state` as a tagged, versioned binary envelope carrying its
  chart's `Statifier.Machine.Identity.t()` - never the chart itself.

  Returns `{:error, :unidentified_chart}` when `machine_state.machine`
  carries no identity (`Statifier.Machine.identity/1` is `nil`) - a `Machine`
  built without a recorded source has nothing for `from_binary/2` to check a
  future load against, so no blob is produced for it at all.

  On success, the payload is `machine_state` as a plain map with `:machine`
  deleted - never `%{machine_state | machine: nil}`. `MachineState`'s `t()`
  declares `machine: Machine.t()`, not `Machine.t() | nil`
  (`lib/statifier/machine_state.ex:415`), so assigning `nil` there is a
  dialyzer contract violation, and dialyzer is a full-gate stage. Dropping
  `:machine` from the payload instead violates no type, keeps ADR-0014 item
  2's premise true (no `%Predicator.Compiled{}` instruction list or span
  table is ever written to a blob), and is what makes the blob far smaller
  than a naive `term_to_binary(machine_state)` - the compiled chart is the
  overwhelming majority of a small position's bytes.
  """
  @spec to_binary(machine_state :: MachineState.t()) ::
          {:ok, binary()} | {:error, :unidentified_chart}
  def to_binary(%MachineState{machine: %Machine{identity: nil}}),
    do: {:error, :unidentified_chart}

  def to_binary(%MachineState{machine: %Machine{identity: identity}} = machine_state) do
    payload = machine_state |> Map.from_struct() |> Map.delete(:machine)
    {:ok, :erlang.term_to_binary({:statifier_position, @format_version, identity, payload})}
  end

  @doc """
  Decodes a `to_binary/1` envelope and rebuilds it into a `MachineState.t()`
  walking `machine`.

  Checks run in this order, and the order matters: decode safely, then check
  the envelope's tag, then its format version, then the blob's identity
  against `machine`'s, then reattach `machine` and rebuild the struct.
  Checking the version before the identity means a future format whose
  identity representation changed reports the version mismatch rather than a
  confusing identity one.

  A version-1 blob (written before `timer_counter` existed) is read, not
  refused: its payload is upgraded with `timer_counter: 0` before the struct
  is rebuilt (ADR-0059 decision 4) - `0` is the only correct value, since no
  ordinal was ever minted against a version-1 position.

  `{:error, {:identity_mismatch, expected, actual}}`'s `expected` is the
  blob's own identity and `actual` is the supplied `machine`'s - both carried
  in the error so a host can log which chart revision it has and which one
  it needed. What to do about it is a choice between two migration
  strategies - drain the old revision, or migrate the position with
  `export/1` and `import/2` - laid out in `docs/persistence.md`. When `machine` itself carries no identity, the error is
  `{:error, :unidentified_chart}` instead: the host handed over a `Machine`
  it built without a recorded source, which is a different mistake with a
  different fix (recompile with a source, or via `Statifier.compile/2`).

  Returns `{:error, :not_a_statifier_blob}` for anything that is not this
  module's tagged envelope - a foreign `term_to_binary` blob, garbage bytes,
  or a well-formed envelope whose payload is not a map.
  """
  @spec from_binary(blob :: binary(), machine :: Machine.t()) ::
          {:ok, MachineState.t()}
          | {:error, :not_a_statifier_blob}
          | {:error, {:unsupported_format_version, term()}}
          | {:error, {:identity_mismatch, expected :: Identity.t(), actual :: Identity.t() | nil}}
          | {:error, :unidentified_chart}
  def from_binary(blob, %Machine{} = machine) when is_binary(blob) do
    case safe_decode(blob) do
      {:ok, {:statifier_position, version, identity, payload}} when is_map(payload) ->
        with :ok <- check_version(version),
             :ok <- check_identity(identity, machine) do
          upgraded_payload = upgrade_payload(version, payload)
          {:ok, struct!(MachineState, Map.put(upgraded_payload, :machine, machine))}
        end

      _other ->
        {:error, :not_a_statifier_blob}
    end
  end

  @spec check_version(version :: term()) :: :ok | {:error, {:unsupported_format_version, term()}}
  defp check_version(@format_version), do: :ok
  defp check_version(1), do: :ok
  defp check_version(version), do: {:error, {:unsupported_format_version, version}}

  # ADR-0059: a version-1 blob predates timer_counter, so no ordinal was ever
  # minted from it and 0 is the only correct value. The record blesses this
  # default rather than leaving it to taste.
  @spec upgrade_payload(version :: term(), payload :: map()) :: map()
  defp upgrade_payload(1, payload), do: Map.put_new(payload, :timer_counter, 0)
  defp upgrade_payload(@format_version, payload), do: payload

  @spec check_identity(blob_identity :: Identity.t(), machine :: Machine.t()) ::
          :ok
          | {:error, {:identity_mismatch, Identity.t(), Identity.t() | nil}}
          | {:error, :unidentified_chart}
  defp check_identity(_blob_identity, %Machine{identity: nil}), do: {:error, :unidentified_chart}

  defp check_identity(blob_identity, %Machine{identity: machine_identity}) do
    if Identity.matches?(blob_identity, machine_identity) do
      :ok
    else
      {:error, {:identity_mismatch, blob_identity, machine_identity}}
    end
  end

  @typedoc """
  The string-id boundary vocabulary `export/1` produces and `import/2`
  consumes: `configuration`, `entered_states`, and `states_to_invoke` as
  `MapSet.t(String.t())`; `history_values` as
  `%{optional(String.t()) => MapSet.t(String.t())}`; `active_invocations` as
  `%{optional({String.t(), non_neg_integer()}) => String.t()}`; the
  `invoke_counter`/`send_counter`/`timer_counter`/`datamodel`/`running`/
  `status`/`macrostep`/`microstep`/`round`/`trace`/`max_macrostep_rounds`
  fields carried verbatim
  from `MachineState.t()`; and `identity`, the source chart's
  `Statifier.Machine.Identity.t() | nil` - provenance only, per this
  module's `export/1`/`import/2` section above.
  """
  @type exported :: %{required(atom()) => term()}

  # `:identity` is deliberately absent from this list: `import/2` performs
  # no identity check at all (see this module's "`export/1` and `import/2`"
  # section above), so its presence, absence, or well-formedness is not
  # this function's concern either.
  @required_export_keys ~w(
    configuration entered_states states_to_invoke history_values
    active_invocations invoke_counter send_counter timer_counter datamodel
    running status macrostep microstep round trace max_macrostep_rounds
  )a

  @doc """
  Translates `machine_state` into the string-id migration vocabulary
  (`t:exported/0`) - the deliberate counterpart to `to_binary/1`'s refusal to
  cross a chart revision. See this module's "`export/1` and `import/2`"
  section above for what is carried, what is dropped, and why.

  Every state index in every translated field is looked up with
  `Statifier.Machine.id/2`. The root, index `0`, has no written id and is
  present in every configuration by construction (ADR-0005's full
  configuration) - and, empirically, in `entered_states` too, since the
  initial macrostep's own `enterStates` walk reaches it as an ancestor. It
  is the one exception to the rule below, dropped here wherever it appears
  and re-added by `import/2` to `configuration` and `entered_states`, the
  two fields it can structurally appear in (`states_to_invoke` can never
  hold it: only a real `<state>`'s own `<invoke>` children populate that
  field, and the root is not a `<state>`). Any *other* index for which
  `Machine.id/2` returns `nil` (a state compiled with no author-written id)
  makes the whole export refuse rather than silently drop the state:
  `{:error, {:unnameable_states, indexes}}`, sorted ascending, naming every
  offending index across every field at once.

  `active_invocations`' `invoke_index` half of each key stays the integer it
  already is - a within-state document-order ordinal over that state's own
  `<invoke>` children (`MachineState`'s own moduledoc), not itself a state
  id. It survives states being added or reordered elsewhere in the chart,
  but not an edit to that one state's own `<invoke>` children.

  Refuses a `machine_state` whose `internal_queue` is non-empty
  (`{:error, :internal_queue_not_empty}`, checked with
  `MachineState.internal_queue_empty?/1` rather than by materializing the
  list): the queued internal events were selected against the source
  chart's own transitions, so a position mid-macrostep is not a thing to
  move across chart revisions. A host drains to quiescence first.
  """
  @spec export(machine_state :: MachineState.t()) ::
          {:ok, exported()}
          | {:error, :internal_queue_not_empty}
          | {:error, {:unnameable_states, [non_neg_integer()]}}
  def export(%MachineState{} = machine_state) do
    if MachineState.internal_queue_empty?(machine_state) do
      do_export(machine_state)
    else
      {:error, :internal_queue_not_empty}
    end
  end

  @spec do_export(machine_state :: MachineState.t()) ::
          {:ok, exported()} | {:error, {:unnameable_states, [non_neg_integer()]}}
  defp do_export(%MachineState{machine: machine} = machine_state) do
    case machine_state |> referenced_indexes() |> unnameable_indexes(machine) do
      [] -> {:ok, build_exported(machine, machine_state)}
      unnameable -> {:error, {:unnameable_states, unnameable}}
    end
  end

  # Every state index this module's exported fields can hold, gathered once
  # so `unnameable_indexes/2` checks the whole export in one pass rather
  # than reporting one field's offenders and leaving a second field's for a
  # follow-up call.
  @spec referenced_indexes(machine_state :: MachineState.t()) :: MapSet.t(non_neg_integer())
  defp referenced_indexes(%MachineState{
         configuration: configuration,
         entered_states: entered_states,
         states_to_invoke: states_to_invoke,
         history_values: history_values,
         active_invocations: active_invocations
       }) do
    history_indexes =
      Enum.reduce(history_values, MapSet.new(), fn {key, value_set}, acc ->
        acc |> MapSet.put(key) |> MapSet.union(value_set)
      end)

    invocation_state_indexes =
      active_invocations
      |> Map.keys()
      |> Enum.map(fn {state_index, _invoke_index} -> state_index end)
      |> MapSet.new()

    configuration
    |> MapSet.union(entered_states)
    |> MapSet.union(states_to_invoke)
    |> MapSet.union(history_indexes)
    |> MapSet.union(invocation_state_indexes)
  end

  # Index `0` (the root) is the one documented exception - it never counts
  # as unnameable even though `Machine.id/2` is `nil` for it too.
  @spec unnameable_indexes(indexes :: MapSet.t(non_neg_integer()), machine :: Machine.t()) ::
          [non_neg_integer()]
  defp unnameable_indexes(indexes, machine) do
    indexes
    |> Enum.filter(&(&1 != 0 and is_nil(Machine.id(machine, &1))))
    |> Enum.sort()
  end

  @spec build_exported(machine :: Machine.t(), machine_state :: MachineState.t()) :: exported()
  defp build_exported(machine, %MachineState{} = machine_state) do
    %{
      identity: Machine.identity(machine),
      configuration: translate_index_set(machine, machine_state.configuration),
      entered_states: translate_index_set(machine, machine_state.entered_states),
      states_to_invoke: translate_index_set(machine, machine_state.states_to_invoke),
      history_values: translate_history_values(machine, machine_state.history_values),
      active_invocations: translate_active_invocations(machine, machine_state.active_invocations),
      invoke_counter: machine_state.invoke_counter,
      send_counter: machine_state.send_counter,
      timer_counter: machine_state.timer_counter,
      datamodel: machine_state.datamodel,
      running: machine_state.running,
      status: machine_state.status,
      macrostep: machine_state.macrostep,
      microstep: machine_state.microstep,
      round: machine_state.round,
      trace: machine_state.trace,
      max_macrostep_rounds: machine_state.max_macrostep_rounds
    }
  end

  # `Machine.id/2` is `nil` for the root, and for the root alone once
  # `do_export/1` has already refused any other nameless index - so this is
  # simultaneously "translate to a string id" and "drop the root",
  # depending on which index is asked.
  @spec translate_index_set(machine :: Machine.t(), indexes :: MapSet.t(non_neg_integer())) ::
          MapSet.t(String.t())
  defp translate_index_set(machine, indexes) do
    indexes
    |> Enum.map(&Machine.id(machine, &1))
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  @spec translate_history_values(
          machine :: Machine.t(),
          history_values :: %{optional(non_neg_integer()) => MapSet.t(non_neg_integer())}
        ) :: %{optional(String.t()) => MapSet.t(String.t())}
  defp translate_history_values(machine, history_values) do
    Enum.reduce(history_values, %{}, fn {key, value_set}, acc ->
      case Machine.id(machine, key) do
        nil -> acc
        id -> Map.put(acc, id, translate_index_set(machine, value_set))
      end
    end)
  end

  @spec translate_active_invocations(
          machine :: Machine.t(),
          active_invocations :: %{optional({non_neg_integer(), non_neg_integer()}) => String.t()}
        ) :: %{optional({String.t(), non_neg_integer()}) => String.t()}
  defp translate_active_invocations(machine, active_invocations) do
    Enum.reduce(active_invocations, %{}, fn {{state_index, invoke_index}, invoke_id}, acc ->
      case Machine.id(machine, state_index) do
        nil -> acc
        state_id -> Map.put(acc, {state_id, invoke_index}, invoke_id)
      end
    end)
  end

  @doc """
  Reverses `export/1`: resolves every string id in `exported` against
  `machine` (`Machine.index/2`) and rebuilds a `MachineState.t()` walking
  it. **Performs no identity check** - see this module's "`export/1` and
  `import/2`" section above; `exported[:identity]` is read by nobody here.

  Collects **every** unknown id before returning, rather than failing on the
  first: `{:error, {:unknown_state_ids, ids}}`, `ids` sorted ascending, so a
  host migrating a position across chart revisions sees the whole list of
  states its new revision dropped in one round trip. Re-adds the root index
  (`0`) to `configuration` and `entered_states` - the reverse of `export/1`'s
  one documented drop.

  Rebuilds `internal_queue` as `:queue.new()` and `routes`/`invoke_types` as
  `nil` - the driver re-stamps both before the next drive, exactly as
  `export/1`'s doc names them as dropped. `machine` is the supplied
  argument.

  `{:error, {:malformed_export, reason}}` covers a map missing a required
  key, or carrying a value of the wrong shape for its field - a host may
  have hand-edited the export, which is the entire point of a string-id
  vocabulary, and a value `struct!/2` would silently misassign is exactly
  what this check exists to catch instead.
  """
  @spec import(machine :: Machine.t(), exported :: exported()) ::
          {:ok, MachineState.t()}
          | {:error, {:unknown_state_ids, [String.t()]}}
          | {:error, {:malformed_export, term()}}
  def import(%Machine{} = machine, exported) when is_map(exported) do
    with :ok <- check_required_keys(exported),
         :ok <- check_shapes(exported) do
      case collect_unknown_ids(machine, exported) do
        [] -> build_machine_state(machine, exported)
        unknown -> {:error, {:unknown_state_ids, unknown}}
      end
    end
  end

  def import(_machine, exported), do: {:error, {:malformed_export, exported}}

  @spec check_required_keys(exported :: term()) :: :ok | {:error, {:malformed_export, term()}}
  defp check_required_keys(exported) do
    case Enum.reject(@required_export_keys, &Map.has_key?(exported, &1)) do
      [] -> :ok
      missing -> {:error, {:malformed_export, {:missing_keys, Enum.sort(missing)}}}
    end
  end

  @spec check_shapes(exported :: exported()) :: :ok | {:error, {:malformed_export, term()}}
  defp check_shapes(exported) do
    [
      {:configuration, &id_set?/1},
      {:entered_states, &id_set?/1},
      {:states_to_invoke, &id_set?/1},
      {:history_values, &history_values_shape?/1},
      {:active_invocations, &active_invocations_shape?/1},
      {:invoke_counter, &is_integer/1},
      {:send_counter, &is_integer/1},
      {:timer_counter, &is_integer/1},
      {:datamodel, &is_map/1},
      {:running, &is_boolean/1},
      {:status, &(&1 in [:running, :done])},
      {:macrostep, &is_integer/1},
      {:microstep, &is_integer/1},
      {:round, &is_integer/1},
      {:trace, &is_boolean/1},
      {:max_macrostep_rounds, &max_macrostep_rounds_shape?/1}
    ]
    |> Enum.find_value(:ok, fn {field, valid?} ->
      value = Map.fetch!(exported, field)
      unless valid?.(value), do: {:error, {:malformed_export, {field, value}}}
    end)
  end

  @spec id_set?(value :: term()) :: boolean()
  defp id_set?(%MapSet{} = set), do: Enum.all?(set, &is_binary/1)
  defp id_set?(_other), do: false

  @spec history_values_shape?(value :: term()) :: boolean()
  defp history_values_shape?(map) when is_map(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and id_set?(value) end)
  end

  defp history_values_shape?(_other), do: false

  @spec active_invocations_shape?(value :: term()) :: boolean()
  defp active_invocations_shape?(map) when is_map(map) do
    Enum.all?(map, fn
      {{state_id, invoke_index}, invoke_id} ->
        is_binary(state_id) and is_integer(invoke_index) and is_binary(invoke_id)

      _other ->
        false
    end)
  end

  defp active_invocations_shape?(_other), do: false

  @spec max_macrostep_rounds_shape?(value :: term()) :: boolean()
  defp max_macrostep_rounds_shape?(:infinity), do: true
  defp max_macrostep_rounds_shape?(n), do: is_integer(n) and n > 0

  @spec collect_unknown_ids(machine :: Machine.t(), exported :: exported()) :: [String.t()]
  defp collect_unknown_ids(machine, exported) do
    history_ids =
      Enum.reduce(exported.history_values, MapSet.new(), fn {key, value_set}, acc ->
        acc |> MapSet.put(key) |> MapSet.union(value_set)
      end)

    invocation_ids =
      exported.active_invocations
      |> Map.keys()
      |> Enum.map(fn {state_id, _invoke_index} -> state_id end)
      |> MapSet.new()

    MapSet.new()
    |> MapSet.union(exported.configuration)
    |> MapSet.union(exported.entered_states)
    |> MapSet.union(exported.states_to_invoke)
    |> MapSet.union(history_ids)
    |> MapSet.union(invocation_ids)
    |> Enum.filter(&(Machine.index(machine, &1) == :error))
    |> Enum.sort()
  end

  @spec build_machine_state(machine :: Machine.t(), exported :: exported()) ::
          {:ok, MachineState.t()}
  defp build_machine_state(machine, exported) do
    machine_state = %MachineState{
      machine: machine,
      configuration: resolve_index_set(machine, exported.configuration) |> MapSet.put(0),
      internal_queue: :queue.new(),
      history_values: resolve_history_values(machine, exported.history_values),
      entered_states: resolve_index_set(machine, exported.entered_states) |> MapSet.put(0),
      states_to_invoke: resolve_index_set(machine, exported.states_to_invoke),
      active_invocations: resolve_active_invocations(machine, exported.active_invocations),
      invoke_counter: exported.invoke_counter,
      send_counter: exported.send_counter,
      timer_counter: exported.timer_counter,
      datamodel: exported.datamodel,
      running: exported.running,
      status: exported.status,
      macrostep: exported.macrostep,
      microstep: exported.microstep,
      round: exported.round,
      trace: exported.trace,
      max_macrostep_rounds: exported.max_macrostep_rounds,
      routes: nil,
      invoke_types: nil
    }

    {:ok, machine_state}
  end

  # Every id reaching this function has already resolved successfully
  # (`collect_unknown_ids/2` ran first), so `Machine.index/2` cannot return
  # `:error` here.
  @spec resolve_index_set(machine :: Machine.t(), ids :: MapSet.t(String.t())) ::
          MapSet.t(non_neg_integer())
  defp resolve_index_set(machine, ids) do
    Enum.into(ids, MapSet.new(), &resolve_index!(machine, &1))
  end

  @spec resolve_index!(machine :: Machine.t(), id :: String.t()) :: non_neg_integer()
  defp resolve_index!(machine, id) do
    {:ok, index} = Machine.index(machine, id)
    index
  end

  @spec resolve_history_values(
          machine :: Machine.t(),
          history_values :: %{optional(String.t()) => MapSet.t(String.t())}
        ) :: %{optional(non_neg_integer()) => MapSet.t(non_neg_integer())}
  defp resolve_history_values(machine, history_values) do
    Map.new(history_values, fn {key, value_set} ->
      {resolve_index!(machine, key), resolve_index_set(machine, value_set)}
    end)
  end

  @spec resolve_active_invocations(
          machine :: Machine.t(),
          active_invocations :: %{optional({String.t(), non_neg_integer()}) => String.t()}
        ) :: %{optional({non_neg_integer(), non_neg_integer()}) => String.t()}
  defp resolve_active_invocations(machine, active_invocations) do
    Map.new(active_invocations, fn {{state_id, invoke_index}, invoke_id} ->
      {{resolve_index!(machine, state_id), invoke_index}, invoke_id}
    end)
  end

  # Same rationale as `Statifier.Machine.Identity`'s own `safe_decode/1`
  # (see that module for the full ADR-0052 argument): `:safe` refuses to
  # create atoms a blob names, so a hostile or corrupt blob cannot grow the
  # atom table, and `:erlang.binary_to_term/2` raises `ArgumentError` on a
  # blob it cannot decode at all, which collapses to `:error` here rather
  # than escaping as an exception.
  #
  # Sobelow's Misc.BinToTerm fires on every `binary_to_term` call site,
  # `:safe` or not, because `:safe` still decodes a fun term. Nothing here
  # ever calls what it decodes: the result is matched against one literal
  # four-tuple shape and used only as data, and anything else becomes
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
