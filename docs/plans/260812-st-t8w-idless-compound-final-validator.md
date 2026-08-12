# Rejects an id-less compound state containing a final child Implementation Plan

## Overview

Appendix D's `enterStates` tail raises `done.state.{parent.id}` when a `<final>`
is entered whose parent is not the `:scxml` root. The pseudocode assumes that
parent has an id; this codebase deliberately admits states that do not
(`Statifier.Validator.Checks.Ids` keeps `nil` and `""` out of the uniqueness set
rather than rejecting them), so st-wju.4 guarded the two raise sites instead and
an id-less parent raises nothing at all.

This plan moves the decision to the layer that owns it: the validator refuses a
document in which a `<final>`'s parent state carries no `id`, because the spec
names that state's completion event after an id it does not have. The
interpreter's guards stay, with comments saying why. Bead: st-t8w.

## Current State Analysis

**The two raise sites.** `lib/statifier/interpreter/exit_entry.ex`:

- `raise_parent_completion/3` (`:758-783`) case-matches
  `Machine.id(machine, parent)` on `parent_id when is_binary(parent_id) and
  parent_id != ""` and returns `{machine_state, []}` on the `_no_id` arm.
- `maybe_raise_grandparent_completion/3` (`:795-823`) repeats the same guard for
  the parallel grandparent's `done.state.{grandparent_id}`.

Both are commented at `:751-757` as skipping the event because
`Statifier.Validator.Checks.Ids` keeps `nil`/`""` ids legal.
`docs/plans/260810-st-wju.4-ports-exit-and-entry-sets.md:499-509` is Decision 9,
which settled the guard and explicitly deferred the validator-shaped fix as a
call st-wju.4 was not entitled to make.

**Which parents can reach site 1.** `raise_completion_events/2` (`:737-749`)
routes to `raise_parent_completion/3` for **any** entered `:final` whose
`parent != 0`. It does not require the parent to be a compound `<state>`: a
`<final>` written as a direct child of a `<parallel>` reaches the same site with
`parent` being that `<parallel>`. So "the parent of a `<final>`" - not "a
compound state" narrowly - is the condition the rule has to cover to make site 1
unreachable.

**Which parents can reach site 2.** Site 2 fires only when the *grandparent* is
a `:parallel` and **every** one of its regions currently satisfies
`in_final_state?/2`. That is a runtime configuration property, not a static
document property; deciding it statically is reachability analysis, which the
validator declines as a stated non-goal
(`docs/plans/260808-st-l5k.5-document-validator.md`, Decision 4's rationale, and
the research doc's non-goals). No static rule makes site 2 unreachable.

**The validator's shape.** `lib/statifier/validator.ex` holds an eleven-entry
`@checks` list of `&Module.check/2` captures, runs every one on every call,
collects rather than fail-fasts, and sorts by `location.start_offset`. There is
no severity axis: Decision 4 of the validator plan
(`docs/plans/260808-st-l5k.5-document-validator.md:296-313`) settled
`{:ok, document} | {:error, [Error.t()]}` with **no warning channel**, on the
grounds that every check is a spec MUST and a warning list with zero producers is
speculative API. So "whatever severity st-l5k.5 established" resolves to: a hard
error that makes `validate/2` return `{:error, errors}`.

**One check per file.** `lib/statifier/validator/checks/*.ex`, each with a
numbered moduledoc citing its spec section, a `check(document, context)` that
returns `[Error.t()]`, and a private `flatten/1` over `state.states`.
`checks/donedata.ex` and `checks/final.ex` are the closest templates.

**Error construction.** `lib/statifier/validator/error.ex` holds a closed
`@type reason` union plus one constructor per tag.
`test/statifier/validator/layer_test.exs` walks that file's AST and enforces
that every tag in the union has exactly one constructor, that no two
constructors share a tag, and that every tag is actually called from some module
under `checks/`. A new reason therefore needs all three: union entry,
constructor, and a call site in a check module.

### Key Discoveries:

- **Exactly one in-repo document is newly rejected**, and it is not in the
  corpus. A REXML scan of all 556 candidate files in the repo (277 corpus test
  files carrying 273 `<scxml>` blocks, the four `ns0:`-prefixed
  `atom3_basic_tests` documents rescanned separately, plus every `test/`,
  `lib/`, and `docs/` heredoc and every `.xml`/`.scxml` file) found a single
  `<state>` or `<parallel>` with an absent/empty `id` and a direct `<final>`
  child:
  `test/statifier/interpreter/exit_entry_enter_test.exs`'s `@document`
  (`:107-109`, the unnamed compound at hand-drawn index 20 wrapping
  `<final id="noid_final"/>`). **The generated conformance corpus is entirely
  clean**, so no corpus document needs fixing or excluding.
- That fixture is compiled through `compile!/1`
  (`test/statifier/interpreter/exit_entry_enter_test.exs:13-19`), which asserts
  `{:ok, document} = Validator.validate(document, xml)`. Adding the rule turns
  that into a `MatchError` at module setup, reddening **every** test in the file,
  not only the id-less one. This is the reason for the phase ordering below.
- `Statifier.Validator.Checks.Ids` (`checks/ids.ex:39-43`) already reports
  `{:empty_id}` for every state written `id=""`, independently of what it
  contains. An `id=""` compound wrapping a `<final>` is therefore *already*
  rejected today. See Open Question 1.
- `Statifier.Validator.Context.compound?/1` (`context.ex:78-81`) counts
  `:parallel`, and `Checks.DefaultEntry`'s moduledoc (`checks/default_entry.ex:19-25`)
  documents that widening a check to it rejected four valid SCION documents.
  This rule wants the parallel included, but for the opposite reason: the raise
  site does not care which kind the parent is.
- Validator errors are collect-all and document-order sorted
  (`validator.ex:6-29`), so the new check adds to the list rather than
  short-circuiting anything.
- ADR-0002 (literal Appendix D port) and `docs/architecture.md` principle 4 (the
  validator is the only gate in front of the compiler) are the two settled
  decisions this plan sits between: the guard is a deviation the validator can
  *justify*, not one it can *delete*, because `Compiler.compile/1` is public and
  reachable without `Validator.validate/2`.

## Desired End State

`Statifier.Validator.validate/2` returns `{:error, [%Error{reason:
{:final_parent_missing_id, final_id}}]}` for any document containing a `<state>`
or `<parallel>` with no written `id` and a direct `<final>` child, located at the
id-less parent's own span. Every other document the validator accepts today it
still accepts, including an id-less state with no `<final>` child anywhere under
it.

The two `done.state.*` guards in `lib/statifier/interpreter/exit_entry.ex` remain
in place, each carrying a comment naming st-t8w and stating why defense in depth
is wanted rather than reading as an unexplained leftover.

Verification that the end state is reached: full `mix quality` green with
coverage at or above the 90% floor; `mix test --include scion --include scxml_w3`
showing no change in conformance results; `mix test.regression` green with
`test/passing_tests.json` unchanged.

## What We're NOT Doing

- **Not making the grandparent-parallel raise site statically unreachable.** It
  fires on a runtime configuration property (`in_final_state?/2` over every
  region), and refusing every id-less `<parallel>` with a `<final>` descendant
  would require reachability analysis the validator has declined since st-l5k.5.
  Its guard stays and is commented as load-bearing rather than defensive.
- **Not removing either guard.** See Open Question 2 for the reasoning and the
  criterion the bead offers as the alternative.
- **Not adding a warning channel or a severity axis.** Decision 4 of
  `docs/plans/260808-st-l5k.5-document-validator.md` settled that; this bead is
  not the place to reopen it.
- **Not touching the conformance corpus or `test/passing_tests.json`.** The scan
  found nothing to fix, and a corpus edit with no failing document behind it
  would be a change with no cause.
- **Not rejecting an id-less state on general principle.** A state with no id and
  no `<final>` child stays legal; the rule is about the completion event's name,
  not about anonymity.
- **Not reporting the `<final>` child's own span.** The offending element is the
  parent that omitted its `id`, so that is where the caret goes - the same
  reasoning `Checks.Final` applies in the opposite direction when it reports at
  the child's span.

## Implementation Approach

Two phases, ordered by the coupling discovered above rather than by module.

The behavior change is a single new check module, which is naturally one commit.
But the moment it is wired into `@checks`, the interpreter's own entry test file
stops compiling its fixture, because that file runs its heredoc through the real
validator. Landing both in one commit would mean a phase whose diff spans the
validator and the interpreter suite for a reason a reviewer has to reconstruct.

So Phase 1 detaches the interpreter fixture from the validator first - a
test-only change that is green on its own and whose comment states the incoming
rule - and Phase 2 lands the rule against a suite that is already ready for it.
Phase 2 is where the interpreter guard comments land, since only then are they
true.

## Phase 1: Detach the id-less interpreter fixture from the validator

### Overview

`test/statifier/interpreter/exit_entry_enter_test.exs` deliberately contains a
document the validator is about to refuse, because it is the only way to exercise
the `_no_id` arm of `raise_parent_completion/3`. Give that file a second compile
path that stops before the validator, and use it for the shared fixture.

### Changes Required:

#### 1. The interpreter entry test's compile helper

**File**: `test/statifier/interpreter/exit_entry_enter_test.exs`
**Changes**: Add `compile_unvalidated!/1` beside the existing `compile!/1`
(`:13-19`) and point the shared `machine()` fixture at it. Keep `compile!/1` if
any other fixture in the file still uses it; delete it only if nothing does, so
the gate's unused-function check stays quiet.

```elixir
  # `@document` deliberately contains an id-less compound wrapping a
  # `<final>` (index 20 below), the one shape
  # `raise_parent_completion/3`'s `_no_id` arm exists for. st-t8w will
  # make `Statifier.Validator` refuse exactly that document, so this
  # fixture compiles through Parser -> Lowering -> Compiler and skips the
  # validator: the guard it covers is defense in depth behind a gate that
  # will reject the input, and a test for it cannot pass through that
  # gate by construction.
  defp compile_unvalidated!(xml) do
    {:ok, root} = Parser.parse(xml)
    {:ok, document} = Lowering.lower(root)
    {:ok, machine} = Compiler.compile(document)
    machine
  end
```

#### 2. The fixture's own index comment

**File**: `test/statifier/interpreter/exit_entry_enter_test.exs`
**Changes**: The hand-drawn index comment's line 20 (`(unnamed compound - no
id)`, `:44-45`) gains a clause noting that this document is intentionally
validator-rejected, so the next reader does not "fix" the fixture by giving the
state an id and silently deleting the coverage.

#### 3. Sabotage bookkeeping

**File**: `test/statifier/interpreter/exit_entry_enter_test.exs`
**Changes**: No test assertion changes, so no sabotage line changes. The existing
line above `"a compound parent with no id raises nothing and does not crash"`
(`:443-448`) still describes a valid mutation and still reddens.
`docs/testing.md`'s requirement is on new or changed *tests*; a changed compile
helper that leaves every assertion identical is harness plumbing, and the
comment in change 1 is its stated exemption.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` green while iterating (never as the phase gate)
- [x] Full `mix quality` green, including the 90% `lib/` coverage floor
- [x] `mix test test/statifier/interpreter/exit_entry_enter_test.exs` green with
      the same test count as before the change
- [x] `mix gate.verify` confirms the green was a full, unscoped run

#### Manual Verification:

- [ ] The touched code is test harness only - `lib/statifier/interpreter/exit_entry.ex`
      is untouched in this phase, so the Appendix D port is unchanged by
      construction
- [ ] The comment on `compile_unvalidated!/1` reads as a deliberate bypass with a
      stated reason, not as a shortcut
- [ ] No other test file compiles this fixture (`grep -rn "noid_final" test/`
      returns only this file)

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual items. In looped (`--loop`) execution, the Automated
Verification list gates advancement via `/wurk:commit --auto` and the Manual
items are surfaced once at the end.

---

## Phase 2: Reject an id-less parent of a `<final>`

### Overview

Add the reason, the constructor, the check module, and the wiring; comment both
interpreter guards. No changelog fragment is due - see change 5.

### Changes Required:

#### 1. The error reason and its constructor

**File**: `lib/statifier/validator/error.ex`
**Changes**: One entry in the `@type reason` union (`:33-55`) and one
constructor, placed next to `final_has_states/2` and `final_has_transitions/2` so
the `<final>` family stays together.

```elixir
          | {:final_parent_missing_id, final_id :: binary() | nil}
```

```elixir
  @doc """
  Check 12 (spec 3.7, Appendix D `enterStates`): a `<final>` state's parent
  carries no `id`. Entering a non-top-level `<final>` raises
  `done.state.{parent.id}`, so a parent with no written id has a completion
  event the spec names after a name it does not have - and no transition
  could match `"done.state."` even if it were raised. `final_id` is the
  offending `<final>` child's own id (itself optionally `nil`), which names
  the completion the document loses; the location is the **parent's** span,
  since the parent is the element that has to change.
  """
  @spec final_parent_missing_id(final_id :: binary() | nil, location :: Location.t()) :: t()
  def final_parent_missing_id(final_id, %Location{} = location) do
    %__MODULE__{
      reason: {:final_parent_missing_id, final_id},
      message:
        "a state containing <final> #{inspect(final_id)} must have an id - its " <>
          "completion event is named done.state.<id>",
      location: location
    }
  end
```

#### 2. The check module

**File**: `lib/statifier/validator/checks/final_parent.ex` (new)
**Changes**: A `check/2` in the family's shape: flatten, keep every state with a
`nil` id and at least one `kind: :final` child, report once per such parent.

Deliberately **not** filtered to `kind: :state`: `raise_completion_events/2`
routes on the entered state being `:final` and its `parent != 0`, never on the
parent's kind, so a `<final>` written directly under a `<parallel>` reaches the
same raise site and the same missing name. The moduledoc says this, and says why
that is the opposite of `Checks.DefaultEntry`'s narrowing to `:state`.

Also deliberately reporting **once per parent**, not once per `<final>` child: a
parent with two `<final>` children has one mistake (one missing `id`), and the
validator's own "one rule, one owner" principle (Decision 5 of the st-l5k.5 plan)
argues against two errors on one span. The first `<final>` child in document
order supplies `final_id`.

Top-level `<final>` elements are outside the rule by construction, since the
check only ever looks at a `State.t()`'s own `states` list and never at
`Document.states`. That matches `raise_completion_events/2`'s `parent == 0` arm,
which raises nothing and only clears `running`.

```elixir
  defp offending?(%State{id: nil, states: children}),
    do: Enum.any?(children, &(&1.kind == :final))

  defp offending?(%State{}), do: false
```

#### 3. Wiring and the count in prose

**File**: `lib/statifier/validator.ex`
**Changes**: `alias Statifier.Validator.Checks.FinalParent`, `&FinalParent.check/2`
added to `@checks` next to `&Final.check/2`, and `validate/2`'s `@doc` updated
from "all eleven `@checks`" to twelve (`:61`). The `@checks` order does not
affect output - errors are sorted by `location.start_offset` regardless - so
placement is for readability only.

#### 4. Both interpreter guard comments

**File**: `lib/statifier/interpreter/exit_entry.ex`
**Changes**: The comment above `raise_parent_completion/3` (`:751-757`) is
rewritten, and a matching clause is added to
`maybe_raise_grandparent_completion/3`'s (`:786-789`). The two say different
things and that difference is the point:

- The **parent** guard is now defense in depth. `Statifier.Validator.Checks.FinalParent`
  refuses the document, but `Statifier.Compiler.compile/1` is public and
  reachable without the validator (`docs/architecture.md` principle 4 makes the
  validator the only gate *in the pipeline*, not the only possible caller), and
  `Machine.id/2`'s return type still admits `nil`. The comment cites st-t8w and
  says the guard is kept for that reason, not that it is unreachable.
- The **grandparent** guard is still load-bearing. Whether a `<parallel>`'s every
  region reaches a final state is a runtime property, so no static rule refuses
  the id-less parallel that reaches this site. The comment says so, so nobody
  later removes it by symmetry with the parent's.

#### 5. No changelog fragment - checked, not assumed

**File**: none
**Changes**: Deliberately no `changelog.d/st-t8w.md`.

The general rule in `changelog.d/README.md` ("a change in observable behavior")
would call for one, but the narrower **"While v2 is unreleased"** rule overrides
it: write a fragment only when **v2 differs from v1**. v1's
`Statifier.Validator.StateValidator.validate_non_empty_ids/2`
(`../statifier/lib/statifier/validator/state_validator.ex:46-53`) filters
`is_nil(&1.id) or &1.id == ""` and errors on **every** such state, so v1 already
rejects an id-less compound wrapping a `<final>` - more broadly than this rule
does. This bead therefore *removes* a v1/v2 difference rather than creating one:
for the document in question, v1 rejected and v2 now rejects too. A fragment
would tell a 1.x upgrader about a behavior that has not changed for them.

Note that `../statifier` is not reachable from a worktree of this repo; the path
above is relative to the main checkout.

#### 6. Tests

**File**: `test/statifier/validator/checks/final_parent_test.exs` (new)
**Changes**: Modeled on `test/statifier/validator/checks/final_test.exs`, driving
`Statifier.Validator.validate/2` end to end over triple-quoted 4-space-indented
heredocs. Each test carries its `# sabotage: <mutation> -> red` line per
`docs/testing.md`. Coverage:

1. **The rule.** An id-less `<state>` wrapping `<final id="done"/>` is rejected
   with `{:final_parent_missing_id, "done"}`, at the parent's span.
   Sabotage: invert `offending?/1`'s `Enum.any?` to `Enum.all?` and add a
   non-final sibling -> the parent stops being reported.
2. **The near miss.** An id-less `<state>` with a `<state>` child and no `<final>`
   anywhere under it validates `{:ok, _}`. Sabotage: drop the `&(&1.kind ==
   :final)` predicate so any child counts -> this document is wrongly rejected.
3. **The near miss, deeper.** An id-less `<state>` whose `<final>` is a
   *grandchild* (nested under a named child) validates `{:ok, _}` - the raise
   site reads the final's immediate parent, so the rule is about direct children.
   Sabotage: recurse `offending?/1` into descendants -> this is wrongly rejected.
4. **Named parent.** A `<state id="p">` wrapping a `<final>` validates
   `{:ok, _}`. Sabotage: drop the `id: nil` head so every parent matches.
5. **Top-level `<final>`.** A `<final>` as a direct child of `<scxml>` validates
   `{:ok, _}`, since its completion raises no event at all. Sabotage: walk
   `Document.states` as if it were a parent's child list.
6. **Parallel parent.** An id-less `<parallel>` with a direct `<final>` child is
   rejected. Sabotage: narrow the head to `kind: :state` -> not reported.
7. **The `id=""` parent.** An `id=""` `<state>` wrapping a `<final>` is rejected -
   asserted as "the document is refused", listing the reasons present rather than
   pinning a single one, so the test states the acceptance criterion's guarantee
   without hard-coding which check delivers it. See Open Question 1.
8. **One error per parent.** An id-less `<state>` with two `<final>` children
   produces exactly one `:final_parent_missing_id`. Sabotage: map over children
   instead of reporting once -> two errors.

`test/statifier/validator/layer_test.exs` needs no edit: it globs
`checks/*.ex` and asserts `length(@check_sources) >= 9`, and its "every reason
tag is called by some check module" guard is satisfied by change 2.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality --profile loop` green while iterating (never as the phase gate)
- [x] Full `mix quality` green, including the 90% `lib/` coverage floor and Doctor's
      100% documentation thresholds on the new public function and module
- [x] `mix gate.verify` confirms the green was a full, unscoped run
- [x] `mix test --include scion --include scxml_w3` shows the same pass/fail split
      as on `origin/main` - the corpus scan predicts zero newly failing documents
- [x] `mix test.regression` green with `test/passing_tests.json` unchanged (no
      `mix test.baseline add` should be needed; if one is, the corpus scan was
      wrong and that is a finding, not a ratchet step)
- [x] `mix gate.check` clean - this branch edits no file in the manifest's
      `moving_files`, adds no `@tag :skip`, and does not shrink
      `test/passing_tests.json`, so no `docs/quality-gate-changes.md` entry is due
- [x] `mix adr.check` clean

#### Manual Verification:

- [ ] Spec-conformance judgment on the touched interpreter file: the guards in
      `raise_parent_completion/3` and `maybe_raise_grandparent_completion/3` still
      match Appendix D's `enterStates` tail line for line, with the deviation
      (skipping the event) unchanged and now carrying a comment citing st-t8w for
      the mechanical reason (ADR-0002)
- [ ] The two guard comments say *different* things, and the grandparent one is
      not phrased in a way that invites a later symmetry-driven deletion
- [ ] The error message reads usefully with a `nil` `final_id` (`"a state
      containing <final> nil must have an id"`) - awkward but honest, and the
      location still points at the element to fix
- [ ] Each new test's sabotage was actually performed: broken, confirmed red,
      reverted, confirmed green, mutation recorded above the `test` line
- [ ] Reading `docs/plans/260810-st-wju.4-ports-exit-and-entry-sets.md` Decision 9
      alongside the new comments, the two tell one consistent story

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual items. In looped (`--loop`) execution, the Automated
Verification list gates advancement via `/wurk:commit --auto` and the Manual
items are surfaced once at the end.

---

## Corpus/Ratchet Notes

**No corpus document is newly rejected, and this was checked rather than
assumed.** The scan parsed every `<scxml>` document reachable in the repo with
REXML and looked for a `<state>` or `<parallel>` element with an absent or empty
`id` attribute and at least one direct `<final>` child:

| Source | Documents | Newly rejected |
|---|---|---|
| `test/scion_tests/**/*.exs` + `test/scxml_tests/**/*.exs` | 277 files, 273 heredoc `<scxml>` blocks | 0 |
| The four `ns0:`-prefixed `atom3_basic_tests` documents (missed by a bare `<scxml` match, rescanned by local name) | 4 | 0 |
| Every other `.exs`/`.ex`/`.xml`/`.scxml`/`.md` heredoc in the repo outside `_build/`, `deps/`, and the plan and research directories | 556 files scanned | 1 |

The single hit is `test/statifier/interpreter/exit_entry_enter_test.exs`'s own
fixture, which Phase 1 handles by construction rather than by editing the
document. So:

- `test/passing_tests.json` is not touched, and `mix test.baseline add` should
  not be run on this branch.
- No corpus document is excluded, and `tools/corpus/`'s exclusion manifest is not
  touched.
- If `mix test --include scion --include scxml_w3` in Phase 2 does show a newly
  failing conformance document, the scan missed a shape (the likeliest candidate
  being a namespace prefix form not covered above) and the right response is to
  re-run the scan against that document, not to exclude it.

## Testing Strategy

### Unit Tests:

- `test/statifier/validator/checks/final_parent_test.exs` - the eight cases in
  Phase 2 change 6, driven through `Statifier.Validator.validate/2` rather than
  through `FinalParent.check/2` directly, matching every sibling check test's
  style and proving the wiring at the same time.
- `test/statifier/interpreter/exit_entry_enter_test.exs` - unchanged assertions.
  The existing `"a compound parent with no id raises nothing and does not crash"`
  test keeps the `_no_id` arm of `raise_parent_completion/3` covered against the
  90% floor once the validator refuses that document through the ordinary path.
- The parallel-grandparent `_no_id` arm of `maybe_raise_grandparent_completion/3`
  is covered by whatever already covers it; if `mix quality`'s coverage report
  shows it uncovered after Phase 2, add an id-less-`<parallel>` case to the same
  unvalidated fixture rather than lowering the floor.

### Manual Testing Steps:

1. In `iex -S mix`, parse, lower, and validate a minimal document with an id-less
   `<state>` wrapping `<final id="d"/>`; confirm `{:error, [%Error{reason:
   {:final_parent_missing_id, "d"}}]}` and that the reported `location` slices
   back to the `<state>` element, not the `<final>`.
2. Repeat with `<state id="p">` wrapping the same `<final>`; confirm `{:ok, _}`.
3. Repeat with an id-less `<state>` containing only `<state id="a"/>`; confirm
   `{:ok, _}` - the rule is not over-broad.
4. Run `mix test --include scion --include scxml_w3` before and after Phase 2 and
   diff the summary lines.

## Open Questions Recorded for the Human

The bead was planned with no human available, so these two were decided here with
reasoning rather than left blank. Both are cheap to reverse.

### Open Question 1: does the rule fire on `id=""` as well as `id=nil`?

The acceptance criterion says "an id-less (nil or empty) compound state".
Firing on both means an `id=""` parent of a `<final>` produces **two** errors -
`{:empty_id}` from `Checks.Ids` plus `{:final_parent_missing_id}` - for one
mistake, which is exactly the outcome the validator plan's Decision 5 ("one rule,
one owner") was written to avoid, and exactly the error-output quality st-l5k.5's
bead called out.

**Recommendation: fire on `id: nil` only.** The criterion's guarantee - that a
document with an id-less compound wrapping a `<final>` is reported - already
holds for the empty case, because `Checks.Ids` rejects **every** `id=""` state
outright regardless of what it contains. Nothing reaches the compiler, so the
raise site is unreachable for `""` either way. Test 7 in Phase 2 asserts the
guarantee at the level the criterion states it (the document is refused, with the
reasons listed) rather than pinning which check delivers it, so the test stays
green under either answer and a later reviewer can change the rule without
rewriting the test's intent.

Reversing this is a one-clause change: add `defp offending?(%State{id: "", states:
children})` alongside the `nil` head.

### Open Question 2: remove the exit_entry guards, or keep them?

The bead offers both: "either removed with a comment citing this bead, or kept
with a comment saying why defense in depth is wanted".

**Recommendation: keep both, with the two distinct comments described in Phase 2
change 4.** Three reasons:

1. The grandparent guard is not made unreachable by anything in this plan, and
   cannot be without reachability analysis the validator has declined since
   st-l5k.5. Removing it would be a live crash on an id-less `<parallel>` whose
   regions all complete. Keeping one and removing the other would leave an
   asymmetry that reads as an oversight.
2. `Machine.id/2` returns `String.t() | nil` and `Statifier.Compiler.compile/1`
   is public. `docs/architecture.md` principle 4 makes the validator the only
   gate in the *pipeline*, which is a statement about the pipeline, not a type-
   level guarantee about every caller. Removing the parent guard converts a
   validator bypass from "no completion event" into an `ArgumentError` raised
   from inside the pure core - the worst failure mode available.
3. ADR-0002 treats a deviation from the pseudocode as a bug unless an inline
   comment cites the mechanical reason. The guard is a deviation either way; the
   comment is what legitimizes it, and this bead is precisely the event that
   makes the comment writable. Deleting the guard would remove the deviation, but
   at the cost of (1) and (2).

Reversing this is also cheap: delete the two `case`/`_no_id` arms, delete the
`"a compound parent with no id"` test, and revert Phase 1's
`compile_unvalidated!/1`. Whoever does it should read Open Question 2's reason 1
first, since it applies to the grandparent site regardless.

## References

- Bead: `st-t8w`
- Source decision: `docs/plans/260810-st-wju.4-ports-exit-and-entry-sets.md:499-509`
  (Decision 9 - the guard, and the deferral of this fix)
- Severity convention: `docs/plans/260808-st-l5k.5-document-validator.md:296-313`
  (Decision 4 - errors only, no warning channel) and `:314-330` (Decision 5 - one
  rule, one owner)
- Validator research: `docs/research/260808-st-l5k.5-document-validator.md`
- Raise sites: `lib/statifier/interpreter/exit_entry.ex:737-823`
- Check templates: `lib/statifier/validator/checks/final.ex`,
  `lib/statifier/validator/checks/donedata.ex`,
  `lib/statifier/validator/checks/default_entry.ex:19-25` (the `:state`-versus-
  `compound?/1` narrowing argument, inverted here)
- Error shape and its AST guard: `lib/statifier/validator/error.ex`,
  `test/statifier/validator/layer_test.exs`
- Newly rejected fixture: `test/statifier/interpreter/exit_entry_enter_test.exs:13-19`,
  `:44-45`, `:107-109`, `:443-458`
- Sabotage requirement: `docs/testing.md` ("Sabotage testing")
- Layering: `docs/architecture.md` principle 4; ADR-0002 (literal Appendix D
  port), ADR-0005 (interned indexes below the boundary)

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The touched code is test harness only - `lib/statifier/interpreter/exit_entry.ex`
      is untouched in this phase, so the Appendix D port is unchanged by
      construction
- [ ] The comment on `compile_unvalidated!/1` reads as a deliberate bypass with a
      stated reason, not as a shortcut
- [ ] No other test file compiles this fixture (`grep -rn "noid_final" test/`
      returns only this file)

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual items. In looped (`--loop`) execution, the Automated
Verification list gates advancement via `/wurk:commit --auto` and the Manual
items are surfaced once at the end.

---

### Phase 2

- [ ] Spec-conformance judgment on the touched interpreter file: the guards in
      `raise_parent_completion/3` and `maybe_raise_grandparent_completion/3` still
      match Appendix D's `enterStates` tail line for line, with the deviation
      (skipping the event) unchanged and now carrying a comment citing st-t8w for
      the mechanical reason (ADR-0002)
- [ ] The two guard comments say *different* things, and the grandparent one is
      not phrased in a way that invites a later symmetry-driven deletion
- [ ] The error message reads usefully with a `nil` `final_id` (`"a state
      containing <final> nil must have an id"`) - awkward but honest, and the
      location still points at the element to fix
- [ ] Each new test's sabotage was actually performed: broken, confirmed red,
      reverted, confirmed green, mutation recorded above the `test` line
- [ ] Reading `docs/plans/260810-st-wju.4-ports-exit-and-entry-sets.md` Decision 9
      alongside the new comments, the two tell one consistent story

**Implementation Note**: Use `mix quality --profile loop` between edits; full
`mix quality` is the phase gate. In interactive execution, pause here for the
human to confirm the manual items. In looped (`--loop`) execution, the Automated
Verification list gates advancement via `/wurk:commit --auto` and the Manual
items are surfaced once at the end.

---
