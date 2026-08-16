# ADR-0042: Invoke content markup compiles under the relaxed namespace rule

Status: accepted (2026-08-16) - amends 0041 in part (settles the
no-declaration half of its namespace limitation; the ancestor-prefix open
question stays open)

## Context

ADR-0041 lowers `<content>`'s inline markup to a verbatim source slice and
compiles it as a standalone top-level document at invoke time, through
`Statifier.Invoke.Source.resolve/2`'s markup-in-a-binary clause. Its amended
namespace-limitation bullet records the measured consequence: all
twenty-four inline `<invoke><content>` documents under
`test/scxml_tests/mandatory/invoke/` compile as parents, and every one then
fails at invoke time with `{:bad_namespace, nil}`, because the corpus writes
its child `<scxml>` with no `xmlns` (`test220_test.exs:28`). st-ybuj is the
bead tracking the decision this record makes.

The failure is a consistency, not a contradiction, between two deliberate
rules:

- `Statifier.Lowering.Namespace.scxml_vocabulary?/1` accepts a `nil`
  namespace for lowering dispatch - the documented relaxed-input rule, so a
  boilerplate-free fragment lowers exactly as its fully-declared twin does.
- `Statifier.Validator.Checks.Boilerplate` exists precisely to close that
  gap for top-level compiles: check 9 rejects a root whose resolved
  namespace is not the SCXML URI, and every `Statifier.compile/1` runs it.
  Spec 3.2.1's attribute table makes `xmlns` a required attribute of
  `<scxml>` whose "value MUST be 'http://www.w3.org/2005/07/scxml'", so the
  check is right for a document that arrives at the top level on its own.

The child slice is neither of those things cleanly. In the parent document
as written, the inner `<scxml>` **is** in the SCXML namespace - the parent
root's `xmlns="http://www.w3.org/2005/07/scxml"` default declaration is in
scope over those bytes under ordinary XML namespace rules. Slicing drops the
ancestor declaration, and only then does the root become namespace-less.
G.6 (informative, "Inline Content and Namespaces") describes exactly this
situation and names the intended semantics:

> Since SCXML documents are XML documents, normal XML namespace rules apply
> to inline content specified with &lt;content&gt; and &lt;data&gt;. In
> particular, if no namespace is specified, the inline content will be
> placed in the SCXML namespace.

Its example hands the recipient `<a xmlns="http://www.w3.org/2005/07/scxml">`
for a `<content><a>` written with no declaration at all.

One more shape constrains the fix. Markup can reach `resolve/2` without ever
being a lowering-time slice: `test530_test.exs` assigns
`<scxml version="1.0"><final /></scxml>` - again no `xmlns` - to a datamodel
variable via `<assign>` and passes it as `<content expr="Var1"/>`. Whatever
the fix is, it must cover a markup binary that was never sliced from the
parent source, or test530 stays broken while its twenty-four siblings are
fixed.

## Decision

**The compile that `Statifier.Invoke.Source.resolve/2` runs on content
markup applies the same relaxed rule to check 9 that lowering dispatch
already applies: a root that resolves to no namespace at all compiles as
SCXML vocabulary.** A root that declares a *wrong* namespace still fails
check 9, and check 10 (`version` must be `"1.0"`) is unchanged - G.6's
placement rule speaks only to namespaces, and 3.2.1's version requirement
binds the child document like any other.

Concretely:

- `Statifier.compile/2` gains an options argument (defaulting to `[]`) with
  a flag - working name `content_markup: true`; the implementation owns the
  final spelling - threaded into `Statifier.Validator.validate/2` and onto a
  new boolean field on `Statifier.Validator.Context`.
- `Checks.Boilerplate.check_namespace/1` accepts the `nil` namespace when
  the flag is set, which is exactly
  `Statifier.Lowering.Namespace.scxml_vocabulary?/1`'s predicate; a non-nil
  non-SCXML namespace keeps failing in both modes.
- `Invoke.Source.resolve/2`'s markup clause is the one call site that sets
  the flag. It covers both routes - the ADR-0041 slice and an expr-delivered
  binary - because both arrive at that clause as `Invoke.content`. A
  grandchild's `<invoke><content>` recurses through the same clause and gets
  the same mode, one session boundary at a time.
- Top-level compiles are untouched: `Statifier.compile(source)` with no
  options still enforces 3.2.1's `xmlns` MUST, and Boilerplate remains "the
  only place in the pipeline that ever refuses" a boilerplate-free fragment
  arriving at the top level.

This is not a weakening of validation so much as a restoration of what the
slice dropped: for the sliced route, the bytes were in the SCXML namespace
in situ and the standalone compile is the only reader that ever saw them
otherwise; for the expr route, no declaration was ever in scope and G.6's
placement rule is the only semantics on offer. One rule covers both.

### Why the other candidates lost

**Injecting the parent's in-scope declarations onto the slice root**
(st-ybuj's second candidate, byte-surgery form) buys the same corpus outcome
at the cost of the two properties ADR-0041 chose slicing for: the slice
stops being the author's exact bytes, and
`markup_location.start_offset + child_offset` stops being a parent-document
byte offset for anything after the injection point (ADR-0012 constraint 3,
ADR-0014). It also cannot reach test530 at all - expr-delivered markup never
passes through lowering, so there is no slice to inject into. A
scope-threading variant (carry the in-scope declarations as data on
`Document.Content`, through `Machine.Invoke`, `Effect.Invoke`, and replay's
recorded inputs, into `resolve/2`) preserves the bytes but adds a field to
the exact rails ADR-0041 promised unchanged, still misses the expr route,
and pays the ancestor-prefix cost before anything needs it - the deferral
ADR-0041's open question records on purpose. That open question stays open
and unchanged: no corpus document uses an ancestor-declared prefix inside
`<content>`, and the follow-up that needs one still chooses between
injection and re-serialization when it arrives.

**Declaring the corpus documents invalid and wrapping them in the harness**
(the third candidate) is falsified by the spec itself: under XML namespace
rules the inline child is in the SCXML namespace as written, and G.6
documents that reading. Rewriting the files would fork the corpus from its
upstream source against ADR-0006's reuse commitment, and a harness-side
wrapper would hide an engine gap that any real document written the corpus
way would still hit.

**Demoting `{:bad_namespace, nil}` to ADR-0033's warning tier globally** was
also considered. Rejected: 3.2.1 makes `xmlns` a required attribute with a
MUST value, and unlike 6.5.2's author-addressed MUST NOT that seeded the
warning tier, the top-level root is exactly where this check has its
footing. Relaxing every compile to fix an invoke-path case is broader than
the need.

## Consequences

- test220's child markup as literally written compiles at invoke time once
  the flag lands, and so do its twenty-three siblings and test530's
  expr-delivered variant. Assertion-level pass/fail stays gated on
  st-cmq.9's harness change, as ADR-0041 already records.
- The implementation touches four files, none of them `machine/invoke.ex`,
  `effect/invoke.ex`, or `session.ex`: `lib/statifier.ex` (`compile/2`
  options), `lib/statifier/validator.ex` and
  `lib/statifier/validator/context.ex` (the flag onto the context),
  `lib/statifier/validator/checks/boilerplate.ex` (the relaxed arm),
  `lib/statifier/invoke/source.ex` (the one call site that sets it).
  Verification: a Boilerplate unit test for the flagged mode (with its
  sabotage line), a `resolve/2` test compiling test220's child slice
  verbatim, and an unflagged-compile test proving the top-level rejection
  still stands.
- `Statifier.compile/1` becomes `compile/2` with a default, so no caller
  changes. The option is part of the public surface and its doc must say
  what it is for - compiling invoke content markup - not present itself as a
  general validation off-switch.
- A child that declares a wrong namespace, or omits `version`, still fails
  its invoke-time compile as `{:compile, errors}` and surfaces as
  `error.communication` on the parent - ADR-0038's arm, unchanged.
- ADR-0041's namespace-limitation bullet is settled for the no-declaration
  case by this record; its ancestor-prefix open question is explicitly not
  settled here.
