defmodule Statifier.Machine.Content do
  @moduledoc """
  Namespace for the compiled executable-content node family: one struct per
  node kind, `Statifier.Machine.Content.Raise`, `Statifier.Machine.Content.Log`,
  `Statifier.Machine.Content.Assign`, `Statifier.Machine.Content.If`,
  `Statifier.Machine.Content.Foreach`, `Statifier.Machine.Content.Script`,
  and `Statifier.Machine.Content.Send`, the interned counterpart to
  `Statifier.Document.Raise` / `Statifier.Document.Log` /
  `Statifier.Document.Assign` / `Statifier.Document.If` /
  `Statifier.Document.Foreach` / `Statifier.Document.Script` /
  `Statifier.Document.Send`. This module owns the family's shared
  vocabulary - `owner/0` and the `t()` union - and no longer a struct
  itself: an Elixir protocol dispatches on the struct module, so each node
  kind needs its own struct for `Statifier.ExecutableContent` to implement
  without a central `case` on a `kind` field. Each future executable-content
  node (`<cancel>`) gets its own struct here too, and its own
  `Statifier.ExecutableContent` implementation, never a clause added to
  this module.

  `c_index` is a dense document-order identity assigned to **every**
  `<raise>`/`<log>`/`<assign>`/`<if>`/`<foreach>`/`<send>` node reachable
  through `onentry`, `onexit`, or a `<transition>`'s own content, across the
  whole machine (ADR-0012 item 3) - including a partition node *inside* an
  `<if>` or a body node *inside* a `<foreach>`, numbered in document order
  relative to the composite node that contains it (its own open tag numbers
  first, then its own children in turn, to arbitrary nesting depth -
  `Statifier.Compiler`'s Decision 2). `<donedata>`'s own `<content>` child is
  deliberately excluded: it is not executable content, never appears in a
  block, and no block-running pass ever runs it, so giving it a `c_index`
  would stop `c_index` meaning "the nth executable-content node".
  """

  alias Statifier.Machine.Content.Assign
  alias Statifier.Machine.Content.Foreach
  alias Statifier.Machine.Content.If
  alias Statifier.Machine.Content.Log
  alias Statifier.Machine.Content.Raise
  alias Statifier.Machine.Content.Script
  alias Statifier.Machine.Content.Send

  @typedoc """
  Which block of executable content a node lives in - the block identity a
  `c_index` alone does not carry, since a state may write several
  `<onentry>`/`<onexit>` elements and a block has no index of its own (the
  `ordinal` is the block's position in its state's `onentry`/`onexit` list):

  - `{:onentry, state_index, ordinal}` - an `<onentry>` block
  - `{:onexit, state_index, ordinal}` - an `<onexit>` block
  - `{:transition, t_index}` - a transition's own executable content
  - `{:finalize, state_index, invoke_index}` - an `<invoke>`'s own
    `<finalize>` block, `invoke_index` naming its position in the owning
    state's own `invoke` list (`Statifier.Compiler.Expressions.owner_ref/0`'s
    `{:invoke, state_index, invoke_index}` arm names the same invocation for
    its own non-block attributes and children)

  The shared home for this concept: `Statifier.Event.Cause.origin` embeds
  this type unwidened for its `:content` cause, rather than redefining it.
  `Statifier.Effect.Trace.ContentExecuted` widens it instead of aliasing it
  plainly - a load-time top-level `<script>` needs an `owner` this type
  cannot carry, since it belongs to no block at all; see that module's own
  `owner/0` typedoc for why the extra case lives there and not here.
  """
  @type owner ::
          {:onentry, non_neg_integer(), non_neg_integer()}
          | {:onexit, non_neg_integer(), non_neg_integer()}
          | {:transition, non_neg_integer()}
          | {:finalize, non_neg_integer(), non_neg_integer()}

  @typedoc "Any compiled executable-content node - the family this module maps."
  @type t :: Raise.t() | Log.t() | Assign.t() | If.t() | Foreach.t() | Script.t() | Send.t()
end
