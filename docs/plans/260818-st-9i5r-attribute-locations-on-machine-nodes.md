---
date: 2026-08-18
planner: Claude
git_commit: 909682a8349544b52b805b468c6e2f1f0b56b6a8
branch: st-9i5r-attribute-locations
repository: statifier-ex
beads_issue: st-9i5r
topic: "Carrying attribute_locations onto Machine.Transition and Machine.State"
tags: [plan, compiler, machine, locations, observability]
status: ready
last_updated: 2026-08-18
last_updated_by: Claude
---

# Carrying attribute_locations onto Machine.Transition and Machine.State Implementation Plan

## Overview

Extend `Statifier.Machine.Invoke`'s carry-verbatim treatment of
`attribute_locations` to `Statifier.Machine.Transition` and
`Statifier.Machine.State`, so the compiled Machine can answer attribute-level
"where in the source" and "did the author write this" questions that the
Document layer already answers and compilation currently drops.

Beads issue: `st-9i5r`

## Current State Analysis

The Document layer records a value span per written attribute on every node
that has attributes. `Statifier.Document`'s moduledoc (`lib/statifier/document.ex:22-44`)
states the contract: the map is keyed by an attribute-name atom, valued by the
attribute's **value span** (the text inside the quotes), and an entry exists
**only for an attribute the author actually wrote** - so
`Map.has_key?(node.attribute_locations, :type)` is exactly the "was it
written" question that a defaulted field's value cannot answer. The type alias
is `Statifier.Document.attribute_locations/0` (`lib/statifier/document.ex:97`).

Both source structs already carry the map:

- `Statifier.Document.Transition` - `attribute_locations: %{}`
  (`lib/statifier/document/transition.ex:44-62`), with a moduledoc paragraph
  spelling out the `type` default versus written-`type` distinction.
- `Statifier.Document.State` - `attribute_locations: %{}`
  (`lib/statifier/document/state.ex:105,122`).
- `Statifier.Document` itself (the root `<scxml>`) -
  `lib/statifier/document.ex:130,145`, holding `initial`, `name`, `datamodel`,
  `binding`, `version`, `xmlns`.

The Machine layer distills rather than carries. `Statifier.Machine.Transition`
(`lib/statifier/machine/transition.ex:55-78`) keeps `location` and
`cond_location`; `Statifier.Machine.State`
(`lib/statifier/machine/state.ex:47-88`) keeps `location` only. Neither can
answer whether a transition's `type` was written, nor where a state's `id` or
`initial` attribute sits, nor where a transition's `event` or `target` sits.

`Statifier.Machine.Invoke` is the precedent and the escape hatch. It carries
`attribute_locations: %{}` typed `Document.attribute_locations()`
(`lib/statifier/machine/invoke.ex:70,85`) and its moduledoc
(`lib/statifier/machine/invoke.ex:46-50`) states the rule: when a node has
several source attributes and no per-field diagnostic use pays for a distilled
`*_location` field each, the Document's own map is carried through unchanged
and stands in for all of them at once. The compiler already does this at
`lib/statifier/compiler.ex:1511` (`attribute_locations: invoke.attribute_locations`),
and does the same for `<send>` (`:1028`) and `<cancel>` (`:1043`).

Construction sites for the two structs this bead touches - there are exactly
four, and only these four:

| Site | Node | What its map must hold |
|---|---|---|
| `lib/statifier/compiler.ex:225` | root `%MState{}`, index 0 | `document.attribute_locations` - the `<scxml>` element's own written attributes |
| `lib/statifier/compiler.ex:390` | every other `%MState{}` | `dstate.attribute_locations`, verbatim |
| `lib/statifier/compiler.ex:768` | every `%MTransition{}` | `transition.attribute_locations`, verbatim (this one pass builds plain, `<initial>`-element, and history-default transitions alike - `assign_transitions/3` at `:466` feeds all three into `transitions_acc`) |
| `lib/statifier/interpreter.ex:288` | the synthesized initial transition | `%{}` - it is not a document element, so no author wrote anything |

`cond_location` (`lib/statifier/compiler.ex:793-803`) already reads
`attribute_locations[:cond]` off the *Document* transition at compile time and
distills it, with a documented fallback to the transition's own `location`.
The bead is explicit that this stays as-is and that existing consumers do not
move to the map.

## Desired End State

`Statifier.Machine.Transition` and `Statifier.Machine.State` each carry an
`attribute_locations` field holding the owning Document node's map verbatim,
`%{}` when the node wrote no attributes; the root state (index 0) holds
`%Statifier.Document{}`'s own map; the interpreter-synthesized initial
transition holds `%{}` and says at the construction site why. Both moduledocs
state the Invoke-style verbatim carry and cite the key-presence contract.
`docs/observability.md` constraint 3 and ADR-0012 item 3 name attribute-level
retention instead of stopping at element level.

Verification: a new Machine-layer location sweep, in the established
`Location.slice/2` style, slices every carried span back out of the source
string and checks it against the value the compiled struct itself carries,
and asserts the written-versus-defaulted key-presence contract survives
compilation.

### Key Discoveries:

- `lib/statifier/machine/invoke.ex:46-50` - the moduledoc paragraph that
  states the escape hatch; the two new paragraphs are written against it.
- `lib/statifier/document.ex:31-39` - the key-presence contract ("an entry
  exists only for an attribute that was actually written in the source"),
  which is the property the Machine currently cannot answer for a
  transition's `type` or for anything on a state.
- `lib/statifier/compiler.ex:466-493` - `assign_transitions/3` is the single
  funnel every transition passes through, so `build_transition/3`
  (`:761-782`) is the single place a transition's map has to be carried; there
  is no separate `<initial>`-element or history-default build path.
- `lib/statifier/machine/state.ex:36-41` - the "written in one pass" paragraph
  ends with "Every field above `donedata` ... `donedata` and `invoke` are the
  exception". Adding a table row after `invoke` breaks that sentence's
  positional phrasing; it has to be reworded, not just appended to.
- `test/statifier/lowering/location_test.exs:52-65` - `assert_node_location/2`
  and `assert_attribute_location/3`, the exact two helpers the new
  Machine-layer sweep mirrors, themselves written "in the style of
  `test/statifier/parser/location_accuracy_test.exs:13-37`" (st-18y's
  harness). The new file is the third member of that family, one layer down.
- The synthesized initial transition at `lib/statifier/interpreter.ex:288` is
  built inside a private `initial_transition/1` and never escapes
  `initialize/2` as a value - trace effects carry `t_index`es, not structs
  (`lib/statifier/effect/trace/transitions_selected.ex:7`). Its `%{}` is
  therefore pinned by the struct default plus a construction-site comment,
  not by a behavioral assertion; see Phase 1.
- ADR-0012 item 3 and `docs/observability.md` constraint 3 frame retention as
  element-level. The st-1xwh amendment (ADR-0012, 2026-08-17) is the precedent
  for how this repo records a constraint-3 enumeration that has fallen behind
  the code: a dated line on the Status header plus an `**Amendment**`
  paragraph after the Decision, leaving the original sentence standing.
- ADR-0014 is not touched. Its subject is expression-level spans inside a
  compiled predicator program; `cond_location` is its statifier-side anchor
  and the bead freezes that field.

## What We're NOT Doing

- **Not** distilling any new per-field `*_location` on either struct. The
  whole point of the Invoke treatment is that one map stands in for all of
  them; a `target_location` or an `id_location` would be the alternative this
  bead rejects.
- **Not** touching `cond_location`, `Statifier.Compiler.cond_location/1`, or
  any of its consumers. It keeps its "attribute span, falling back to the
  element span" semantics, which the raw map deliberately does not have.
- **Not** moving `<send>`, `<cancel>`, `<invoke>`, `<data>`, `<log>`,
  `<assign>`, `<foreach>` or `<if>` distillations onto the map either.
- **Not** adding a `Statifier.Machine` accessor function
  (`Machine.attribute_location/3` or similar). The field is reachable through
  `Machine.at/2` and `Machine.transition/2`, which is how `Invoke`'s map is
  reached today; a convenience wrapper with no in-repo caller is speculation.
- **Not** writing a new ADR. The bead is the decision record; ADR-0012 gains
  an amendment note only, in the narrow st-1xwh sense (the constraint's
  enumeration completing, the Decision sentence untouched).
- **Not** re-parsing or joining Document nodes to Machine identities by
  location equality. The bead weighed and rejected that alternative, and its
  UI mirror `sui-qay` explicitly forbids it.
- **Not** implementing anything on the statifier-ui side. This bead lands the
  producer; `sui-qay` is the consumer and is parked behind it.

## Implementation Approach

Three phases, in dependency-free order. Phase 1 and Phase 2 are one struct
each - separate files, separate compiler construction sites, separate test
sections - so either could land first and each is independently green. Phase 3
records the widening in the two documents that describe the constraint. Every
phase's edit is additive: a struct field with a `%{}` default, a value passed
at a construction site, and prose. No existing field changes type, no existing
call site changes shape, and no behavior outside the compiler is affected,
which is why no conformance result can move (see Testing Strategy).

Both struct fields are declared with a `%{}` default rather than added to
`@enforce_keys`. That matches `Machine.Invoke` (`lib/statifier/machine/invoke.ex:57-71`,
where `@enforce_keys` is `[:index, :location]` and `attribute_locations`
defaults) and it is what lets the interpreter's synthesized transition and any
future compiler-synthesized node be correct by default rather than by
remembering.

---

## Phase 1: Machine.Transition carries the map

### Overview

Add `attribute_locations` to `Statifier.Machine.Transition`, carry it in the
compiler's transition pass, make the interpreter's synthesized transition state
what its map holds, and stand up the Machine-layer location sweep with its
transition half.

### Changes Required:

#### 1. The struct

**File**: `lib/statifier/machine/transition.ex`
**Changes**: new field, new type entry, new moduledoc paragraph, and the
`Document` alias. Use the multi-alias form `Machine.Invoke` uses
(`alias Statifier.{Document, Machine}`) so Credo's consistency check sees the
same shape in both files.

```elixir
  defstruct [
    :t_index,
    :source,
    :targets,
    :events,
    :cond,
    :type,
    :content,
    :location,
    :cond_location,
    attribute_locations: %{}
  ]
```

with `attribute_locations: Document.attribute_locations()` in `@type t`.

The moduledoc paragraph goes after the `cond`/`cond_location` paragraph and
before the `content` one, so the two location-bearing topics sit together:

```
`attribute_locations` is `Statifier.Document.Transition`'s own map, carried
through unchanged rather than distilled into per-attribute `*_location`
fields - the escape hatch `Statifier.Machine.Invoke`'s moduledoc describes,
applied here because `event`, `target` and `type` each have a diagnostic
use (an attribute-level hover target) and none has a distinct enough one to
pay for a field of its own. `cond_location` above is the deliberate
exception, retained because it also carries a fallback the raw map does not:
the transition's own `location` when `cond` was written without a recorded
span.

The map keeps `Statifier.Document`'s key-presence contract verbatim: an
entry exists only for an attribute the author actually wrote, so
`Map.has_key?(transition.attribute_locations, :type)` is the "was `type`
written" question that `type`'s own value cannot answer once lowering has
applied the `:external` default. `%{}` when the element wrote no
attributes at all, and on the synthesized initial transition
(`Statifier.Interpreter`), which no author wrote.
```

#### 2. The compiler's transition pass

**File**: `lib/statifier/compiler.ex` (`build_transition/3`, around `:768`)
**Changes**: one field on the struct literal.

```elixir
           location: transition.location,
           cond_location: cond_location(transition),
           attribute_locations: transition.attribute_locations
```

This one site covers plain transitions, an `<initial>` element's transition,
and a `:history` state's default transition alike - all three reach
`transitions_acc` through `assign_transitions/3`.

#### 3. The synthesized initial transition

**File**: `lib/statifier/interpreter.ex` (`initial_transition/1`, around `:280-296`)
**Changes**: write the field explicitly rather than leaning on the default,
and extend the existing ADR-0002 deviation comment above the function so it
names both consequences of "not a document element" in one place.

```elixir
  # `expandScxmlSource(doc)` (Appendix D's own normalization step) is what
  # gives a document an `<initial>` element where it wrote none; this is
  # that step, done lazily for the root only. ADR-0002 mechanical
  # deviation: a synthesized transition is not a document element, so it
  # has no `t_index` - and, for the same reason, its `attribute_locations`
  # is empty: no author wrote an attribute for it, which is exactly what
  # `Statifier.Document`'s key-presence contract says an empty map means.
```

```elixir
        %Transition{
          t_index: nil,
          source: 0,
          targets: Machine.initial(machine),
          events: [],
          type: :external,
          content: [],
          location: machine.location,
          attribute_locations: %{}
        }
```

Writing `%{}` explicitly here is redundant against the struct default on
purpose: this is the one construction site whose emptiness is a claim about
the source rather than an accident of defaults, and the bead's acceptance
criteria ask it to be documented at the site.

#### 4. The Machine-layer location sweep (new file), transition half

**File**: `test/statifier/compiler/location_test.exs` (new)
**Changes**: a sweep in the style of `test/statifier/lowering/location_test.exs`,
one layer down - it compiles a fixture through
`Parser.parse/1 -> Lowering.lower/2 -> Validator.validate/2 -> Compiler.compile/1`
(the `compile!/1` helper `test/statifier/machine/transition_test.exs:7-13`
already uses) and then slices each carried span back out of the same source
string. Every tokenized field is written with a value equal to its own
rendered form, the way `test/statifier/lowering/location_test.exs:11-16`
explains, so plain slice-equality holds without reversing the tokenization.

```elixir
  # An `attribute_locations` entry on a *compiled* node slices back to
  # exactly the text the author wrote inside the quotes - the Document
  # layer's own property (test/statifier/lowering/location_test.exs:59-65),
  # re-asserted one layer down to prove compilation carried the map rather
  # than rebuilding or dropping it.
  defp assert_attribute_location(attribute_locations, key, expected) do
    location = Map.fetch!(attribute_locations, key)
    assert Location.slice(location, @source) == expected
  end
```

Cases in this phase:

- Every attribute of a fully-written `<transition target="..." event="..."
  cond="..." type="internal"/>` slices back to its own text on the compiled
  `%Machine.Transition{}`.
- An `<initial>` element's transition and a `:history` state's default
  transition each carry their own map (reached through
  `Machine.at(machine, i).initial_transition` and `.history_default`, then
  `Machine.transition/2`).
- Key presence survives compilation: a transition that wrote no `type`
  compiles to `type: :external` **and** `refute Map.has_key?(t.attribute_locations, :type)`,
  while one that wrote `type="external"` explicitly has the key. This is the
  Document-layer assertion at `test/statifier/document/transition_test.exs:67-74`,
  re-run against the compiled struct.
- `cond_location` is unchanged and still non-nil exactly when `cond` is - a
  regression guard for the field the bead freezes.

**File**: `test/statifier/machine/transition_test.exs`
**Changes**: one test pinning the struct default, since the synthesized
transition at `lib/statifier/interpreter.ex:288` is built inside a private
function and never escapes `initialize/2` as a value, so no behavioral
assertion can reach it. Build a `%Machine.Transition{}` with only its
`@enforce_keys` and assert `attribute_locations == %{}`.

Every new test asserting `lib/` behavior carries its one-line sabotage note
above it, per `docs/testing.md` - for the sweep, dropping
`attribute_locations: transition.attribute_locations` from `build_transition/3`
must redden it; for the default test, removing the `%{}` default from the
`defstruct` entry must.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality --profile loop` green while iterating (not a phase gate on
      its own)
- [x] Full `mix quality` green, unscoped, with `mix gate.verify` confirming
      the run was not profiled, scoped, `--quick`-ed or `--skip`-ed
- [x] `mix test test/statifier/compiler/location_test.exs` passes on its own
- [x] `mix test test/statifier/machine/transition_test.exs` passes on its own
- [x] Each new test's sabotage mutation was applied, observed red, and
      reverted, and the mutation is recorded in the one-line comment above
      the test
- [x] `mix test --include scion --include scxml_w3` shows no change in
      pass/fail counts against `test/passing_tests.json` (`mix test.regression`
      green, no `mix test.baseline add` needed)

#### Manual Verification:
- [ ] Spec-conformance judgment: `Statifier.Interpreter.initial_transition/1`
      still matches Appendix D's `expandScxmlSource(doc)` normalization line
      for line. The only ADR-0002 deviation on this path remains the existing
      one - a synthesized transition is not a document element - and the
      comment now names both of its consequences (`t_index: nil`,
      `attribute_locations: %{}`) rather than one. No new deviation is
      introduced.
- [ ] The moduledoc paragraph reads as a sibling of `Machine.Invoke`'s, not a
      restatement of it: it says why *this* node takes the escape hatch and
      why `cond_location` stays out of it.
- [ ] A compiled transition from a real fixture, inspected in IEx, shows the
      map keys the source actually wrote and no others.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: Machine.State carries the map

### Overview

The same carry for `Statifier.Machine.State`, including the root state at
index 0, whose map comes from `%Statifier.Document{}` itself rather than from
a `%Statifier.Document.State{}`.

### Changes Required:

#### 1. The struct

**File**: `lib/statifier/machine/state.ex`
**Changes**: new field (`attribute_locations: %{}`, last in the `defstruct`
keyword list), new `@type t` entry, `alias Statifier.Document` added ahead of
the existing `Statifier.Machine.{...}` alias, a new row in the kind-scoped
table, and a paragraph.

Table row, appended after `invoke`:

```
  | `attribute_locations` | any - the owning element's own written-attribute spans, carried verbatim |
```

The paragraph that follows the table currently opens "Every field above
`donedata` is written in one pass" and closes "`donedata` and `invoke` are the
exception". Adding a row after `invoke` makes the positional phrasing wrong;
reword it to name the exceptions rather than point at a position:

```
Every field in the table except `donedata` and `invoke` is written in one
pass: the compiler's state-interning walk builds each
`%Statifier.Machine.State{}` whole, index and `t_index`/`c_index` references
included. `donedata` and `invoke` are the exception - each is filled in
after that walk, once its own compilation pass has run, so they are the only
fields whose values are not known when the struct is first built.
```

Then the new paragraph, after it, under its own `attribute_locations`
subheading (an `##` heading in the moduledoc, matching the existing
"Fields that are kind-scoped" one):

```
`attribute_locations` is the owning `Statifier.Document.State`'s own map,
carried through unchanged rather than distilled into per-attribute
`*_location` fields - the escape hatch `Statifier.Machine.Invoke`'s
moduledoc describes, applied here because `id`, `initial` and a history's
`type` each have an attribute-level diagnostic use and none pays for a field
of its own.

At index 0 the source is `%Statifier.Document{}` itself, not a
`Statifier.Document.State`, exactly as `location` at index 0 is the
document's own - so the root's map holds the `<scxml>` element's written
attributes (`initial`, `name`, `datamodel`, `binding`, `version`, `xmlns`),
and is `%{}` only for a document that wrote none of them.

The map keeps `Statifier.Document`'s key-presence contract verbatim: an
entry exists only for an attribute the author actually wrote. A `:history`
state whose `history_type` is `:shallow` because lowering applied the
default carries no `:type` key; one that wrote `type="shallow"` does. `%{}`
means the element wrote no attributes at all.
```

#### 2. The compiler's root construction

**File**: `lib/statifier/compiler.ex` (around `:225-236`)
**Changes**: one field, with a short comment naming where its value comes
from, since this is the one state whose source is not a
`%Statifier.Document.State{}`.

```elixir
      history_children: history_children_of(children, acc.states_acc),
      location: document.location,
      # Index 0's source node is `%Statifier.Document{}` itself, so its map
      # is the `<scxml>` element's own written attributes - the same reason
      # `location` above is `document.location`.
      attribute_locations: document.attribute_locations
    }
```

#### 3. The compiler's state-interning walk

**File**: `lib/statifier/compiler.ex` (around `:390-406`)
**Changes**: one field.

```elixir
      location: dstate.location,
      attribute_locations: dstate.attribute_locations
    }
```

#### 4. The location sweep, state half

**File**: `test/statifier/compiler/location_test.exs`
**Changes**: extend the file Phase 1 created (the fixture already carries the
states these cases need; add attributes to it only where a case demands one).

- Every written attribute on a compound `<state id="..." initial="...">`, a
  `<parallel id="...">`, a `<final id="...">` and a
  `<history id="..." type="deep">` slices back to its own text on the compiled
  `%Machine.State{}`.
- The root state (`Machine.at(machine, 0)`) carries the `<scxml>` element's
  own spans - `initial`, `name`, `datamodel`, `binding`, `version`, `xmlns` -
  each slicing back to its own text. This is the index-0 claim the moduledoc
  makes, asserted rather than asserted-in-prose.
- Key presence survives compilation: a `<history id="h">` with no `type`
  compiles to `history_type: :shallow` **and**
  `refute Map.has_key?(state.attribute_locations, :type)`; a state that wrote
  only `id` has exactly `[:id]` as its keys.
- A state whose element wrote no attributes at all compiles to `%{}`. A bare
  `<state/>` nested inside an id-bearing `<state id="s">` is the fixture: it
  validates with **no** warnings and interns normally (verified during
  planning - it compiles to a `%Machine.State{kind: :state, id: nil}` at its
  own index), so no id-less-state warning has to be tolerated to assert this.

Sabotage lines as in Phase 1: dropping the carry at `:390` must redden the
state cases, and dropping it at `:225` must redden the root case
specifically - two distinct mutations, so note them on the two tests
separately rather than sharing one line.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality --profile loop` green while iterating
- [ ] Full `mix quality` green, unscoped, confirmed by `mix gate.verify`
- [ ] `mix test test/statifier/compiler/location_test.exs` passes on its own
- [ ] Each new test's sabotage mutation applied, observed red, reverted, and
      recorded in its one-line comment - including the two distinct compiler
      sites (`:225` root, `:390` walk)
- [ ] `mix test.regression` green with no `test/passing_tests.json` change

#### Manual Verification:
- [ ] Spec-conformance judgment: the compiler's state-interning walk
      (`walk_siblings/4`) and root construction still match the structure
      Appendix D's `expandScxmlSource`/document-order assumptions rely on -
      both edits are a single additional field on an existing struct literal
      and introduce no new ADR-0002 deviation.
- [ ] The reworded "written in one pass" paragraph is still true of every
      field the table now lists, `attribute_locations` included.
- [ ] Compiling a real fixture in IEx and reading `Machine.at(machine, 0)`
      shows the `<scxml>` attributes the fixture wrote and no others.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 3: Record the widening in the constraint documents

### Overview

`docs/observability.md` constraint 3 and ADR-0012 item 3 both describe
retained locations at element granularity - "a visualizer highlighting the
`<transition>` line currently executing needs nothing else". That sentence was
written before an attribute-level consumer existed. Phases 1 and 2 make the
Machine carry more than it describes, and this repo's rule is that the
description catches up on the same branch.

### Changes Required:

#### 1. Constraint 3

**File**: `docs/observability.md` (constraint 3, "the Machine retains
locations and identities")
**Changes**: one bullet added after the existing "States, transitions, and
executable-content nodes ... needs nothing else" bullet - leaving that
sentence standing, since it is still true of the consumer it names.

```
- Attribute-level spans are retained too, one step finer than the bullet
  above: `Statifier.Machine.State`, `Statifier.Machine.Transition` and
  `Statifier.Machine.Invoke` each carry their source node's
  `attribute_locations` map verbatim (`Statifier.Document`'s moduledoc holds
  the contract - value spans only, and a key exists only for an attribute
  the author wrote). The element-level sentence above is what a
  line-highlighting visualizer needs; a consumer with attribute-level hover
  targets on a `<transition>`'s `event`/`target`/`type` or a state's
  `id`/`initial` needs the map, and re-deriving it by re-parsing the source
  and joining Document nodes to Machine identities by location equality is
  sound only while the re-parsed bytes match what built the Machine, which
  nothing checks (st-9i5r).
```

**File**: `docs/observability.md` ("Where the seams live" table)
**Changes**: extend the existing compiler-retains-locations row's description
so the table names attribute spans too, rather than adding a near-duplicate
row:

```
| compiler retains locations on states, transitions, executable content, and each node's written-attribute spans (`attribute_locations`, carried verbatim) | `Statifier.Compiler`, `Statifier.Machine.State`/`Transition`/`Content`/`Invoke` |
```

#### 2. ADR-0012

**File**: `docs/adr/0012-debuggability-designed-into-the-core.md`
**Changes**: a second dated amendment, in the exact shape the st-1xwh one
uses - a clause on the Status line and an `**Amendment (st-9i5r):**`
paragraph after the existing amendment, with the original item 3 left
unedited.

Status line becomes:

```
Status: accepted (2026-08-04) - amended 2026-08-17 (st-1xwh: `d_index` named a
third identity under item 3) - amended 2026-08-18 (st-9i5r: item 3's retention
reaches attribute-level spans, not only element-level)
```

Amendment paragraph:

```
**Amendment (st-9i5r):** item 3 says compilation "keeps locations on states,
transitions, and executable content", and `docs/observability.md` constraint
3 illustrates that with a visualizer highlighting a `<transition>` line.
Both are element-granular. `Statifier.Machine.Invoke` had already gone one
step finer - carrying `Statifier.Document.Invoke`'s `attribute_locations`
map verbatim rather than distilling a `*_location` field per attribute - and
`Statifier.Machine.State` and `Statifier.Machine.Transition` now do the
same. The retained data is the value span of each attribute the author
actually wrote, so the Machine can answer both "where is this attribute" and
"was it written or defaulted" without a second parse. This widens what item
3 retains; it mints no new identity and adds no runtime cost beyond the
memory the Consequences section already accepts, which is why it is an
amendment rather than a new record. The original sentence stands above,
unedited, for the same reason the st-1xwh amendment explains rather than
rewrites.
```

#### 3. Changelog fragment

**File**: `changelog.d/st-9i5r.md` (new)
**Changes**: a public struct gains a public field, which
`changelog.d/README.md` classes as a public API addition.

```markdown
### Added

- `Statifier.Machine.State` and `Statifier.Machine.Transition` each carry an
  `attribute_locations` field, the source node's written-attribute value
  spans carried through compilation verbatim - the same treatment
  `Statifier.Machine.Invoke` already had. An entry exists only for an
  attribute the author actually wrote, so `Map.has_key?/2` on the map answers
  "was this written or defaulted" for a transition's `type` or a history's
  `type`, which the compiled field's value alone cannot. The root state
  (index 0) carries the `<scxml>` element's own attribute spans; the
  interpreter-synthesized initial transition carries `%{}`.
```

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality --profile loop` green while iterating (not a phase gate on
      its own, and on a docs-only diff it proves little - the two stages below
      are the ones with something to say here)
- [ ] Full `mix quality` green, unscoped, confirmed by `mix gate.verify` -
      including the `ADR guard` stage (`mix adr.check`), which must report no
      finding for the branch
- [ ] `mix quality --profile merge` green, which is what actually runs the ADR
      judge stage the bare gate skips by design (`.quality.exs:23`; see
      `CLAUDE.md`'s not-applicable-skips section) - the judge is the check
      that reads the amendment against the branch's diff
- [ ] `changelog.d/st-9i5r.md` exists and no line of `CHANGELOG.md` changed
- [ ] No `docs/quality-gate-changes.md` entry is required, because no guarded
      path (`.quality.exs`, `.credo.exs`, `coveralls.json`, `.sobelow-conf`,
      `.doctor.exs`, gate-relevant `mix.exs` lines, `@tag :skip`,
      `test/passing_tests.json`) is touched by this branch - `mix gate.check`
      passing is the mechanical confirmation

#### Manual Verification:
- [ ] The ADR-0012 amendment reads as completing/widening item 3, not as
      reversing it; the original item 3 sentence is byte-identical to what it
      was
- [ ] Constraint 3's existing element-level bullet is untouched and the new
      bullet is additive
- [ ] The changelog fragment passes `changelog.d/README.md`'s test - someone
      who only calls the public API could tell the difference

**Implementation Note**: This phase touches no Elixir code, so per `CLAUDE.md`
it could commit on review of the diff alone; run the full gate anyway, since
`mix adr.check` and the merge-profile ADR judge are exactly the stages that
have something to say about it. In looped execution, its Automated
Verification gates advancement as usual.

---

## Testing Strategy

### Unit Tests:

- **`test/statifier/compiler/location_test.exs` (new)** - the Machine-layer
  member of the location-accuracy family that
  `test/statifier/parser/location_accuracy_test.exs` (DOM) and
  `test/statifier/lowering/location_test.exs` (Document) already have. One
  fixture, every attribute written, every carried span sliced back out of the
  source and compared to the text the author wrote. The property is stated
  once and applied to every node, so no line or column number is written down
  anywhere and an off-by-one anywhere upstream still reddens it.
- **`test/statifier/machine/transition_test.exs`** - one added test pinning
  the `%{}` struct default, which is the only reachable assertion about the
  interpreter's synthesized initial transition.
- **Key edge cases**: the root state at index 0 (its map comes from a
  different struct than every other state's); a defaulted `type` on a
  transition and on a `:history` state (present field value, absent key); an
  `<initial>` element's transition and a history default transition (both
  built through the same `build_transition/3` as a plain transition, so both
  must carry); a node that wrote no attributes at all (`%{}`, not `nil`).

### Ratchet and conformance:

No conformance result can move. Every change is either an additional struct
field with a `%{}` default, an additional value passed at a construction site,
or prose; no existing field changes type, no function's return shape changes,
and nothing in `lib/statifier/interpreter/` reads the new field. `mix
test.regression` is still run per phase as the mechanical confirmation of that
reasoning, and no `mix test.baseline add` is expected on any phase. If the
ratchet does move, that is a defect in the phase, not a corpus update to
accept.

### Manual Testing Steps:

1. `iex -S mix`, then parse/lower/validate/compile a fixture with a
   fully-attributed `<transition>` and a compound `<state>`; read
   `Machine.transition(machine, 0).attribute_locations` and
   `Machine.at(machine, 1).attribute_locations` and check the keys against
   what the fixture actually wrote.
2. `Statifier.Parser.Location.slice(map[:event], source)` on one of those
   entries returns the bare attribute value, without the `event="` prefix or
   the closing quote.
3. Compile a document whose root writes no `<initial>` and confirm
   `Statifier.Interpreter.initialize/2` still runs to quiescence - the
   synthesized transition path, which is not otherwise observable.
4. Compile a transition that omits `type` and confirm the compiled struct has
   `type: :external` with no `:type` key in the map - the whole point of the
   key-presence contract.

## References

- Bead: `st-9i5r` (mirrors `sui-qay` in statifier-ui, parked behind this)
- Related ADRs: `docs/adr/0012-debuggability-designed-into-the-core.md`
  (item 3, the retention constraint this widens),
  `docs/adr/0014-expression-spans-in-cond-diagnostics.md`
  (the expression-level layer, untouched here)
- `docs/observability.md` - constraint 3 and the "Where the seams live" table
- Precedent implementation: `lib/statifier/machine/invoke.ex:46-50,70,85` and
  its carry at `lib/statifier/compiler.ex:1511`
- Contract being preserved: `lib/statifier/document.ex:22-44,97`
- Test style: `test/statifier/lowering/location_test.exs:52-65`,
  `test/statifier/parser/location_accuracy_test.exs:13-41` (st-18y's harness)
- Amendment precedent: ADR-0012's st-1xwh amendment (2026-08-17)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Spec-conformance judgment: `Statifier.Interpreter.initial_transition/1`
      still matches Appendix D's `expandScxmlSource(doc)` normalization line
      for line. The only ADR-0002 deviation on this path remains the existing
      one - a synthesized transition is not a document element - and the
      comment now names both of its consequences (`t_index: nil`,
      `attribute_locations: %{}`) rather than one. No new deviation is
      introduced.
- [ ] The moduledoc paragraph reads as a sibling of `Machine.Invoke`'s, not a
      restatement of it: it says why *this* node takes the escape hatch and
      why `cond_location` stays out of it.
- [ ] A compiled transition from a real fixture, inspected in IEx, shows the
      map keys the source actually wrote and no others.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
