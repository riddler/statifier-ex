defmodule Statifier.Invoke.Source do
  @moduledoc """
  Turns an `%Statifier.Effect.Invoke{}`'s `content`/`src` pair into a
  `Statifier.Machine.t()` ready to start as a child session - the seam
  ADR-0038 decided: **the library never dereferences `src`.**

  Spec 6.4.2 treats the two identically ("these services MUST treat values
  specified by 'src' and `<content>` identically"), but they cannot share
  one resolution path. `content` reaching this module has already been
  resolved by the pure core (`Statifier.Effect.Invoke`'s own moduledoc);
  when it is a binary, 6.4.2 requires an SCXML-typed service to "interpret
  [it]... as markup to be executed", and `Statifier.compile/2` is exactly
  that interpretation - called here with `invoke_content_markup: true`
  (ADR-0042), the one call site in the pipeline that sets it, since this is
  the one place a `Document.Content` markup slice or expr-delivered markup
  binary is ever compiled standalone. `src` names a resource the core never
  fetches
  (ADR-0031); resolving it is handed to an embedder-supplied function,
  never performed here, on the same security posture ADR-0024 already
  applies to `<data src>` - a document-named URI dereferenced by the engine
  by default is a request-forgery surface handed to whoever writes the
  document.

  `content` is checked before `src` when a document specifies both: 6.4
  treats the two as interchangeable, so a document naming both is already
  non-conformant, and there is no ordering rule this module could violate
  by picking one over the other.

  Every `{:error, _}` this module returns is the session's cue to raise
  `error.communication` (spec 3.12.2) on the parent and abandon the
  invocation without writing a table entry - this module has no opinion on
  how that error is delivered; it only decides whether a `Machine.t()` can
  be produced at all.
  """

  alias Statifier.Effect.Invoke
  alias Statifier.Machine

  @typedoc """
  Why a source could not be resolved into a `Machine.t()`:

  - `{:compile, errors}` - `content` was markup that failed to compile
    (`Statifier.compile/2`'s own error list).
  - `:src_not_resolved` - `src` was present but no `invoke_source` resolver
    was configured.
  - `{:content_not_markup, content}` - `content` was present but neither
    `nil` nor a binary (a value-shaped `<content>`, 5.6's other case,
    naming nothing an SCXML-typed service can start).
  - `:no_source` - neither `src` nor `content` was present.

  An embedder-supplied `invoke_source` resolver's own `{:error, reason}` is
  returned unchanged, so its `reason` shape is not enumerated here.
  """
  @type reason ::
          {:compile, [Statifier.error()]}
          | :src_not_resolved
          | {:content_not_markup, term()}
          | :no_source
          | term()

  @doc """
  Resolves `invoke`'s `content`/`src` into a `Machine.t()`. `opts[:invoke_source]`,
  when given, is a `(src :: String.t() -> {:ok, Machine.t()} | {:error, term()})`
  function an embedder supplies to `Statifier.start_session/2`; with no
  resolver configured, a `src`-only invocation is `{:error,
  :src_not_resolved}` rather than a fetch attempt.

  `content`, when a binary, compiles with `invoke_content_markup: true`
  (ADR-0042) - the one call site in the whole pipeline that sets this
  `Statifier.compile/2` option, so a namespace-less `<content>` markup root
  compiles here exactly as G.6 places it, and nowhere else relaxes that
  check.
  """
  @spec resolve(invoke :: Invoke.t(), opts :: keyword()) ::
          {:ok, Machine.t()} | {:error, reason()}
  def resolve(%Invoke{content: content}, _opts) when is_binary(content) do
    case Statifier.compile(content, invoke_content_markup: true) do
      {:ok, machine} -> {:ok, machine}
      {:error, errors} -> {:error, {:compile, errors}}
    end
  end

  def resolve(%Invoke{content: nil, src: src}, opts) when is_binary(src) do
    case Keyword.get(opts, :invoke_source) do
      resolver when is_function(resolver, 1) -> resolver.(src)
      nil -> {:error, :src_not_resolved}
    end
  end

  def resolve(%Invoke{content: nil, src: nil}, _opts) do
    {:error, :no_source}
  end

  # No guard needed: `content: nil` is already fully handled by the two
  # clauses above (`is_binary(src)` and `src: nil` between them exhaust
  # `src`'s `String.t() | nil` type), and `is_binary(content)` is fully
  # handled by the `resolve/2` clause above that. Whatever reaches here has
  # `content` present and not a binary - `content` is `term()`, so that is
  # not expressible as a structural pattern the way a `String.t() | nil`
  # field would be.
  def resolve(%Invoke{content: content}, _opts) do
    {:error, {:content_not_markup, content}}
  end
end
