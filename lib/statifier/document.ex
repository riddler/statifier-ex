defmodule Statifier.Document do
  @moduledoc """
  The typed parse target: what lowering (st-l5k.4) produces, and what the
  validator (st-l5k.5) and the Machine compiler (st-wju.1) consume.

  This is the layer `docs/architecture.md:47` names directly: "Document
  (typed structs, source locations, uncompiled expressions)". Interning,
  indexing, and expression compilation are the compiler's job, not this
  layer's - a `%Statifier.Document{}` tree is walkable and unambiguous, not
  fast, and it deliberately stays the pre-validation type so it can hold the
  malformed shapes st-l5k.5 exists to report (`docs/architecture.md:33-36`,
  principle 4).

  ## Raw expressions

  `cond`, `log`'s `expr`, and `content`'s `expr` are `String.t() | nil` -
  the exact predicator source the author wrote, uncompiled. Compilation into
  the `{:static, term()} | {:compiled, instructions, source}` sum type
  happens once at Machine-build time (`docs/datamodel.md`), so nothing in
  `lib/statifier/document/` may reference `Predicator`.

  ## The `attribute_locations` contract

  Every node with source attributes carries an `attribute_locations` map,
  keyed by an attribute name atom drawn from a fixed, known set per element,
  valued by that attribute's **value span** - the text inside the quotes,
  which is what ADR-0014's arithmetic needs and what a diagnostic underlines.
  The node's own `location` already covers the whole element for anything
  coarser.

  The map's defining rule: **an entry exists only for an attribute that was
  actually written in the source.** Lowering applies defaults (`:external`,
  `:early`, `:shallow`), so a field's runtime value alone cannot say whether
  the author wrote it or the default applied. `Map.has_key?(node.attribute_locations, :type)`
  is exactly the "was it written" question, and the same lookup is the
  location a diagnostic would want. A struct with a non-nil default (like
  `Statifier.Document.Transition.type`) and no corresponding key in
  `attribute_locations` means the default applied, not that the author wrote
  the default's value explicitly.

  Inherited from `Statifier.Parser.DOM.Attribute`: the stored string is
  entity-expanded while the span covers raw source, so an offset *inside* a
  value containing an entity or character reference does not map 1:1 onto
  the source.
  """

  alias Statifier.Document.{Log, Raise}
  alias Statifier.Parser.Location

  @typedoc """
  Value spans only, keyed by the attribute's name as an atom drawn from a
  fixed, known set per element. See the moduledoc for the "written, not
  defaulted" contract this map carries.
  """
  @type attribute_locations :: %{optional(atom()) => Location.t()}

  @typedoc "The executable-content node types Phase 1 defines."
  @type content_node :: Raise.t() | Log.t()

  @typedoc """
  The kinds a `Statifier.Document.State` can have. Equal to the element
  name that produced it - `<initial>` is not a member (it has no `id` and is
  a slot on its parent, not a targetable state; see `Statifier.Document.Initial`),
  and neither are the compiler-only widenings `:atomic` / `:compound`.
  """
  @type state_kind :: :state | :parallel | :final | :history
end
