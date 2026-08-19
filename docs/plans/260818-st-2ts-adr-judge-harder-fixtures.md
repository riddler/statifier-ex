# ADR Judge Corpus Hardening Implementation Plan

## Overview

The ADR judge's fixture corpus (`test/fixtures/adr_judge/`, 8 rows: 4
violating, 4 clean) is a working scoreboard whose violating half is entirely
blatant - a dropped `:location` field, a dropped trace effect, a dropped span
table, a judgment step handed to a script. Every one of those is a shape the
deterministic `AdrGuard`/`GateGuard` would also catch or a reviewer would spot
on sight, so a green score proves the judge is not a no-op and little more.

This plan adds ten fixtures - five violating/clean pairs - whose violations are
real but invisible to both guards: a location that survives but loses precision
on one of three call sites, a trace effect that survives but is stamped after
the phase it claims to record, a span table that survives but is built over a
trimmed source that has already lost its anchor, a refusal clause hollowed into
a check on its own artifact, and a `.claude/wurk.json` policy key with no prose
behind it. Each violating fixture ships with a clean fixture of the *same
shape*, so a pair differentiates the judge rather than rewarding a verdict
bias. It then re-runs the `claude-sonnet-5` versus `claude-haiku-4-5-20251001`
comparison against the harder corpus, under a stated repeat policy and a stated
spend ceiling, and records a recommendation on `@default_model` without moving
it. Bead: st-2ts.

## Current State Analysis

The judge (`lib/mix/statifier/adr_judge.ex`) slices a diff per judged ADR, runs
one propose call per registry entry and one refute call per candidate, and
promotes only candidates the refute pass fails to overturn. Three registry
entries exist (`adr_judge.ex:173-211`): `adr-0012-debuggability` and
`adr-0014-expression-spans` both scoped to `lib/statifier`, and
`adr-0015-swallowed-judgment` scoped to `.claude/wurk` - whose key is
historical and whose text, label and focus are **ADR-0017's**, since ADR-0015
is superseded.

The corpus is eight hand-written unified diffs bound to registry keys by
`test/fixtures/adr_judge/manifest.exs`, loaded by
`test/support/adr_judge_corpus.ex`. A fixture is text shaped like
`git diff --unified=0 --src-prefix=a/ --dst-prefix=b/`; it does not have to
apply, only to parse through `AdrJudge.scoped_chunks/2` and land in the scope
its row claims. One existing fixture (`0014_span_table_dropped.diff`) names a
path that no longer exists, which is not a defect of the corpus design.

`test/mix/statifier/adr_judge_corpus_test.exs` generates one ExUnit test per
manifest row under `@moduletag :adr_judge_corpus`, excluded in
`test/test_helper.exs`; each test passes `caller: &AdrJudge.call_claude_cli/1`
explicitly, making real CLI calls and real spend.
`test/mix/statifier/adr_judge_corpus_shape_test.exs` is the free companion in
the ordinary suite, enforcing five invariants (files exist, keys are real, each
registry entry has both verdicts, each fixture lands in its own scope and not a
differing one, no fixture contains the literal `@tag :skip`).

Recorded baselines (`docs/plans/260808-st-6f7-adr-judge-refute-grounding.md`,
mirrored in `docs/testing.md:26-79`), all on the current 8 fixtures:

| Run | Model | FN | FP | Wall |
|---|---|---|---|---|
| Baseline, ungrounded refute prompt | haiku-4-5-20251001 | 4/4 | 0/4 | 357.9s |
| Confirmatory rerun, same prompt | haiku-4-5-20251001 | 3/4 | 0/4 | 329.9s |
| Grounded refute prompt | haiku-4-5-20251001 | 0/4 | 0/4 | 272.4s |
| Same grounded prompt | claude-sonnet-5 | 0/4 | 0/4 | 91.4s |

`@default_model` is `claude-sonnet-5` (`adr_judge.ex:214`), chosen by the user
directly on wall time with accuracy tied at 0/4-0/4. The stage is disabled in
`.quality.exs` by default and re-enabled by the `merge` profile, which
`.claude/wurk/mr.md` runs before every push.

### Key Discoveries:

- **`AdrGuard` never looks at removed lines.** `parse_diff/1`
  (`adr_guard.ex:511-535`) has no `-` case, and every check is a single-line
  regex over added text - no data flow, no call graph, no AST. Reordering two
  statements, threading a value through one branch but not another, and
  rebuilding a value from a different source are all outside its model
  entirely. `GateGuard`'s scope is five filenames plus a `mix.exs` keyword list
  plus `@tag :skip` under `test/`. That blind spot is precisely the design
  space for these fixtures.
- **Semantics of a preserved shape are invisible to both guards.** A struct
  that still has a `:location` key, a span table that still exists, a trace
  effect that is still emitted - none of these are inspected for meaning. Every
  new violating fixture below preserves the shape and breaks the meaning.
- **The live judge is not deterministic run to run.** st-6f7's confirmatory
  rerun flipped `0015_delegated_judgment.diff` from false negative to correct
  under an identical prompt. Fixtures nearer the decision boundary will flap
  more, so a single run of the harder corpus is not a measurement.
- **ExUnit's include beats exclude.** A per-test `@tag tier: :subtle` and
  `@tag fixture: <file>` make `mix test --only tier:subtle` and
  `mix test --only fixture:<file>` run those rows despite the module's
  `:adr_judge_corpus` exclusion. `mix test <file>:<line>` cannot do this: every
  generated test shares one `test` macro line, so a line filter selects the
  whole corpus and spends the whole corpus.
- **Shape invariant 4 forbids a cross-scope fixture.** A fixture touching both
  `lib/statifier` and `.claude/wurk` fails "empty chunks in a differing scope".
  Every fixture below stays in one scope.
- **Fixture bodies are diff lines under `test/`.** `AdrGuard`'s ADR-0018 check
  scans added lines under `lib/` or `test/` for a `st-<id>` string in comment
  or doc text, so no fixture body and no manifest note may contain a literal
  bead id (the existing manifest already writes "live repro" rather than naming
  st-laz). `GateGuard`'s skip-tag scan forbids the literal `@tag :skip` for the
  same reason.
- **Real code sites for every shape exist at HEAD.**
  `lib/statifier/validator/checks/data.ex:80-125` (three callers of one
  `id_location/1` helper), `lib/statifier/interpreter/exit_entry.ex:136-157`
  (`Trace.ExitSet` built deliberately *before* `record_history_values/2` and
  the `depart/2` reduce), `lib/statifier/compiler.ex:790-793` (`build_cond/2`
  handing an untrimmed source to `Expressions.compile/3`) against
  `lib/statifier/parser/location.ex:94-97` (the anchor invariant a trim
  breaks), `.claude/wurk/commit.md:15-23` (the sabotage refusal), and
  `.claude/wurk.json`'s `gate.project_level_skips` /
  `gate.not_applicable_skips` (policy keys whose prose lives in `CLAUDE.md`).

## Desired End State

1. `test/fixtures/adr_judge/manifest.exs` carries a required `tier:` field on
   every row - `:blatant` for the existing eight, `:subtle` for the ten new
   ones - and the corpus test tags each generated test with its tier and its
   fixture filename, so a tier can be run (and paid for) on its own and a
   single fixture can be iterated on for the cost of one fixture.
2. Ten new fixtures exist as five violating/clean pairs, two per registry
   entry's shape family, each violating one invisible to both deterministic
   guards for a reason stated in its manifest note.
3. The shape test enforces the tier field's presence and legality, and enforces
   the pairing requirement *per tier*: every registry entry has at least one
   `:violation` and one `:clean` row **in each tier it has any row in**. That
   is the mechanical form of the bead's "matching clean fixtures so the pairs
   differentiate the judge".
4. The corpus's score is recorded per tier, so the blatant tier remains
   directly comparable to the four recorded baselines and the subtle tier is
   read as a new, separate number rather than diluting them.
5. A model comparison run under the repeat policy in "Decisions this plan
   records" produces per-tier false-negative and false-positive counts for both
   `claude-sonnet-5` and `claude-haiku-4-5-20251001`, and the plan records a
   recommendation on `@default_model` and leaves the attribute untouched.

Verify with: a bare `mix quality` green with the shape test running and the
corpus still excluded from `mix test`; then the hand-run, paid corpus runs of
Phase 5, whose scorecards are pasted into this plan and summarized in
`docs/testing.md`.

## What We're NOT Doing

- **Not moving `@default_model`.** The record says a human made that call
  directly on 2026-08-08, on wall time, with accuracy tied. If the harder
  corpus separates the models on accuracy, that re-opens a human's decision;
  Phase 5 states the finding and the recommendation and changes nothing.
  `STATIFIER_ADR_JUDGE_MODEL` remains the escape hatch in both directions.
- **Not renaming the `adr-0015-swallowed-judgment` registry key.** The key is
  historical; the entry ships ADR-0017's text, label, scope and focus, and
  every fixture and note still says "0015". Renaming it touches
  `adr_judge.ex`'s registry, its literal-path `read_adr_source/1` clause, the
  manifest, eight fixture filenames and the recorded baselines' vocabulary at
  once - a rename with no behavior change that would make the recorded
  baselines harder to read across. Phase 5 records it as a finding for a
  maintainer. New fixtures keep the `0015_` filename prefix for consistency
  with the existing eight, and their manifest notes name ADR-0017 in prose.
- **Not adding registry entries or widening the judged registry.** ADR-0016 and
  ADR-0018 through ADR-0047 have no recorded verdict in the judge's own survey
  (`adr_judge.ex:88-118`), and the round-counter and arrival-order families are
  plausible candidates - but widening the registry changes what shape invariant
  4's "differing scope" resolves to and is outside st-2ts's stated scope.
- **Not building a cross-scope fixture.** Invariant 4 forbids it, and relaxing
  the invariant to allow one is a change to what the cheap test guarantees.
  Recorded as a finding in Phase 5.
- **Not changing any prompt, parser, or judge behavior.** This plan touches
  `lib/` not at all. It adds fixtures, a manifest field, tags, shape
  assertions, and documentation.
- **Not registering the corpus as a `mix quality` stage, and not touching
  `.quality.exs` or `test/test_helper.exs`.** The corpus stays hand-run and
  tag-excluded; nothing here narrows what the suite runs, so no
  `docs/quality-gate-changes.md` entry is owed. (The pre-existing question of
  whether `test/test_helper.exs` should become a guarded path is a
  maintainer's, and is restated in Phase 5's findings.)
- **Not writing a changelog fragment.** `changelog.d/README.md` excludes
  quality-gate and agent-tooling changes; no caller of the public API can tell
  the difference.
- **Not automating any paid run.** No phase's Automated Verification includes
  a corpus run, and no CI or gate path gains one.

## Implementation Approach

Cheap structure first, fixtures second, spend last. Phase 1 makes the corpus
tierable and single-fixture-runnable without adding a single fixture or
spending a cent, which is what lets Phases 2-4 iterate on wording at the cost
of one fixture per attempt rather than one corpus per attempt. Phases 2, 3 and
4 each add one registry entry's worth of pairs; each is independently
committable because the shape test - which is free and runs in the ordinary
suite - is a complete automated bar for a fixture-only change, and each phase
adds a `:violation`/`:clean` pair together so the per-tier pairing invariant
never goes red mid-phase.

Phase 5 is where the money is spent, once, under a stated policy. It produces
no `lib/` change at all: its committable artifact is the recorded scorecards in
this plan and the summary in `docs/testing.md`, and every paid run sits under
Deferred Manual Verification where no automated gate can depend on it.

**On the hunks shown in Phases 2-4**: each is written against the real file as
it stands at this plan's commit, and each `@@` header's line numbers are the
real ones at that commit. They are still to be re-derived when the fixture is
authored - the files move, and a fixture whose context lines do not match the
file it names reads to a human reviewer as sloppy even though the parser does
not care. Copy the *shape* of each hunk, re-read the file for its text.

The design principle behind every fixture: **preserve the shape, break the
meaning**. A guard that reads added lines with a regex sees a field still
present, a call still made, a table still built, a step still written down.
Only a reader in context sees that the field is now the coarser one, the call
is now stamped against the wrong state, the table is now anchored to a string
that was trimmed, and the step now checks its own artifact instead of making
the call it names.

## Decisions this plan records

The research document (`docs/research/260818-st-2ts-adr-judge-harder-fixtures.md`)
left three questions open that a plan has to answer before implementation can
start. Each is decided here, with the reasoning, so no phase begins on an
assumption.

### Decision 1: the corpus grows, and the rows are tiered

The ten new fixtures **join** the existing eight in one corpus, and every row
gains a required `tier:` field (`:blatant` or `:subtle`).

Replacing the eight would strand the four recorded baselines: nothing measured
after the swap would be comparable to `docs/testing.md`'s table, and the
evidence that st-6f7's prompt fix works would become unre-runnable. Growing
without a tier field is the other failure - a green 18-row score cannot say
whether the subtle rows passed or whether the blatant ones carried it, which is
the exact ambiguity the bead is trying to remove.

A `tier:` field costs one manifest key, one shape assertion, and one ExUnit tag,
and buys three things: the blatant tier can be run alone and compared directly
against every recorded baseline; the subtle tier can be run alone at
proportionate cost; and a scorecard reports two numbers whose difference is the
answer to "did hardening the corpus change what the judge can do".

The pairing invariant moves with it: the shape test requires both verdicts per
`(key, tier)` rather than per `key`. Without that, a registry entry could
satisfy invariant 3 with a blatant clean row and a subtle violating row and
never pair anything.

### Decision 2: three runs per model, majority of three, with flaps reported

A measurement is **three runs of the same tier on the same model, at three
distinct seeds**. A fixture's verdict is the majority of its three; a fixture
whose three runs are not unanimous is additionally reported in a *flap* column.
The headline score is the majority-verdict score; the flap count is reported
next to it and never folded into it.

Two runs is what st-6f7 had, and two runs is exactly the number that cannot
distinguish a fixed verdict from a coin flip - which is why its confirmatory
rerun could only say "not perfectly deterministic". Three is the smallest odd
number, gives a majority, and costs one extra corpus pass per model. Five would
tighten the estimate and cost 67% more for a corpus this size; the flap column
already surfaces the instability that would motivate going to five, so the
decision to spend more is deferred to evidence rather than taken up front.

A fixture that flaps on all three runs of both models is a fixture whose wording
is ambiguous, not a judge failure. Phase 5 says so explicitly and hands the
rewrite back as a manual step rather than treating it as a score.

### Decision 3: the spend ceiling is eight corpus-equivalent runs

The whole bead is budgeted at **eight full-corpus-equivalent runs**, where one
corpus-equivalent is one pass over all 18 fixtures. This unit is pinned at 18
fixture-runs as a fixed unit of account and does not float with the corpus's
size - the corpus stood at 20 rows at st-xsb1 and 22 rows after st-6f7h, and
st-xsb1's 1.0 CE was computed on this pinned unit, not on the corpus size at
the time. Allocated:

| Purpose | Runs | Notes |
|---|---|---|
| Fixture authoring (Phases 2-4) | 2 | Single-fixture runs via `--only fixture:<file>`; ~18 single-fixture runs is one corpus-equivalent, so this is a generous iteration budget |
| Subtle-tier measurement, sonnet | 1.7 | 3 runs x 10 fixtures |
| Subtle-tier measurement, haiku | 1.7 | 3 runs x 10 fixtures |
| Blatant-tier comparability check | 1.4 | 1 run per model x 8 fixtures, confirming the recorded baselines still reproduce |
| Reserve | 1.2 | For one re-measurement if a fixture is rewritten |

Estimated wall time at st-6f7's measured per-fixture rates (sonnet ~11s,
haiku ~34s): roughly 6 minutes of sonnet and 17 minutes of haiku for the subtle
measurement, plus about 6 minutes for the blatant checks - under 30 minutes of
model time in total, spread across deliberate hand-runs.

**If the ceiling is reached before Phase 5's measurement is complete, stop and
report the partial scorecard.** Continuing to spend past a stated ceiling
because the numbers are almost in is the decision this line exists to prevent,
and raising the ceiling is a human's call.

## Phase 1: Tier the Manifest and Make Single Fixtures Runnable

### Overview

Add the `tier:` field to every existing row, tag each generated corpus test with
its tier and its fixture filename, tighten the shape test's pairing invariant to
be per-tier, and document both. No new fixtures, no model calls, no `lib/`
change. This phase is what makes Phases 2-4 affordable.

### Changes Required:

#### 1. Manifest schema

**File**: `test/fixtures/adr_judge/manifest.exs`
**Changes**: Every one of the eight existing rows gains `tier: :blatant`.

```elixir
%{
  key: "adr-0012-debuggability",
  file: "0012_dropped_location.diff",
  expect: :violation,
  tier: :blatant,
  note: "live repro: enforced :location dropped from Document.Content"
},
```

#### 2. Loader documentation

**File**: `test/support/adr_judge_corpus.ex`
**Changes**: `manifest/0`'s `@doc` gains `:tier` in its field list, with one
sentence on what the two values mean - `:blatant` is a deletion or omission the
deterministic guards would also catch, `:subtle` is a violation that preserves
the shape and breaks the meaning. No code change: rows are plain maps and the
new key rides along.

#### 3. Corpus test tags

**File**: `test/mix/statifier/adr_judge_corpus_test.exs`
**Changes**: Inside the generation loop, before each `test`, tag the test with
its tier and its file, and put the tier in the test name so `--trace` output is
readable.

```elixir
for entry <- AdrJudgeCorpus.manifest() do
  @entry entry

  if entry.expect == :violation do
    # sabotage: n/a - scores real model output against known fixtures; the
    #           implementation under test is the prompt, not a pure function
    @tag tier: entry.tier
    @tag fixture: entry.file
    test "#{entry.file} (#{entry.tier} violation)" do
```

with the same two tags on the `:clean` branch. A comment above the loop records
why the tags exist and how they are used:

```elixir
# `tier:` and `fixture:` are the spend controls. ExUnit's include beats
# exclude, so `mix test --only tier:subtle` and
# `mix test --only fixture:0012_trace_after_departure.diff` reach these
# tests despite the module's :adr_judge_corpus exclusion - a tier or a
# single fixture, rather than the whole paid corpus. A `file:line` filter
# cannot do this: every generated test shares this one `test` macro line.
```

#### 4. Shape test: tier legality and per-tier pairing

**File**: `test/mix/statifier/adr_judge_corpus_shape_test.exs`
**Changes**: One new test, and one existing test tightened.

```elixir
# sabotage: n/a - asserts manifest/fixture consistency, no lib/ behavior
test "every manifest row declares a known tier" do
  for entry <- @manifest do
    assert entry.tier in [:blatant, :subtle],
           "#{entry.file} has tier #{inspect(Map.get(entry, :tier))}; " <>
             "expected :blatant or :subtle"
  end
end
```

and the pairing test regrouped by `{key, tier}`:

```elixir
# sabotage: n/a - asserts manifest/fixture consistency, no lib/ behavior
test "every registry entry has both verdicts in every tier it appears in" do
  by_key_and_tier = Enum.group_by(@manifest, &{&1.key, &1.tier})

  for {{key, tier}, rows} <- by_key_and_tier do
    assert Enum.any?(rows, &(&1.expect == :violation)),
           "#{key} has no :violation fixture in the #{tier} tier"

    assert Enum.any?(rows, &(&1.expect == :clean)),
           "#{key} has no :clean fixture in the #{tier} tier"
  end
end
```

Grouping by the pairs actually present, rather than iterating the registry
across both tiers, is deliberate: it does not force every registry entry to
have subtle rows before Phase 4 has added them, so Phases 2-4 can land one at a
time without an intermediate red gate. It still catches the failure that
matters - a tier that has a violating row for a key and no clean one.

The existing scope test keeps its sabotage line
(`# sabotage: have in_scope?/2 ignore scope.prefix -> red`), since it is the one
assertion here that exercises `lib/`. The new assertions are manifest-shape
assertions and carry the `n/a` form the file already uses.

#### 5. Documentation

**File**: `docs/testing.md`
**Changes**: In the fourth-suite subsection, add the tier vocabulary and the
two selection commands - what `:blatant` and `:subtle` mean, that the recorded
score table's numbers are blatant-tier numbers, and that
`mix test --only tier:subtle` / `--only fixture:<name>` exist so a reader does
not reach for the whole corpus to check one fixture.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] The shape test's new tier and per-tier pairing assertions pass in the
      ordinary suite
- [x] `mix test` still reports zero `adr_judge_corpus` tests executed
- [x] `mix test.regression` is unaffected
- [x] Use `mix quality --profile loop` between edits (never as the phase gate)

#### Manual Verification:
- [x] A reader of `docs/testing.md` can tell which tier the recorded baseline
      table refers to
- [x] No paid run was made in this phase

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. This phase spends nothing and must not be
used to "try out" a tier-filtered run - the first paid run of this branch is
Phase 2's single-fixture check.

---

## Phase 2: Subtle Fixtures for ADR-0012 (Location Precision, Trace Stamping)

### Overview

Two pairs against `adr-0012-debuggability`. The first pair is about a location
that survives but loses its attribute-level precision on one of three call
sites; the second is about a trace effect that survives, keeps its struct and
its payload, and is stamped against the wrong side of a phase boundary. Both
are invisible to `AdrGuard`: the first is a one-token change with no removed
line the guard reads, the second is a pure reorder.

### Changes Required:

#### 1. `0012_location_precision_one_caller.diff` (`:violation`, `:subtle`)

**File**: `test/fixtures/adr_judge/0012_location_precision_one_caller.diff`
**Changes**: Against `lib/statifier/validator/checks/data.ex`, where three
callers (`expr_and_src_errors/1`, `value_and_children_errors/1`,
`reserved_id_errors/1`) share `id_location/1`
(`Map.get(attribute_locations, :id, location)`), change **exactly one** call
site to pass `data.location` directly. The helper stays, the other two callers
stay, a location is still reported - it is now the element's span rather than
the `id` attribute's, for one of the three checks only.

```
diff --git a/lib/statifier/validator/checks/data.ex b/lib/statifier/validator/checks/data.ex
--- a/lib/statifier/validator/checks/data.ex
+++ b/lib/statifier/validator/checks/data.ex
@@ -103,1 +103,1 @@
-      [Error.data_reserved_id(id, id_location(data))]
+      [Error.data_reserved_id(id, data.location)]
```

**Manifest note**: "one of three callers of the shared id-location helper now
reports the element span instead of the id attribute's - a location is still
reported, at coarser granularity, for that check only".

#### 2. `0012_location_helper_extracted.diff` (`:clean`, `:subtle`)

**File**: `test/fixtures/adr_judge/0012_location_helper_extracted.diff`
**Changes**: The same three call sites refactored to route through a renamed,
two-argument helper, every caller still resolving the attribute-level location.
The diff removes and re-adds the same three call lines, so it has the same
surface shape as the violating fixture and a different meaning.

```
diff --git a/lib/statifier/validator/checks/data.ex b/lib/statifier/validator/checks/data.ex
--- a/lib/statifier/validator/checks/data.ex
+++ b/lib/statifier/validator/checks/data.ex
@@ -88,1 +88,1 @@
-    [Error.data_expr_and_src(id, id_location(data))]
+    [Error.data_expr_and_src(id, attribute_location(data, :id))]
@@ -97,1 +97,1 @@
-      [Error.data_value_and_children(id, id_location(data))]
+      [Error.data_value_and_children(id, attribute_location(data, :id))]
@@ -103,1 +103,1 @@
-      [Error.data_reserved_id(id, id_location(data))]
+      [Error.data_reserved_id(id, attribute_location(data, :id))]
@@ -123,3 +123,3 @@
-  defp id_location(%Data{attribute_locations: attribute_locations, location: location}) do
-    Map.get(attribute_locations, :id, location)
+  defp attribute_location(%Data{attribute_locations: locations, location: location}, attribute) do
+    Map.get(locations, attribute, location)
   end
```

**Manifest note**: "the shared id-location helper is generalized and renamed;
every caller still resolves the attribute-level location".

#### 3. `0012_trace_after_departure.diff` (`:violation`, `:subtle`)

**File**: `test/fixtures/adr_judge/0012_trace_after_departure.diff`
**Changes**: Against `lib/statifier/interpreter/exit_entry.ex:136-157`, move the
`Effect.trace(machine_state, Effect.Trace.ExitSet, indexes: states_to_exit)`
line from before `record_history_values/2` and the `depart/2` reduce to after
both, so it is stamped from the post-departure `machine_state`. Struct,
`indexes:` payload, and the effect's position in the returned list are all
unchanged; `Effect.trace/3` stamps macrostep, microstep and round from whatever
`machine_state` reaches it (`lib/statifier/effect.ex:51-84`), and the
moduledoc's stated ordering (`exit_entry.ex:109-133`) is now false.

```
diff --git a/lib/statifier/interpreter/exit_entry.ex b/lib/statifier/interpreter/exit_entry.ex
--- a/lib/statifier/interpreter/exit_entry.ex
+++ b/lib/statifier/interpreter/exit_entry.ex
@@ -146,2 +146,0 @@
-    trace_effects = Effect.trace(machine_state, Effect.Trace.ExitSet, indexes: states_to_exit)
-
@@ -154,0 +152,2 @@
+    trace_effects = Effect.trace(machine_state, Effect.Trace.ExitSet, indexes: states_to_exit)
+
```

**Manifest note**: "the exit-set trace effect is built after the departure
reduce instead of before it, so it is stamped against post-departure state while
its payload and list position are unchanged".

#### 4. `0012_trace_prestate_captured.diff` (`:clean`, `:subtle`)

**File**: `test/fixtures/adr_judge/0012_trace_prestate_captured.diff`
**Changes**: The same function, the same reorder of the `trace_effects = ...`
line to below the reduce - but the pre-departure state is bound to a named
variable first and the trace call reads that binding, so the effect is still
stamped from the state the ADR requires. Same removed and added lines in the
same places; the only difference is which state the call names.

```
diff --git a/lib/statifier/interpreter/exit_entry.ex b/lib/statifier/interpreter/exit_entry.ex
--- a/lib/statifier/interpreter/exit_entry.ex
+++ b/lib/statifier/interpreter/exit_entry.ex
@@ -146,2 +146,1 @@
-    trace_effects = Effect.trace(machine_state, Effect.Trace.ExitSet, indexes: states_to_exit)
-
+    pre_exit_state = machine_state
@@ -154,0 +153,2 @@
+    trace_effects = Effect.trace(pre_exit_state, Effect.Trace.ExitSet, indexes: states_to_exit)
+
```

**Manifest note**: "the exit-set trace call moves below the departure reduce but
reads a binding captured before it, so the stamped state is unchanged".

#### 5. Manifest rows

**File**: `test/fixtures/adr_judge/manifest.exs`
**Changes**: Four rows, all `key: "adr-0012-debuggability"`, `tier: :subtle`,
with the notes above. Notes must contain no literal `st-<id>` (ADR-0018 scan)
and no fixture body may contain `@tag :skip`.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] The shape test passes with the four new rows: files exist, key is real,
      tier legal, both verdicts present for `(adr-0012-debuggability, :subtle)`,
      each fixture produces non-empty chunks in `lib/statifier` and empty chunks
      in the `.claude/wurk` scope, no `@tag :skip`
- [x] `mix test` still reports zero `adr_judge_corpus` tests executed
- [x] Use `mix quality --profile loop` between edits

#### Manual Verification:
- [x] Each violating fixture reads as unambiguously violating to a human who
      knows ADR-0012 and `docs/observability.md` - a fixture a reviewer would
      argue about is not a known-violating fixture and must be reworded or
      dropped before Phase 5 scores it
- [x] Each clean fixture is unambiguously clean by the same standard, and is the
      *same shape* as its partner - the pair differs in meaning, not in surface
- [x] The touched functions' real behavior is understood well enough to say the
      violation is real: `exit_states/2`'s trace ordering matches the W3C
      Appendix D `exitStates` phase boundaries the moduledoc cites, and the
      fixture breaks that ordering rather than an incidental one
- [x] Single-fixture spot checks, if run, are recorded against the Phase-2
      authoring budget of Decision 3

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. Fixture wording iteration, if it needs a
model in the loop at all, uses `mix test --only fixture:<name>` - one fixture,
not the corpus. Do not run the full corpus in this phase.

---

## Phase 3: Subtle Fixture Pair for ADR-0014 (Span Anchor)

### Overview

One pair against `adr-0014-expression-spans`. The span table survives, the
compiled-expression tuple keeps the shape ADR-0014 item 2 demands, and every
span it produces is silently offset because the source it was built from was
trimmed after the location anchor was taken. This is the hardest fixture in the
set: the invariant it breaks is stated in a different file
(`lib/statifier/parser/location.ex:94-97`) from the one the diff touches, and
`Statifier.Compiler.Expressions.inline_value/1` already trims before compiling
elsewhere in the same module, so the change reads as consistency.

### Changes Required:

#### 1. `0014_trimmed_before_compile.diff` (`:violation`, `:subtle`)

**File**: `test/fixtures/adr_judge/0014_trimmed_before_compile.diff`
**Changes**: Against `lib/statifier/compiler.ex`'s `build_cond/2`
(`compiler.ex:790-793`), pass `String.trim(source)` to `Expressions.compile/3`
while continuing to pass the untrimmed `cond_location(transition)` as the
anchor. `compile_with_spans/1` still runs, `spans: true` is still implicit, the
table still travels in `{:compiled, compiled, source}` - and
`Parser.Location.resolve_span/3`'s stated precondition ("requires `value`'s
position `{1, 1}` to be `value_location`'s start... a caller that trimmed before
compiling must adjust the anchor itself") no longer holds.

```
diff --git a/lib/statifier/compiler.ex b/lib/statifier/compiler.ex
--- a/lib/statifier/compiler.ex
+++ b/lib/statifier/compiler.ex
@@ -790,1 +790,1 @@
-    Expressions.compile(source, {:transition, t_index}, cond_location(transition))
+    Expressions.compile(String.trim(source), {:transition, t_index}, cond_location(transition))
```

**Manifest note**: "the cond source is trimmed before compiling while the
location anchor is not adjusted, so the retained span table is offset from the
document positions it is resolved against".

#### 2. `0014_trim_with_anchor_adjust.diff` (`:clean`, `:subtle`)

**File**: `test/fixtures/adr_judge/0014_trim_with_anchor_adjust.diff`
**Changes**: The same trim, with the anchor advanced by the trimmed prefix so
the precondition still holds - the compliant version of the same refactor,
which is what makes the pair differentiate rather than reward a bias toward
"any trim is a violation".

```
diff --git a/lib/statifier/compiler.ex b/lib/statifier/compiler.ex
--- a/lib/statifier/compiler.ex
+++ b/lib/statifier/compiler.ex
@@ -790,1 +790,10 @@
-    Expressions.compile(source, {:transition, t_index}, cond_location(transition))
+    trimmed = String.trim_leading(source)
+    skipped = byte_size(source) - byte_size(trimmed)
+    anchor = advance_anchor(cond_location(transition), skipped)
+    Expressions.compile(trimmed, {:transition, t_index}, anchor)
+  end
+
+  # `resolve_span/3` requires the compiled value's `{1, 1}` to be the anchor's
+  # start, so a caller that trims must move the anchor by what it skipped.
+  defp advance_anchor(%Location{} = location, 0), do: location
+
+  defp advance_anchor(%Location{} = location, skipped) do
```

The clean fixture introduces its own anchor-advancing helper in the same diff
rather than naming an API the repository does not have: `Parser.Location`
exposes `resolve_span/3` but no public advance, so a fixture that called one
would be arguing from a mechanism the judge cannot see - the exact shape
st-6f7's refute grounding was built to reject, and it would read as unfair to a
human reviewer too.

**Manifest note**: "the cond source is trimmed and the location anchor advanced
by the trimmed prefix, so resolved spans still land on the document positions
they name".

#### 3. Manifest rows

**File**: `test/fixtures/adr_judge/manifest.exs`
**Changes**: Two rows, `key: "adr-0014-expression-spans"`, `tier: :subtle`.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] The shape test passes with the two new rows, including both verdicts
      present for `(adr-0014-expression-spans, :subtle)` and empty chunks in the
      `.claude/wurk` scope
- [x] `mix test` still reports zero `adr_judge_corpus` tests executed
- [x] Use `mix quality --profile loop` between edits

#### Manual Verification:
- [x] The violating fixture is unambiguous to a human holding ADR-0014 and
      `lib/statifier/parser/location.ex:94-97` side by side - if the violation
      cannot be stated in one sentence from the shown material plus the ADR
      text, the fixture is too indirect for the corpus, since the judge is shown
      only the ADR and the hunks
- [x] The clean fixture's anchor arithmetic is right, so the pair really is
      compliant-versus-not and not two flavors of broken. The fixture need not
      compile, but every mechanism it relies on must be visible in the fixture
      itself - it may not lean on an API the repository does not have
- [x] The touched compiler path matches the repository's actual span contract as
      documented, not a remembered one

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. This pair is the most likely to need a
wording pass; iterate with `--only fixture:<name>` against the Phase-3 share of
the authoring budget, not the corpus.

---

## Phase 4: Subtle Fixtures for ADR-0017 (Hollowed Refusal, Policy Key)

### Overview

Two pairs against `adr-0015-swallowed-judgment` - the registry key that ships
ADR-0017's text. The first pair hollows a refusal into a check on its own
artifact while leaving policy-sounding prose in place, which is ADR-0017 point
1's stated tell. The second exercises point 6's `.claude/wurk.json` extension:
a manifest key that encodes a policy call with no prose pointing back at it,
against a genuine constant change that the ADR says must *not* be reported.

### Changes Required:

#### 1. `0015_refusal_reduced_to_check.diff` (`:violation`, `:subtle`)

**File**: `test/fixtures/adr_judge/0015_refusal_reduced_to_check.diff`
**Changes**: Against `.claude/wurk/commit.md:15-23`, rewrite the sabotage
refusal so an empty `data.sabotage.missing` becomes the sufficient condition to
proceed. The step still names the mechanics, the surrounding prose still reads
like policy, and the clause that refuses to invent a note for a mutation that
was never run is gone - the discipline is now a check on the script's own
artifact.

```
diff --git a/.claude/wurk/commit.md b/.claude/wurk/commit.md
--- a/.claude/wurk/commit.md
+++ b/.claude/wurk/commit.md
@@ -18,4 +18,3 @@
-- **In auto mode**, sabotaging the test yourself and continuing is fine; what
-  is never fine is committing a test with no note. Refuse and report which
-  tests are unverified rather than inventing a note for a mutation that was
-  never run - a fabricated note is the one failure mode this check cannot
-  catch afterward.
+- **In auto mode**, sabotaging the test yourself and continuing is fine.
+  Proceed once `data.sabotage.missing` is empty - that list is what the
+  refusal condition reduces to.
```

**Manifest note**: "the sabotage refusal is replaced by a check on the script's
own missing-notes list, so the clause forbidding an invented note is gone while
the surrounding prose still reads as policy".

#### 2. `0015_refusal_restated_with_script.diff` (`:clean`, `:subtle`)

**File**: `test/fixtures/adr_judge/0015_refusal_restated_with_script.diff`
**Changes**: The same section rewritten to name the script for the mechanics
*and* restate the refusal in prose - ADR-0017 point 1's explicitly permitted
shape.

```
diff --git a/.claude/wurk/commit.md b/.claude/wurk/commit.md
--- a/.claude/wurk/commit.md
+++ b/.claude/wurk/commit.md
@@ -18,4 +18,5 @@
-- **In auto mode**, sabotaging the test yourself and continuing is fine; what
-  is never fine is committing a test with no note. Refuse and report which
-  tests are unverified rather than inventing a note for a mutation that was
-  never run - a fabricated note is the one failure mode this check cannot
-  catch afterward.
+- **In auto mode**, sabotaging the test yourself and continuing is fine.
+  `data.sabotage.missing` lists the tests with no note - that list is the
+  mechanics. What is never fine is committing a test with no note: refuse and
+  report which tests are unverified rather than inventing a note for a
+  mutation that was never run, whatever the list says - a fabricated note is
+  the one failure mode this check cannot catch afterward.
```

**Manifest note**: "the sabotage step names the script for the mechanics and
restates the refusal in prose, which ADR-0017 point 1 permits".

#### 3. `0015_manifest_policy_key.diff` (`:violation`, `:subtle`)

**File**: `test/fixtures/adr_judge/0015_manifest_policy_key.diff`
**Changes**: Against `.claude/wurk.json`, add a pattern to
`gate.not_applicable_skips` - a decision about what stops blocking a branch -
with no prose anywhere it points back to. ADR-0017 point 6 names exactly this,
and `CLAUDE.md`'s "Which skipped stages are gaps and which will never apply"
section says a pattern arriving with no prose is the failure the ADR describes.

```
diff --git a/.claude/wurk.json b/.claude/wurk.json
--- a/.claude/wurk.json
+++ b/.claude/wurk.json
@@ -48,0 +49,1 @@
+      "^coverage tooling unavailable$"
```

**Manifest note**: "a new not-applicable skip pattern reclassifies a stage that
would otherwise block, with no prose stating the policy it points back to -
ADR-0017 point 6".

#### 4. `0015_manifest_constant_change.diff` (`:clean`, `:subtle`)

**File**: `test/fixtures/adr_judge/0015_manifest_constant_change.diff`
**Changes**: Against `.claude/wurk.json`, change a genuine constant - the
`gate.loop` command array - which ADR-0017 point 6 says explicitly "is not a
violation and must not be reported as one". This fixture is the direct test of
the judge's ability to hold that distinction, and its false-positive result is
the more informative half of the pair.

```
diff --git a/.claude/wurk.json b/.claude/wurk.json
--- a/.claude/wurk.json
+++ b/.claude/wurk.json
@@ -31,1 +31,1 @@
-    "loop": ["mix", "quality", "--profile", "loop"],
+    "loop": ["mix", "quality", "--profile", "loop", "--test-scope", "changed"],
```

**Manifest note**: "a gate command array changes - a project fact, not a choice
about what blocks - which ADR-0017 point 6 says must not be reported".

#### 5. Manifest rows

**File**: `test/fixtures/adr_judge/manifest.exs`
**Changes**: Four rows, `key: "adr-0015-swallowed-judgment"`, `tier: :subtle`.
The `0015_` prefix is retained for consistency with the existing eight; the
notes say ADR-0017 in prose, since that is the text the entry ships.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] The shape test passes with the four new rows, including both verdicts
      present for `(adr-0015-swallowed-judgment, :subtle)`, non-empty chunks in
      the `.claude/wurk` scope for all four (including the two
      `.claude/wurk.json` fixtures, whose path matches the scope prefix), and
      empty chunks in the `lib/statifier` scope
- [x] `mix test` still reports zero `adr_judge_corpus` tests executed
- [x] Use `mix quality --profile loop` between edits

#### Manual Verification:
- [x] The two prose fixtures differ only in whether the refusal survives as
      prose, so the pair isolates ADR-0017 point 1's tell and nothing else
- [x] The two manifest fixtures differ only in whether the changed key encodes a
      policy call, so the pair isolates point 6's constant-versus-decision line
- [x] Neither fixture body nor manifest note contains a literal bead id, which
      `AdrGuard`'s ADR-0018 scan would flag on lines added under `test/`
- [x] The fixture diffs against `.claude/wurk.json` and `.claude/wurk/commit.md`
      are plausible against those files as they stand, and the real files are
      unchanged by this phase

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. Take particular care that only the fixture
*files* change - a fixture is a text file describing a hypothetical diff, and
this phase must not edit the real `.claude/wurk.json` or
`.claude/wurk/commit.md`.

---

## Phase 5: Measure, Record, and Recommend

### Overview

Spend the budget, once, under Decision 2's repeat policy and Decision 3's
ceiling. Produce a per-tier scorecard for both models, write it into this plan
and summarize it in `docs/testing.md`, and state a recommendation on
`@default_model` without moving it. This phase changes no `lib/` code; its
committable artifact is the record.

### Changes Required:

#### 1. Measurement (no code change)

Runs, in this order, so an early stop still leaves a usable record:

1. `mix test --only tier:subtle --seed <s1|s2|s3> --trace` under
   `STATIFIER_ADR_JUDGE_MODEL=claude-sonnet-5` - three runs, three seeds.
2. The same three runs under
   `STATIFIER_ADR_JUDGE_MODEL=claude-haiku-4-5-20251001`.
3. `mix test --only tier:blatant --seed <s1> --trace` once per model, confirming
   the recorded 0/4-0/4 baselines still reproduce on the current prompts, so the
   subtle numbers are read against a live blatant control rather than a
   three-month-old table.

Record per run: per-fixture verdict, per-fixture wall time, total wall time,
model id, and seed.

#### 2. Scorecard

**File**: this plan, a `#### Phase 5 measurement (recorded)` subsection
**Changes**: Two tables per model - a per-fixture verdict matrix across the
three seeds, and a summary row of majority-verdict false negatives, false
positives, and flap count, per tier.

| Tier | Model | FN (majority) | FP (majority) | Flaps | Wall (mean) |
|---|---|---|---|---|---|
| blatant | ... | /4 | /4 | | |
| subtle | ... | /5 | /5 | | |

#### 3. `docs/testing.md`

**File**: `docs/testing.md`
**Changes**: The recorded-scores table gains the subtle-tier rows and a sentence
saying the earlier rows are blatant-tier numbers, plus a line on the repeat
policy (majority of three, flaps reported separately) so the next person to run
the corpus reproduces the same measurement rather than inventing one.

#### 4. Findings left to a human

**File**: this plan, a `## Findings for a maintainer` section
**Changes**: State, with the evidence, and change nothing:

- **`@default_model` - the harder corpus reverses the tie, and the attribute is
  left alone.** On the subtle tier, `claude-haiku-4-5-20251001` is the more
  accurate model: 1 majority false negative against `claude-sonnet-5`'s 3, over
  the same ten fixtures at the same three seeds, with no false positives and an
  identical 3/10 flap rate on either side. It is also about six times slower
  here - 890.6s mean against 145.7s. The current value, `claude-sonnet-5`
  (`adr_judge.ex:214`), was a human's call made on wall time *because accuracy
  was tied* on the blatant-only corpus
  (`docs/plans/260808-st-6f7-adr-judge-refute-grounding.md`'s Phase 4
  measurement); that premise no longer holds, so the trade the current default
  encodes is now accuracy-for-latency rather than latency-for-free.
  **Recommendation: reconsider the default, with the direction being haiku on
  accuracy grounds.** The attribute is not moved here - the original choice was
  the user's own, the stage is opt-in at merge time where a 15-minute run is a
  real cost, and one measurement of a ten-fixture corpus is thin ground for
  reversing it. `STATIFIER_ADR_JUDGE_MODEL` stays the escape hatch in either
  direction meanwhile.
- **The blatant baselines are not a deterministic floor.** Each control run
  produced one false positive on a known-clean fixture where the recorded
  baseline says 0/4, and on a different fixture per model. Whoever next cites
  `docs/testing.md`'s recorded-scores table should read it as a single-run
  observation, not a reproducible bar. Making it one would mean re-recording it
  under Decision 2's majority-of-three policy - a further paid run, not done
  here.
- **Three of ten subtle fixtures flapped on each model**, which is the evidence
  Decision 2 named as the trigger for considering five runs per measurement
  rather than three. No fixture flapped on all three runs of both models, so
  none is condemned as ambiguous under this phase's own rule.
- **The `adr-0015-swallowed-judgment` key.** The registry key names a
  superseded ADR while shipping ADR-0017's text, label, scope and focus. This is
  a mislabel a reader trips over, and renaming it is a mechanical change across
  the registry, the `read_adr_source/1` clause, the manifest, ten fixture
  filenames and the recorded baselines' vocabulary. Recommended, out of scope
  here.
- **Cross-scope fixtures.** Shape invariant 4 forbids a fixture touching both
  registry scopes, so the judge's one-propose-call-per-entry path over a real
  multi-scope branch has no fixture. Relaxing the invariant changes what the
  free test guarantees; recorded as a gap.
- **`test/test_helper.exs` as a guarded path.** Restated from st-6f7's
  voluntary ledger entry: `mix gate.check` does not guard it, and this branch
  adds no new exclusion, but whether it should be guarded remains open.
- **Any fixture that flapped on all three runs of both models.** Its wording is
  ambiguous rather than its verdict wrong; name it and recommend a rewrite.

#### Phase 5 measurement (recorded)

**Measured 2026-08-18**, under Decision 2's repeat policy: three subtle-tier
runs per model at seeds 101/202/303, plus one blatant-tier control run per model
at seed 101. A fixture's verdict is the majority of its three subtle runs; a
fixture whose three runs disagree is additionally counted as a flap, and the
flap count is never folded into the score. The blatant controls are one run
each, so they carry no majority and no flap column - they exist to say whether
the recorded 0/4-0/4 baselines still reproduce.

**`claude-sonnet-5`**

| Tier | Model | FN (majority) | FP (majority) | Flaps | Wall (mean) |
|---|---|---|---|---|---|
| blatant (1 run, control) | claude-sonnet-5 | 0/4 | 1/4 | n/a | 88.0s |
| subtle (3 runs) | claude-sonnet-5 | 3/5 | 0/5 | 3/10 | 145.7s |

**`claude-haiku-4-5-20251001`**

| Tier | Model | FN (majority) | FP (majority) | Flaps | Wall (mean) |
|---|---|---|---|---|---|
| blatant (1 run, control) | claude-haiku-4-5-20251001 | 0/4 | 1/4 | n/a | 622.2s |
| subtle (3 runs) | claude-haiku-4-5-20251001 | 1/5 | 0/5 | 3/10 | 890.6s |

Per-fixture verdicts across the three seeds, `ok` meaning the fixture's own
expected verdict was produced:

| Fixture | sonnet 101/202/303 | haiku 101/202/303 |
|---|---|---|
| `0012_location_precision_one_caller.diff` (violation) | ok, FN, FN | FN, FN, FN |
| `0012_location_helper_extracted.diff` (clean) | ok, ok, ok | ok, ok, ok |
| `0012_trace_after_departure.diff` (violation) | ok, FN, FN | ok, FN, ok |
| `0012_trace_prestate_captured.diff` (clean) | ok, ok, ok | ok, FP, ok |
| `0014_trimmed_before_compile.diff` (violation) | FN, FN, FN | ok, ok, ok |
| `0014_trim_with_anchor_adjust.diff` (clean) | ok, ok, ok | ok, ok, ok |
| `0015_refusal_reduced_to_check.diff` (violation) | ok, ok, ok | ok, ok, ok |
| `0015_refusal_restated_with_script.diff` (clean) | FP, ok, ok | ok, ok, ok |
| `0015_manifest_policy_key.diff` (violation) | ok, ok, ok | FN, ok, ok |
| `0015_manifest_constant_change.diff` (clean) | ok, ok, ok | ok, ok, ok |

**What the numbers say.**

1. **The corpus does what the bead asked of it.** The blatant tier separates
   nothing - both models score 0/4 false negatives on it, as they did in
   st-6f7. The subtle tier separates the models on the first run: 3 majority
   false negatives for sonnet against 1 for haiku, on the same ten fixtures.
   A green score now means something a green blatant score did not.
2. **The blatant baselines no longer reproduce exactly.** Each control run
   produced one false positive on a known-clean fixture - sonnet on
   `0015_mechanics_only.diff`, haiku on `0014_span_preserving_refactor.diff`,
   different fixtures in each case. The recorded baseline is 0/4-0/4 for both.
   A single control run cannot distinguish a regression from a flap, and
   Decision 2's own argument says so; what it does establish is that the
   recorded baselines are not the deterministic floor the table reads as.
3. **Flap rate is the same on both models** - 3 of 10 subtle fixtures were not
   unanimous across three seeds, for each model. This is the evidence Decision
   2 said would motivate going to five runs, and it arrived. No fixture flapped
   on all three runs of both models, so no fixture is condemned as ambiguous
   by the rule this phase set for itself.
4. **`0012_location_precision_one_caller.diff` is the one fixture both models
   miss by majority** (sonnet 2/3, haiku 3/3). Read together with the ADR, that
   is at least as likely to indict ADR-0012's text as the judge: the record
   commits to nodes retaining "their source location" and never states that a
   location must be the finest-grained one available, so a check that still
   reports a real `%Location{}` at coarser precision is arguably compliant on
   the ADR's literal wording. Either the ADR grows a sentence about precision
   or this fixture is reclassified; both are a human's call and neither is made
   here.

**Spend.** 76 fixture-runs - 60 subtle (3 seeds x 10 fixtures x 2 models) and 16
blatant (8 fixtures x 2 models) - which at 18 fixtures to the corpus-equivalent
is **4.2 of Decision 3's ceiling of 8**. Wall time was about 63 minutes, the
bulk of it haiku's. No re-measurement was needed, so the 1.2-run reserve is
unspent.

##### Partial re-measurement, 2026-08-18 (st-xsb1)

**This is a partial re-measurement, not a replacement.** It covers six
ADR-0012 `:subtle` rows on one model (`claude-sonnet-5`); the ten-fixture,
two-model tables above are the standing measurement and are not superseded.
It was bought because st-xsb1 amended ADR-0012 with a sentence on pre-mutation
stamping, and an amendment to the rubric text invalidates the prior ADR-0012
numbers without saying which way.

Same repeat policy as above: seeds 101/202/303, majority of three, flaps
counted separately and never folded into the score.

| Fixture | sonnet 101/202/303 | Wall 101/202/303 | Prior (st-2ts) |
|---|---|---|---|
| `0012_trace_stamp_swapped_comment_kept.diff` (violation, new) | ok, ok, ok | 30.4s, 38.2s, 44.1s | FN (st-ntf5 hand-run, unamended) |
| `0012_configuration_read_post_departure.diff` (clean, new) | ok, ok, ok | 8.3s, 8.5s, 14.8s | n/a |
| `0012_trace_after_departure.diff` (violation) | ok, ok, ok | 39.1s, 31.3s, 36.1s | ok, FN, FN |
| `0012_trace_prestate_captured.diff` (clean) | ok, ok, ok | 6.1s, 8.6s, 5.9s | ok, ok, ok |
| `0012_location_precision_one_caller.diff` (violation) | FN, FN, FN | 28.1s, 37.4s, 31.3s | ok, FN, FN |
| `0012_location_helper_extracted.diff` (clean) | ok, ok, ok | 6.0s, 6.8s, 5.7s | ok, ok, ok |

Wall times are the ExUnit-reported duration of each fixture's own test, which is
the judge round trip and nothing else. The violation rows cost three to six
times the clean ones because a surviving candidate buys a second CLI call: the
clean rows are one propose pass, the violation rows are propose plus refute.

| Slice | Model | FN (majority) | FP (majority) | Flaps | Wall (mean) |
|---|---|---|---|---|---|
| ADR-0012 subtle, 6 rows (3 runs) | claude-sonnet-5 | 1/3 | 0/3 | 0/6 | 21.5s |

**What the numbers say.**

1. **The amendment closed the gap st-xsb1 was opened for.**
   `0012_trace_stamp_swapped_comment_kept.diff` - the stamp swap with the
   ADR-0012 comment left in place - was a measured false negative against the
   unamended rubric (st-ntf5, hand-run). It is now caught unanimously. The
   signal no longer depends on the diff also deleting the comment that names
   the rule.
2. **It carried `0012_trace_after_departure.diff` with it**, from a majority
   false negative (ok, FN, FN) to unanimous ok. Both rows turn on the same
   question, so one sentence of ADR text fixing both is the expected shape.
3. **No false positive was introduced.** The clean half deliberately reads
   `configuration` post-mutation, which is exactly the read a judge that
   over-learned "anything after the reduce is a violation" would flag. It is
   clean on all three seeds, as is the pre-existing clean partner. This is the
   specific risk the pair was added to detect, and it did not fire.
4. **`0012_location_precision_one_caller.diff` remains the standing miss**, and
   is now unanimous (3/3 FN) where st-2ts measured 2/3. It was already a
   majority false negative on both models before this amendment, and st-2ts's
   finding 4 diagnosed it as an ADR-text question - the record never says a
   location must be the finest-grained one available - rather than a judge
   failure. **The one-seed move from 2/3 to 3/3 is not separable from noise at
   three runs**, against a measured flap rate of 3/10 in the standing tables.
   It is reported, not explained; buying the runs that would separate the two
   is a second measurement pass and is not budgeted.
5. **Zero flaps across all six rows**, where the standing tables measured 3/10
   on each model. Six rows is too small a sample to read as a trend, and it is
   recorded rather than interpreted.

**Provenance.** The runs were executed by an agent under explicit human
authorization, not by a human at the keyboard. Phase 3's manual criterion asks
that a human run every command; the human decided to start the phase and
authorized the spend, and the agent ran the eighteen commands. The raw ExUnit
output for all eighteen was read directly rather than summarized by the process
that produced it. Recorded here as a deviation rather than ticked, so a later
reader weighs these cells accordingly.

**Spend.** 18 fixture-runs (6 fixtures x 3 seeds x 1 model) = **1.0
corpus-equivalent**, drawn from the 1.2-run reserve this phase left unspent.
Cumulative against Decision 3's ceiling of 8: **5.2**. Wall time was 6.4
minutes. The budget was not exceeded and no fixture was re-run.

##### First measurement of two new rows, 2026-08-19 (st-6f7h)

**This is a first measurement of two new rows, not a re-measurement.** It
covers the two ADR-0012 `:subtle` fixtures st-6f7h Phase 1 added at
`exit_interpreter/1` (site B) - `0012_exit_sweep_stamp_swapped_beside_done.diff`
(violation) and `0012_done_trace_stamped_post_sweep.diff` (clean) - on one
model (`claude-sonnet-5`). Every table above, including the st-xsb1 partial
re-measurement, stands unchanged; neither of these two rows appeared in any
prior measurement, so there is nothing to supersede.

Same repeat policy as above: seeds 101/202/303, majority of three, flaps
counted separately and never folded into the score.

| Fixture | sonnet 101/202/303 | Wall 101/202/303 |
|---|---|---|
| `0012_exit_sweep_stamp_swapped_beside_done.diff` (violation, new) | uncaptured, FN, FN | uncaptured, 8.1s, 8.3s |
| `0012_done_trace_stamped_post_sweep.diff` (clean, new) | ok, ok, ok | 34.2s, 23.5s, 15.3s |

Seed 101's violation-row run exited 2 (an ExUnit failure, consistent with a
miss), but its assertion text was not captured - the terminal output was
truncated before it could be read. Per the plan's manual criterion, that cell
is recorded as an uncaptured miss and is not inferred from the other two
seeds. The majority verdict for the row is unaffected: seeds 202 and 303 are
both unambiguous false negatives, which already forms a majority of three
regardless of what seed 101's specific assertion said.

| Slice | Model | FN (majority) | FP (majority) | Flaps | Wall (mean, captured cells) |
|---|---|---|---|---|---|
| ADR-0012 subtle, 2 new rows (3 runs) | claude-sonnet-5 | 1/2 | 0/2 | 0/2 | 17.9s |

**What the numbers say.**

1. **The violation row missed unanimously; the clean row was acquitted
   unanimously - the inverse of what the plan predicted.** The plan expected
   the clean row (a legitimately post-sweep `Trace.Done` stamp, made maximally
   conspicuous) to be the likelier miss, on the theory that a judge which had
   internalized "stamp pre-mutation" as an unconditional rule would fire a
   false positive on it. Instead the clean row was caught clean on all three
   seeds, and the violation row - the swapped `Trace.ExitSet` stamp beside the
   untouched, correctly post-sweep `Trace.Done` call - was missed on all
   three. Read plainly: on this wide two-trace hunk the judge did not indict
   the swapped stamp at all.
2. **The miss is a failure to propose, not a refute-pass over-rejection.**
   The violation row's runs completed in roughly 6.0s of sync time against the
   clean row's 13-32s. The judge's propose step returned no candidate at all
   on the violation row - no candidate means no refute call, which is why the
   run is short. On the clean row the judge proposed candidates and then
   refuted them away, the longer round trip. The distinction matters: this is
   not a case of the judge seeing a violation and being talked out of it by
   its own refute step, it never saw one to begin with.
3. **The measurement cannot separate content from context or from site.**
   `0012_trace_stamp_swapped_comment_kept.diff` - the comment-kept stamp swap
   at the *other* governed `Trace.ExitSet` site (site A, `exit_states/2`) -
   was previously measured caught unanimously (st-xsb1, above). This new
   violation row differs from that fixture in at least three ways at once:
   the wider `--unified=14` context (no prior fixture used more than 3), the
   presence of a second, legitimately post-sweep trace call in the same hunk,
   and the different production site. Any of the three could explain why this
   row misses where that one caught. The budget spent here (six fixture-runs)
   cannot isolate which; separating them would be a second measurement pass
   and is explicitly out of this phase's scope. This is reported as an open
   question, not resolved.
4. **No false positive was introduced on the clean row.** The clean row was
   cut specifically to probe whether the judge had over-generalized "stamp
   pre-mutation" unconditionally - the risk ADR-0012's amendment's second
   paragraph exists to bound. It did not fire here, unanimously.

**Provenance.** The runs were executed by an agent, not by a human at the
keyboard. Per this plan's Phase 5 (Phase 2 of st-6f7h) manual criterion, a
human decided to start the phase and authorized the spend - the user
explicitly said to go ahead and run the six commands - and the agent ran them.
Recorded here as a deviation rather than ticked, following the st-xsb1
precedent above. Additionally, and distinctly from that precedent: one cell
(violation row, seed 101) has no captured assertion text, because the agent's
first invocation was run without redirecting output and the terminal output
was truncated before the text could be read. The verdict for that cell (a
miss, exit status 2) is sound; the specific assertion is not on the record.
This is stated plainly rather than papered over.

**Spend.** 6 fixture-runs (2 fixtures x 3 seeds x 1 model) = **0.33
corpus-equivalents**. Cumulative against Decision 3's ceiling of 8, with 4.2
(st-2ts, above) and 1.0 (st-xsb1, above) already spent: **5.53 of 8**, leaving
2.47. The budget was not exceeded: 6 of 6 planned runs, no fixture was
re-run, no second model was added, no tier-wide selector was used.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] `mix test` still reports zero `adr_judge_corpus` tests executed - the
      measurement changed nothing about what the ordinary suite runs
- [x] `lib/` is untouched by this phase: `git diff --stat` shows no `lib/` path
- [x] Use `mix quality --profile loop` between edits

#### Manual Verification:
- [x] Every finding above is written down with its evidence, and no
      recommendation was acted on
- [x] The scorecard tables in this plan and the summary rows in
      `docs/testing.md` hold real measured numbers, not a template. A command
      can see a table; only a reader can see whether its cells came from a run,
      which is why this is not an automated criterion - a `--loop` pass must not
      be able to satisfy Phase 5 with an empty table
- [x] The spend ceiling of Decision 3 was respected, and the actual number of
      corpus-equivalent runs is recorded next to the ceiling

The paid runs this phase's record is filled in from are listed once, at the end
of this document under `## Deferred Manual Verification

Everything below costs real money and real wall time. None of it may be added to
`mix quality`, to CI, or to any phase's Automated Verification list, and no
phase's advancement may be gated on it. Run each by hand, deliberately, and
record the result in Phase 5's scorecard.

**All of it was run by hand on 2026-08-18**, after the fixture fixups recorded
under "Verification pass" below; the scorecard in Phase 5 holds the results and
the spend.

### Paid corpus runs (Phase 5)

- [x] Three `claude-sonnet-5` subtle-tier runs at three distinct seeds
      (`STATIFIER_ADR_JUDGE_MODEL=claude-sonnet-5 mix test --only tier:subtle
      --seed <s> --trace`), per-fixture verdicts and wall times recorded -
      seeds 101/202/303, 117.7s / 138.3s / 181.0s
- [x] Three `claude-haiku-4-5-20251001` subtle-tier runs at the same three
      seeds, likewise - 831.9s / 1044.8s / 795.0s
- [x] One blatant-tier control run per model
      (`mix test --only tier:blatant`), confirming the recorded 0/4-0/4
      baselines still reproduce - **they do not**: one false positive per
      model, on a different clean fixture each. Recorded in Phase 5 and in
      the findings
- [x] Majority-of-three verdicts computed per fixture and the flap column
      filled in, per Decision 2
- [x] The scorecard tables in Phase 5 and the summary in `docs/testing.md`
      filled in from those runs
- [x] If the corpus separates the two models on accuracy, the direction and
      magnitude recorded and the `@default_model` recommendation stated - with
      the attribute itself left at its current value. It does separate them:
      haiku 1 majority FN against sonnet's 3, at six times the wall time
- [x] The number of corpus-equivalent runs actually spent recorded next to
      Decision 3's ceiling of eight - 4.2 of 8

### Optional single-fixture checks (Phases 2-4)

- [x] Any `mix test --only fixture:<name>` spot check made while wording a
      fixture, recorded against Decision 3's two-run authoring budget. None
      were made: the fixture rework described below was driven by reading the
      real files, and the first model calls on this branch were the measurement
      runs above. The two-run authoring budget is unspent

### Verification pass (2026-08-18)

The Phase 1-4 manual criteria were read through before the paid runs, against
the real files. Four defects were found and fixed; the fixtures were then
regenerated from real edits to the real source files, captured with
`git diff --unified=3` and reverted, so every hunk header is exactly what git
emits and the mechanism each fixture depends on is visible in the fixture
itself rather than off-page:

- `0012_location_precision_one_caller.diff` was a one-hunk change calling a
  helper whose body was not in the diff, so the precision loss was invisible to
  a judge shown only the ADR and the hunks - and its clean partner was a
  four-hunk rework, making the pair differ in surface rather than meaning. Both
  halves are now the same four hunks and differ by one token.
- Three hunk headers in the trace pair were off by one against what git emits,
  and both fixtures inserted a second consecutive blank line.
- `0012_trace_binding_renamed.diff` renamed nothing; it is now
  `0012_trace_prestate_captured.diff`, and its manifest note says what it does.
  The violating partner's note claimed the moved effect is "stamped against
  post-departure state"; every field `Effect.Trace.ExitSet` actually stamps is
  untouched by the reduce, so the note now says what is true - the effect no
  longer records the boundary it names, and any state-derived field would take
  post-departure values.
- `0015_manifest_constant_change.diff` had a hunk header matching neither its
  body nor the file (`@@ -28,7 +28,7 @@` for a five-line hunk starting at 29),
  and changed `gate.loop` to narrow test scope - close enough to "a choice
  about what blocks" to be arguable as clean. It now adds an output-format flag
  to `gate.report`, which is a constant on any reading.

Two items were recorded rather than changed, both being judgment calls a human
owns: `0015_manifest_policy_key.diff` targets `gate.not_applicable_skips`,
which ADR-0017 point 6 does not name among its policy-bearing exemplars (the
sentence that settles it lives in `CLAUDE.md`, which the judge never sees), so
a miss there indicts the ADR's exemplar list rather than the judge; and
`0012_trace_after_departure.diff` breaks a documented phase boundary that no
currently-stamped field depends on.

### Phase 1

- [x] A reader of `docs/testing.md` can tell which tier the recorded baseline
      table refers to
- [x] No paid run was made in this phase

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. This phase spends nothing and must not be
used to "try out" a tier-filtered run - the first paid run of this branch is
Phase 2's single-fixture check.

---

### Phase 2

- [x] Each violating fixture reads as unambiguously violating to a human who
      knows ADR-0012 and `docs/observability.md` - a fixture a reviewer would
      argue about is not a known-violating fixture and must be reworded or
      dropped before Phase 5 scores it
- [x] Each clean fixture is unambiguously clean by the same standard, and is the
      *same shape* as its partner - the pair differs in meaning, not in surface
- [x] The touched functions' real behavior is understood well enough to say the
      violation is real: `exit_states/2`'s trace ordering matches the W3C
      Appendix D `exitStates` phase boundaries the moduledoc cites, and the
      fixture breaks that ordering rather than an incidental one
- [x] Single-fixture spot checks, if run, are recorded against the Phase-2
      authoring budget of Decision 3

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. Fixture wording iteration, if it needs a
model in the loop at all, uses `mix test --only fixture:<name>` - one fixture,
not the corpus. Do not run the full corpus in this phase.

---

### Phase 3

- [x] The violating fixture is unambiguous to a human holding ADR-0014 and
      `lib/statifier/parser/location.ex:94-97` side by side - if the violation
      cannot be stated in one sentence from the shown material plus the ADR
      text, the fixture is too indirect for the corpus, since the judge is shown
      only the ADR and the hunks
- [x] The clean fixture's anchor arithmetic is right, so the pair really is
      compliant-versus-not and not two flavors of broken. The fixture need not
      compile, but every mechanism it relies on must be visible in the fixture
      itself - it may not lean on an API the repository does not have
- [x] The touched compiler path matches the repository's actual span contract as
      documented, not a remembered one

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. This pair is the most likely to need a
wording pass; iterate with `--only fixture:<name>` against the Phase-3 share of
the authoring budget, not the corpus.

---

### Phase 4

- [x] The two prose fixtures differ only in whether the refusal survives as
      prose, so the pair isolates ADR-0017 point 1's tell and nothing else
- [x] The two manifest fixtures differ only in whether the changed key encodes a
      policy call, so the pair isolates point 6's constant-versus-decision line
- [x] Neither fixture body nor manifest note contains a literal bead id, which
      `AdrGuard`'s ADR-0018 scan would flag on lines added under `test/`
- [x] The fixture diffs against `.claude/wurk.json` and `.claude/wurk/commit.md`
      are plausible against those files as they stand, and the real files are
      unchanged by this phase

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. Take particular care that only the fixture
*files* change - a fixture is a text file describing a hypothetical diff, and
this phase must not edit the real `.claude/wurk.json` or
`.claude/wurk/commit.md`.

---

### Phase 5

- [x] Every finding above is written down with its evidence, and no
      recommendation was acted on
- [x] The scorecard tables in this plan and the summary rows in
      `docs/testing.md` hold real measured numbers, not a template. A command
      can see a table; only a reader can see whether its cells came from a run,
      which is why this is not an automated criterion - a `--loop` pass must not
      be able to satisfy Phase 5 with an empty table
- [x] The spend ceiling of Decision 3 was respected, and the actual number of
      corpus-equivalent runs is recorded next to the ceiling

The paid runs this phase's record is filled in from are listed once, at the end
of this document under `## Deferred Manual Verification`. They are deliberately
not repeated here: no phase's Automated Verification may depend on them, and
keeping them in one place is what makes that visible.

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. In looped execution this phase's Manual
and Deferred Manual items do not block advancement and are surfaced at the end;
the phase is complete as an automated matter once the record is written, and
complete as a matter of fact only once the paid runs above have filled it in.

---
## Open Questions

No human is available during planning, so each question below carries the
decision this plan proceeds on. Each is a place a human may overrule.

1. **Do the new fixtures grow the corpus or replace it?** *Decided: grow, with a
   required `tier:` field* (Decision 1). Replacing strands four recorded
   baselines; growing without tiers makes a green score unattributable.
2. **How many runs make a measurement?** *Decided: three per model per tier,
   majority verdict, flaps reported separately* (Decision 2). Two cannot
   distinguish a fixed verdict from a coin flip, which is the exact limit
   st-6f7's confirmatory rerun hit.
3. **How much real spend is the model comparison worth?** *Decided: eight
   corpus-equivalent runs for the whole bead, with a stop-and-report rule at the
   ceiling* (Decision 3). Roughly 30 minutes of model time; raising it is a
   human's call.
4. **Should `@default_model` move if haiku wins on accuracy?** *Decided: not
   here.* The current value was a human's own call on wall time with accuracy
   tied. Phase 5 records the numbers and the recommendation; the change is a
   human's.
5. **Should the `adr-0015-swallowed-judgment` key be renamed to name ADR-0017?**
   *Decided: not here.* It is a real mislabel and the rename is mechanical, but
   it touches the registry, the `read_adr_source/1` clause, the manifest, ten
   filenames and the baselines' vocabulary for no behavior change. Recorded as a
   finding in Phase 5.
6. **Is a cross-scope fixture wanted?** *Decided: no, not in this bead.* Shape
   invariant 4 forbids it and relaxing the invariant weakens what the free test
   guarantees. Recorded as a gap.
7. **Do the ADRs added since the judge's survey want registry entries?**
   *Decided: out of scope.* Adding one changes what invariant 4's "differing
   scope" resolves to, and st-2ts is about the corpus, not the registry.
8. **Can fixture unambiguity be checked mechanically?** *Decided: no, and the
   plan does not pretend otherwise.* Every phase carries an explicit manual
   criterion that a human read each new fixture beside its ADR, and Phase 5
   treats a fixture that flaps on all six runs as evidence its wording is
   ambiguous rather than as a judge score.

## References

- Bead: st-2ts
- Source document: `docs/research/260818-st-2ts-adr-judge-harder-fixtures.md`
- Prior plan and recorded baselines:
  `docs/plans/260808-st-6f7-adr-judge-refute-grounding.md` (Phase 1 baseline,
  Phase 4 measurement, Open Questions 3 and 6)
- Stage origin: `docs/plans/260804-st2-meo-adr-enforcement-stage.md`
- Related ADRs: `docs/adr/0011-quality-gate-config-not-agent-editable.md`,
  `docs/adr/0012-debuggability-designed-into-the-core.md`,
  `docs/adr/0014-expression-spans-in-cond-diagnostics.md`,
  `docs/adr/0017-judgment-not-scriptable-in-wurk-extensions.md`
- Judge: `lib/mix/statifier/adr_judge.ex:173-211` (registry), `:214-215`
  (`@default_model`), `:445-476` (`scoped_chunks/2`), `:543-585` (refute prompt)
- Guards: `lib/mix/statifier/adr_guard.ex:511-535`,
  `lib/mix/statifier/gate_guard.ex:36-52`
- Corpus: `test/fixtures/adr_judge/manifest.exs`,
  `test/support/adr_judge_corpus.ex`,
  `test/mix/statifier/adr_judge_corpus_test.exs`,
  `test/mix/statifier/adr_judge_corpus_shape_test.exs`
- Fixture subject sites: `lib/statifier/validator/checks/data.ex:80-125`,
  `lib/statifier/interpreter/exit_entry.ex:136-157`,
  `lib/statifier/compiler.ex:786-793`,
  `lib/statifier/parser/location.ex:94-97`, `.claude/wurk/commit.md:15-23`,
  `.claude/wurk.json`
- Suite docs: `docs/testing.md:26-79`, `docs/observability.md`
