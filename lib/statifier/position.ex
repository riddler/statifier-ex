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

  @format_version 1

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

  `{:error, {:identity_mismatch, expected, actual}}`'s `expected` is the
  blob's own identity and `actual` is the supplied `machine`'s - both carried
  in the error so a host can log which chart revision it has and which one
  it needed. When `machine` itself carries no identity, the error is
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
          {:ok, struct!(MachineState, Map.put(payload, :machine, machine))}
        end

      _other ->
        {:error, :not_a_statifier_blob}
    end
  end

  @spec check_version(version :: term()) :: :ok | {:error, {:unsupported_format_version, term()}}
  defp check_version(@format_version), do: :ok
  defp check_version(version), do: {:error, {:unsupported_format_version, version}}

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
