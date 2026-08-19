defmodule Statifier.Chart do
  @moduledoc """
  The versioned binary contract for a *chart* - a `Statifier.Machine.t()`
  reduced to the inputs that reproduce it: its SCXML source, the persisted
  subset of the options it was compiled with, and its
  `Statifier.Machine.Identity.t()`. No compiled term is written - `from_binary/1`
  rebuilds a `Machine.t()` by recompiling the stored source with the stored
  options through `Statifier.compile/2`, the same pipeline any other caller
  runs, rather than by deserializing compiler output directly.

  This is boundary work, not core work (`docs/architecture.md` principle 2),
  and it could not live on `Machine` even if that boundary argument were set
  aside: `from_binary/1` calls `Statifier.compile/2` to rebuild its result,
  and `Statifier.compile/2` itself builds a `Machine.t()` (ADR-0003's
  layering - the thing produced does not call back into its own producer).
  Putting the pair here instead keeps the dependency pointing one direction:
  `Statifier.Chart` depends on `Statifier` and `Statifier.Machine`, never the
  reverse. It also keeps `lib/statifier/machine.ex`'s moduledoc - already
  carrying the full 100% Doctor burden for the compiled struct itself - free
  of a second concern (persisting a chart across a process or storage
  boundary) that has nothing to do with what the struct means once compiled.

  `to_binary/1` refuses to encode a `Machine` carrying no `identity` or no
  `source` (`{:error, :unidentified_chart}`): a `Machine` built without
  either has nothing for a future `from_binary/1` to recompile from or check
  against, so no blob is produced for it at all. `from_binary/1` decodes
  safely, checks the envelope's tag and shape, checks its format version,
  recompiles the stored source under the stored options, and only then
  compares the recompiled `Machine`'s identity against the blob's - in that
  order, for the same reason `Statifier.Position` checks version before
  identity: a future format whose identity representation changed should
  report the version mismatch, not a confusing identity one.

  Neither function performs I/O; encoding and decoding a binary in memory,
  and recompiling source already held in memory, are not effects a caller
  has to route around (ADR-0003 does not apply here, and this module is not
  listed in `@effect_interpreter_paths`).
  """

  alias Statifier.Machine
  alias Statifier.Machine.Identity

  # `@sobelow_skip` is read out of this file's AST by Sobelow, never at
  # runtime, so the compiler sees an attribute that is set and never used and
  # rejects the build under `--warnings-as-errors`. Registering it as
  # persisted is what makes it a declaration rather than dead code; see its
  # one use site below, and .sobelow-conf for the mechanism (the same one
  # `lib/statifier/position.ex` already uses).
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @format_version 1

  @doc """
  The version tag `to_binary/1` writes and `from_binary/1` checks. A bare
  integer, so a future format change is a version bump here rather than an
  inference from the blob's shape.
  """
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc """
  Encodes `machine` as a tagged, versioned binary envelope carrying its SCXML
  `source`, its persisted `compile_opts`, and its `Statifier.Machine.Identity.t()`
  - never a compiled term.

  Returns `{:error, :unidentified_chart}` when `machine.identity` or
  `machine.source` is `nil` - a `Machine` built without either (for instance
  one that came straight from `Statifier.Compiler.compile/1` rather than
  `Statifier.compile/2`) has nothing for `from_binary/1` to recompile from or
  check a future load against, so no blob is produced for it at all.

  The payload is `machine.source` and `machine.compile_opts` verbatim, never
  `machine` itself - the whole point of this module is that a chart's binary
  form holds nothing `Statifier.compile/2` cannot reproduce, which is what
  keeps the blob far smaller than `term_to_binary(machine)` for the same
  chart: the compiled states, transitions, and expressions are the
  overwhelming majority of a `Machine`'s bytes.
  """
  @spec to_binary(machine :: Machine.t()) :: {:ok, binary()} | {:error, :unidentified_chart}
  def to_binary(%Machine{identity: nil}), do: {:error, :unidentified_chart}
  def to_binary(%Machine{source: nil}), do: {:error, :unidentified_chart}

  def to_binary(%Machine{identity: identity, source: source, compile_opts: opts}) do
    {:ok, :erlang.term_to_binary({:statifier_chart, @format_version, identity, source, opts})}
  end

  @doc """
  Decodes a `to_binary/1` envelope and recompiles it into a `Machine.t()`.

  Checks run in this order, and the order matters: decode safely, then check
  the envelope's tag and shape, then its format version, then recompile the
  stored source under the stored options through `Statifier.compile/2`, then
  compare the recompiled `Machine`'s identity against the blob's own. Version
  before recompile before identity, because the identity being checked is
  the *recompiled* `Machine`'s - there is no identity to compare until the
  recompile has run, and a version this build cannot read at all should
  report as a version mismatch rather than failing to compile for reasons
  that have nothing to do with the source.

  `{:error, {:compile_failed, errors}}` carries `Statifier.compile/2`'s own
  `[Statifier.error()]` list unchanged - a blob whose source no longer
  compiles under this build (for instance a validator check tightened across
  a library upgrade) is a real, distinct failure and must not be flattened
  into `:not_a_statifier_blob`.

  `{:error, {:identity_mismatch, expected, actual}}`'s `expected` is the
  blob's own stored identity and `actual` is the recompiled `Machine`'s -
  Position's own argument order. Both are compared with
  `Statifier.Machine.Identity.matches?/2`, never `==/2` on the struct
  (ADR-0052 decision 1): a future identity field addition should not
  silently change what "the same chart" means at this call site either.

  Returns `{:error, :not_a_statifier_blob}` for anything that is not this
  module's tagged envelope - a foreign `term_to_binary` blob, garbage bytes,
  or a well-formed envelope whose source is not a binary or whose opts are
  not a keyword list.
  """
  @spec from_binary(blob :: binary()) ::
          {:ok, Machine.t()}
          | {:error, :not_a_statifier_blob}
          | {:error, {:unsupported_format_version, term()}}
          | {:error, {:compile_failed, [Statifier.error()]}}
          | {:error, {:identity_mismatch, expected :: Identity.t(), actual :: Identity.t() | nil}}
  def from_binary(blob) when is_binary(blob) do
    case safe_decode(blob) do
      {:ok, {:statifier_chart, version, identity, source, opts}}
      when is_binary(source) and is_list(opts) ->
        with :ok <- check_version(version),
             {:ok, machine} <- recompile(source, opts) do
          check_identity(identity, machine)
        end

      _other ->
        {:error, :not_a_statifier_blob}
    end
  end

  @spec check_version(version :: term()) :: :ok | {:error, {:unsupported_format_version, term()}}
  defp check_version(@format_version), do: :ok
  defp check_version(version), do: {:error, {:unsupported_format_version, version}}

  @spec recompile(source :: binary(), opts :: keyword()) ::
          {:ok, Machine.t()} | {:error, {:compile_failed, [Statifier.error()]}}
  defp recompile(source, opts) do
    case Statifier.compile(source, opts) do
      {:ok, machine} -> {:ok, machine}
      {:error, errors} -> {:error, {:compile_failed, errors}}
    end
  end

  @spec check_identity(blob_identity :: Identity.t(), machine :: Machine.t()) ::
          {:ok, Machine.t()}
          | {:error, {:identity_mismatch, Identity.t(), Identity.t() | nil}}
  defp check_identity(blob_identity, %Machine{identity: machine_identity} = machine) do
    if Identity.matches?(blob_identity, machine_identity) do
      {:ok, machine}
    else
      {:error, {:identity_mismatch, blob_identity, machine_identity}}
    end
  end

  # Same rationale as `Statifier.Position`'s own `safe_decode/1` (see that
  # module and `Statifier.Machine.Identity` for the full ADR-0052 argument):
  # `:safe` refuses to create atoms a blob names, so a hostile or corrupt
  # blob cannot grow the atom table, and `:erlang.binary_to_term/2` raises
  # `ArgumentError` on a blob it cannot decode at all, which collapses to
  # `:error` here rather than escaping as an exception.
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
