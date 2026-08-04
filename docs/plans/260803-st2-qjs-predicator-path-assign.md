# Auto-vivifying Path Assignment in Predicator Implementation Plan

## Overview

Add assignment-with-creation to predicator, beside the existing `context_location`
path resolution: given a context and a location path (or location expression), write
a value at that path, materializing any missing intermediate maps and lists along
the way. This closes seam #2 of `docs/datamodel.md`'s "Upstreaming to predicator"
list and removes the gap ADR-0004 named as "auto-vivifying assignment".

Beads issue: `st2-qjs` (label `upstream`).

**All code changes in this plan happen in a different repository**:
`~/repos/github/predicator-ex` (hex package `predicator`, currently v3.5.0, checked
out on `main`). Nothing in `statifier_2` changes. The statifier bead exists to track
the upstream work; the mirrored predicator-ex issue and PR are the deliverable.

## Current State Analysis

**What exists in predicator today:**

- `Predicator.context_location/3` (`lib/predicator.ex:476-493`) tokenizes, parses,
  and delegates to `Predicator.ContextLocation.resolve/2`.
- `Predicator.ContextLocation.resolve/2` (`lib/predicator/context_location.ex:101-244`)
  turns an assignable AST into a `location_path()` - `[binary() | integer()]` where
  strings are map keys and integers are list indices. It validates *shape* only: it
  never checks that intermediate containers exist, so
  `Predicator.context_location("user.profile.name", %{})` already returns
  `{:ok, ["user", "profile", "name"]}`.
  The single context-dependent case is a variable bracket key (`items[index]`,
  `context_location.ex:223-234`), which resolves the *key's value*.
- Negative indices are reachable: `resolve_bracket_key/2` accepts
  `{:unary, :minus, {:literal, n}}` and returns `-n` (`context_location.ex:217-220`).
- `Predicator.Errors.LocationError` (`lib/predicator/errors/location_error.ex`) has
  five error types, all about *resolution* failures: `:not_assignable`,
  `:invalid_node`, `:undefined_variable`, `:invalid_key`, `:computed_key`. There is
  no write-time error type.
- `:undefined` is predicator's existing sentinel for an absent value
  (`lib/predicator/evaluator.ex:380-388`).

**What is missing:** any function that takes `{:ok, path}` plus a value and produces
an updated context. Predicator has no `put_in`-equivalent for location paths, and
neither `README.md` nor `CHANGELOG.md` mentions one.

**What exists in statifier today:** nothing to integrate with. `lib/` has no
`<assign>` implementation, no interpreter, and no datamodel module
(`docs/research/260803-st2-qjs-predicator-path-assign.md`). `mix.exs:41` pins
`{:predicator, "~> 3.5"}`.

**Constraints discovered:**

- Predicator's own conventions (`~/repos/github/predicator-ex/CLAUDE.md`): work on a
  non-main branch, `@doc` + `@spec` on every public function, doctests, >90%
  coverage, `mix quality` as the gate (its own task at `lib/mix/tasks/quality.ex`;
  there is no `--profile loop` flag there), Keep-a-Changelog with an `## [Unreleased]`
  section, commit titles < 50 chars in simple present tense.
- ADR-0004 binds the direction: gaps go upstream into predicator, not into
  statifier's glue.
- `docs/datamodel.md:24-26` binds the semantics: ECMAScript-like auto-vivification,
  explicitly unlike v1's refusal to create intermediates.
- The 2026-08-03 six-seam design pass
  (`~/repos/github/predicator-ex/docs/design/2026-08-03-statifier-seams.md`)
  adopted this plan unchanged as release step 1 (the 3.6.0 feature) and made
  `put/3` a **contract-stable shared primitive**: predicator 3.8's
  `Context.assign/3` and 4.0's `["store", n]` statement opcode both write
  through it. Its signature and the semantics table below should be treated as
  frozen by that design, not merely by this plan.
- The same design pass decided **string keys are predicator's internal law**:
  atom keys convert eagerly at the future `Context` edge (3.8), and the
  read-side `String.to_existing_atom` fallbacks are deleted there. `put/3`
  anticipates this: it consults **string and integer keys only**, never atom
  keys. Writing `["user", "name"]` into a context holding `%{user: ...}`
  vivifies a new `"user"` map beside the atom key rather than descending into
  it. That divergence from the 3.5 evaluator's read fallback is accepted and
  documented (a doc note in `put/3`, plus one test pinning it); it resolves
  itself at 3.8 when contexts are normalized at the edge and the read
  fallback is gone.

## Desired End State

Predicator exposes two new public functions on a feature branch of predicator-ex,
with tests, docs, and a green `mix quality`:

```elixir
# Low-level primitive: context + resolved path + value
Predicator.ContextLocation.put(%{}, ["user", "profile", "name"], "Ada")
#=> {:ok, %{"user" => %{"profile" => %{"name" => "Ada"}}}}

# Expression-level convenience: resolve then put
Predicator.context_assign(%{}, "user.profile.name", "Ada")
#=> {:ok, %{"user" => %{"profile" => %{"name" => "Ada"}}}}
```

### Semantics (decided, not open)

1. **Auto-vivification fills absent slots only.** A segment whose current value is
   missing, `nil`, or `:undefined` is created: a following string segment vivifies a
   `%{}`, a following integer segment vivifies a `[]`.
2. **Collisions error.** A segment whose current value is a scalar (not a map, not a
   list) returns `{:error, %LocationError{type: :not_a_container}}`. This is the JS
   strict-mode TypeError behavior, and it is what statifier's interpreter will map
   to `error.execution`. Auto-vivification never destroys existing data.
3. **Integer segments index lists, and pad.** An integer index past the end of a list
   pads the gap with `:undefined` and writes at the index:
   `put(%{"items" => [1]}, ["items", 2], "x")` yields `%{"items" => [1, :undefined, "x"]}`.
   A negative index returns `{:error, %LocationError{type: :invalid_index}}`.
4. **Kind mismatches against an existing container error.** A string segment against
   an existing list is `:not_a_container`. An integer segment against an existing
   *map* is allowed and writes with the integer key (predicator's evaluator already
   reads integer-keyed maps), because refusing would destroy data the caller put there.
5. **The leaf is always overwritten,** whatever its current type, including when it
   currently holds a map or a list.
6. **An empty path errors** with `:not_assignable` rather than silently returning the
   context.

### How to verify

- `cd ~/repos/github/predicator-ex && mix quality` is green, coverage still >90%.
- The doctests in the new functions execute the table above.
- `git -C ~/repos/github/predicator-ex log` shows the work on a feature branch, and
  a PR is open against predicator-ex `main`.

## What We're NOT Doing

- **No version bump, no changelog release header, no hex publish.** The changes land
  under `## [Unreleased]`. Cutting 3.6.0 and pushing to hex is a separate, later act.
- **No change to `statifier_2`.** `mix.exs` stays `{:predicator, "~> 3.5"}`;
  `docs/datamodel.md`'s seam list is not edited yet (seam #2 is not "landed" until
  predicator releases the feature and statifier consumes it).
- **No `<assign>` implementation in statifier.** That is separate work, currently
  untracked by this bead, and this plan does not start it.
- **No other seams from `docs/datamodel.md:58-76`** - no persistent bound context, no
  typed undefined, no statement sequences, no string prefix/substring, no list
  concatenation. All five are now designed (with decisions recorded) in
  predicator-ex's `docs/design/2026-08-03-statifier-seams.md` and land in
  later releases (3.7, 3.8, 4.0); this plan is deliberately the smallest first
  step of that arc.
- **No changes to `ContextLocation.resolve/2`.** Resolution already behaves
  correctly for this feature; only additive code is in scope.
- **No deletion primitive.** `<assign>` needs writes; a `delete/2` counterpart is not
  requested by any statifier need today.
- **No batch/multi-assign API.** One path, one value.

## Implementation Approach

Three phases, each independently committable behind a green `mix quality` in
predicator-ex:

1. The write primitive plus the error types it needs. This is the whole algorithm and
   the bulk of the tests, and it is self-contained: `ContextLocation.put/3` is public
   and directly testable without any other change.
2. The expression-level wrapper on the `Predicator` module, which is thin because
   phase 1 did the work, plus doctests and pipeline integration tests.
3. Documentation: README, `CLAUDE.md`/`AGENTS.md`, and the `[Unreleased]` changelog
   entry.

Phases 1 and 2 are kept separate rather than merged because phase 1's error-type
additions and walk algorithm carry all the semantic risk and deserve their own review
surface; phase 2 cannot leave the gate red on its own since phase 1 ships a fully
working public function.

**Working directory note for the executing agent**: every `Read`, `Edit`, `Write`,
and `mix` invocation in phases 1-3 targets `~/repos/github/predicator-ex`, not the
statifier worktree. Before the first edit, create a branch there:

```bash
git -C ~/repos/github/predicator-ex checkout -b context-location-put
```

---

## Phase 1: `ContextLocation.put/3` and its error types

### Overview

Add the two write-time `LocationError` constructors and the auto-vivifying path
writer, with full unit coverage of the vivification, padding, collision, and
mismatch cases.

### Changes Required:

#### 1. Write-time error types

**File**: `~/repos/github/predicator-ex/lib/predicator/errors/location_error.ex`
**Changes**: Extend `@type error_type` with `:not_a_container` and `:invalid_index`,
document both in the moduledoc's "Error Types" list, and add two constructors.

```elixir
@type error_type ::
        :not_assignable
        | :invalid_node
        | :undefined_variable
        | :invalid_key
        | :computed_key
        | :not_a_container
        | :invalid_index

@doc """
Creates a LocationError for assignment through a non-container value.

Used when a location path traverses a value that is neither a map nor a list,
so intermediate structure cannot be created without destroying existing data.
"""
@spec not_a_container(binary(), term(), term()) :: t()
def not_a_container(location, segment, value) do
  %__MODULE__{
    type: :not_a_container,
    message: "Cannot assign through non-container value at '#{location}'",
    details: %{
      location: location,
      segment: segment,
      value: value,
      value_type: get_type_name(value)
    }
  }
end

@doc """
Creates a LocationError for an out-of-range list index in a location path.
"""
@spec invalid_index(binary(), integer()) :: t()
def invalid_index(location, index) do
  %__MODULE__{
    type: :invalid_index,
    message: "Invalid list index #{index} at '#{location}'",
    details: %{location: location, index: index}
  }
end
```

`get_type_name/1` already exists (`location_error.ex:127-136`) and already handles
`:undefined`; reuse it rather than adding a second type-name helper.

#### 2. The path writer

**File**: `~/repos/github/predicator-ex/lib/predicator/context_location.ex`
**Changes**: Add a public `put/3` beside `resolve/2`, plus private walk helpers.
Extend the moduledoc with an "Assignment" section describing vivification, padding,
and the collision rule. Do not modify `resolve/2` or any existing `do_resolve_base/2`
clause.

```elixir
@typedoc """
Result of writing a value at a location path.
"""
@type put_result :: {:ok, Types.context()} | {:error, LocationError.t()}

@doc """
Writes `value` into `context` at `path`, creating missing intermediate containers.

Auto-vivification is ECMAScript-like: a missing (or `nil`/`:undefined`) segment is
created as a map when the next segment is a string key, and as a list when the next
segment is an integer index. Existing data is never destroyed to make room - a path
that traverses a scalar returns a `:not_a_container` error. The leaf is always
overwritten.

Integer indices past the end of an existing list pad the gap with `:undefined`.
Negative indices are rejected with `:invalid_index`.

## Examples

    iex> Predicator.ContextLocation.put(%{}, ["user", "profile", "name"], "Ada")
    {:ok, %{"user" => %{"profile" => %{"name" => "Ada"}}}}

    iex> Predicator.ContextLocation.put(%{"items" => [1]}, ["items", 2], "x")
    {:ok, %{"items" => [1, :undefined, "x"]}}

    iex> {:error, error} = Predicator.ContextLocation.put(%{"user" => 5}, ["user", "name"], "Ada")
    iex> error.type
    :not_a_container

"""
@spec put(Types.context(), location_path(), term()) :: put_result()
def put(context, path, value)

def put(context, [], _value) when is_map(context) do
  {:error, LocationError.not_assignable("empty location path", [])}
end

def put(context, path, value) when is_map(context) and is_list(path) do
  do_put(context, path, value, [])
end
```

The walk itself. `trail` accumulates the segments already traversed so error messages
can name the offending location:

```elixir
# Leaf: overwrite whatever is there.
defp do_put(container, [segment], value, trail) do
  set_in(container, segment, value, trail)
end

# Interior: vivify or descend, then write the updated child back.
defp do_put(container, [segment | rest], value, trail) do
  with {:ok, child} <- fetch_in(container, segment, trail),
       {:ok, child} <- vivify(child, hd(rest), trail ++ [segment]),
       {:ok, updated} <- do_put(child, rest, value, trail ++ [segment]) do
    set_in(container, segment, updated, trail)
  end
end

# A missing/nil/undefined slot becomes a container shaped by the *next* segment.
defp vivify(absent, next_segment, _trail) when absent in [nil, :undefined] do
  if is_integer(next_segment), do: {:ok, []}, else: {:ok, %{}}
end

defp vivify(child, _next_segment, _trail) when is_map(child) or is_list(child) do
  {:ok, child}
end

defp vivify(scalar, _next_segment, trail) do
  {:error, LocationError.not_a_container(format_path(trail), List.last(trail), scalar)}
end
```

`fetch_in/3` and `set_in/4` are the two places the map/list distinction lives:

- map + any segment: `Map.get/2` and `Map.put/3` (integer keys allowed on maps, per
  the decided semantics).
- list + non-negative integer: `Enum.at/2` (out of range reads as `nil`, which
  vivifies) and a `List.replace_at/3`-or-pad write:

```elixir
defp set_in(list, index, value, trail) when is_list(list) and is_integer(index) and index >= 0 do
  cond do
    index < length(list) -> {:ok, List.replace_at(list, index, value)}
    true -> {:ok, list ++ List.duplicate(:undefined, index - length(list)) ++ [value]}
  end
end

defp set_in(list, index, _value, trail) when is_list(list) and is_integer(index) do
  {:error, LocationError.invalid_index(format_path(trail ++ [index]), index)}
end

defp set_in(list, key, _value, trail) when is_list(list) and is_binary(key) do
  {:error, LocationError.not_a_container(format_path(trail ++ [key]), key, list)}
end
```

`format_path/1` renders a trail the way a document author wrote it -
`["user", "profile"]` as `user.profile`, `["items", 2]` as `items[2]` - so error
messages are actionable. Keep it private and small.

Credo strict mode is on in this repo: keep each helper single-purpose and prefer
pattern-matched clauses over `cond`/`case` chains where the above sketch used them
for readability.

#### 3. Unit tests

**File**: `~/repos/github/predicator-ex/test/predicator/context_location_test.exs`
**Changes**: Add `describe "put/3 ..."` blocks alongside the existing `resolve/2`
blocks, matching the file's existing style (`use ExUnit.Case, async: true`, direct
`assert {:ok, ...} =` pattern matches).

Cases to cover:

- Single-segment write into an empty context, and overwriting an existing scalar leaf.
- Deep vivification from `%{}`: `["user", "profile", "name"]`.
- Partial vivification: `%{"user" => %{}}` extended with `["user", "profile", "name"]`.
- Existing sibling keys preserved through vivification.
- `nil` and `:undefined` intermediates treated as absent and vivified.
- Leaf overwrite where the leaf currently holds a map, and where it holds a list.
- Integer segment vivifies a list from absent: `put(%{}, ["items", 2], "x")`.
- Padding an existing short list; exact-append at `length(list)`; in-range replace.
- Mixed path: `["data", "users", 0, "name"]` from `%{}`.
- Collision: scalar intermediate returns `:not_a_container`, with the offending
  location in `details`.
- Kind mismatch: string segment against an existing list returns `:not_a_container`.
- Integer segment against an existing map writes with the integer key.
- Negative index returns `:invalid_index`.
- Empty path returns `:not_assignable`.
- Context is not mutated in place: the original map is unchanged after a write
  (trivially true in Elixir, but assert it once as documentation of intent).
- Atom keys are never consulted: `put(%{user: %{}}, ["user", "name"], "Ada")`
  vivifies a new `"user"` string key and leaves the `:user` entry untouched.
  Pins the string-keys-only contract from the 2026-08-03 design pass.

**File**: `~/repos/github/predicator-ex/test/predicator/errors/location_error_test.exs`
**Changes**: Add constructor tests for `not_a_container/3` and `invalid_index/2`
mirroring the existing constructor tests (type, message, details shape).

### Success Criteria:

#### Automated Verification:
- [x] Full gate passes in predicator-ex: `cd ~/repos/github/predicator-ex && mix quality`
- [x] Coverage remains above the project's 90% threshold (reported by the gate's
      coverage stage; `ContextLocation` and `LocationError` should be at or near 100%)
- [x] New doctests on `put/3` execute and pass (they run as part of `mix test`)
- [x] Credo strict passes with no new complexity or nesting warnings on the new helpers

#### Manual Verification:
- [ ] Error messages read usefully for a document author: `user.profile` and
      `items[2]` render as written, not as raw lists
- [ ] An `iex -S mix` session confirms the padding and collision tables in
      "Desired End State" exactly, including `:undefined` padding values
- [ ] The vivification rule never overwrites existing data in any tested case

**Implementation Note**: predicator has no `--profile loop`; use `mix test` between
edits and the full `mix quality` as the phase gate. In interactive execution, pause
here for manual confirmation before proceeding. In looped (`--loop`) execution, the
Automated Verification above gates advancement and Manual Verification is deferred to
the end.

---

## Phase 2: `Predicator.context_assign/4`

### Overview

Add the expression-level entry point that resolves a location expression and writes
through `ContextLocation.put/3`, so callers with a raw `location` attribute do not
have to compose two calls.

### Changes Required:

#### 1. Public API function

**File**: `~/repos/github/predicator-ex/lib/predicator.ex`
**Changes**: Add `context_assign/4` immediately after `context_location/3` (the file's
last function), reusing the same tokenize/parse error handling.

```elixir
@doc """
Assigns `value` at the location `expression` names within `context`.

Resolves the location expression the same way `context_location/3` does, then writes
through `Predicator.ContextLocation.put/3`, creating any missing intermediate maps
and lists. See `Predicator.ContextLocation.put/3` for the full auto-vivification and
collision rules.

Note the argument order: `context` comes first because this function *transforms* a
context and returns a new one, which makes it pipeline-friendly, whereas
`context_location/3` merely inspects one.

## Examples

    iex> Predicator.context_assign(%{}, "user.profile.name", "Ada")
    {:ok, %{"user" => %{"profile" => %{"name" => "Ada"}}}}

    iex> Predicator.context_assign(%{"items" => [1, 2, 3]}, "items[1]", "x")
    {:ok, %{"items" => [1, "x", 3]}}

    iex> {:error, error} = Predicator.context_assign(%{}, "len(items)", 1)
    iex> error.type
    :not_assignable

"""
@spec context_assign(Types.context(), binary(), term(), keyword()) ::
        {:ok, Types.context()} | {:error, struct()}
def context_assign(context, expression, value, opts \\ [])
    when is_map(context) and is_binary(expression) do
  case context_location(expression, context, opts) do
    {:ok, path} -> ContextLocation.put(context, path, value)
    {:error, _error} = error -> error
  end
end
```

Resolving against the *pre-assignment* context is deliberate and matches SCXML: a
variable bracket key (`items[index]`) reads `index` as it stands before the write.

#### 2. Integration tests

**File**: `~/repos/github/predicator-ex/test/predicator/context_location_test.exs`
(or `test/predicator/predicator_test.exs`, matching where the existing
`context_location/3` end-to-end tests live - check both and follow the file that
already covers the expression-level function)
**Changes**: Add a `describe "context_assign/4"` block covering:

- Expression forms end to end: `user`, `user.profile.name`, `items[0]`,
  `user.settings['theme']`, `data['users'][0].name`.
- Variable bracket key resolved against the pre-assignment context:
  `context_assign(%{"index" => 1, "items" => [1, 2, 3]}, "items[index]", "x")`.
- Parse failures surface `ParseError` unchanged (e.g. `"user."`).
- Non-assignable expressions surface the existing `:not_assignable` `LocationError`
  (`"42"`, `"len(items)"`, `"user.age + 1"`).
- An undefined bracket-key variable still surfaces `:undefined_variable` - assignment
  does not vivify the *key*, only the location.
- Write-time errors from phase 1 propagate unchanged (scalar collision).
- Sequential assigns compose: two `context_assign` calls threading the context build
  a nested structure incrementally.

### Success Criteria:

#### Automated Verification:
- [ ] Full gate passes in predicator-ex: `cd ~/repos/github/predicator-ex && mix quality`
- [ ] The new `context_assign/4` doctests pass
- [ ] Dialyzer is clean on the new `@spec` (the `{:error, struct()}` union covers both
      `LocationError` and `ParseError`, matching `context_location/3`'s existing spec)

#### Manual Verification:
- [ ] `iex -S mix` confirms `Predicator.context_assign(%{}, "user.profile.name", "Ada")`
      returns the nested map, and that a second assign into `user.profile.age`
      preserves `name`
- [ ] The argument-order divergence from `context_location/3` is documented clearly
      enough that a caller will not transpose them silently (both accept a map and a
      binary, so a transposition would be a runtime `FunctionClauseError`, not a
      silent wrong answer - confirm that is what happens)

**Implementation Note**: In interactive execution, pause here for manual confirmation
before proceeding. In looped execution, Automated Verification gates advancement.

---

## Phase 3: Documentation and changelog

### Overview

Record the feature where predicator's users and future agents will find it, without
cutting a release.

### Changes Required:

#### 1. README

**File**: `~/repos/github/predicator-ex/README.md`
**Changes**: Extend the existing "SCXML Location Expressions" section with an
"Assignment" subsection: the two new functions, the vivification and padding
examples, and the collision error. Keep the section's existing prose style and code
fence format.

#### 2. Agent context docs

**Files**: `~/repos/github/predicator-ex/CLAUDE.md` and
`~/repos/github/predicator-ex/AGENTS.md`
**Changes**: Update the "Location Expressions for SCXML" block to add
`ContextLocation.put/3` and `Predicator.context_assign/4` to the API list, and add the
two new `LocationError` types (`:not_a_container`, `:invalid_index`) to the error-type
list. Check whether the two files are duplicates or diverge, and apply the same edit
to both.

#### 3. Changelog

**File**: `~/repos/github/predicator-ex/CHANGELOG.md`
**Changes**: Add entries under the existing `## [Unreleased]` heading, following the
file's `### Added` + `#### <Title>` + bullets + `#### Examples` shape used by the
3.4.0 and 3.5.0 entries. Do **not** add a version heading or a date.

```markdown
## [Unreleased]

### Added

#### Auto-vivifying path assignment for SCXML location expressions

- `Predicator.ContextLocation.put/3` writes a value at a resolved location path,
  creating missing intermediate maps and lists
- `Predicator.context_assign/4` resolves a location expression and writes in one call
- Integer path segments index lists and pad gaps with `:undefined`
- Assigning through an existing scalar returns a `:not_a_container` error rather than
  destroying data; negative indices return `:invalid_index`
```

### Success Criteria:

#### Automated Verification:
- [ ] Full gate passes in predicator-ex: `cd ~/repos/github/predicator-ex && mix quality`
- [ ] Any code fences added to README/CHANGELOG that are also doctests still pass
      (`mix test`)
- [ ] `mix docs` builds without warnings for the new functions

#### Manual Verification:
- [ ] README's new subsection reads coherently next to the existing resolution prose
- [ ] The changelog entry stays under `[Unreleased]` - no version bump leaked in
- [ ] `mix.exs` still reads `@version "3.5.0"`

---

## Testing Strategy

### Unit Tests:

`test/predicator/context_location_test.exs` carries the bulk: vivification from
empty, partial vivification, sibling preservation, `nil`/`:undefined` as absent, leaf
overwrite of every type, list padding and in-range replace, mixed map/list paths,
scalar collisions, kind mismatches, integer-into-map, negative index, and empty path.
`test/predicator/errors/location_error_test.exs` covers the two new constructors.

### Integration Tests:

Expression-level `context_assign/4` tests exercise the full lexer -> parser ->
resolve -> put pipeline, including the error shapes that pass through unchanged from
tokenization and parsing, and sequential composition of assigns.

### Conformance Tests:

None. Statifier's SCION and W3C conformance suites cannot exercise this yet - there
is no `<assign>` implementation in `lib/` to route through predicator, so no
conformance test changes state and there is nothing to ratchet. When statifier's
`<assign>` work lands (separate, later), the `assign` corpus fixtures under
`test/scion_tests/assign*` and `test/scxml_tests/mandatory/assign/*` become the real
conformance signal for these semantics.

### Manual Testing Steps:

1. In `~/repos/github/predicator-ex`, run `iex -S mix` and reproduce every row of the
   "Desired End State" table, checking exact return shapes.
2. Confirm auto-vivification preserves siblings:
   `{:ok, c} = Predicator.context_assign(%{"user" => %{"id" => 1}}, "user.profile.name", "Ada")`
   leaves `c["user"]["id"] == 1`.
3. Confirm a collision errors rather than overwriting:
   `Predicator.context_assign(%{"user" => 5}, "user.profile.name", "Ada")` returns
   `{:error, %LocationError{type: :not_a_container}}` and the original context is
   untouched.
4. Confirm padding uses `:undefined`, not `nil`:
   `Predicator.context_assign(%{}, "items[2]", "x")`.
5. Confirm `Predicator.context_location/3` behavior is unchanged by running the
   pre-existing `context_location` tests and spot-checking a resolution in `iex`.

## Performance Considerations

The walk is O(depth) map operations. The one non-constant step is list handling:
`length/1`, `Enum.at/2`, and `List.replace_at/3` are each O(n) in the list's length,
and padding allocates the gap. This is acceptable - SCXML datamodel lists are small,
and the alternative (a tuple- or map-backed sparse representation) would break
predicator's existing list semantics in the evaluator for no real gain. Do not
optimize this speculatively.

No change to the compile-once/evaluate-many path: assignment is a context transform,
not an expression evaluation, and does not touch the instruction pipeline.

## Corpus/Ratchet Notes

None. No statifier corpus regeneration, no `passing_tests.json` change, no
`mix test.baseline add`. Statifier is untouched by this plan.

## Follow-up (not part of this plan)

Recorded so the sequencing is explicit, not as work to do here:

1. Open the mirrored predicator-ex issue and PR for this feature; `st2-qjs` closes
   when that PR merges upstream (it will not merge into `statifier_2`'s `origin/main`,
   so this bead's close is a manual judgment, not the usual merged-branch check).
2. When predicator cuts 3.6.0, bump `statifier_2`'s `mix.exs` to `~> 3.6` and mark
   seam #2 in `docs/datamodel.md:65-66` as landed.
3. Statifier's `<assign>` implementation consumes `context_assign/4` and maps its
   `{:error, %LocationError{}}` returns to `error.execution` internal events, per the
   evaluation contract in `docs/datamodel.md:31-42`.
4. The rest of the upstream arc follows the 2026-08-03 design pass
   (`~/repos/github/predicator-ex/docs/design/2026-08-03-statifier-seams.md`):
   3.7.0 = ISA v2 (short-circuit jumps, `make_list`, positions) + string/list
   builtins; 3.8.0 = `Context` struct, `on_unbound` policy, string-key and
   nil-to-`:undefined` edge normalization (which retroactively makes this
   plan's "nil/`:undefined` treated as absent" rule the system-wide
   definition of absence); 4.0.0 = statement sequences + `=` becomes
   assignment-only. `Context.assign/3` and the `store` opcode reuse this
   plan's `put/3` unchanged.

## References

- Source document: `docs/research/260803-st2-qjs-predicator-path-assign.md`
- Beads issue: `st2-qjs` (label `upstream`)
- Related ADR: `docs/adr/0004-predicator-as-the-datamodel.md:20-23` - auto-vivifying
  assignment named as a gap to upstream
- `docs/datamodel.md:24-26` - target `<assign>` behavior (auto-vivification, unlike v1)
- `docs/datamodel.md:58-76` - the seam list; this is seam #2
- Adjacent but out of scope: `docs/plans/260802-st2-00p.5-w3c-xsl-predicator-datamodel.md`
  (uses `context_location` as a corpus validator only)
- `~/repos/github/predicator-ex/lib/predicator/context_location.ex:101-244` -
  `resolve/2`, unchanged by this plan
- `~/repos/github/predicator-ex/lib/predicator/context_location.ex:217-220` - the
  negative-index path that makes `:invalid_index` reachable
- `~/repos/github/predicator-ex/lib/predicator.ex:476-493` - `context_location/3`,
  the model for `context_assign/4`
- `~/repos/github/predicator-ex/lib/predicator/errors/location_error.ex:41-136` -
  error types, constructors, and the reusable `get_type_name/1`
- `~/repos/github/predicator-ex/lib/predicator/evaluator.ex:380-388` - existing
  `:undefined` sentinel semantics
- `~/repos/github/predicator-ex/CLAUDE.md` - predicator's conventions and gate
- `mix.exs:41` - statifier's `{:predicator, "~> 3.5"}` pin, unchanged
