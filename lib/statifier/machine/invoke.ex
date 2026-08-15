defmodule Statifier.Machine.Invoke do
  @moduledoc """
  One compiled `<invoke>` element (spec 6.4) - the interned counterpart to
  `Statifier.Document.Invoke`, reachable only through its owning state as
  `elem(machine.states, i).invoke`, in document order.

  `index` is this invocation's position within its own state's `invoke`
  list - what `{:invoke, state_index, invoke_index}` and `{:finalize,
  state_index, invoke_index}` name, `Statifier.Compiler.Expressions.owner_ref/0`'s
  and `Statifier.Machine.Content.owner/0`'s own new arms.

  `type` and `src` each fold their own static/expr attribute pair into a
  single `Machine.expr() | nil`, mirroring `Statifier.Machine.Donedata.expr`:
  `{:static, v}` from `type`/`src`, `{:compiled, ...}` from
  `typeexpr`/`srcexpr`, `nil` when neither was written (an already-validated
  document never writes both - 6.4.1's "Must not occur with" pair).

  `id` is the author's literal `id` attribute, used verbatim
  (ADR-0008 as amended - "document-authored IDs are always respected").
  `idlocation` stays a **raw, uncompiled location path string**, never a
  compiled expression - the same reason
  `Statifier.Machine.Content.Assign`'s moduledoc gives for its own
  `location` field: a location path cannot be resolved any earlier than
  execute time, even in principle.

  `namelist` and `params` are kept as two separate lists of
  `Statifier.Machine.Param.t()`, every `namelist` entry compiled with
  `kind: :location`, even though 6.4's data-sharing rule treats the two
  channels identically at the invoked service - they stay apart here only so
  the validator can enforce 6.4.1's "namelist Must not occur with the
  `<param>` element" and so a later empty-`<finalize>` auto-assign can find
  its write targets by name.

  `content` folds `<content>`'s markup into a single `Machine.expr()`,
  exactly as `Machine.Donedata.expr` does - `nil` when `<invoke>` has no
  `<content>` child.

  `finalize` is `nil` when `<invoke>` has no `<finalize>` child at all, and a
  `Statifier.Machine.Block.t()` (possibly with an empty `content` list) when
  it does - the same absent-versus-empty distinction
  `Statifier.Document.Invoke`'s moduledoc describes, carried through
  compilation structurally. Unlike every other field here, its `c_index`es
  come from the same dense, whole-machine counter every `<onentry>`/`<onexit>`
  block uses (`Statifier.Compiler`'s Decision 4) - `<finalize>` is executable
  content, the other fields are not.

  `attribute_locations` is `Statifier.Document.Invoke`'s own map, carried
  through unchanged rather than distilled into individual `*_location`
  fields the way most other compiled nodes are: an `<invoke>` has eight
  source attributes and this struct has no per-field diagnostic use for most
  of them, so the one shared map stands in for all of them at once.
  """

  alias Statifier.Document
  alias Statifier.Machine
  alias Statifier.Machine.Block
  alias Statifier.Machine.Param
  alias Statifier.Parser.Location

  @enforce_keys [:index, :location]
  defstruct [
    :index,
    :location,
    type: nil,
    src: nil,
    id: nil,
    idlocation: nil,
    namelist: [],
    params: [],
    content: nil,
    autoforward: false,
    finalize: nil,
    attribute_locations: %{}
  ]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          location: Location.t(),
          type: Machine.expr() | nil,
          src: Machine.expr() | nil,
          id: String.t() | nil,
          idlocation: String.t() | nil,
          namelist: [Param.t()],
          params: [Param.t()],
          content: Machine.expr() | nil,
          autoforward: boolean(),
          finalize: Block.t() | nil,
          attribute_locations: Document.attribute_locations()
        }
end
