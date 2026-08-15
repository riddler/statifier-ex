# Datamodel key guard for `MachineState.new/2` Implementation Plan

## Overview

`Statifier.MachineState.new/2`'s `:datamodel` option is the only place a
caller-supplied map enters `machine_state.datamodel` without any check on its
keys. Every other writer produces string keys by construction, because every
other key comes from an SCXML id. This plan makes `new/2` reject a key that
violates the invariant, at every nesting level, with a message naming the
offending path - so the string-key invariant the rest of the system assumes is
established at the one door rather than assumed everywhere. Bead: st-e7w.

## Current State Analysis

**The hole.** `lib/statifier/machine_state.ex:268` reads the option and
`:276` merges it:

```elixir
author_datamodel = Keyword.get(opts, :datamodel, %{})
...
datamodel: Map.merge(author_datamodel, SystemVariables.initial(machine, session_id))
```

Nothing inspects the keys. The option is public API three levels up:
`Statifier.MachineState.new/2` itself, `Statifier.Interpreter.initialize/2`
(`lib/statifier/interpreter.ex:163,176` - "no option is interpreted"),
`Statifier.initialize/2` (`lib/statifier.ex:82`), and
`Statifier.Session.start_link/2` (`lib/statifier/session.ex:170`).

**What happens today with a bad key.** The two levels behave differently, and
neither is a good answer:

- **Top level.** `Statifier.Evaluator.context/1`
  (`lib/statifier/evaluator.ex:178-196`) folds `Predicator.Context.bind/3`
  over the datamodel's roots. `bind/3` is guarded `when is_binary(name)`
  (`deps/predicator/lib/predicator/context.ex:381`), so an atom root raises a
  bare `FunctionClauseError` from inside predicator, at the first evaluation
  site, long after the constructor that accepted it. `context/1`'s own `@doc`
  (`lib/statifier/evaluator.ex:167-175`) already states this and calls it "a
  louder failure for a case no writer can produce today" - true of every
  writer except the `:datamodel` option.
- **Every nested level.** `bind/3` applies
  `Predicator.Context.normalize_value/1` to the value it binds
  (`context.ex:382`), and `normalize_map/1` (`context.ex:499-514`) silently
  rewrites atom keys with `Atom.to_string/1`, dropping the atom entry
  entirely when a same-named string key already occupies the slot. So a
  nested atom key is neither rejected nor stably kept: it is coerced, per
  evaluation site, with a precedence rule the caller never saw, and the map
  stored on `%MachineState{}` never matches the map every expression is
  evaluated against.

**Why the invariant matters beyond tidiness.** predicator 8.0 offers
`Context.new/2`'s `normalize: false` - a caller-vouches contract that `data`
is string-keyed at every level. ADR-0030's amendment and
`lib/statifier/evaluator.ex:106-121` refuse it on unrelated grounds (the
shipped path never calls `new/2`; it starts from a compile-time constant and
binds per root). The bead is explicit that it is **not** a prerequisite for
revisiting that refusal - but it is the hole that would have to close first
if the vouch were ever taken, because the `:datamodel` option is the one
place a non-string key can enter.

**What predicator's normalization actually rewrites.** `normalize_value/1`
walks lists and non-struct maps; structs pass through whole
(`context.ex:480`); scalars pass through (`context.ex:484`). Inside a map,
`normalize_map/1` splits on `is_atom(key) and not is_boolean(key)`
(`context.ex:501`) - so **atom keys other than `true`/`false` are the entire
set of keys it rewrites.** Boolean keys are left alone deliberately (a
documented carve-out: `config[true]` compiles to a literal atom-key lookup),
and non-atom keys (binaries, integers) are already carried through unchanged.

**Existing conventions this has to fit.**

- `new/2` already rejects caller error by crashing: its head matches
  `%Machine{} = machine`, so a non-machine argument raises
  `FunctionClauseError`. Its `@spec` returns a bare `t()`, not
  `{:ok, t()} | {:error, _}`.
- `lib/statifier/` contains no `raise` in any runtime path today; the only
  raises in the tree are in `lib/mix/statifier/`. ADR-0003's "errors are
  events" rule is mechanically guarded by `Mix.Statifier.AdrGuard`, but the
  guarded pattern is I/O and process calls (`adr_guard.ex:87-93`) - `raise`
  is not in it.
- ADR-0018 is guarded mechanically too: `@bead_id_pattern`
  (`adr_guard.ex:107`) fails the gate on a bead id appearing in a comment,
  moduledoc, or test description. No `st-` id may appear in the code or test
  text this plan adds.
- `test/statifier/machine_state_test.exs:66-199` is the `new/2` describe
  block, one test per option, each carrying a `# sabotage:` note.

## Desired End State

`Statifier.MachineState.new/2` raises `ArgumentError` when its `:datamodel`
option contains a key that predicator's normalization would rewrite - an atom
key that is not `true`/`false` - anywhere in the walked structure: at the top
level, inside a nested map, inside a map held in a list, and at any depth
reachable by that walk. The message names the path to the offending key. Every
accepted `:datamodel` value is therefore string-keyed at every level in the
sense the `normalize: false` vouch means, so that walk is provably a no-op
over anything a `%MachineState{}` can hold, and the difference between the map
the caller passed and the map every expression sees is zero.

Verify: `mix quality` green, with new tests in
`test/statifier/machine_state_test.exs` asserting a raise at each nesting
level and a non-raise for the keys predicator carries through unchanged.

### Key Discoveries:

- `lib/statifier/machine_state.ex:268,276` - the unguarded read and merge.
- `deps/predicator/lib/predicator/context.ex:381` - `bind/3`'s
  `is_binary(name)` guard, the late and ugly version of this check.
- `deps/predicator/lib/predicator/context.ex:499-514` - `normalize_map/1`,
  whose `is_atom(key) and not is_boolean(key)` split defines exactly the set
  of keys this guard must reject.
- `deps/predicator/lib/predicator/context.ex:480` - structs pass through
  normalization unwalked; the guard must stop at the same boundary or it
  would reject `%Date{}` and every other struct a caller may legitimately
  seed.
- `lib/statifier/evaluator.ex:106-121` and
  `docs/adr/0030-in1-becomes-a-provider-context-stays-off-machinestate.md`
  (amendment) - the `normalize: false` refusal, argued on grounds this plan
  does not touch.
- `lib/statifier/evaluator.ex:167-175` - `context/1`'s claim that every
  writer produces binary keys, which this plan makes true rather than nearly
  true.
- `lib/mix/statifier/adr_guard.ex:107` - no bead id in any comment,
  moduledoc, or test description.
- `docs/testing.md:87-130` - the sabotage protocol; "deleting the function
  body or raising is not sabotage", so the mutation must be a plausible
  narrowing of the guard, not its removal.

## What We're NOT Doing

- **Not taking `normalize: false`.** ADR-0030's amendment and
  `lib/statifier/evaluator.ex:106-121` refuse it because the shipped path
  never calls `Context.new/2`, and that reasoning is untouched by this plan.
  Closing the hole does not reopen the decision; the bead says so in as many
  words.
- **Not normalizing.** Argued in "Implementation Approach" below rather than
  assumed, per the bead's acceptance criteria.
- **Not guarding the merged datamodel.** The walk covers the author's option
  only. `SystemVariables.initial/2` is string-keyed by construction and
  walking its output would be work spent re-checking this module's own
  literal.
- **Not guarding `put_event/2`, `<data>` seeding, `<assign>`, `<foreach>`, or
  a program's writes.** Each derives its key from an SCXML id or a literal in
  this codebase; the bead scopes the hole to the one caller-supplied source.
- **Not writing a changelog fragment.** Decided, with reasoning, in Phase 2's
  notes.
- **Not writing an ADR.** The decision is a constructor's argument contract,
  recorded in the moduledoc beside the option it constrains. It contradicts no
  accepted ADR and creates no cross-cutting rule; ADR-0030 is cited, not
  amended. If review disagrees, the moduledoc paragraph is the draft.

### Open questions recorded for the human

Each is **decided** below so the plan is executable as written; each is
recorded here because a reviewer may prefer the alternative, and changing it
is a one-line edit to the guard plus one test.

1. **Boolean and integer keys are accepted.** The guard rejects atom keys
   other than `true`/`false`, not "every non-string key". The stricter
   binary-only rule reads more directly off the phrase "string-key
   invariant", and would be simpler to state - but it would reject
   `%{"lookup" => %{1 => "a"}}`, which predicator carries through unchanged
   and evaluates correctly today. Decided: mirror predicator's own split, so
   the guard rejects exactly the keys whose presence would make the
   `normalize: false` vouch a lie and nothing else. If the reviewer prefers
   strict binary-only, change `offending_key?/1` to `not is_binary(key)` and
   flip the "keys predicator carries through unchanged" test.
2. **The guard walks values, including inside lists.** An alternative narrow
   reading of the acceptance criterion is "every nesting level of maps".
   Decided: walk exactly what `normalize_value/1` walks (lists and non-struct
   maps), because a map inside a list is a nesting level predicator does
   rewrite, and a guard that missed it would leave the vouch false.
3. **Structs are not walked.** Their fields are atom-keyed by definition and
   predicator passes them through whole. Decided: stop at the struct
   boundary. The consequence is that `%{"d" => %Date{}}` is accepted and its
   atom fields are not keys in the datamodel sense.

## Implementation Approach

### Decision 1: reject, do not normalize

The bead requires this argued. Four grounds, in the order they carry weight:

**a. Rejecting is what the system already does; normalizing would be a new
leniency.** A top-level atom key raises `FunctionClauseError` from
`bind/3` today. The guard moves that same refusal earlier, to the
constructor that accepted the value, and gives it a message. Normalizing
would instead make `new/2` accept input the current system crashes on -
adding behavior under the banner of closing a hole. The one place the system
does coerce today (nested keys, inside predicator's walk) is precisely the
silent behavior that makes the map on `%MachineState{}` differ from the map
expressions see; endorsing it by doing the same coercion earlier entrenches
the divergence rather than removing it.

**b. Normalizing means owning a coercion policy that belongs upstream.**
`normalize_map/1` has rules: string key beats same-named atom key, booleans
are exempt, structs are opaque. A statifier-side normalizer must reproduce all
of them and stay in step with them across predicator versions, or the map on
`%MachineState{}` diverges from the map predicator would have produced -
which is the exact failure `bind_roots/2`'s equivalence comment
(`lib/statifier/evaluator.ex:184-191`) and its test exist to prevent. ADR-0025
rule 1 puts the shape of predicator's own coercion in predicator's hands. A
rejection owns no policy: "the keys must be the ones predicator would not
rewrite" is a statement statifier can make and keep with no upstream
coupling beyond one guard predicate.

**c. Silent coercion loses caller intent, and can collide.**
`%{"x" => 1, x: 2}` normalizes to one entry, chosen by a precedence rule the
caller never stated. A constructor that quietly drops one of a caller's two
data items is a worse outcome for the caller than one that refuses the map
and says which key is wrong.

**d. The errors-are-events convention does not reach here.** CLAUDE.md's rule
- "evaluations return `{:ok, v} | {:error, e}`; only the interpreter raises
`error.execution`" - and `docs/architecture.md` principle 3 govern the
evaluation membrane: a document-authored expression failing at runtime is a
condition the SCXML spec has an answer for, and that answer is an
`error.execution` event on the internal queue. This is not that. `new/2` runs
before any state is entered, with no configuration, no queues, and no event
loop to deliver an event to; the offending value came from host Elixir code,
not from a document; and there is no spec clause describing it because SCXML
has no notion of an embedder-seeded Elixir map. It is a caller/programmer
error at a constructor, which in Elixir raises - and this constructor already
raises for the same species of error, via its `%Machine{}` head match. Its
`@spec` returns `t()`, so the alternative shape would be a tagged return
rippling through `Interpreter.initialize/2`, `Statifier.initialize/2`, and
`Session.start_link/2`, all of which document initialization as unfailable
(`lib/statifier.ex:79-81`: "a `%Machine{}` is valid by construction, so
initialization cannot fail"). Turning a programmer error into a runtime error
channel would make every caller handle a case that only a bug produces.

### Decision 2: the rejected set mirrors `normalize_map/1`'s split

The guard rejects a key iff `is_atom(key) and not is_boolean(key)`, i.e.
exactly the keys predicator's walk would rewrite. This makes the guard's
postcondition equal to the `normalize: false` precondition ("normalizing this
map would change nothing"), which is the invariant worth having rather than a
paraphrase of it. See open question 1 for the stricter alternative.

### Decision 3: the walk mirrors `normalize_value/1`

Descend lists and non-struct maps; stop at structs; ignore scalars. Same
boundary as upstream, for the same reason as Decision 2.

### Appendix D

`new/2` is not a port of an Appendix D procedure - it is the constructor of
the reified position ADR-0012 constraint 1 requires, and the pseudocode has no
counterpart to it (its globals are assigned inline in `interpret`). There is
therefore no pseudocode line for this change to deviate from, and no ADR-0002
mechanical-deviation comment is owed.

## Phase 1: The guard, its tests, and the moduledoc invariant

### Overview

Add the recursive key check to `MachineState.new/2`, bind it with tests at
every nesting level, and state the invariant in the moduledoc beside the
system-variables section that already describes what lives in `datamodel`.
These are one commit because the guard without the tests is an untested
behavior change and the tests without the guard are red.

### Changes Required:

#### 1. The guard

**File**: `lib/statifier/machine_state.ex`

**Changes**: Route the `:datamodel` option through a checking function before
the merge, and add the private walk. Keep the walk private to this module -
it has one caller and states this constructor's contract, not a shared rule.

```elixir
author_datamodel = opts |> Keyword.get(:datamodel, %{}) |> checked_datamodel!()
```

```elixir
# Mirrors `Predicator.Context`'s own `normalize_value/1` walk
# (`deps/predicator/lib/predicator/context.ex`): lists and non-struct maps
# are descended, structs pass through whole, scalars are ignored. Inside a
# map, `normalize_map/1` rewrites exactly the atom keys that are not
# `true`/`false` - `config[true]` is a literal atom-key lookup upstream, so
# boolean keys are data, not variable names - and those are exactly the keys
# refused here. What that buys: a caller-supplied datamodel that reaches the
# struct is one predicator's normalization would not change, at any depth, so
# the map stored here and the map every expression evaluates against are the
# same map. The refusal is deliberate rather than a silent stringification:
# coercing would duplicate upstream's precedence rules here, and would drop
# one of `%{"x" => 1, x: 2}`'s two entries by a rule the caller never stated.
@spec checked_datamodel!(datamodel :: map()) :: map()
defp checked_datamodel!(datamodel) when is_map(datamodel) do
  check_keys!(datamodel, [])
  datamodel
end

@spec check_keys!(value :: term(), path :: [term()]) :: :ok
defp check_keys!(list, path) when is_list(list) do
  list
  |> Enum.with_index()
  |> Enum.each(fn {element, index} -> check_keys!(element, [index | path]) end)
end

defp check_keys!(%_struct{}, _path), do: :ok

defp check_keys!(map, path) when is_map(map) do
  Enum.each(map, fn {key, value} ->
    if offending_key?(key), do: raise(ArgumentError, key_message(key, path))
    check_keys!(value, [key | path])
  end)
end

defp check_keys!(_scalar, _path), do: :ok

@spec offending_key?(key :: term()) :: boolean()
defp offending_key?(key), do: is_atom(key) and not is_boolean(key)
```

`key_message/2` builds the message from the reversed path, e.g.:

```
the :datamodel option must not contain the key :name at "user" -> "profile":
datamodel keys must be strings at every level, and an atom key would be
rewritten (or dropped, if a string key of the same name is present) by the
expression context this datamodel is evaluated against
```

Notes for the implementer:

- No bead id in any comment, moduledoc, or test description
  (`lib/mix/statifier/adr_guard.ex:107` fails the gate on one).
- `if ... do:` rather than `unless` - Credo's `RefuteCaseNegation`-family
  rules and this codebase's existing style both prefer the positive form.
- Doctor's thresholds require the module's public-function doc coverage to
  stay at 100%; these are private and carry `@spec` like the module's other
  privates.

#### 2. The `@doc` on `new/2`

**File**: `lib/statifier/machine_state.ex` (the `new/2` `@doc`, currently
lines 252-264)

**Changes**: Extend the options paragraph to state that `:datamodel` keys must
be strings at every level and that a violating key raises `ArgumentError`,
naming the boolean/struct boundaries so a caller can predict the answer
without reading the private walk.

#### 3. The moduledoc companion paragraph

**File**: `lib/statifier/machine_state.ex`, under "System variables live in
the datamodel" (currently line 139)

**Changes**: Add a short paragraph stating the string-key invariant for the
whole `datamodel` field: every key is a string, at every level; every writer
except the `:datamodel` option produces one by construction because every
other key is an SCXML id, and the option is checked in `new/2` so the field's
invariant holds for every reachable `%MachineState{}` value. Cite what the
invariant is for - the expression context built over this map binds by string
name - without re-arguing ADR-0030.

#### 4. The tests

**File**: `test/statifier/machine_state_test.exs`, inside the existing
`describe "new/2"` block, after the `:datamodel` tests at lines 171-186

**Changes**: Add tests binding the invariant at each level. Suggested shape,
one `assert_raise ArgumentError` per level so a partial guard cannot pass:

- top level: `datamodel: %{x: 1}`
- nested map: `datamodel: %{"user" => %{name: "Ada"}}`
- map inside a list: `datamodel: %{"rows" => [%{id: 1}]}`
- deeper still, to prove the walk is recursive rather than two levels deep:
  `datamodel: %{"a" => %{"b" => [%{"c" => %{d: 1}}]}}`
- the message names the offending key and its path (assert on the raised
  message, so a guard that raises without saying where does not pass)
- accepted: `%{"ok" => %{"nested" => [%{"deep" => 1}]}}` builds normally
- accepted, per Decision 2: `%{"flags" => %{true => 1}, "lookup" => %{1 => "a"}}`
- accepted: a struct value (`%{"d" => ~D[2026-08-15]}`) is not walked

**Sabotage** (`docs/testing.md:87-130`): every one of these tests asserts
`lib/` behavior, so every one carries its own note - one line, above the
`test` line, in the existing file's format. The mutation must be a plausible
narrowing, not a deletion: "deleting the function body or raising is not
sabotage". A mutation per test, so none is left to be invented mid-implementation:

| Test | Mutation |
|---|---|
| top level | `checked_datamodel!/1` returns `datamodel` without calling `check_keys!/2` at all - the option is read and merged unchecked, exactly the pre-change behavior |
| nested map, map in a list, deep nest | `check_keys!/2`'s map clause stops recursing (drop the `check_keys!(value, [key \| path])` call) - the top-level test stays green and all three nested tests redden together |
| message content | `key_message/2` drops the path from the message and names only the key |
| accepted: plain nested | `offending_key?/1` inverts to `is_binary(key)`, so a well-formed string-keyed map is refused |
| accepted: boolean and integer keys | `offending_key?/1` drops its `not is_boolean(key)` term (reddens the boolean case) and, separately, widens to `not is_binary(key)` (reddens the integer case) - two mutations, one per half of the assertion |
| accepted: struct value | `check_keys!/2`'s `%_struct{}` clause is removed, so the walk descends into a struct's atom-keyed fields |

Note that one mutation reddening three tests at once (the recursion stop) is
the `docs/testing.md:116-119` "one mutation, twenty tests" signal: it is
expected here and not a defect, because the three tests differ in *where* the
nesting sits (map, list, mixed depth) rather than in what they assert, and a
guard could plausibly handle maps but not lists. Say so in the notes rather
than collapsing the three into one test.

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (the phase gate). Use
      `mix quality --profile loop` between edits; a loop run alone never
      satisfies this phase.
- [x] `mix gate.verify` exits zero, proving the run was a full, unscoped,
      unskipped gate.
- [x] `mix test test/statifier/machine_state_test.exs` passes.
- [x] `mix test.regression` passes - the ratchet's `internal_tests` list is
      globbed, so the new tests join it the moment they are written.

#### Manual Verification:
- [x] Spec-conformance judgment: the change adds no Appendix D procedure and
      alters none, and `new/2`'s existing fields are untouched - confirm by
      reading the diff that only the `:datamodel` option's path changed.
- [x] No conformance movement: run `mix test --include scion --include
      scxml_w3` and compare its failure list against a run from
      `origin/main`. This is a manual item deliberately, not an automated
      one - no command decides "the same pass set as before" on its own
      (`mix test.regression` re-verifies only the fixed registry in
      `test/passing_tests.json`, so it cannot see a file outside it change
      state). No document supplies the `:datamodel` option, so the expected
      answer is an identical list and no `mix test.baseline add`; a
      difference means something other than this change moved.
- [x] Each sabotage was actually performed and reverted, and each note names
      the mutation that reddened its test.
- [x] The raised message is legible without reading the source: run
      `Statifier.initialize(machine, datamodel: %{"user" => %{name: "Ada"}})`
      in `iex -S mix` and confirm the message identifies both the key and its
      path.
- [x] No regression in the seeded-system-variable behavior: the existing
      `new/2` datamodel tests still describe the same merge order.

**Implementation Note**: Use `mix quality --profile loop` between edits and
the full `mix quality` as the phase gate. In interactive execution, pause here
for the human to confirm the manual items before Phase 2. In looped
execution, the Automated Verification list gates advancement and the manual
items are surfaced at the end.

---

## Phase 2: Reconcile the claims the rest of the tree makes about datamodel keys

### Overview

Two places assert the string-key property in prose that was true-by-luck
before Phase 1 and is true-by-construction after it. This phase is docs-only,
separately committable, and touches different modules than Phase 1 - which is
also why it is not folded in: it changes no behavior and should be reviewable
without re-reading the guard.

### Changes Required:

#### 1. `context/1`'s claim

**File**: `lib/statifier/evaluator.ex` (the `@doc` on `context/1`, currently
lines 167-175)

**Changes**: The sentence "Every writer of `machine_state.datamodel` produces
binary keys today (the seed in `MachineState.new/2`, ...)" lists writers and
concludes the `bind/3` crash is "a louder failure for a case no writer can
produce today". Amend it to say that the `:datamodel` option - the one writer
whose keys did not come from an SCXML id - is now checked in `new/2`, so the
property holds for every `%MachineState{}` rather than for every writer this
codebase happens to contain. Keep the existing `bind/3` sentence: the crash is
still the backstop for a struct assembled by hand in a test.

#### 2. `docs/datamodel.md`

**File**: `docs/datamodel.md`

**Changes**: One sentence in the "Evaluation contract" section stating that
datamodel keys are strings at every level and that an embedder-supplied
`:datamodel` is checked at construction. Do not restate the reject-vs-normalize
argument here - the moduledoc owns it; this is the pointer a reader of the
datamodel document needs to know the rule exists. Note that this file uses
plain hyphens, matching its neighbors.

#### 3. Changelog fragment: none, deliberately

No `changelog.d/st-e7w.md`. `changelog.d/README.md:40-50` narrows the rule
while v2 is unreleased: a fragment is owed when v2 differs from v1, and
`../statifier`'s `StateChart` has no author-supplied datamodel option at all
(`../statifier/lib/statifier/state_chart.ex:16,59,79` construct `datamodel:
%{}` unconditionally). There is nothing a 1.x user upgrading could tell the
difference about: the option itself is new in v2 and unreleased, so the guard
is part of its initial shape rather than a change to shipped behavior. If a
reviewer wants one anyway, the line is `### Changed` /
"`Statifier.MachineState.new/2` raises `ArgumentError` when its `:datamodel`
option contains a non-string key at any level."

### Success Criteria:

#### Automated Verification:
- [x] Full `mix quality` passes (the phase gate), including the docs stages.
- [x] `mix gate.verify` exits zero.
- [x] No `changelog.d/st-e7w.md` exists, and `git status` shows only the two
      documentation files changed in this phase.

#### Manual Verification:
- [x] Spec-conformance judgment for the `lib/statifier/` file touched:
      `evaluator.ex`'s change is prose only, and `context/1`'s behavior
      description still matches what the function does.
- [x] The amended `context/1` doc does not claim the `bind/3` guard is now
      unreachable - a hand-built `%MachineState{}` in a test can still reach
      it.
- [x] `docs/datamodel.md`'s new sentence reads as a pointer, not a second
      copy of the argument.

**Implementation Note**: Same gate rules as Phase 1.

---

## Performance Considerations

The walk is O(size of the caller-supplied datamodel), paid once per
`MachineState.new/2` call - which is once per session
(`Statifier.Interpreter.initialize/2` is its only caller in `lib/`). It is not
on any per-microstep or per-evaluation-site path, and it is strictly smaller
than the work `new/2` already does building the struct and merging the system
variables. For the overwhelmingly common case the option is absent and the
walk runs over `%{}`. No benchmark run is owed; the numbers ADR-0030 and
`bench/results/260815-st-59d-predicator-8-0.md` record are for the per-site
context build, which this change does not touch.

## Testing Strategy

### Unit Tests:

All in `test/statifier/machine_state_test.exs`, `describe "new/2"`, beside the
existing `:datamodel` option tests:

- One raise assertion per nesting level - top, nested map, map in a list, and
  a deeper mixed nest - so a guard that checks only the top level, or only
  two levels, or that fails to descend lists, is caught by a distinct failing
  test rather than by one test doing four jobs.
- One assertion on the message content (the key and its path), so the guard
  cannot pass by raising something unhelpful.
- Acceptance tests for the keys predicator carries through unchanged
  (boolean, integer) and for a struct value, pinning Decisions 2 and 3 so a
  later broadening or narrowing of the rule is a visible test change.
- A sabotage note per test, per `docs/testing.md:87-96` - every one of these
  asserts `lib/` behavior, so none is exempt. Phase 1's table names the
  mutation for each, so the implementer picks none of them mid-flight.

No conformance-corpus test can exercise this: no SCXML document supplies the
`:datamodel` option, which is exactly the property that made this the only
unguarded key source.

### Manual Testing Steps:

1. `iex -S mix`, compile a trivial document, and call
   `Statifier.initialize(machine, datamodel: %{"user" => %{name: "Ada"}})`.
   Confirm an `ArgumentError` naming `:name` and the path `"user"`.
2. Repeat with `datamodel: %{"user" => %{"name" => "Ada"}}` and confirm the
   machine initializes and `machine_state.datamodel["user"]` is the map as
   passed.
3. Start a `Statifier.Session` with a bad `:datamodel` and confirm the failure
   surfaces from `start_link/2` (as an exit from `init/1`) rather than being
   swallowed - the option is documented as passed straight through, and the
   guard's value depends on it reaching the caller.

## References

- Bead: `st-e7w` (surfaced by `st-59d`, filed out of that plan's "What We're
  NOT Doing")
- `lib/statifier/machine_state.ex:252-285` - `new/2`, the change site
- `lib/statifier/evaluator.ex:106-121,167-196` - the `normalize: false` cost
  paragraph and `context/1`'s key claim
- `deps/predicator/lib/predicator/context.ex:381-382,475-514` - `bind/3` and
  the normalization walk this guard mirrors
- `docs/adr/0030-in1-becomes-a-provider-context-stays-off-machinestate.md` -
  the `normalize: false` refusal, cited and unchanged
- `docs/adr/0028-executable-content-blocks-thread-one-context.md`,
  `docs/adr/0012-debuggability-designed-into-the-core.md`,
  `docs/adr/0003-pure-core-with-effects.md`, `docs/adr/0025-cross-repo-tracker-authority-and-mirrors.md`
- `docs/datamodel.md`, `docs/testing.md:87-130`, `changelog.d/README.md:40-50`
- `docs/plans/260815-st-59d-predicator-8-0-bump-structured-compile-errors.md` -
  where this bead was surfaced
- `test/statifier/machine_state_test.exs:66-199` - the `new/2` test block to
  extend

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

All eight items were verified with the human on 2026-08-15, after both
phases had landed. Two findings came out of it, neither a code defect; both
are recorded under "Findings from the verification pass" below.

### Phase 1

- [x] Spec-conformance judgment: the change adds no Appendix D procedure and
      alters none, and `new/2`'s existing fields are untouched - confirm by
      reading the diff that only the `:datamodel` option's path changed.
      *Verified: every struct field, the `@spec`, and every other `new/2`
      assignment are byte-identical; the only change is `Keyword.get/3`
      piping through `checked_datamodel!/1`.*
- [x] No conformance movement: run `mix test --include scion --include
      scxml_w3` and compare its failure list against a run from
      `origin/main`. This is a manual item deliberately, not an automated
      one - no command decides "the same pass set as before" on its own
      (`mix test.regression` re-verifies only the fixed registry in
      `test/passing_tests.json`, so it cannot see a file outside it change
      state). No document supplies the `:datamodel` option, so the expected
      answer is an identical list and no `mix test.baseline add`; a
      difference means something other than this change moved.
      *Verified: both runs performed - this branch, and `origin/main` in a
      throwaway worktree (`origin/main` was exactly `HEAD~2`, so the baseline
      carried no drift). 107 failures on each side, and `diff` of the two
      sorted failure lists is empty. The test count moves 1683 -> 1691,
      exactly the eight tests added here. No `mix test.baseline add` needed.*
- [x] Each sabotage was actually performed and reverted, and each note names
      the mutation that reddened its test.
      *Verified by re-running all seven distinct mutations mechanically
      against the committed tree: each reddened the test its note names, and
      the file reverted byte-identical afterwards. See finding 1 below.*
- [x] The raised message is legible without reading the source: run
      `Statifier.initialize(machine, datamodel: %{"user" => %{name: "Ada"}})`
      in `iex -S mix` and confirm the message identifies both the key and its
      path.
      *Verified via `mix run` over three shapes. The path segment renders as
      `the top level`, `"user"`, and `"a" -> "b" -> 0 -> "c"` - list indices
      included.*
- [x] No regression in the seeded-system-variable behavior: the existing
      `new/2` datamodel tests still describe the same merge order.
      *Verified: the test file's diff is 80 insertions and 0 deletions, so
      both pre-existing merge-order tests are untouched. Mutation D1 reddened
      both, which is what proves they are still live rather than passing
      vacuously.*

**Implementation Note**: Use `mix quality --profile loop` between edits and
the full `mix quality` as the phase gate. In interactive execution, pause here
for the human to confirm the manual items before Phase 2. In looped
execution, the Automated Verification list gates advancement and the manual
items are surfaced at the end.

---

### Phase 2

- [x] Spec-conformance judgment for the `lib/statifier/` file touched:
      `evaluator.ex`'s change is prose only, and `context/1`'s behavior
      description still matches what the function does.
      *Verified: the diff touches only the `@doc` heredoc; `def context/1`
      and `bind_roots/2` are unchanged. The description still matches -
      `bind_roots/2` folds `bind/3` over the top-level roots, which is
      exactly where the `is_binary(name)` guard the doc describes applies.*
- [x] The amended `context/1` doc does not claim the `bind/3` guard is now
      unreachable - a hand-built `%MachineState{}` in a test can still reach
      it.
      *Verified: the doc says so explicitly - "The `bind/3` crash remains
      the backstop for a `%MachineState{}` assembled by hand, bypassing
      `new/2` - as a test might."*
- [x] `docs/datamodel.md`'s new sentence reads as a pointer, not a second
      copy of the argument.
      *Verified: it states the invariant and where it is checked, then
      defers to `context/1`'s `@doc`; the reject-vs-normalize argument
      appears nowhere in it. House style also checked - that file contains
      no em dashes, so the plain-hyphen form used is the right one.*

**Implementation Note**: Same gate rules as Phase 1.

---

## Findings from the verification pass

Neither finding is a defect in the shipped code, and neither was acted on
during the pass - both are recorded so the next reader does not have to
rediscover them.

1. **The sabotage bookkeeping in this plan undercounts by one.** The
   recursion-stop mutation (`check_keys!/2`'s map clause dropping its
   recursive call) reddens *four* tests, not the three the notes claim: the
   message test uses `%{"user" => %{name: "Ada"}}`, whose offending key is
   nested, so it joins the set. Each individual sabotage note still names a
   mutation that genuinely reddens its own test, which is what
   `docs/testing.md` requires; only the cross-referencing prose in the notes
   on the three nesting tests is off. Left as-is rather than corrected in
   place, since editing a landed sabotage note to match a later recount is a
   change to the record rather than to the code.

2. **`new/2` on a non-map `:datamodel` raises a different error than it used
   to.** `checked_datamodel!/1` carries `when is_map(datamodel)`, so
   `new(machine, datamodel: [])` now raises `FunctionClauseError` on a
   private function, where it previously raised `BadMapError` from
   `Map.merge/2`. Both crash and neither is more informative, but the new
   one names a function the caller cannot see. No test covers it either way.
   Out of scope for this bead; worth a separate one only if the constructor
   ever grows a broader argument-shape contract.

---
