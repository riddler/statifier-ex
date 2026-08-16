# ADR-0041: `<content>` markup lowers to a source slice, compiled at invoke time

Status: accepted (2026-08-16)

## Context

`Statifier.Lowering.Builders.build_content/2` reports every element child of
`<content>` as `{:misplaced_element, name, "content"}`, and
`Statifier.Lowering.finalize/2` makes any lowering error fatal, so
`<invoke><content><scxml>...</scxml></content></invoke>` does not compile at
all. `Statifier.Document.Content`'s moduledoc records the original reasoning:
preserving markup "would mean holding a DOM subtree inside a Document struct,
crossing the layer boundary this rewrite is organized around, and nothing in
the conformance corpus needs it." The last clause is now falsified: twenty-five
of the twenty-seven files under `test/scxml_tests/mandatory/invoke/` write
exactly this shape (`test220_test.exs:26-31` is the minimal case), and the
spec requires it to work. 5.6.2:

> When present, the children of `<content>` MAY consist of text, XML from any
> namespace, or a mixture of both.

and 6.4.2:

> Invoked services of type http://www.w3.org/TR/scxml/ ... MUST interpret
> values specified by the `<content>` element or 'src' attribute as markup to
> be executed.

ADR-0038 built the execution half of that sentence and named this gap in its
own Consequences: `Statifier.Invoke.Source.resolve/2` already compiles a
`content` that arrives as markup-in-a-binary with `Statifier.compile/1`, and
deferred "how `<content>`'s element children survive lowering" to this record.
The st-cmq.7 plan's Decision 1 deferred the same choice for the same reason
and named three candidates, each crossing the parser/document layer boundary
differently:

1. Preserve a DOM subtree on `Document.Content`.
2. Keep the raw source span and re-parse it at invoke time.
3. Re-serialize the element subtree to XML at lowering time and reuse
   ADR-0038's existing binary path.

Three existing mechanisms decide which crossing is cheap:

- `Statifier.Parser.DOM.Element.location` spans "from the `<` of the start tag
  to the byte after the `>` of the end tag", and
  `Statifier.Parser.Location.slice/2` slices exactly those bytes back out of
  the source - the verbatim markup of any subtree is already addressable
  without a serializer.
- The whole downstream pipeline for a text-bodied `<content>` already carries
  a binary: `Document.Content.text` folds to `{:static, text}` on
  `Machine.Invoke.content` (`Statifier.Compiler.build_content_expr/2`), the
  invoke pass evaluates that onto `Effect.Invoke.content`, and
  `Invoke.Source.resolve/2`'s first clause compiles it. A markup binary rides
  the same rails with no new shapes.
- Lowering's relaxed-input rule (`Statifier.Lowering.Namespace.scxml_vocabulary?/1`
  accepts `nil`) means a fragment whose root carries no namespace declaration
  still compiles as SCXML vocabulary - which is also the semantics G.6
  (informative) describes for inline content: "if no namespace is specified,
  the inline content will be placed in the SCXML namespace."

## Decision

**Option 3, with slicing as the serializer.** `<content>`'s element children
lower to a verbatim slice of the source, stored as a binary on
`Document.Content`, and the child document is compiled from that binary at
invoke time through `Statifier.Invoke.Source.resolve/2`'s existing
markup-in-a-binary clause - ADR-0038's path, unchanged.

Concretely:

- **`Statifier.Document.Content` gains two nilable fields**: `markup` (the
  sliced binary) and `markup_location` (the slice's own span in the parent
  source). The moduledoc's DOM-subtree rationale stands - no DOM subtree
  enters a Document struct - but its "nothing in the corpus needs it" premise
  and the element-children-are-errors rule are rewritten to cite this record.
  `text` keeps its exact meaning (the concatenation of direct text children,
  whitespace-only in the pure-markup case) so `Statifier.Validator.Checks.Content`
  keeps its footing.
- **Lowering receives the source binary.** `Statifier.Lowering.lower/1` gains
  the source alongside the root (threaded to builders via the existing `ctx`
  map), the same second argument `Statifier.Validator.validate/2` already
  takes. Lowering still never re-parses anything; it only slices bytes it
  already has spans for.
- **`build_content/2` stops erroring on element children.** When `<content>`
  has at least one element child, `markup` is the slice from the start of the
  first non-whitespace child to the end of the last non-whitespace child
  (elements and `Text` runs both carry `Location` spans; a 5.6.2 "mixture" is
  therefore sliced whole, text runs included). `{:misplaced_element, _,
  "content"}` disappears for every `<content>` - `<invoke>`, `<send>`, and
  `<donedata>` alike, since 5.6.2 states the rule on `<content>` itself.
  Foreign-namespace children are never dispatched or walked, so they produce
  no `foreign_element` errors either: the slice is opaque bytes at this layer.
- **The compiler folds `markup` exactly as it folds `text`.**
  `build_content_expr/2` picks `expr` (compiled) when written, else `markup`
  as `{:static, markup}` when present, else `{:static, text}`. Its diagnostic
  span for the markup arm is `markup_location`. Nothing changes on
  `Machine.Invoke`, `Effect.Invoke`, `Invoke.Source`, or `Statifier.Session`.
- **The child compile is not re-entrant.** No parse nests inside a parse: the
  parent document's parse finished long before, and the child's
  `Statifier.compile/1` runs at invoke time, inside the session process, on a
  standalone binary - an ordinary fresh top-level pipeline run, per ADR-0038.
  A child that itself contains `<invoke><content>` recurses the same way, one
  session boundary at a time.
- **Validation of the child is the child compile's job.** The parent's
  validator does not look inside `markup`. `Statifier.Validator.Checks.Content`
  extends its 5.6.2 mutual exclusion - `expr` alongside `markup` is the same
  violation as `expr` alongside text, reported the same way. A slice that is
  not well-formed XML (a "mixture" payload, a non-`<scxml>` root, a truncated
  fragment) fails at invoke time inside `resolve/2` as `{:compile, errors}`,
  which is already the session's cue for `error.communication` (3.12.2, per
  ADR-0038); no new error channel exists.

### Why the other options lost

**Option 1 (DOM subtree on `Document.Content`)** is the crossing the rewrite
is organized to forbid, and it does not stop at Document: the subtree has to
reach invoke time, so `Machine.expr()` grows a DOM-carrying arm,
`Effect.Invoke.content` carries a tree, and `Invoke.Source` needs a
compile-from-DOM entry that bypasses `Statifier.Parser.parse/1` yet still owes
`Validator.validate/2` a source binary it no longer has. Its literal-port
credential is hollow - Appendix D never models parsing at all, so no fidelity
is bought for the largest structural change of the three.

**Option 2 (keep the span, re-parse at invoke time)** stores the cheapest
value but the most expensive obligation: a span is only usable with the source
in hand, so the parent's entire source binary must ride the `Machine` into the
session and into replay's recorded inputs (ADR-0034) for the lifetime of every
invoking document. The error timing is identical to option 3 either way - the
child compiles at invoke time in both - so the retained-source plumbing buys
nothing the slice taken at lowering time does not already deliver.

**Within option 3, slicing beats DOM re-serialization.** `Text` values are
entity-decoded and CDATA-unwrapped, so a serializer must re-encode; the slice
preserves the author's exact bytes - entities, CDATA sections, prefixes,
formatting - with no serializer to build or maintain. And a slice keeps a
coordinate system a re-serialization destroys: `markup_location.start_offset +
child_offset` is a parent-document byte offset, the same plain arithmetic
ADR-0014 fixed for expression spans.

## Consequences

- The implementation touches five files - `lib/statifier/document/content.ex`
  (fields + moduledoc), `lib/statifier/lowering.ex` (source threading),
  `lib/statifier/lowering/builders.ex` (`build_content/2`),
  `lib/statifier/compiler.ex` (`build_content_expr/2`,
  `content_expr_location/1`), `lib/statifier/validator/checks/content.ex`
  (mutual exclusion arm) - and none of `machine/invoke.ex`,
  `effect/invoke.ex`, `invoke/source.ex`, or `session.ex`.
- A child document's own compile errors surface at invoke time as
  `error.communication` on the parent (ADR-0038's existing arm), never at
  parent compile time. Their locations are child-relative; `markup_location`
  is what makes them translatable back into parent coordinates by offset
  arithmetic (ADR-0012 constraint 3, ADR-0014), with
  `Location.at_offset/2` re-deriving line/column for a tool that holds the
  parent source.
- The twenty-five inline-invoke corpus files compile once this lands.
  Assertion-level pass/fail stays blocked on st-cmq.9's harness change, as the
  bead records; `invoke_elements` stays wherever st-cmq.9 decides.
- `<send><content>` and `<donedata><content>` markup payloads become XML
  strings as a side effect of stating the rule at `<content>`. That matches
  5.6.2's placement of the grammar and G.6's send examples; whether a given
  receiver wants a string or a parsed value is that consumer's decision at its
  own boundary, not lowering's.
- **Namespace limitation, accepted.** The slice drops namespace declarations
  made on ancestors. For the case the spec and corpus exercise - an
  undeclared-namespace fragment under a default-SCXML-namespace document - the
  relaxed no-namespace rule compiles the fragment as SCXML vocabulary, which
  is G.6's stated semantics, so behavior is right where it matters. A fragment
  whose root uses a prefix declared outside the slice compiles to a
  `foreign_element`/unresolved failure at invoke time instead. Nothing in the
  corpus writes that shape.
- **Open question.** If a real document ever needs ancestor-declared prefixes
  inside `<content>` markup, a follow-up must choose between injecting the
  in-scope declarations onto the slice's root element at lowering time and
  full DOM re-serialization - the exact cost this record declines to pay
  before anything needs it. That follow-up amends this record; it does not
  reopen options 1 or 2.
