# ADR-0012 Pre-Mutation Stamping Fixture Pair Implementation Plan

## Overview

Add an ADR-0012 judge fixture pair that turns on **which state a trace
payload's fields are read from** rather than on where the trace call sits,
close the false negative the violation half is already known to produce, and
record a re-measurement against st-2ts's Phase 5 scorecard without spending
past its stated ceiling. Beads issue: `st-xsb1`.

The corpus today has no fixture where a payload field is *deliberately*
post-mutation. `exit_states/2` reads `configuration` from the post-departure
`machine_state` on purpose while stamping counters from `pre_exit_state`
([`lib/statifier/interpreter/exit_entry.ex:150-164`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/exit_entry.ex#L150-L164)).
A judge that learned "anything read after the reduce is a violation" would be
wrong about that field and right about nothing, and no row catches it.

## Current State Analysis

Everything below is established by
`docs/research/260818-st-xsb1-adr-0012-pre-mutation-fixture.md` and re-verified
against the working tree at commit `463fb45`.

**The path from `.diff` to verdict has no schema enforcement of its own.**
`test/fixtures/adr_judge/manifest.exs` is a bare list literal `Code.eval_file`-d
by `Mix.Statifier.AdrJudgeCorpus.manifest/0`
([`test/support/adr_judge_corpus.ex:37`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L37)).
Five keys per row: `:key`, `:file`, `:expect`, `:tier`, `:note`. The real
enforcement is the free companion
`test/mix/statifier/adr_judge_corpus_shape_test.exs`, whose six checks any new
row must satisfy: the file exists, the key is a live registry key, the tier is
`:blatant` or `:subtle`, both verdicts exist per `{key, tier}`, the diff lands
in its own scope and no other, and the diff text contains no literal
`@tag :skip`.

**The rubric is the whole ADR file plus one `focus` line.** There is no rubric
file. `read_adr_source/1`
([`lib/mix/statifier/adr_judge.ex:346-356`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L346-L356))
reads `docs/adr/0012-debuggability-designed-into-the-core.md` verbatim into both
the propose and refute prompts, alongside the one-line `focus` string in the
`@judged` registry
([`lib/mix/statifier/adr_judge.ex:174-182`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L174-L182)).
ADR-0012's item 4 says counters exist and traces carry "the step and the
identity of what raised them"; it says nothing about *which* state those
counters are read from. That rule is stated only in the `@doc` at
[`lib/statifier/interpreter/exit_entry.ex:100-132`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/exit_entry.ex#L100-L132)
and the six-line inline comment at `:144-149`. `enter_states/2` carries the
identical shape and an identically worded comment at `:710-715`, which matters
twice: the fixtures must target the `exit_states/2` site only, and the Phase 2
amendment must be worded so it covers both.

**The violation half is a measured false negative today.** st-ntf5's hand-run
(recorded on the bead and in the `0012_trace_after_departure.diff` manifest
note) found that a variant which keeps that six-line comment and deletes only
the `pre_exit_state` binding produces **no surviving finding**. The shipped
violation fixture is caught, but part of its signal is the deleted comment
naming the rule the diff then breaks.

**Nothing on the gate path runs the corpus.**
[`test/test_helper.exs:9`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/test_helper.exs#L9)
excludes `:adr_judge_corpus`, and in `:test` builds the default caller is
`refuse_real_call/1`. Only an explicit `mix test --only adr_judge_corpus`,
`--only tier:<tier>`, or `--only fixture:<file>` spends money. The `adr_judge`
ExQuality stage runs `mix adr.judge` against the *branch diff*, not the corpus,
and is `enabled: false` outside `--profile merge`.

**st-2ts fixed the measurement policy and the ceiling.** A measurement is three
runs of the same tier on one model at three distinct seeds, majority verdict per
fixture, flaps reported separately and never folded in
(`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:241-259`). The budget is
eight corpus-equivalents with 1.2 held as reserve "for one re-measurement if a
fixture is rewritten", and an explicit stop rule: "**If the ceiling is reached
before Phase 5's measurement is complete, stop and report the partial
scorecard.** ... raising the ceiling is a human's call" (`:261-282`). Its own run
spent 4.2 of 8, leaving the reserve intact.

**Nothing guarded is touched.** Fixture files under `test/` are outside
`GateGuard`'s `@guarded_paths`
([`lib/mix/statifier/gate_guard.ex:36`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/gate_guard.ex#L36));
only the `@tag :skip` scan reaches them. No `docs/quality-gate-changes.md` entry
is mechanically required by any phase of this plan.

## Desired End State

1. `test/fixtures/adr_judge/` holds two new ADR-0012 `:subtle` fixtures, both
   anchored to current `lib/statifier/interpreter/exit_entry.ex`:
   - a **violation** half that keeps the six-line ADR-0012 comment intact and
     breaks only the stamping (the measured-false-negative variant), and
   - a **clean** half in which the deliberately post-mutation `configuration`
     read is made maximally conspicuous while the stamping is untouched.
2. Both have manifest rows with `key: "adr-0012-debuggability"`,
   `tier: :subtle`, correct `expect`, and a `:note` recording the measured
   history and the phase that resolves it.
3. ADR-0012 carries an amendment stating the pre-mutation stamping rule and,
   equally, that a payload field whose meaning is defined only after the
   mutation is correctly read after it - so the rubric distinguishes the two
   halves without relying on an inline code comment.
4. A recorded, human-run measurement of the ADR-0012 subtle rows appears in
   st-2ts's `#### Phase 5 measurement (recorded)` subsection with its spend
   stated against Decision 3's ceiling, and the summary is mirrored into
   `docs/testing.md`.

**Verification of the end state**: `mix quality` green on each phase;
`mix test` still executing zero `adr_judge_corpus` tests; the shape test passing
all 20 manifest rows; and, for item 4 only, a human reading the recorded
tables and confirming their cells came from real runs.

### Key Discoveries:

- The trace site's three-shape form, and the exact lines a fixture must cut:
  [`lib/statifier/interpreter/exit_entry.ex:144-164`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/exit_entry.ex#L144-L164).
- The six shape checks a new row must satisfy:
  [`test/mix/statifier/adr_judge_corpus_shape_test.exs:13-82`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_shape_test.exs#L13-L82).
- `--only fixture:<file>` is a first-class spend control, documented as such at
  [`test/mix/statifier/adr_judge_corpus_test.exs:22-28`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_test.exs#L22-L28).
  This is what makes a sub-tier measurement possible at all.
- ADR-0012's amendment convention is established twice (st-1xwh, st-9i5r):
  append an `**Amendment (<bead>):**` block, leave the original sentence
  standing unedited, and say why it is an amendment rather than a new record.
- st-2ts set the precedent that choosing between "amend the ADR" and
  "reclassify the fixture" is a human's call, for the structurally identical
  `0012_location_precision_one_caller.diff` case
  (`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:1005-1013`).
- The re-anchoring method for fixtures: apply a real edit to current source,
  `git diff --unified=3`, revert
  (`docs/plans/260818-st-ntf5-microstep-configuration-on-trace-effects.md:557-576`).
- No changelog fragment is indicated: `changelog.d/README.md` scopes fragments
  to library users, and nothing here is public API, observable behavior, SCXML
  support, or a user-visible fix.

## What We're NOT Doing

- **Not changing any judge behavior in `lib/`.** Phase 2 is a docs-only
  amendment. Widening the ADR-0012 `focus` string
  ([`lib/mix/statifier/adr_judge.ex:174-182`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L174-L182))
  is the recorded fallback if a maintainer redirects, not the plan of record.
- **Not touching `lib/statifier/interpreter/exit_entry.ex`.** The production
  shape st-ntf5 landed is the anchor the fixtures are cut from, not a target.
- **Not adding a third tier.** The pair joins `:subtle`.
- **Not moving `@default_model`.** st-2ts's recommendation stands unacted, and
  this bead is not the place to act on it.
- **Not re-measuring the full subtle tier, and not re-measuring `haiku`.**
  Both exceed Decision 3's 1.2-run reserve; see the provisional decision on
  question 2 below.
- **Not adding any paid run to `mix quality`, to CI, or to any phase's
  Automated Verification.** This restates st-2ts's guardrail
  (`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:176-177`) and binds
  this plan identically.
- **Not editing `.quality.exs`**, so no `docs/quality-gate-changes.md` entry is
  required.
- **Not writing a changelog fragment**, per `changelog.d/README.md`.
- **Not adding new ExUnit tests.** The corpus tests are generated from the
  manifest, so two new rows produce two new generated tests automatically; both
  generated forms already carry `# sabotage: n/a` with a stated reason
  ([`test/mix/statifier/adr_judge_corpus_test.exs:35-36`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_test.exs#L35-L36), `:50-51`).
  No hand-written test asserting `lib/` behavior is added by any phase, so the
  repo's sabotage rule has nothing new to attach to.

## Implementation Approach

Three phases, each independently committable and independently gate-verifiable,
ordered so that a maintainer can redirect the pivotal decision without
invalidating anything already committed:

1. **Phase 1 - the corpus addition.** Files and manifest rows only. Its gate is
   the free shape test inside a full `mix quality`. It is correct and complete
   whether or not the judge ever catches the violation half, because the
   manifest note carries the measured status.
2. **Phase 2 - the rubric change.** A docs-only ADR-0012 amendment. Separately
   committable, separately gate-verifiable, and reversible with one revert. If a
   maintainer prefers a widened `focus` string or a reclassification instead,
   Phase 1 stands untouched and only this phase is rewritten.
3. **Phase 3 - the recorded measurement.** Real spend, human-gated, **manual
   success criteria only**. No agent executes this phase unattended.

The pivotal ordering constraint is that Phase 1 must not pretend the violation
row passes. It lands with `expect: :violation` and a note stating in plain terms
that it is a known false negative as of the st-ntf5 hand-run, that no gate runs
it, and that Phase 3 is where its status is next measured. That is what keeps
Phase 1 honest as a standalone commit.

## Phase 1: The pre-mutation fixture pair and its manifest rows

### Overview

Author two `.diff` fixtures against current `exit_entry.ex` and register them.
No `lib/` change, no ADR change, no paid run.

### Changes Required:

#### 1. The violation half

**File**: `test/fixtures/adr_judge/0012_trace_stamp_swapped_comment_kept.diff`
**Changes**: The measured variant from st-ntf5's hand-run. Cut with the
established method - apply the edit to
`lib/statifier/interpreter/exit_entry.ex`, `git diff --unified=3`, revert - so
the base blob matches the two existing `exit_entry` fixtures.

The edit: delete **only** the `pre_exit_state = machine_state` binding at
`:150`, and swap the trace's first argument from `pre_exit_state` to
`machine_state`. The six-line ADR-0012 comment at `:144-149` stays exactly as
it is, including its now-dangling reference to `pre_exit_state`. Do not touch
the mirrored `enter_states/2` site at `:710-715`; the diff must present one
site, so the judge is scored on one signal.

```
     # ADR-0012: the counters this payload stamps must be the ones that stood
     # at the exit-set phase boundary, so the trace is stamped against
     # `pre_exit_state`; only `configuration` is read from the post-departure
     ...
-    pre_exit_state = machine_state
-
     machine_state = record_history_values(machine_state, states_to_exit)
     ...
     trace_effects =
-      Effect.trace(pre_exit_state, Effect.Trace.ExitSet,
+      Effect.trace(machine_state, Effect.Trace.ExitSet,
         indexes: states_to_exit,
         configuration: machine_state.configuration
       )
```

This is a `:subtle` violation by the corpus's own definition
([`test/support/adr_judge_corpus.ex:33-34`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L33-L34)):
the shape of the change is preserved and only its meaning breaks. It differs
from `0012_trace_after_departure.diff` in exactly one respect - the comment
survives - which is what isolates the signal.

#### 2. The clean half

**File**: `test/fixtures/adr_judge/0012_configuration_read_post_departure.diff`
**Changes**: A meaning-preserving edit that makes the deliberately post-mutation
read as conspicuous as possible, so a judge that has learned "read after the
reduce means violation" fires on it and is scored a false positive.

The edit: keep `pre_exit_state` and the stamping untouched; bind the reduce's
result to an explicitly named `post_departure_state`, and read the payload's
`configuration` from that binding. The comment is reworded to name both
bindings, without changing the rule it states.

```
     {machine_state, depart_effects} = ...
+    post_departure_state = machine_state
+
     trace_effects =
       Effect.trace(pre_exit_state, Effect.Trace.ExitSet,
         indexes: states_to_exit,
-        configuration: machine_state.configuration
+        configuration: post_departure_state.configuration
       )
```

This is distinct from `0012_trace_prestate_captured.diff`, which varies the
*pre*-state binding's name and hoists the configuration read into a local. This
one leaves the pre-state binding alone and varies only how visibly the
post-mutation read is expressed - which is the axis the bead names.

#### 3. Manifest rows

**File**: `test/fixtures/adr_judge/manifest.exs`
**Changes**: Two rows appended next to the existing ADR-0012 subtle pair, in the
five-key schema.

```elixir
%{
  key: "adr-0012-debuggability",
  file: "0012_trace_stamp_swapped_comment_kept.diff",
  expect: :violation,
  tier: :subtle,
  note:
    "the exit-set trace's counters are stamped from the post-departure state ... " <>
      "the six-line ADR-0012 comment naming the rule is left in place, so the only " <>
      "signal is the stamp swap itself. Measured a FALSE NEGATIVE by hand on " <>
      "2026-08-18 (st-ntf5) against the real CLI; landed under st-xsb1 as the row " <>
      "that isolates that gap. No gate path runs this row - next measured in " <>
      "docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md Phase 3"
},
%{
  key: "adr-0012-debuggability",
  file: "0012_configuration_read_post_departure.diff",
  expect: :clean,
  tier: :subtle,
  note:
    "the payload's `configuration` is read from an explicitly named " <>
      "post-departure binding, which is what ADR-0012 requires of that field - " <>
      "the state the counters are stamped against is unchanged. The adversarial " <>
      "partner to the row above: a judge that learned 'read after the reduce is a " <>
      "violation' scores a false positive here"
},
```

#### 4. Fixture inventory prose

**File**: `docs/testing.md`
**Changes**: Exactly one count exists in this file today and needs editing:
`docs/testing.md:92`, "A `:subtle` tier (ten fixtures, five per-registry-entry
pairs)", becomes twelve fixtures and six pairs. There is **no** combined
corpus total stated anywhere in the file - `:63` names only "the original
eight-fixture corpus" - so do not go hunting for an "eighteen" to change.
Append to the same sentence, or the one after it, a clause naming what the new
pair isolates: that ADR-0012's subtle tier now separates a payload field
stamped from the wrong state from one deliberately read after the mutation.

Leave every recorded score cell alone - those describe measurements over the
ten-fixture tier and are annotated rather than superseded (see the provisional
decision on question 5). Phase 3, not this phase, adds the new labeled row.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] `mix gate.verify` confirms the run was a full, unscoped gate
- [x] `mix test test/mix/statifier/adr_judge_corpus_shape_test.exs` passes, now
      all 20 rows (18 + 2) - specifically the file-exists, real-key, known-tier,
      both-verdicts-per-`{key, tier}`, own-scope-only, and no-`@tag :skip`
      checks
- [x] `mix test` reports zero `adr_judge_corpus` tests executed, so the addition
      put nothing paid on the ordinary suite
- [x] `git diff --stat` shows no path under `lib/`
- [x] `git diff --stat` shows no guarded path (`.quality.exs`, `.credo.exs`,
      `coveralls.json`, `.sobelow-conf`, `.doctor.exs`, `mix.exs`,
      `test/passing_tests.json`), so `mix gate.check` needs no ledger entry
- [x] Use `mix quality --profile loop` between edits while iterating

#### Manual Verification:
- [ ] Both new `.diff` files were cut by the established method (apply, `git
      diff --unified=3`, revert) against current `exit_entry.ex`, and their
      `index` base blob matches the two existing `exit_entry` fixtures
- [ ] The violation half differs from st-ntf5's hand-measured variant in no
      respect - it is that diff, not a re-derivation of it
- [ ] The clean half is genuinely meaning-preserving: read the diff and confirm
      the state the payload is stamped against and the configuration it carries
      are both unchanged
- [ ] The clean half varies something `0012_trace_prestate_captured.diff` does
      not, and a reader can say in one sentence what
- [ ] No regression in the other 18 rows' prose or verdicts

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run full `mix quality` as the phase gate. In interactive execution,
pause here for the human to confirm the manual items before Phase 2. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically and the Manual items are deferred to the end.

---

## Phase 2: The ADR-0012 amendment that makes the rule readable

### Overview

State in ADR-0012 itself what the rubric currently states only in an inline code
comment: which state a trace payload's counters are stamped against, and that a
field whose meaning is defined only after the mutation is correctly read after
it. Docs-only; no `lib/` change; no paid run.

This phase is where the pivotal open question is resolved. The provisional
resolution is the ADR amendment, for the reasons under question 1 below. If a
maintainer redirects to a widened `focus` string or to landing the row as a
recorded known failure, **this phase is rewritten and Phase 1 stands.**

### Changes Required:

#### 1. The amendment block

**File**: `docs/adr/0012-debuggability-designed-into-the-core.md`
**Changes**: Append a third `**Amendment (st-xsb1):**` block after the st-9i5r
one, following the convention the first two set - the original item 4 sentence
stays standing, unedited. Update the status line's amendment list the same way
the previous two did.

The amendment says, in the ADR's own register:

- Item 4 commits to trace effects carrying "the step and the identity of what
  raised them" but does not say **which** state those counters are read from.
  A trace effect names a phase boundary; the step counters it carries are the
  ones that stood **at** that boundary, so they are stamped against the state
  as it was when the boundary was crossed, not against whatever the state
  became afterwards.
- The converse is equally part of the rule: a payload field whose meaning is
  defined only by the mutation - "the configuration after this exit set was
  applied" - is correctly read from the post-mutation state. Reading such a
  field after the mutation is not a violation of this item; stamping the
  counters after it is.
- Why an amendment rather than a new record: this mints no new identity, adds
  no runtime cost, and constrains no code that was not already constrained by
  item 4. It completes a sentence item 4 left half-stated, exactly as st-1xwh
  completed the index enumeration.

The `exit_states/2` doc comment
([`lib/statifier/interpreter/exit_entry.ex:100-132`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/exit_entry.ex#L100-L132))
is the worked example the amendment can cite by name, but **the amendment must
be readable without it** - a rubric that only works when the code under review
still carries the explaining comment is the exact failure this bead exists to
fix.

#### 2. Nothing in `lib/`

Recorded explicitly so an implementer does not reach for it: this phase does not
touch the `focus` string, the prompts, `parse_refute/1`, or `@default_model`.
`test/mix/statifier/adr_judge_test.exs:799` asserts
`adr_0012.adr_text =~ "Debuggability"`, which an appended amendment preserves;
no test keys on the ADR's body text.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] `mix gate.verify` confirms the run was a full, unscoped gate
- [x] `mix test test/mix/statifier/adr_judge_test.exs` passes - in particular
      the `adr_text` assertion that reads the amended file
- [x] `git diff --stat` for this phase shows exactly one path,
      `docs/adr/0012-debuggability-designed-into-the-core.md`
- [x] `mix test` still reports zero `adr_judge_corpus` tests executed
- [x] Use `mix quality --profile loop` between edits while iterating

#### Manual Verification:
- [ ] The amendment follows the st-1xwh/st-9i5r convention: appended block, the
      original item 4 sentence left standing unedited, and a stated reason why
      it is an amendment rather than a new record
- [ ] Read the amendment with the two new fixtures side by side and confirm it
      calls the violation half a violation and the clean half clean, **without
      reference to any inline code comment**
- [ ] Read the amendment against the four other ADR-0012 subtle and blatant
      fixtures and confirm it does not newly indict any known-clean one - the
      false-positive risk a rubric widening carries is a reader's judgment
      before it is a measurement
- [ ] `mix quality --profile merge` on this branch: the `ADR judge` stage should
      report a clean skip (`:no_scoped_changes`), since no phase of this plan
      touches `lib/statifier/`. Confirm the skip line rather than assuming it

**Implementation Note**: Same loop/full-gate discipline as Phase 1. Pause for
the human before Phase 3 unconditionally - Phase 3 spends money and is not an
agent's to start.

---

## Phase 3: Recorded measurement (HUMAN-GATED - real spend)

### Overview

Measure the ADR-0012 subtle rows against the amended rubric, record the result
in st-2ts's scorecard, and mirror the summary into `docs/testing.md`.

> **This phase MUST NOT be executed unattended.** Every run below makes real
> `claude` CLI calls and costs real money. No agent may start it, and no agent
> may continue it past the budget stated below. All of its success criteria are
> **manual**; it has no Automated Verification list by design, so no `--loop`
> pass and no gate can advance through it.

### Changes Required:

#### 1. The runs (a human's, by hand)

**Budget: 18 fixture-runs = 1.0 corpus-equivalent**, against Decision 3's
1.2-run reserve. The scope is the six ADR-0012 `:subtle` rows (four existing,
two new), three seeds, `claude-sonnet-5` only:

```
STATIFIER_ADR_JUDGE_MODEL=claude-sonnet-5 \
  mix test --only fixture:<name> --seed <101|202|303> --trace
```

once per fixture per seed, for:

| Fixture | Expect |
|---|---|
| `0012_trace_stamp_swapped_comment_kept.diff` | violation (new) |
| `0012_configuration_read_post_departure.diff` | clean (new) |
| `0012_trace_after_departure.diff` | violation |
| `0012_trace_prestate_captured.diff` | clean |
| `0012_location_precision_one_caller.diff` | violation |
| `0012_location_helper_extracted.diff` | clean |

Do **not** use `--only tier:subtle` (12 fixtures x 3 seeds = 2.0
corpus-equivalents, over the reserve) and do **not** use
`--include adr_judge_corpus` (the whole corpus).

Record per run: per-fixture verdict, per-fixture wall time, model id, seed.
Compute the majority of three per fixture; count any non-unanimous fixture as a
flap and never fold the flap count into the score, per Decision 2.

**The stop rule, restated and binding here:** if the budget above is reached
before the measurement is complete, **stop and report the partial scorecard.**
Do not run the remaining fixtures, do not add a model, do not raise the ceiling.
Raising it is a human's call and st-2ts says so at `:279-282`.

**The pre-amendment datum is not re-measured.** st-ntf5's hand-run already
established that the violation half is a false negative against the unamended
rubric; that is the "before" number, cited rather than re-bought.

#### 2. The scorecard entry

**File**: `docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md`
**Changes**: A dated sub-entry appended inside the existing
`#### Phase 5 measurement (recorded)` subsection, in that subsection's own two
shapes: a per-fixture verdict matrix (one row per fixture, a `sonnet
101/202/303` column, cells `ok` / `FN` / `FP`) and a summary row. It is labeled
as a partial re-measurement - six ADR-0012 rows on one model - so no reader
mistakes it for a replacement of the ten-fixture, two-model table above it.
The spend is stated in corpus-equivalents against the ceiling of 8, cumulative
with st-2ts's own 4.2.

#### 3. The mirror

**File**: `docs/testing.md`
**Changes**: The recorded-scores section gains the new summary row with the same
partial-re-measurement label, and a sentence saying the earlier subtle rows were
measured over the ten-fixture tier on two models and are not superseded by this
one.

#### 4. If the violation row is still missed

**Files**: `test/fixtures/adr_judge/manifest.exs`, and this plan's findings
section
**Changes**: If the violation half is still a majority false negative under the
amended rubric, **record it and stop.** Update its `:note` to say so with the
date and the seeds, write the finding into the findings section below, and
report to a human. Do **not** iterate on the amendment and re-measure; a second
measurement pass is a second 1.0 corpus-equivalents and it is not budgeted here.

### Success Criteria:

#### Automated Verification:

None. This phase has no automated criteria **by design** - every criterion below
requires a human, and giving it an automated one would let a `--loop` pass
advance through a phase that spends money.

The one command that may be run to confirm this phase changed nothing it should
not: `mix quality` still passes and `git diff --stat` shows only
`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md`, `docs/testing.md`, and
this plan - **plus `test/fixtures/adr_judge/manifest.exs` if and only if change
4's branch was taken** and the violation row's `:note` was updated to record a
surviving false negative. That fourth path is an expected outcome, not a
symptom. The check is on the record, not on the measurement, and it does not
substitute for anything below.

#### Manual Verification:
- [~] A human, not an agent, decided to start this phase and ran every command -
      **half met, recorded as a deviation.** The human decided to start the
      phase and authorized the spend; an agent ran the eighteen commands. The
      deviation is written into the scorecard entry itself rather than ticked
      away, so a later reader can weigh the cells. Noted 2026-08-18
- [x] Every recorded cell came from a real run - every cell traces to one
      `mix test --only fixture:<name> --seed <n>` invocation whose raw ExUnit
      output was read directly; no cell was inferred from another
- [x] The spend is recorded in corpus-equivalents next to Decision 3's ceiling
      of 8, cumulative with st-2ts's 4.2 - 1.0 spent, cumulative 5.2 of 8
- [x] The budget above was not exceeded; if it was reached mid-measurement, the
      partial scorecard was reported rather than the run continued - 18 of 18
      runs, no fixture re-run, no second model, no tier-wide selector
- [x] The entry is unambiguously labeled a partial re-measurement, and st-2ts's
      existing tables are left standing
- [x] `docs/testing.md`'s mirrored row carries the same label
- [n/a] If the violation row is still missed, the finding is written down and no
      further paid run was made - **change 4's branch was not taken.** The
      violation half was caught on all three seeds, so there is no surviving
      false negative to record for it. No further paid run was made either way

**Outcome, 2026-08-18.** The amendment worked. Both ADR-0012 stamp-swap
violation rows are now caught unanimously, including the one st-ntf5 measured
as a false negative against the unamended rubric, and neither clean row drew a
false positive - so the amendment did not buy its recall by teaching the judge
that any post-reduce read is a violation, which was the specific failure the
fixture pair exists to detect. `0012_location_precision_one_caller.diff` is
still missed and is now unanimous where it was 2/3; it was already a majority
false negative on both models before this amendment, st-2ts's finding 4 already
diagnosed it as an ADR-wording question, and the one-seed move is not separable
from noise at three runs. Full matrix and spend in st-2ts's Phase 5 subsection.

**Implementation Note**: There is no `--loop` execution of this phase. An agent
reaching it stops, reports that Phases 1 and 2 are complete, and states plainly
that Phase 3 is a human's to run.

---

## Corpus/Ratchet Notes

This plan touches the **ADR-judge** corpus, which is unrelated to the SCXML
conformance corpus and the regression ratchet. No phase regenerates the
conformance corpus, changes `test/passing_tests.json`, or can move a SCION or
W3C result - no phase touches `lib/` at all. `mix test.regression` and
`mix test.baseline add` are therefore not phase criteria here; the full
`mix quality` each phase runs already covers everything this work can move.

## Testing Strategy

### Unit Tests:

No new hand-written tests. The corpus tests are generated from the manifest at
compile time
([`test/mix/statifier/adr_judge_corpus_test.exs:29-60`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_test.exs#L29-L60)),
so Phase 1's two rows produce two new generated tests with no test-file edit,
each inheriting the existing `# sabotage: n/a` line and its stated reason. The
repo's sabotage rule therefore has no new assertion to attach to; this is
recorded rather than omitted, per `docs/testing.md`.

The real coverage of Phase 1 is the free shape test, which already exists and
already asserts the six invariants a new row must satisfy. Its own sabotage
lines are unchanged.

Key edge cases the shape test decides for us, and that Phase 1 must not trip:

- A `.diff` whose paths fall outside `lib/statifier/` produces no scoped chunks
  and fails the own-scope check.
- A `.diff` that also touches `.claude/wurk/` fails the differing-scope check.
- A tier other than `:blatant`/`:subtle` fails outright.

### Manual Testing Steps:

1. After Phase 1: read both new diffs against
   `lib/statifier/interpreter/exit_entry.ex` at HEAD and confirm each applies
   cleanly in the head, and that the violation one is st-ntf5's measured
   variant.
2. After Phase 2: read the amendment against all six ADR-0012 subtle fixtures
   and answer, per fixture, whether the amendment alone decides it correctly.
3. After Phase 2: run `mix quality --profile merge` and confirm the `ADR judge`
   stage reports the `:no_scoped_changes` skip.
4. Phase 3 is manual in its entirety; its steps are the runs listed in that
   phase.

## Provisional Decisions and Findings for a Maintainer

The research document left five questions open. **No human was available while
this plan was written**, so each is answered provisionally here so the plan is
executable, with the assumption stated and the redirect cost named. Every one of
these is a maintainer's to overturn.

**1. Landing the violation half obliges a rubric or judge change. Which one?**
*Provisional answer: amend ADR-0012 (Phase 2).* Grounds: the entire ADR file is
the rubric, read verbatim into both prompts, so the ADR is the most direct lever;
the rule is genuinely missing from item 4 rather than merely under-emphasized;
ADR-0012 already has a twice-used amendment convention; and st-2ts reached the
structurally identical fork on
`0012_location_precision_one_caller.diff` and named "the ADR grows a sentence"
as one of the two legitimate answers. *Assumption*: that a rubric sentence,
rather than a `focus`-string nudge, is the right place for a rule about the ADR's
own semantics. *Redirect cost*: rewriting Phase 2 only. Widening the `focus`
string at
[`lib/mix/statifier/adr_judge.ex:174-182`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L174-L182)
is a small `lib/` change on an unguarded path; landing the row as a recorded
known failure needs no code change at all and is already half-done by Phase 1's
manifest note. Phases 1 and 3 are unaffected by either substitution.

**2. Does "re-measure to include them" exceed st-2ts's 1.2-run reserve?**
*Provisional answer: measure the six ADR-0012 subtle rows on `claude-sonnet-5`
at three seeds - 18 fixture-runs, 1.0 corpus-equivalent, inside the reserve.*
Grounds: Decision 2's unit is three runs at three seeds, which is preserved
exactly; `--only fixture:<file>` is a documented spend control, so a sub-tier
slice is a supported operation rather than an invention; sonnet is the current
`@default_model`, so it is the model the score should be read against; and a
rubric change can only plausibly move the rows of the ADR it amends, which is
what bounds the slice. *Assumption*: that a per-fixture slice satisfies "the
scorecard is re-measured to include them" in the bead's acceptance criteria.
*What this leaves unmeasured, and it is real*: the `haiku` column for the two new
rows, the other six subtle fixtures (0014 and 0015 rows, which the amendment
should not touch but which nothing here proves it does not), and the blatant
tier. A full twelve-fixture two-model re-measurement is 4.0 corpus-equivalents
and would put cumulative spend at 8.2 of a ceiling of 8. **Raising the ceiling is
a human's call and this plan does not make it.**

**3. Which tier does the pair join?** *Provisional answer: `:subtle`.* Grounds:
the corpus's own definition
([`test/support/adr_judge_corpus.ex:33-34`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/support/adr_judge_corpus.ex#L33-L34))
is that a subtle fixture preserves the shape of the change it fakes and breaks
only its meaning, which is precisely this pair; and the shape test admits only
two tiers
([`test/mix/statifier/adr_judge_corpus_shape_test.exs:30-36`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/test/mix/statifier/adr_judge_corpus_shape_test.exs#L30-L36)),
so a third would mean editing an assertion and the `docs/testing.md` tier prose
to dodge a cost question. *Consequence, stated rather than hidden*: this is what
makes question 2 bite, since the subtle tier is the measured one.

**4. Must the clean half be distinct from `0012_trace_prestate_captured.diff`?**
*Provisional answer: yes, a new distinct clean fixture (Phase 1, change 2).*
Grounds: the existing clean row varies the pre-state binding's name and hoists
the configuration read, so its signal is mixed across both halves of the rule;
the new one holds the pre-state binding fixed and varies only how conspicuously
the post-mutation read is written, which is the single axis the bead names. It is
also the exact adversarial partner to the new violation half, at the same site,
with the same base blob. *Assumption*: that a pair worth measuring wants both
halves cut against one axis. *Redirect cost*: dropping the clean half is
possible - the shape test's both-verdicts requirement is already satisfied by
the existing pair - and would reduce Phase 3's budget by 3 fixture-runs.

**5. Does `docs/testing.md` supersede or annotate its old numbers?**
*Provisional answer: annotate, never overwrite.* Grounds: the existing subtle
rows are a real two-model, ten-fixture, majority-of-three measurement, and the
new one is a one-model six-fixture slice; overwriting the stronger measurement
with the weaker one loses information the project paid for. Phase 1 updates only
the *counts* in the inventory prose (10 -> 12 subtle, 18 -> 20 corpus) and Phase
3 adds a labeled row beside the old ones. *Assumption*: that a reader is better
served by two labeled measurements than by one unlabeled current one.

### Findings recorded but not acted on

- **A rubric widening can produce false positives on rows it was not aimed at,
  and this plan cannot prove it does not within its budget.** Phase 2's manual
  criteria include a read-through of the other ADR-0012 fixtures, and Phase 3
  measures the four existing ADR-0012 subtle rows alongside the two new ones for
  exactly this reason. The blast radius is bounded by construction: each registry
  entry has its own `adr_path` and `read_adr_source/1` reads only that file
  ([`lib/mix/statifier/adr_judge.ex:173-211`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/mix/statifier/adr_judge.ex#L173-L211),
  `:346-356`), so an ADR-0012-only edit cannot reach the 0014 or 0015 rows -
  they are judged against different text entirely and are deliberately not
  re-measured. The residual risk is confined to the **four ADR-0012 blatant
  fixtures**, which this plan does not re-measure. That is the gap.
- **st-2ts's `@default_model` recommendation still stands unacted**, and this
  plan measures on sonnet partly because of that. If a maintainer moves the
  default to haiku first, Phase 3's model should move with it.
- **The `0012_location_precision_one_caller.diff` question is the same shape as
  this bead's** and remains open. This plan does not resolve it, but Phase 3
  re-measures that row incidentally, which will produce a third data point on it
  at no additional cost.

## Deferred Manual Verification

Everything below costs real money and real wall time. None of it may be added to
`mix quality`, to CI, or to any phase's Automated Verification list, and no
phase's advancement may be gated on it. Run each by hand, deliberately, and
record the result in Phase 3's scorecard entry.

**An automated pass must stop here.** Phase 3 carries no automated criteria, so
a tool that reads "all automated criteria satisfied" as "phase complete" will
read Phase 3 as complete on arrival. It is not. An agent reaching Phase 3 reports
that Phases 1 and 2 are done and that Phase 3 is unstarted and a human's to run.

### Paid corpus runs (Phase 3)

- [ ] Three `claude-sonnet-5` runs at seeds 101/202/303 over each of the six
      ADR-0012 `:subtle` fixtures, via `--only fixture:<name>` - 18 fixture-runs
      = 1.0 corpus-equivalent, inside Decision 3's 1.2 reserve
- [ ] Per-fixture verdicts and wall times recorded per run
- [ ] Majority-of-three computed per fixture and the flap column filled in, per
      Decision 2
- [ ] The per-fixture matrix and summary row added to st-2ts's
      `#### Phase 5 measurement (recorded)` subsection, labeled a partial
      re-measurement
- [ ] The summary mirrored into `docs/testing.md` with the same label
- [ ] Spend recorded in corpus-equivalents against the ceiling of 8, cumulative
      with st-2ts's 4.2
- [ ] If the new violation row is still a majority false negative, the finding
      written down and **no further paid run made**

### Explicitly not budgeted

- A `haiku` column for any row. A second model doubles the phase to 2.0
  corpus-equivalents and puts cumulative spend at 6.2 of 8.
- A full twelve-fixture subtle-tier re-measurement on two models (4.0
  corpus-equivalents, cumulative 8.2 of 8 - over the ceiling).
- A blatant-tier control run.

Any of these is a ceiling decision, and Decision 3 says a ceiling decision is a
human's call.


### Phase 1

- [ ] Both new `.diff` files were cut by the established method (apply, `git
      diff --unified=3`, revert) against current `exit_entry.ex`, and their
      `index` base blob matches the two existing `exit_entry` fixtures
- [ ] The violation half differs from st-ntf5's hand-measured variant in no
      respect - it is that diff, not a re-derivation of it
- [ ] The clean half is genuinely meaning-preserving: read the diff and confirm
      the state the payload is stamped against and the configuration it carries
      are both unchanged
- [ ] The clean half varies something `0012_trace_prestate_captured.diff` does
      not, and a reader can say in one sentence what
- [ ] No regression in the other 18 rows' prose or verdicts

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run full `mix quality` as the phase gate. In interactive execution,
pause here for the human to confirm the manual items before Phase 2. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically and the Manual items are deferred to the end.

---

### Phase 2

- [ ] The amendment follows the st-1xwh/st-9i5r convention: appended block, the
      original item 4 sentence left standing unedited, and a stated reason why
      it is an amendment rather than a new record
- [ ] Read the amendment with the two new fixtures side by side and confirm it
      calls the violation half a violation and the clean half clean, **without
      reference to any inline code comment**
- [ ] Read the amendment against the four other ADR-0012 subtle and blatant
      fixtures and confirm it does not newly indict any known-clean one - the
      false-positive risk a rubric widening carries is a reader's judgment
      before it is a measurement
- [ ] `mix quality --profile merge` on this branch: the `ADR judge` stage should
      report a clean skip (`:no_scoped_changes`), since no phase of this plan
      touches `lib/statifier/`. Confirm the skip line rather than assuming it

**Implementation Note**: Same loop/full-gate discipline as Phase 1. Pause for
the human before Phase 3 unconditionally - Phase 3 spends money and is not an
agent's to start.

---
## References

- Source document:
  `docs/research/260818-st-xsb1-adr-0012-pre-mutation-fixture.md`
- Related ADRs: `docs/adr/0012-debuggability-designed-into-the-core.md` (the
  judged record, amended in Phase 2),
  `docs/adr/0011-*` (guarded gate config - no phase touches a guarded path),
  `docs/adr/0002-*` (Appendix D literalness - no phase touches the interpreter)
- Prior plans: `docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md`
  (Decisions 1-3, the Phase 5 scorecard, the spend ceiling),
  `docs/plans/260818-st-ntf5-microstep-configuration-on-trace-effects.md`
  (the third trace-site shape, the re-anchoring method, the hand-run that filed
  this bead),
  `docs/plans/260808-st-6f7-adr-judge-refute-grounding.md`,
  `docs/plans/260807-st-laz-adr-judge-multi-adr.md`,
  `docs/plans/260804-st2-meo-adr-enforcement-stage.md`
- Anchor site:
  [`lib/statifier/interpreter/exit_entry.ex:134-167`](https://github.com/riddler/statifier-ex/blob/463fb453d27237ebf2bf329647d2518700ac847a/lib/statifier/interpreter/exit_entry.ex#L134-L167)
- Similar implementation (fixture pair + manifest rows + recorded measurement):
  st-2ts Phases 2-5
- Beads issue: `st-xsb1`
