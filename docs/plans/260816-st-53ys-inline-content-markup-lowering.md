# Inline `<content>` Markup Lowering Implementation Plan

## Overview

Implement ADR-0041: `<content>`'s element children lower to a verbatim slice of
the parent source, stored as `Statifier.Document.Content.markup` /
`markup_location`, folded by the compiler to `{:static, markup}`, and compiled
into a child `Machine` at invoke time through
`Statifier.Invoke.Source.resolve/2`'s existing markup-in-a-binary clause
(ADR-0038). The direction decision is already made and is not reopened here.
Bead: st-53ys.

## Current State Analysis

`<invoke><content><scxml>...</scxml></content></invoke>` does not compile at
all today:

- `Statifier.Lowering.Builders.build_content/2`
  (`lib/statifier/lowering/builders.ex:354-374`) maps every element child of
  `<content>` through `DOM.elements/1` into
  `Error.misplaced(name, "content", location)`.
- `Statifier.Lowering.finalize/2` (`lib/statifier/lowering.ex:164-168`) makes
  any accumulated error fatal, so one misplaced child fails the whole document.
- `Statifier.Document.Content` (`lib/statifier/document/content.ex:1-44`) has
  only `expr`, `text`, `location`, `attribute_locations`, and its moduledoc
  states the now-falsified "nothing in the conformance corpus needs it".
- `Statifier.Lowering.lower/1` (`lib/statifier/lowering.ex:96-113`) takes only
  the root element; it never sees the source binary, so nothing downstream of
  the parser can slice bytes. `Statifier.compile/1`
  (`lib/statifier.ex:69-79`) already holds the source and already passes it to
  `Validator.validate/2` as a second argument.
- `Statifier.Compiler.build_content_expr/2`
  (`lib/statifier/compiler.ex:1637-1660`) folds `text` to
  `Expressions.static(text)` when `expr` is nil, and compiles `expr`
  otherwise; `content_expr_location/1` gives the diagnostic span. It is shared
  by `<send>` (`:1113`), `<donedata>` (`:1351`), and `<invoke>` (`:1543`).
- `Statifier.Validator.Checks.Content`
  (`lib/statifier/validator/checks/content.ex:67-78`) reports
  `{:content_expr_and_text, expr}` only for `expr` alongside non-blank `text`.
- `Statifier.Invoke.Source.resolve/2` (`lib/statifier/invoke/source.ex:68-74`)
  already compiles a binary `content` with `Statifier.compile/1` and maps
  failure to `{:compile, errors}`, the session's `error.communication` cue.
  Nothing there changes.

Twenty-five of the twenty-seven files under
`test/scxml_tests/mandatory/invoke/` write the inline shape
(`test/scxml_tests/mandatory/invoke/test220_test.exs:26-31` is the minimal
case); the exceptions are test216 and test224, which use `src`.

Two facts shape the phasing and the verification story:

1. **`Lowering.lower/1` becomes `lower/2` and that is a wide mechanical
   change.** There are 131 `Lowering.lower(` call sites across 90 test files
   (87 of the form `Lowering.lower(root)`, 44 of the piped form
   `xml |> parse!() |> Lowering.lower()`), plus the one in
   `lib/statifier.ex:71`. Every one of those helpers already has the source
   binary in scope under some name.
2. **The corpus files cannot be the automated proof.**
   `Statifier.Case.test_scxml/4` calls `validate_features!/2` first
   (`test/support/case.ex:84`, `:99-115`), and
   `test/support/feature_detector.ex:112` still has
   `invoke_elements: :unsupported`, so all twenty-five flunk on the feature
   gate before any compile is attempted. Flipping that flag is st-cmq.9 and is
   out of scope. Compilation of those exact documents is therefore proven by
   internal tests over the same XML plus one scripted sweep recorded as a
   manual criterion.

## Desired End State

`Statifier.compile/1` returns `{:ok, %Machine{}}` for a document whose
`<invoke>` carries an inline `<content><scxml>...</scxml></content>`; the
compiled `Machine.Invoke.content` is `{:static, "<scxml ...>...</scxml>"}`
holding the author's exact bytes; and `Statifier.Invoke.Source.resolve/2` on
the corresponding `%Effect.Invoke{}` returns `{:ok, %Machine{}}` for the child
document. `{:misplaced_element, _, "content"}` no longer exists for any
`<content>` - `<invoke>`, `<send>`, or `<donedata>`. All twenty-five inline
corpus documents compile; their assertions stay gated on st-cmq.9.

Verify with: `mix quality` green; the new internal tests in
`test/statifier/lowering/content_test.exs`,
`test/statifier/validator/checks/content_test.exs`,
`test/statifier/compiler/invoke_test.exs`, and
`test/statifier/invoke/` compiling and passing; `mix test.regression` still
green.

### Key Discoveries:

- `Statifier.Parser.Location.slice/2`
  (`lib/statifier/parser/location.ex:68-72`) is `binary_part(source,
  start_offset, end_offset - start_offset)` - the verbatim markup of any
  subtree is already addressable, and `Location.at_offset/2` (`:46-58`)
  re-derives line/column for parent-coordinate translation (ADR-0012
  constraint 3, ADR-0014).
- `%Statifier.Parser.DOM.Text{}` carries a `location` spanning the **raw**
  source of the run (`lib/statifier/parser/dom/text.ex:5-13`), so a 5.6.2
  "mixture" of text and elements is sliceable whole from first to last
  non-whitespace child.
- `build_content/2` deliberately reads `element.children` / `DOM.elements/1`
  rather than `Lowering.walk_children/2` - `<content>` is exempt from the
  stray-text rule. Keeping that shape is what makes foreign-namespace children
  produce no `foreign_element` error: they are never dispatched or walked
  (ADR-0041, Decision bullet 3).
- The `ctx` map is already the builder-threading mechanism
  (`lib/statifier/lowering.ex:104`, `:149`), carrying `:ns_scope`. `:source`
  rides the same map with no new plumbing.
- `Statifier.Validator.validate/2` (`lib/statifier/validator.ex:107`) is the
  precedent for the second `source` argument.
- Nothing changes in `machine/invoke.ex`, `effect/invoke.ex`,
  `invoke/source.ex`, or `session.ex` (ADR-0041 Consequences).
- ADR-0018 is mechanically guarded (`lib/mix/statifier/adr_guard.ex`): no bead
  id may appear in a comment, doc, or test description under `lib/` or
  `test/`. Sabotage comments and test names in this plan must cite ADR numbers
  or spec clauses, never `st-53ys`.

## What We're NOT Doing

- **Not touching the corpus harness.** `invoke_elements` stays `:unsupported`
  in `test/support/feature_detector.ex`; flipping it and ratcheting is
  st-cmq.9. No corpus test's pass/fail changes on this branch.
- **Not re-litigating ADR-0041.** Options 1 (DOM subtree) and 2 (span +
  retained source) are rejected on the record.
- **Not solving the namespace-prefix limitation.** A fragment whose root uses a
  prefix declared on an ancestor outside the slice fails at invoke time.
  ADR-0041 accepts this and records the follow-up; nothing in the corpus writes
  that shape. This plan adds a test pinning the *accepted* behavior, not a fix.
- **Not validating inside `markup`.** The parent's validator never looks in the
  slice; a malformed or non-`<scxml>` payload fails at invoke time as
  `{:compile, errors}` -> `error.communication` (ADR-0038, 3.12.2).
- **Not adding a `lower/1` compatibility shim.** A defaulted empty source would
  silently produce empty slices - a footgun worse than the mechanical churn of
  updating 90 test files. `lower/2` is the only arity.
- **Not extending `Validator.Checks.Content`'s walk to `<send><content>`.**
  The check walks `<final>`'s `<donedata><content>` and a state's
  `<invoke><content>`; `<send>` is executable content nested in a block's
  `content` list, so reaching it needs a block walk the check does not have.
  That gap exists today, independently of markup, and closing it is a
  behavior change to `<send>` validation with its own tests - not something to
  smuggle into the markup arm. It is also not a two-line change: reaching a
  `<send>` nested under `<if>`/`<foreach>`/`<finalize>` needs the same
  traversal `Statifier.Validator.Checks.Send` already carries across seven
  functions (`lib/statifier/validator/checks/send.ex:99-158`), so whoever
  closes it mirrors or shares that walk rather than re-deriving a shallower
  one. Phase 2 records the gap in the moduledoc instead.
  Lowering and compilation of `<send><content>` markup **do** change here, as
  ADR-0041's Consequences require; only the validator walk is left alone.
- **Not building a DOM re-serializer.** Slicing preserves entities, CDATA, and
  formatting; ADR-0041 chose it over re-serialization within option 3.

## Implementation Approach

Three code phases along the pipeline's module boundaries (lowering ->
validator -> compiler/runtime), then a docs phase.

Phase 1 is deliberately the largest: `Document.Content`'s new fields, the
`lower/2` source threading, and `build_content/2`'s slicing are individually
inert. A field nobody writes, a `ctx` key nobody reads, and a slicer with no
source are each an un-exercisable commit; together they are one observable
behavior change (lowering an inline `<content>` yields `markup` and no errors)
that the gate can decide. The skill's own rule - combine rather than leave an
intermediate gate meaningless - applies exactly here.

Phases 2 and 3 are genuinely separable: after Phase 1 the validator's new arm
and the compiler's new arm each stand alone, each with its own tests, each
green on its own.

## Phase 1: Lowering slices `<content>`'s markup

### Overview

`Document.Content` gains `markup` and `markup_location`; `Lowering.lower/2`
threads the source binary to builders through `ctx`; `build_content/2` stops
erroring on element children and slices them instead.

### Changes Required:

#### 1. The Content document node
**File**: `lib/statifier/document/content.ex`
**Changes**: Add two nilable fields and rewrite the moduledoc paragraph whose
"nothing in the conformance corpus needs it" premise ADR-0041 falsified. Keep
the DOM-subtree rationale (still true - no subtree enters the struct) and
retarget it at the slice; keep `text`'s exact meaning unchanged so
`Validator.Checks.Content` keeps its footing.

```elixir
defstruct [:location, expr: nil, text: nil, markup: nil, markup_location: nil,
           attribute_locations: %{}]

@type t :: %__MODULE__{
        expr: String.t() | nil,
        text: String.t() | nil,
        markup: String.t() | nil,
        markup_location: Location.t() | nil,
        location: Location.t(),
        attribute_locations: Document.attribute_locations()
      }
```

#### 2. Source threading
**File**: `lib/statifier/lowering.ex`
**Changes**: `lower/1` -> `lower/2`, taking the source binary as the second
argument (the shape `Validator.validate/2` already has). Seed it into the
initial ctx; `walk_child/4` already copies ctx forward, so nothing else
changes. Update the moduledoc's accumulator/dispatch prose to mention that
`ctx` carries `:source` for the one builder that slices, and that lowering
still never re-parses - it only slices bytes it already has spans for.

```elixir
@spec lower(root :: Element.t(), source :: binary()) ::
        {:ok, Document.t()} | {:error, [Error.t()]}
def lower(%Element{name: name, location: location} = root, source)
    when is_binary(source) do
  ...
  {document, errors} = builder.(root, %{ns_scope: scope, source: source})
```

**File**: `lib/statifier.ex`
**Changes**: `Lowering.lower(root)` -> `Lowering.lower(root, source)` at
`:71`.

**Files**: the 90 test files holding 131 `Lowering.lower(` call sites.
**Changes**: mechanical - `Lowering.lower(root)` -> `Lowering.lower(root, xml)`
and `|> Lowering.lower()` -> `|> Lowering.lower(xml)`, using whatever the
source binary is bound to in each helper's own scope. Do this with a scripted
pass, then compile: a helper whose source is not in scope surfaces as an
undefined-variable error rather than silently taking the wrong binding. No test
assertion changes.

#### 3. The slicing builder
**File**: `lib/statifier/lowering/builders.ex`
**Changes**: `build_content/2` reads `ctx.source`, drops the
`Error.misplaced/3` map entirely, and sets `markup`/`markup_location` when
`<content>` has at least one element child. The slice runs from the start
offset of the first non-whitespace child to the end offset of the last
non-whitespace child, over the **unfiltered** `element.children` so a 5.6.2
mixture is sliced whole, text runs included. `text` keeps its existing
`DOM.text/1` value untouched. Rewrite the `@doc`'s "an element child is not
silently dropped ... `<content>` does not hold a markup subtree" paragraph to
cite ADR-0041 instead, and fix the three sibling `@doc`s that cross-reference
`build_content/2`'s old element-child rule
(`build_data/2` ~`:411`, `build_assign/2` ~`:471`, `build_script/2` ~`:725`) so
they cite the stray-text exemption only, not the vanished misplaced rule.

```elixir
def build_content(%Element{} = element, ctx) do
  {markup, markup_location} = slice_markup(element, Map.fetch!(ctx, :source))
  ...
  {{:content, content}, []}
end

# nil when no element child is present; otherwise the verbatim source
# between the first and last non-whitespace child (ADR-0041).
defp slice_markup(%Element{children: children}, source) do
  significant = Enum.reject(children, &blank_text?/1)

  case {Enum.any?(significant, &match?(%Element{}, &1)), significant} do
    {true, [first | _] = nodes} ->
      last = List.last(nodes)
      location = %Location{first.location | end_line: last.location.end_line,
                           end_column: last.location.end_column,
                           end_offset: last.location.end_offset}

      {Location.slice(location, source), location}

    _ ->
      {nil, nil}
  end
end
```

(The exact `Location` merge is the implementer's; what matters is that
`markup_location.start_offset` and `end_offset` bound exactly the sliced bytes
so `markup_location.start_offset + child_offset` is a parent byte offset -
ADR-0014's arithmetic.)

#### 4. Tests
**File**: `test/statifier/lowering/content_test.exs`
**Changes**: a new `describe "lower/2 - <content> markup"` block. Each test
carries its sabotage line per `docs/testing.md`; none may name a bead id
(ADR-0018 is guarded).

- an `<invoke><content><scxml .../></content></invoke>` lowers with no errors
  and `markup` equal to the exact `<scxml>...</scxml>` bytes
- `markup_location` bounds exactly those bytes -
  `Location.slice(markup_location, xml) == markup`
- indentation and trailing newline around the child are excluded (first/last
  non-whitespace boundary)
- a 5.6.2 mixture (`text <el/> text`) slices whole, text runs included, and
  `text` still holds `DOM.text/1`'s untrimmed concatenation
- an entity reference and a CDATA section inside the markup survive verbatim
  (the slice is raw bytes, not `Text.value`)
- a foreign-namespace child produces no `foreign_element` and no
  `misplaced_element` error - the slice is opaque at this layer
- a text-only `<content>` still has `markup: nil` and `markup_location: nil`
- `<send><content>` and `<donedata><content>` get markup on the same rule

**File**: `test/statifier/lowering/donedata_test.exs:200-220`
**Changes**: the `describe "lower/1 - element child inside <content>"` block is
the **only** assertion in the suite that pins the removed rule
(`{:misplaced_element, "state", "content"}`). Retarget it - same XML, now
asserting `{:ok, _}` with the child sliced into `markup` - rather than
deleting it, and rewrite its sabotage line for the new behavior.

**File**: `test/statifier/lowering/layer_test.exs:39`
**Changes**: a prose comment citing `Error.misplaced(name, "content",
location)` inside `build_content/2` as an example of a name flowing through a
function body. That call site is gone; swap the example for another one the
comment already lists (`content_node_name/1`) or for a surviving
`Error.misplaced/3` call. The guard's own logic is untouched.

**Not affected**, despite matching a grep for `misplaced.*content`:
`test/statifier/lowering/invoke_test.exs:131` and
`test/statifier/lowering/send_test.exs:147` are sabotage comments about
`{:misplaced_element, "content", <parent>}` - a `<content>` misplaced *under*
its parent, a different rule that stays. `misplaced/3` itself stays for the
same reason; confirm with a grep before touching `Error`.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (`mix quality --profile loop` between edits;
      a loop run alone never satisfies this phase)
- [x] `mix test test/statifier/lowering/` passes
- [x] `mix test.regression` passes - the ratchet is unmoved
- [x] `grep -rn "Lowering.lower(" lib test` shows no remaining single-argument
      call
- [x] `grep -rn "misplaced.*\"content\"" lib test` returns nothing

#### Manual Verification:
- [ ] The touched functions match the W3C Appendix D pseudocode line for line -
      vacuously here: Appendix D models no parsing stage, so lowering has no
      pseudocode counterpart and this phase introduces no interpreter
      deviation (ADR-0002)
- [ ] The slice is byte-exact against 5.6.2's "text, XML from any namespace, or
      a mixture of both" for a hand-written mixture, checked in IEx
- [ ] The mechanical test-file rewrite changed only call arity - `git diff
      --stat` on `test/` shows one or two changed lines per file and no
      assertion edits
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 2: Validator extends 5.6.2 mutual exclusion to markup

### Overview

`expr` alongside `markup` is the same 5.6.2 violation as `expr` alongside
text, reported the same way.

### Changes Required:

#### 1. The check
**File**: `lib/statifier/validator/checks/content.ex`
**Changes**: `check_content/1`'s non-nil-`expr` clause fires when `markup` is
present **or** `text` is non-blank. The reported error stays
`{:content_expr_and_text, expr}` at the `<content>` node's own `location` -
ADR-0041 says "the same violation, reported the same way", so no new error
reason and no new message shape. Update the moduledoc to state the markup arm
and cite ADR-0041, and correct its "when `<send>` gains a `<content>` child,
this walk grows a third arm" sentence: `<send>` has a `<content>` child today
(`lib/statifier/document/send.ex:54`,
`lib/statifier/compiler.ex:1113`), but `contents/1` still walks only
`<final>`'s `<donedata><content>` and a state's `<invoke><content>` - `<send>`
is executable content living inside a block's `content` list
(`lib/statifier/document/send.ex:27-30`), so reaching it needs a block walk
this check does not have. That gap predates this branch and is **not** closed
here (see "What We're NOT Doing"); the sentence becomes a statement of the
standing gap rather than a prediction.

```elixir
defp check_content(%Content{expr: nil}), do: []

defp check_content(%Content{expr: expr, text: text, markup: markup, location: location}) do
  if is_nil(markup) and blank?(text) do
    []
  else
    [Error.content_expr_and_text(expr, location)]
  end
end
```

#### 2. Tests
**File**: `test/statifier/validator/checks/content_test.exs`
**Changes**: add, each with its sabotage line:

- `<content expr="x"><scxml/></content>` reports
  `{:content_expr_and_text, "x"}` at the `<content>` element's own line
- `<content><scxml/></content>` (markup, no expr) reports nothing
- whitespace around markup with an `expr` present still reports (the markup,
  not the whitespace, is the payload)
- existing expr+text and expr-only cases keep their current outcomes

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (loop gate between edits)
- [x] `mix test test/statifier/validator/` passes
- [x] `mix test.regression` passes

#### Manual Verification:
- [ ] The touched functions match the W3C Appendix D pseudocode line for line -
      vacuously: validation has no Appendix D counterpart (ADR-0002)
- [ ] The reported message reads correctly for a markup payload, not just a
      text one - read one actual error string in IEx
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 3: Compiler folds markup, and the inline shape reaches a child Machine

### Overview

`build_content_expr/2` gains its markup arm, which makes the whole
`<invoke><content><scxml>` shape compile end to end and resolve to a child
`Machine` through ADR-0038's existing binary path. This phase delivers the
bead's acceptance criterion.

### Changes Required:

#### 1. The fold
**File**: `lib/statifier/compiler.ex`
**Changes**: `build_content_expr/2` picks `expr` (compiled) when written, else
`markup` as `{:static, markup}` when present, else `{:static, text}`.
`content_expr_location/1` gains the matching arm returning `markup_location`.
Clause order must keep the written-`expr` arm first, matching ADR-0041's
"`expr` (compiled) when written". Extend the existing comment above
`content_expr_location/1` to say why the markup arm's span is
`markup_location` rather than the node's own `location` - unlike `text`,
markup *has* a span, and it is the one ADR-0014's offset arithmetic needs.

```elixir
defp build_content_expr(%DContent{expr: nil, markup: markup}, _owner)
     when is_binary(markup),
     do: {:ok, Expressions.static(markup)}

defp build_content_expr(%DContent{expr: nil, text: text}, _owner),
  do: {:ok, Expressions.static(text)}

defp build_content_expr(%DContent{expr: source} = content, owner) do
  Expressions.compile(source, owner, content_expr_location(content))
end

defp content_expr_location(%DContent{expr: nil, markup_location: %Location{} = location}),
  do: location
```

No change to `Machine.Invoke`, `Effect.Invoke`, `Invoke.Source`, or
`Session` (ADR-0041 Consequences).

#### 2. Tests
**File**: `test/statifier/compiler/invoke_test.exs`
**Changes**: with sabotage lines -

- compiling test220's exact XML
  (`test/scxml_tests/mandatory/invoke/test220_test.exs:22-46`) yields
  `{:ok, %Machine{}}` whose invoke's `content` is
  `{:static, "<scxml initial=\"subFinal\" ...>...</scxml>"}`
- the invoke's content `expr_location` is the markup's span, and
  `Location.slice/2` of it against the parent source round-trips to the same
  binary

**File**: `test/statifier/machine/content_test.exs` (or the existing
`<send>`/`<donedata>` compiler tests, whichever holds the sibling coverage)
**Changes**: `<send><content>` and `<donedata><content>` markup fold to
`{:static, markup}` on the same rule.

**File**: `test/statifier/invoke/source_test.exs` (extend if present, else new)
**Changes**: the end-to-end case, with sabotage lines -

- an `%Effect.Invoke{content: markup}` produced from the compiled test220
  document resolves through `Invoke.Source.resolve/2` to `{:ok, %Machine{}}`
- a `<content>` holding a fragment with no namespace declaration compiles as
  SCXML vocabulary (the relaxed rule, G.6's stated semantics)
- a `<content>` holding a non-`<scxml>` root, or a truncated fragment, fails at
  resolve time as `{:error, {:compile, _}}` - never at parent compile time
- a fragment whose root uses a prefix declared on an ancestor **outside** the
  slice fails at resolve time. This pins ADR-0041's accepted namespace
  limitation as tested behavior so a future change to it is visible; the test's
  comment cites ADR-0041, and it is an assertion about the limitation, not a
  fix for it
- a child document that itself contains `<invoke><content>` compiles - one
  session boundary at a time, no re-entrant parse

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (loop gate between edits)
- [x] `mix test test/statifier/compiler/ test/statifier/invoke/` passes
- [x] `mix test.regression` passes - no ratchet movement, since
      `invoke_elements` stays `:unsupported` and every affected corpus file
      still flunks the feature gate before compiling (st-cmq.9)
- [x] `mix quality --format json --report -` is available for a later agent
      routing on results

#### Manual Verification:
- [ ] The touched functions match the W3C Appendix D pseudocode line for line -
      vacuously: compilation has no Appendix D counterpart, and the child
      compile at invoke time is an ordinary top-level pipeline run, not a
      nested parse (ADR-0002, ADR-0041)
- [ ] **All twenty-five inline corpus documents compile.** Run a throwaway
      script (Ruby to extract, `mix run` to compile, or a single
      `Code.eval_string` sweep) that pulls the XML heredoc out of each file
      under `test/scxml_tests/mandatory/invoke/` and asserts
      `Statifier.compile/1` returns `{:ok, _}` for all but test216 and
      test224, which use `src`. Do **not** commit the script - it is a
      one-shot check of a criterion the corpus suite cannot yet express,
      because `test/support/feature_detector.ex:112` still flunks these files
      on `invoke_elements` before any compile happens
- [ ] Reading one child compile error in IEx confirms its location is
      child-relative and `markup_location.start_offset + child_offset` lands on
      the right parent byte (ADR-0012 constraint 3, ADR-0014)
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

## Phase 4: Record the decision and the user-visible change

### Overview

Close the two documentation gaps the direction stage deliberately left, and
make the assembled release notes internally consistent.

### Changes Required:

#### 1. The ADR index
**File**: `docs/adr/README.md`
**Changes**: append the ADR-0041 row after 0040, matching the existing table
format exactly:

```
| [0041](0041-content-markup-lowers-to-a-source-slice.md) | `<content>` markup lowers to a source slice, compiled at invoke time | accepted |
```

The row is not an amendment of 0038 - ADR-0038 named this gap and deferred it,
so 0041 completes it rather than amending it, and 0038's own row stays as it
is.

#### 2. The changelog fragment
**File**: `changelog.d/st-53ys.md` (new)
**Changes**: this clears the v2-vs-v1 bar in `changelog.d/README.md`: v1's
`Statifier.InvokeHandler` existed but v2 has, until now, failed to compile the
document at all, and `changelog.d/st-cmq.7.md` published that failure as a
documented limitation. A user calling the public API can tell the difference.

```markdown
### Added

- `<invoke><content><scxml>...</scxml></content></invoke>` now compiles and
  starts the inline child document as a session. `<content>`'s element
  children are preserved as the verbatim source they were written as, and
  compiled when the invocation runs; a `<content>` that specifies both an
  `expr` and inline markup is rejected as the same 5.6.2 violation as `expr`
  alongside inline text. Markup whose root element uses a namespace prefix
  declared on an ancestor outside `<content>` is not yet supported.
```

**File**: `changelog.d/st-cmq.7.md`
**Changes**: the closing sentences of its second bullet state that an inline
`<content><scxml>` "does not start a session either - the document fails to
compile at all" and that CDATA-wrapped markup is "the supported way ... until
element children of `<content>` are supported". Both are false once Phase 3
lands, and the fragments are assembled into one release section, so leaving
them contradicts the new fragment in the shipped notes. Trim those sentences
to the part that stays true (the `src`-without-resolver behavior). This is a
deliberate cross-fragment edit, not a conflict: fragments are per-issue to
avoid *concurrent* edits, and st-cmq.7's is already landed.

#### 3. Struct-level documentation sweep
**File**: `lib/statifier/document/content.ex` and the builders/validator
moduledocs touched in Phases 1-2
**Changes**: none new - this phase only verifies that the prose landed in the
phase that changed the behavior, rather than accumulating a documentation
debt here. If anything is missing, fix it in this phase.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes - including `mix gate.check`, which sees no
      guarded path in this diff
- [x] `grep -n "0041" docs/adr/README.md` returns the new index row
- [x] `test -f changelog.d/st-53ys.md`
- [x] `grep -rn "st-53ys" lib test` returns nothing (ADR-0018)

#### Manual Verification:
- [ ] The ADR-0041 row's wording and status column match the table's
      established style
- [ ] Reading `changelog.d/st-53ys.md` and `changelog.d/st-cmq.7.md` back to
      back, the assembled notes make one coherent statement about `<invoke>`
      sources with no contradiction
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. This phase touches no Elixir
behavior, so its gate is a formality; the review of the diff is the real bar.

---

## Corpus/Ratchet Notes

No corpus regeneration and no `test/passing_tests.json` movement. The
twenty-five affected files under `test/scxml_tests/mandatory/invoke/` gain the
ability to compile, but `Statifier.Case.test_scxml/4` flunks them on
`invoke_elements: :unsupported` (`test/support/feature_detector.ex:112`)
before reaching a compile, so none of them changes from fail to pass on this
branch. `mix test.baseline add` is therefore **not** run in any phase; running
it would be a no-op at best. `mix test.regression` is asserted green in every
code phase as a guard against the reverse - a document that used to compile
and no longer does.

st-cmq.9 owns the flip and the ratchet addition. This bead's acceptance
criterion stops at compilation, which the Phase 3 manual sweep proves for all
twenty-five.

## Testing Strategy

### Unit Tests:

- **Lowering** (`test/statifier/lowering/content_test.exs`, plus the retargeted
  block in `test/statifier/lowering/donedata_test.exs:200-220`): the slice is
  byte-exact; `markup_location` bounds exactly the sliced bytes; whitespace
  boundaries; 5.6.2 mixtures; entities and CDATA survive verbatim;
  foreign-namespace children raise nothing; text-only `<content>` is
  unaffected; `<send>` and `<donedata>` get the same rule. The one existing
  `{:misplaced_element, _, "content"}` assertion is retargeted, not deleted.
- **Validator** (`test/statifier/validator/checks/content_test.exs`): expr +
  markup reports; markup alone does not; existing expr/text cases unchanged.
- **Compiler** (`test/statifier/compiler/invoke_test.exs`): test220's XML
  compiles to `{:static, markup}` with `markup_location` as the diagnostic
  span.
- **Runtime** (`test/statifier/invoke/`): resolve produces a child `Machine`;
  malformed and non-`<scxml>` payloads fail at resolve time as
  `{:compile, _}`; the accepted namespace limitation is pinned; a nested
  inline invoke recurses one session boundary at a time.

Every one of these asserts `lib/` behavior, so every one carries a sabotage
line proved by breaking the code, watching it go red, and reverting
(`docs/testing.md`). None may name a bead id in a comment or test description -
`mix adr.check`'s ADR-0018 rule is mechanical and only `ADR-0018-exempt`
clears it.

### Manual Testing Steps:

1. In IEx, `Statifier.compile/1` test220's XML; confirm `{:ok, machine}` and
   inspect the invoke's `content` for the verbatim child markup.
2. Resolve that invoke through `Statifier.Invoke.Source.resolve/2`; confirm a
   child `%Machine{}` comes back.
3. Corrupt the child markup (drop a closing tag); confirm the parent still
   compiles and the failure appears only at resolve time as
   `{:error, {:compile, _}}`.
4. Run the throwaway sweep over all twenty-five inline corpus documents
   (Phase 3's manual criterion) and confirm every one returns `{:ok, _}`.
5. Take one child compile error's location and add
   `markup_location.start_offset`; confirm `Location.at_offset/2` on the parent
   source lands on the expected line.

## References

- Bead: `st-53ys`
- Direction record: `docs/adr/0041-content-markup-lowers-to-a-source-slice.md`
- Related ADRs: `docs/adr/0038-invoke-source-resolves-at-the-session-boundary.md`,
  `docs/adr/0012` (observability), `docs/adr/0014` (span composition),
  `docs/adr/0002` (Appendix D fidelity), `docs/adr/0018` (process artifacts are
  not code comments)
- Predecessor plan: `docs/plans/260815-st-cmq.7-invoke-scxml-child-sessions.md`
  (Decision 1 deferred this choice)
- Research: `docs/research/260815-st-cmq.7-invoke-scxml-child-sessions.md`,
  "Open Questions" item 1
- Minimal corpus case: `test/scxml_tests/mandatory/invoke/test220_test.exs:22-46`
- Slicing mechanism: `lib/statifier/parser/location.ex:68-72`
- Existing binary path: `lib/statifier/invoke/source.ex:68-74`
- Precedent for the second `source` argument: `lib/statifier/validator.ex:107`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The touched functions match the W3C Appendix D pseudocode line for line -
      vacuously here: Appendix D models no parsing stage, so lowering has no
      pseudocode counterpart and this phase introduces no interpreter
      deviation (ADR-0002)
- [ ] The slice is byte-exact against 5.6.2's "text, XML from any namespace, or
      a mixture of both" for a hand-written mixture, checked in IEx
- [ ] The mechanical test-file rewrite changed only call arity - `git diff
      --stat` on `test/` shows one or two changed lines per file and no
      assertion edits
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 2

- [ ] The touched functions match the W3C Appendix D pseudocode line for line -
      vacuously: validation has no Appendix D counterpart (ADR-0002)
- [ ] The reported message reads correctly for a markup payload, not just a
      text one - read one actual error string in IEx
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 3

- [ ] The touched functions match the W3C Appendix D pseudocode line for line -
      vacuously: compilation has no Appendix D counterpart, and the child
      compile at invoke time is an ordinary top-level pipeline run, not a
      nested parse (ADR-0002, ADR-0041)
- [ ] **All twenty-five inline corpus documents compile.** Run a throwaway
      script (Ruby to extract, `mix run` to compile, or a single
      `Code.eval_string` sweep) that pulls the XML heredoc out of each file
      under `test/scxml_tests/mandatory/invoke/` and asserts
      `Statifier.compile/1` returns `{:ok, _}` for all but test216 and
      test224, which use `src`. Do **not** commit the script - it is a
      one-shot check of a criterion the corpus suite cannot yet express,
      because `test/support/feature_detector.ex:112` still flunks these files
      on `invoke_elements` before any compile happens
- [ ] Reading one child compile error in IEx confirms its location is
      child-relative and `markup_location.start_offset + child_offset` lands on
      the right parent byte (ADR-0012 constraint 3, ADR-0014)
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. In interactive execution,
pause here for the human to confirm the manual testing before moving to the
next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead
of blocking here.

---

### Phase 4

- [ ] The ADR-0041 row's wording and status column match the table's
      established style
- [ ] Reading `changelog.d/st-53ys.md` and `changelog.d/st-cmq.7.md` back to
      back, the assembled notes make one coherent statement about `<invoke>`
      sources with no contradiction
- [ ] No regressions in related features

**Implementation Note**: Use the project's loop gate between edits while
iterating; run the full gate as the phase gate. This phase touches no Elixir
behavior, so its gate is a formality; the review of the diff is the real bar.

---
