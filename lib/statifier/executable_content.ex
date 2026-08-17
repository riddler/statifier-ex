defprotocol Statifier.ExecutableContent do
  @moduledoc """
  The one dispatch point every executable-content node implements. There is
  no central `case`/`cond` anywhere in this tree that switches on a node's
  kind (`docs/architecture.md:101-105`'s named v1 mistake); a node's runtime
  behavior lives in exactly one place, this protocol's `defimpl` for that
  node's struct, in the same file as the struct itself
  (`Statifier.Machine.Content.Raise`, `Statifier.Machine.Content.Log`,
  `Statifier.Machine.Content.If`, `Statifier.Machine.Content.Foreach`). A
  future datamodel element (`<script>`) or session element
  (`<send>`/`<cancel>`/`<invoke>`) adds a struct and a `defimpl`, never a
  clause here or in the block runner.

  `Statifier.Machine.Content.If` is the first *composite* node - one that
  runs child content of its own rather than acting alone - and its own
  moduledoc is where the reasoning for folding its own children directly,
  rather than calling back into the block runner, lives.
  `Statifier.Machine.Content.Foreach` is the second composite node and
  reuses that reasoning unchanged; its own contribution is settling what
  `<if>` left open only by analogy - spec 4.6.3 states outright that a
  child failure halts "the block that contains it" too, so the three-element
  `{:error, context, reason}` form's purpose is spelled
  out in the spec text itself here, not inferred.

  ## Contract

  `execute/2` takes the compiled node and a
  `Statifier.ExecutableContent.Context.t()` and returns:

  - `{:ok, context, [Statifier.Effect.t()]}` - the node ran. `context` is the
    (possibly updated) context threading `machine_state` forward; `effects`
    are the ones this node produced, in the order it produced them. Most
    nodes emit zero or one effect, but the shape does not assume that.
  - `{:error, reason}` - the node failed. `reason` is a bare `term()`; an
    implementation never constructs a `Statifier.Event` and never raises -
    turning a failure into `error.execution` is the block runner's job, not
    a leaf's (ADR-0003's error model: "only the interpreter raises
    `error.execution`"). This keeps the errors-are-events conversion in
    exactly one place regardless of how many node kinds exist.
  - `{:error, context, reason}` - the node failed, and state it had already
    legitimately produced (queued events, datamodel writes,
    `pending_errors`) must not be discarded with it. A node returns this
    form when it has already produced state that must not be discarded with
    the failure - which is every *composite* node (one that runs child
    content), and, per ADR-0047, `<send>`: a leaf that has minted a send id
    and written `idlocation` before rejecting an invalid target or
    unsupported type. Every other leaf still returns the two-element form.

  Both error forms keep the same rule: an implementation never constructs a
  `Statifier.Event` and never raises.

  ## Effect ordering

  Effects come back from `execute/2` in the order the node itself produced
  them; the runner accumulates each node's effects onto the block's list in
  the same document order it executed the nodes, so the final list a caller
  sees is execution order, start to finish, never re-sorted.

  ## No `@fallback_to_any`

  A node struct reachable from a `c_index` that has no `execute/2`
  implementation is a compiler bug - `Machine`-is-valid-by-construction
  (`docs/architecture.md:34-37`) means such a struct should never exist at
  runtime. Leaving the fallback off turns that bug into a `Protocol.UndefinedError`
  naming the offending struct, which is a better diagnosis than any
  fallback behavior could be.
  """

  alias Statifier.Effect
  alias Statifier.ExecutableContent.Context

  @typedoc "What `execute/2` returns: success threads the context forward with any effects produced, in order; failure carries an opaque reason for the runner to convert, either bare (a leaf) or alongside the context a composite node had already produced before it failed."
  @type result ::
          {:ok, Context.t(), [Effect.t()]}
          | {:error, term()}
          | {:error, Context.t(), term()}

  @doc """
  Runs `node` against `context`, returning `result()`. See the moduledoc for
  the full contract: what the node may and may not do, and what each half of
  the return value means.
  """
  @spec execute(node :: t(), context :: Context.t()) :: result()
  def execute(node, context)
end
