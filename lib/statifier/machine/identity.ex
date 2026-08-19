defmodule Statifier.Machine.Identity do
  @moduledoc """
  A chart's identity: a content hash taken over the SCXML source
  `Statifier.compile/2` received, plus an optional embedder-supplied name and
  version. `Statifier.compile/2` stamps one onto every `Statifier.Machine.t()`
  it produces (`Statifier.Machine.identity/1`).

  The hash is taken over the source **binary**, not the compiled
  `%Statifier.Machine{}` term: the full argument for that choice lives in
  ADR-0052 (a term-level hash would vary with compiler internals - numbering
  order, expression-compilation output - that carry no meaning to a host
  comparing chart revisions, while two byte-identical documents must always
  agree regardless of what the compiler does with them).

  Two `t()` values are the same chart only when `matches?/2` says so -
  `==/2` on the struct is deliberately not the public comparison, since a
  future field addition here should not silently change what "the same
  chart" means at every existing call site.
  """

  @enforce_keys [:content_hash]
  defstruct [:content_hash, :name, :version]

  @type t :: %__MODULE__{
          content_hash: String.t(),
          name: String.t() | nil,
          version: String.t() | nil
        }

  # `@sobelow_skip` is read out of this file's AST by Sobelow, never at
  # runtime, so the compiler sees an attribute that is set and never used and
  # rejects the build under `--warnings-as-errors`. Registering it as persisted
  # is what makes it a declaration rather than dead code; see its one use site
  # below, and .sobelow-conf for the mechanism.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @algorithm :sha256
  @format_version 1

  @doc """
  Hashes `source` and carries `opts[:chart_name]`/`opts[:chart_version]`
  alongside the hash.

  `opts` is `Statifier.compile/2`'s whole option keyword list, passed through
  unfiltered - this function reads only its own two keys and ignores every
  other one (`invoke_content_markup: true` included). That is intentional:
  narrowing this to a filtered keyword list would just move the coupling to
  this call site instead of removing it.
  """
  @spec of_source(source :: binary(), opts :: keyword()) :: t()
  def of_source(source, opts \\ []) when is_binary(source) and is_list(opts) do
    %__MODULE__{
      content_hash: "sha256:" <> Base.encode16(:crypto.hash(@algorithm, source), case: :lower),
      name: Keyword.get(opts, :chart_name),
      version: Keyword.get(opts, :chart_version)
    }
  end

  @doc """
  Whether `a` and `b` name the same chart identity. Total: `nil` on either
  side answers `false`, never `true` - two unidentified charts are not the
  same chart, and treating `nil == nil` as a match would be exactly the
  silent misread this module exists to prevent.
  """
  @spec matches?(a :: t() | nil, b :: t() | nil) :: boolean()
  def matches?(%__MODULE__{} = a, %__MODULE__{} = b), do: a == b
  def matches?(_a, _b), do: false

  @doc """
  The version tag `to_binary/1` writes and `from_binary/1` checks. A bare
  integer, so a future format change is a version bump here rather than an
  inference from the blob's shape.
  """
  @spec format_version() :: pos_integer()
  def format_version, do: @format_version

  @doc """
  Encodes `identity` as a tagged, versioned binary envelope, so a host can
  store an identity beside the source it retained for it.
  """
  @spec to_binary(identity :: t()) :: binary()
  def to_binary(%__MODULE__{} = identity),
    do: :erlang.term_to_binary({:statifier_chart_identity, @format_version, identity})

  @doc """
  Decodes a `to_binary/1` envelope back into a `t()`.

  Returns `{:error, :not_a_statifier_blob}` for anything that is not this
  module's tagged envelope - a foreign `term_to_binary` blob, garbage bytes,
  or a well-formed envelope whose payload is not a `t()` - and
  `{:error, {:unsupported_format_version, version}}` when the envelope is
  recognizably this module's own but carries a format version this build
  does not know how to read.
  """
  @spec from_binary(blob :: binary()) ::
          {:ok, t()}
          | {:error, :not_a_statifier_blob}
          | {:error, {:unsupported_format_version, term()}}
  def from_binary(blob) when is_binary(blob) do
    case safe_decode(blob) do
      {:ok, {:statifier_chart_identity, @format_version, %__MODULE__{} = identity}} ->
        {:ok, identity}

      {:ok, {:statifier_chart_identity, version, _payload}} ->
        {:error, {:unsupported_format_version, version}}

      _other ->
        {:error, :not_a_statifier_blob}
    end
  end

  # ADR-0052: `:safe` refuses to create atoms a blob names, so a hostile or
  # corrupt blob cannot grow the atom table. `:erlang.binary_to_term/2`
  # raises `ArgumentError` on a blob it cannot decode at all (truncated,
  # non-term bytes); that case carries the same meaning as a decoded term of
  # the wrong shape, so it collapses to `:error` here rather than escaping as
  # an exception.
  #
  # Sobelow's Misc.BinToTerm fires on every `binary_to_term` call site, `:safe`
  # or not, because `:safe` still decodes a fun term. Nothing here ever calls
  # what it decodes: the result is matched against one literal three-tuple
  # shape and a `%__MODULE__{}` payload, and anything else becomes
  # `:not_a_statifier_blob`. The skip is per-function and named, so the rest of
  # this module stays scanned - see .sobelow-conf for why the file is not
  # excluded by path instead.
  @sobelow_skip ["Misc.BinToTerm"]
  defp safe_decode(blob) do
    {:ok, :erlang.binary_to_term(blob, [:safe])}
  rescue
    ArgumentError -> :error
  end
end
