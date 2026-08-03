---
date: 2026-08-03T15:13:24-0600
researcher: Claude
git_commit: 2e4a8e79a323e49ed0c6cc6b0ce2932e156b9383
branch: st2-qjs-predicator-path-assign
repository: statifier_2
beads_issue: st2-qjs
topic: "Auto-vivifying path assignment in predicator (Predicator.context_location)"
tags: [research, codebase, predicator, datamodel, assign, context_location]
status: complete
last_updated: 2026-08-03
last_updated_by: Claude
---

# Research: Auto-vivifying path assignment in predicator

**Date**: 2026-08-03T15:13:24-0600
**Git Commit**: 2e4a8e79a323e49ed0c6cc6b0ce2932e156b9383
**Branch**: st2-qjs-predicator-path-assign
**Beads Issue**: st2-qjs

## Research Question

Beads issue st2-qjs: "Upstream: auto-vivifying path assignment in predicator - Assignment-with-creation
beside `context_location`, so `user.profile.name` assignment creates intermediates." What exists today
in statifier and in the vendored `predicator` dependency around `<assign>` and `context_location`, and
what exactly is the gap this issue is tracking?

## Summary

This is a pre-implementation research issue, not a bug in running code: **statifier's `lib/` has no
`<assign>` implementation yet at all** - no interpreter, no datamodel module, no path-writing function.
The only thing that exists today is `Predicator.context_location/2` (vendored at
`deps/predicator/lib/predicator/context_location.ex`, hex dep `~> 3.5`), which resolves a location
expression string (e.g. `"user.profile.name"`) into a path list (e.g. `["user", "profile", "name"]`) for
use as an assignment target. It validates *shape* (is this expression an assignable l-value at all) but
never reads or writes datamodel data to do so, and it has no companion function that takes a resolved
path plus a value and produces an updated context.

Contrary to how the issue title might first read, `context_location` does **not** require intermediate
path segments to already exist in the context in order to resolve successfully - property access
(`.name`) and bracket access with a literal/string key (`[0]`, `['key']`) are resolved purely
structurally from the parsed AST, with no context lookups. The one context-dependent case is a bracket
key that is itself a variable reference (`items[index]`), where the *key's* value must be bound - that
is orthogonal to whether the location's own intermediate containers (`user`, `user.profile`) exist.

So the actual gap, as `docs/datamodel.md` frames it, is downstream of `context_location`: predicator has
no "assignment-with-creation" primitive that takes `{:ok, path}` and a value and materializes any missing
intermediate maps along that path before setting the leaf, matching ECMAScript's auto-vivifying
assignment semantics (`docs/datamodel.md:24-26`). Statifier v1 deliberately refused to create
intermediates; v2's committed direction is the opposite (ECMAScript-like auto-vivification), and the ADR
directs that this capability should be built into predicator itself, not glued on in statifier
(ADR-0004, `docs/datamodel.md:58-69`).

## Detailed Findings

### Current state of `<assign>` in statifier's `lib/`

Nothing exists yet:

- `lib/` contains only `lib/statifier.ex` (a stub `Statifier.hello/0`) and mix-task/corpus-registry
  tooling (`lib/mix/statifier/regression_registry.ex`, `lib/mix/tasks/test.baseline.ex`,
  `lib/mix/tasks/test.regression.ex`) - unrelated to `<assign>`.
- `grep -rn "context_location" lib/ test/` and `grep -rln -i "assign" lib/` both return nothing.
- There is no `AssignAction` module, no interpreter, no datamodel module, and no path-writing/
  auto-vivification function anywhere in this repo's own code.
- `test/scion_tests/assign*` and `test/scxml_tests/mandatory/assign/*` are conformance-corpus fixtures
  carried over from the older test tree; they are not wired to any v2 assign implementation.
- The only in-repo, non-dependency reference to `context_location` outside `docs/` is a sabotage comment
  in `test/corpus/check_exprs_test.exs:9` about corpus/XSL checker tooling, unrelated to runtime
  `<assign>` execution.

### `Predicator.context_location/2` - what it does and doesn't do

Public entry point: `deps/predicator/lib/predicator.ex:476-493`. It tokenizes and parses the expression,
then delegates to `Predicator.ContextLocation.resolve/2`.

Resolution logic, `deps/predicator/lib/predicator/context_location.ex`:

- `{:identifier, name}` -> `{:ok, [name]}` (`context_location.ex:111-113`) - no context lookup.
- `{:property_access, left, prop}` -> recurses on `left`, appends `prop` (`context_location.ex:116-122`)
  - purely structural, no context lookup for whether `left`'s value currently contains `prop`.
- `{:bracket_access, left, key}` -> resolves the key, recurses on `left`, appends the key
  (`context_location.ex:125-136`).
- Bracket keys: literal integers/strings resolve directly with no context lookup
  (`context_location.ex:207-220`); only a bracket key that is itself a variable reference
  (`items[index]`) does a `Map.get(context, var_name)` and can fail with
  `LocationError.undefined_variable` if that key variable is unbound (`context_location.ex:223-234`).
  This is resolving the *key's value*, not checking that the location's containing structure exists.
- Non-assignable expression shapes (literals, string literals, function calls, arithmetic, comparison,
  logical, unary, list literals) all return `{:error, %LocationError{type: :not_assignable, ...}}`
  (`context_location.ex:141-200`).

Net effect: `Predicator.context_location("user.profile.name", %{})` returns `{:ok, ["user", "profile",
"name"]}` even when `context["user"]` doesn't exist - resolution never fails due to a missing
intermediate. What's missing is entirely downstream: nothing in predicator or statifier takes that
resolved path and a value and produces a context with `%{"user" => %{"profile" => %{"name" => value}}}`
built out from an empty starting map. Predicator has no `put_in`/`get_and_update_in`-equivalent
"assign with creation" function; it stops at path resolution.

### Where this is recorded as a known gap

- `docs/datamodel.md:24-26` states the *target* behavior for `<assign>` as already-decided design intent:
  deep paths (`user.profile.name`, `items[0].sku`) "including auto-vivification of intermediate maps
  (ECMAScript-like assignment behavior; v1 refused to create intermediates)."
- `docs/datamodel.md:58-69`, "Upstreaming to predicator," seam #2: "**Auto-vivifying path assignment**:
  path resolution exists (`context_location`); assignment-with-creation should live beside it." The
  section's closing line notes each listed seam "gets a beads issue here and a mirrored issue in
  predicator-ex when we hit the seam in implementation" (`docs/datamodel.md:75-76`) - st2-qjs is that
  beads issue for seam #2, filed ahead of the implementation work that would hit it.
- `docs/adr/0004-predicator-as-the-datamodel.md:21` lists "auto-vivifying assignment" among the gaps
  predicator has for SCXML use that the decision commits to upstreaming into predicator rather than
  papering over in statifier's glue code.
- `docs/plans/260802-st2-00p.5-w3c-xsl-predicator-datamodel.md` (read in full) is a different, narrower
  plan: an XSL/corpus-transform effort for validating that W3C test `location`/`item`/`idlocation`
  attributes compile, using `context_location` purely as a *validator* of location syntax. It explicitly
  scopes itself out of touching `lib/` and out of upstreaming work: "Not upstreaming anything to
  predicator... filing the mirrored predicator-ex issues is follow-up work, not this issue." It does not
  address assignment-with-creation.
- No document in `docs/` or `CHANGELOG.md` yet cross-references `st2-qjs` by ID - the bead predates any
  committed reference to it.

### Vendored dependency's own documentation

- `deps/predicator/README.md` ("SCXML Location Expressions" section) and `deps/predicator/CHANGELOG.md`
  ([3.0.0] entry, "Location Expressions for SCXML Assignment Operations (Phase 2 Complete)") both
  describe `context_location/3` strictly as resolution/validation: turning an expression into a path list
  and distinguishing assignable from non-assignable shapes. Neither document mentions creating missing
  intermediate structure during assignment, nor is there a roadmap/limitations note about
  auto-vivification - confirming the feature does not exist upstream yet, matching the gap statifier's
  docs identify.
- Predicator is pulled in as a normal Hex dependency (`mix.exs:41`, `{:predicator, "~> 3.5"}`), vendored
  under `deps/predicator/` by the build tool in the usual way - it is not a local path dependency in this
  worktree.

## Code References

- `deps/predicator/lib/predicator.ex:476-493` - `Predicator.context_location/3` public entry point
  (tokenize -> parse -> `ContextLocation.resolve/2`).
- `deps/predicator/lib/predicator/context_location.ex:100-244` - full resolution logic: identifier,
  property access, bracket access, bracket-key resolution, and the non-assignable error cases.
- `deps/predicator/lib/predicator/context_location.ex:223-234` - the only context-dependent resolution
  path (`items[index]`-style variable bracket keys), which resolves the key's *value*, not the
  location's containing structure.
- `docs/datamodel.md:24-26` - stated target behavior: auto-vivifying `<assign>`, contrasted with v1's
  refusal to create intermediates.
- `docs/datamodel.md:58-69` - "Upstreaming to predicator" seam list; item 2 is this issue's origin.
- `docs/adr/0004-predicator-as-the-datamodel.md:21` - ADR listing auto-vivifying assignment as a gap to
  upstream.
- `docs/plans/260802-st2-00p.5-w3c-xsl-predicator-datamodel.md` - adjacent but out-of-scope plan; uses
  `context_location` for corpus validation only, explicitly excludes upstreaming work.
- `test/corpus/check_exprs_test.exs:9` - only other in-repo, non-vendored reference to
  `context_location`, unrelated to runtime `<assign>`.
- `mix.exs:41` - `{:predicator, "~> 3.5"}` dependency declaration.

## Architecture Documentation

Per ADR-0004 and `docs/datamodel.md`, predicator is the permanent datamodel commitment (no ECMAScript, no
Elixir eval). Gaps predicator has for SCXML use - persistent bound context, auto-vivifying assignment (this
issue), a typed undefined, statement sequences, string prefix/substring, list concatenation - are treated as
seams to be upstreamed into predicator itself rather than solved with statifier-side glue, so every
predicator embedding benefits (`docs/datamodel.md:58-76`). Each seam gets a beads issue in this repo plus a
mirrored issue filed against `predicator-ex` when implementation actually reaches that seam.

## Historical Context (from docs/)

- `docs/adr/0004-predicator-as-the-datamodel.md` - the accepted decision (2026-08-02) committing to
  predicator as the sole datamodel and naming auto-vivifying assignment as one of several gaps to
  upstream rather than work around.
- `docs/plans/260802-st2-00p.5-w3c-xsl-predicator-datamodel.md` - a same-day, narrower plan for corpus/XSL
  location-attribute validation; explicitly out of scope for this issue's upstreaming concern.

## Related Research

No prior research documents reference `st2-qjs`, `context_location`, or auto-vivification specifically;
this is the first research document on the topic.

## Open Questions

- No `<assign>` interpreter code exists yet in this repo, so this issue's resolution is currently blocked
  on (or at minimum sequenced before/alongside) the actual `<assign>` implementation work landing in
  `lib/`; it isn't yet clear which beads issue is tracking that implementation, or whether this upstream
  work is expected to precede it, since the issue's language ("mirrored issue in predicator-ex... when we
  hit the seam in implementation") implies the seam is normally discovered during, not before,
  implementation.
- What exact auto-vivification semantics are wanted at intermediate collisions (e.g. assigning to
  `user.profile.name` when `context["user"]` already holds a non-map value, or a bracket-indexed path
  like `items[5]` on a list shorter than 6 elements) is not specified anywhere in `docs/` yet.
