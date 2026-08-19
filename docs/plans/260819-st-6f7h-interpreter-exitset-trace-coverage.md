# Interpreter Exit-Sweep ExitSet Trace Coverage Implementation Plan

## Overview

st-6f7h asks for one of two things: a judge-corpus fixture pair anchored on the
uncovered `exit_interpreter/1` ExitSet trace stamp site, or a recorded decision
that one site's coverage is sufficient for the rule. **This plan takes the
fixture branch, in the redesigned form the research reached** - not a transplant
of `0012_trace_stamp_swapped_comment_kept.diff` to a second path, but a pair
built around the two trace calls `exit_interpreter/1` emits with *opposite*
pre/post splits. Beads issue: `st-6f7h`.

The one-line rationale: a transplant would buy only the judge's sensitivity to a
file path, which no ADR clause makes relevant, but a hunk containing both
`Trace.ExitSet` (stamped pre-sweep) and `Trace.Done` (legitimately stamped
post-sweep) is a discrimination task no existing fixture poses, and its clean
half probes the one half of ADR-0012's amendment the corpus has never tested -
a **legitimately post-mutation stamp**.

**Corrected 2026-08-19 (st-6f7h `/wurk:verify` pass).** The "not a transplant"
claim above is wrong for the violation half, and the correction matters because
Phase 2's result turns on it. The violation half's *changed lines* are
byte-identical to `0012_trace_stamp_swapped_comment_kept.diff` - the same four
lines, deleting `pre_exit_state = machine_state` and swapping
`Effect.trace(pre_exit_state, Effect.Trace.ExitSet, ...)` to
`Effect.trace(machine_state, ...)`. It *is* that transplant, deliberately re-cut
at `--unified=14` against site B. What is genuinely new in this pair is the
clean half (a legitimately post-mutation stamp) and the wide two-trace hunk,
never the violation half's edit.

This is what makes Phase 2's finding sharp rather than ambiguous: site A's row
is caught 3/3 and site B's is missed 3/3 **on identical changed bytes**, so the
edit itself is exonerated as the cause and only the surrounding context can
explain the divergence.

## Current State Analysis

Everything below is established by
`docs/research/260819-st-6f7h-interpreter-exitset-trace-coverage.md` and
re-verified against the working tree at commit `a2948a4`.

**There are three governed sites, not two.** The bead names two; the research
found a third.

| Site | Location | Payload | Corpus coverage |
|---|---|---|---|
| A | `lib/statifier/interpreter/exit_entry.ex:134-167`, `exit_states/2` | `Trace.ExitSet` | six ADR-0012 subtle fixtures |
| B | `lib/statifier/interpreter.ex:1741-1799`, `exit_interpreter/1` | `Trace.ExitSet` | none |
| C | `lib/statifier/interpreter/exit_entry.ex:706-733`, `enter_states/2` | `Trace.EntrySet` | none |

The three six-line ADR-0012 comments differ by one or two words
(`post-departure` / `post-sweep` / `post-entry`, and the binding name). The
undercount matters: any argument of the form "each governed site needs its own
row" argues for a third pair as well as a second, and the corpus has never been
sized per site.

**A stamp swap is value-inert at all three sites today.** `Effect.trace/3`
(`lib/statifier/effect.ex:172-182`) stamps only `macrostep`/`microstep`/`round`,
and none of the three reduces mutates those counters. So no `test/` assertion
can catch a swap at any site, and the judge corpus is the only instrument in
play. "Coverage" in this bead means judge-corpus coverage, never test coverage.

**The judge sees hunk bytes, not the repository.** `source_for/1`
(`test/support/adr_judge_corpus.ex:46-62`) hands it the registry `label`, the
one-line `focus`, the whole ADR file, and the scoped chunks; the propose prompt
(`lib/mix/statifier/adr_judge.ex:516-540`) says "they are everything you get".
It cannot see the enclosing function, the moduledoc, or the sibling site. So
"is a site-B fixture distinct?" is entirely a question about what the hunk
contains.

**The corpus's coverage unit is `{registry key, tier}`, not a production site.**
`test/mix/statifier/adr_judge_corpus_shape_test.exs:39-49` requires one
`:violation` and one `:clean` row per `{key, tier}` pair. ADR-0012's amendment
(`docs/adr/0012-debuggability-designed-into-the-core.md:83-98`) is stated
generally - its subject is "a trace effect" in every normative sentence, with
`exit_states/2` named only in the trailing worked-example position.

**Site B holds material no fixture in the corpus contains.**
`lib/statifier/interpreter.ex:1781-1784` emits
`Effect.trace(machine_state, Effect.Trace.Done, configuration:
configuration_at_exit, donedata: donedata)` - stamped **post**-sweep while
carrying a **pre**-sweep field, the exact mirror of the `ExitSet` payload eight
lines above it. No existing fixture contains two trace calls at all.

**The spend ledger.** One corpus-equivalent (CE) is one pass over 18 fixtures
(`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:263-264`). Decision 3's
ceiling is **8 CE**. Spent: 4.2 (st-2ts Phase 5) + 1.0 (st-xsb1 Phase 3) =
**5.2 cumulative, 2.8 remaining**. The bead's original note read 5.2 as
headroom; that misreading is already corrected on the bead by a research-stage
note and is not re-recorded here. Raising the ceiling is a human's call
(`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:279-282`).

**Nothing guarded is touched.** Fixture files and `manifest.exs` are outside
`GateGuard`'s `@guarded_paths`; no `docs/quality-gate-changes.md` entry is
mechanically required by any phase here. No phase touches `lib/`.

## Desired End State

1. `test/fixtures/adr_judge/` holds two new ADR-0012 `:subtle` fixtures cut
   against current `lib/statifier/interpreter.ex` (blob `f98c27d`):
   - **violation**: `0012_exit_sweep_stamp_swapped_beside_done.diff` - the
     `ExitSet` stamp is swapped to the post-sweep state while the correctly
     post-sweep `Trace.Done` stamp stands untouched **in the same hunk**;
   - **clean**: `0012_done_trace_stamped_post_sweep.diff` - the `Done` payload's
     legitimately post-sweep stamp is made maximally conspicuous, with the
     `ExitSet` stamp untouched.
2. Both carry manifest rows with `key: "adr-0012-debuggability"`,
   `tier: :subtle`, the right `expect`, and a `:note` stating what the row
   isolates and where it was next measured. The corpus is 22 rows.
3. `docs/testing.md`'s subtle-tier inventory reads fourteen fixtures / seven
   pairs, with one clause naming what the new pair isolates.
4. st-2ts's Decision 3 carries one appended sentence pinning the CE unit at 18
   fixture-runs, so a growing corpus cannot silently re-denominate the ledger.
5. A recorded measurement of the two new rows appears in st-2ts's
   `#### Phase 5 measurement (recorded)` subsection with spend stated in CE
   against the ceiling of 8, cumulative, and mirrored into `docs/testing.md`.
6. Site C (`enter_states/2`) is recorded as a deliberate non-target, with the
   reason, rather than left as an unstated gap.

**Verification of the end state**: `mix quality` green on each phase; `mix test`
still executing zero `adr_judge_corpus` tests; the shape test passing all 22
rows; and, for item 5 only, a human reading the recorded table and confirming
its cells came from real runs.

### Key Discoveries:

- **The hunk geometry is settled, not guessed.** Cut in a scratch copy against
  the real file, testing widths 3, 10, 14 and 16: at `--unified=3` and
  `--unified=10` the violation edit produces **two** hunks and `Trace.Done` is
  not fully visible; at `--unified=14` it produces **one** contiguous hunk
  containing the ADR-0012 comment, the deleted `pre_exit_state` binding, the
  swapped `ExitSet` stamp, and the whole `Trace.Done` call. The clean edit is a
  single hunk at `--unified=14` that shows the untouched `ExitSet` stamp above
  the changed `Done` stamp. `--unified=14` is therefore the width for both
  halves. **14 is confirmed sufficient, not confirmed minimal** - widths 11-13
  were not tried and one of them may also merge the hunks. Nothing rides on
  minimality: the requirement is one hunk carrying both trace calls, and the
  phase's `grep -c '^@@'` criterion decides that mechanically at whatever width
  is used.
- The fixture-authoring convention: hand-written unified diffs cut by applying
  a real edit, `git diff --unified=<n> --src-prefix=a/ --dst-prefix=b/`, then
  reverting. Diffs **need not apply**; they need to parse through
  `AdrJudge.scoped_chunks/2` and land in their own scope
  (`docs/plans/260808-st-6f7-adr-judge-refute-grounding.md:178-184`).
- ADR-0012's scope is `%{prefix: "lib/statifier", suffix: nil}`
  (`lib/mix/statifier/adr_judge.ex:178`), so `lib/statifier/interpreter.ex` is
  in scope and in no other registry entry's scope.
- `--only fixture:<file>` is a first-class spend control
  (`test/mix/statifier/adr_judge_corpus_test.exs:22-31`), which is what makes a
  two-row measurement possible at all.
- Adding a fixture changes no ADR text and no prompt, so **no existing row needs
  re-measuring**. st-xsb1's 1.0 CE was bought because amending the ADR
  invalidated prior ADR-0012 numbers (`docs/testing.md:112-114`); nothing here
  does that.
- No changelog fragment is indicated: `changelog.d/README.md` scopes fragments
  to library users, and nothing here is public API, observable behavior, SCXML
  support, or a user-visible fix.

## What We're NOT Doing

- **Not cutting a transplant of `0012_trace_stamp_swapped_comment_kept.diff`
  to `interpreter.ex`.** At `--unified=3` that fixture's hunk would be nearly
  byte-identical to the existing one modulo the path string and one word of
  comment, and the isolated stamp-swap signal is already measured caught 3/3
  (`docs/testing.md:104-119`). The decision to reject the transplant is the
  substance of the either/or; see **Decision 1** below.
- **Not cutting a fixture at site C (`enter_states/2`).** See **Decision 3**.
  Site C is recorded as a deliberate non-target in the new violation row's
  manifest note, not merely omitted.
- **Not re-cutting the four existing ADR-0012 `exit_entry` fixtures.** Two carry
  a two-revision-stale index base, verified benign by st-xsb1
  (`docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md:755-767`);
  rewriting them would invalidate measurements already on the record. The bead's
  note forbids it.
- **Not re-measuring any existing row.** No ADR text, `focus` string, or prompt
  changes, so every recorded per-fixture verdict still stands.
- **Not amending ADR-0012.** The amendment already states the rule generally and
  st-xsb1 verified it decides both halves of the site-A pair without reference
  to an inline comment. If the new clean half draws a false positive, that is a
  **finding to record**, not a licence to re-word the ADR and re-measure - see
  Phase 2 change 4.
- **Not touching any file under `lib/`.** Neither the three production sites nor
  the judge. The Appendix D rule (`.claude/wurk/plan.md`, ADR-0002) is therefore
  not engaged by any phase: no interpreter function is edited, so there is no
  deviation to justify.
- **Not adding a third tier.** The pair joins `:subtle`, by the corpus's own
  definition (`test/support/adr_judge_corpus.ex:33-34`) and because the shape
  test admits only two.
- **Not adding any paid run to `mix quality`, to CI, or to any phase's Automated
  Verification.** This restates st-2ts's guardrail (`:176-177`) and binds this
  plan identically.
- **Not editing `.quality.exs`** or any other guarded path, so no
  `docs/quality-gate-changes.md` entry is required.
- **Not writing a changelog fragment.**
- **Not adding hand-written ExUnit tests.** The corpus tests are generated from
  the manifest (`test/mix/statifier/adr_judge_corpus_test.exs:29-59`), so two
  rows produce two generated tests with no test-file edit; both generated forms
  already carry `# sabotage: n/a` with a stated reason. The repo's sabotage rule
  has no new `lib/`-asserting test to attach to, which is recorded here rather
  than omitted.
- **Not re-denominating the corpus-equivalent unit.** See **Decision 4**.

## Implementation Approach

Two phases, ordered so the unpaid work is complete and committable before any
money is spent, and so a maintainer can decline Phase 2 without invalidating
Phase 1.

1. **Phase 1 - the corpus addition and the ledger prose.** Two `.diff` files,
   two manifest rows, the `docs/testing.md` count and clause, the Decision 3
   unit-pinning sentence, and the site-C non-target record. No paid run. Its
   gate is the free shape test inside a full `mix quality`. It is correct and
   complete whether or not the judge ever catches the violation half, because
   the manifest note carries the measured status honestly.
2. **Phase 2 - the recorded measurement.** Real spend, human-gated, **manual
   success criteria only**. No agent executes it unattended.

The pivotal honesty constraint, inherited from st-xsb1: Phase 1 must not pretend
the new rows pass. Each lands with its `expect` and a note stating plainly that
it is **unmeasured** as of Phase 1, that no gate path runs it, and that Phase 2
is where its status is first measured.

## Phase 1: The `Trace.Done` discrimination pair and its manifest rows

### Overview

Author two `.diff` fixtures against current `lib/statifier/interpreter.ex`,
register them, and update the three pieces of prose the addition moves. No
`lib/` change, no ADR change, no paid run.

### Changes Required:

#### 1. The violation half

**File**: `test/fixtures/adr_judge/0012_exit_sweep_stamp_swapped_beside_done.diff`
**Changes**: Cut by the established method against
`lib/statifier/interpreter.ex` (base blob `f98c27d`) with **`--unified=14`**.

The edit, in `exit_interpreter/1`: delete **only** the
`pre_exit_state = machine_state` binding at `:1750` (and its trailing blank
line), and swap the `ExitSet` trace's first argument from `pre_exit_state` to
`machine_state`. Leave the six-line ADR-0012 comment at `:1744-1749` exactly as
it is, including its now-dangling reference to `pre_exit_state`. Leave the
`Trace.Done` call at `:1781-1784` completely untouched.

```
     # ADR-0012: the counters this payload stamps must be the ones that stood
     # at the exit-set phase boundary, so the trace is stamped against
     # `pre_exit_state`; only `configuration` is read from the post-sweep
     ...
-    pre_exit_state = machine_state
-
     {machine_state, donedata, exit_effects} =
     ...
     exit_set_trace =
-      Effect.trace(pre_exit_state, Effect.Trace.ExitSet,
+      Effect.trace(machine_state, Effect.Trace.ExitSet,
         indexes: states_to_exit,
         configuration: machine_state.configuration
       )

     done_trace =
       Effect.trace(machine_state, Effect.Trace.Done,
         configuration: configuration_at_exit,
         donedata: donedata
       )
```

The width is load-bearing and was verified empirically: at `--unified=14` this
is **one** hunk carrying both trace calls, so the judge is asked to indict the
`ExitSet` stamp and acquit the `Done` stamp from the same bytes. At
`--unified=3` or `10` it splits into two hunks and `Trace.Done` is not fully
visible - at which point the fixture degenerates into the transplant this plan
rejects. Do not narrow it.

This is `:subtle` by the corpus's definition: the shape of the change is
preserved and only its meaning breaks.

#### 2. The clean half

**File**: `test/fixtures/adr_judge/0012_done_trace_stamped_post_sweep.diff`
**Changes**: Cut the same way, `--unified=14`, single hunk.

A meaning-preserving edit that makes the `Done` payload's **legitimately**
post-sweep stamp as conspicuous as possible, so a judge that has internalized
"stamp pre-mutation" as unconditional fires on it and scores a false positive.
Bind `post_sweep_state = machine_state` immediately before `done_trace` and
stamp from it. The `ExitSet` stamp and `pre_exit_state` are untouched and, at
this width, visible directly above.

```
     exit_set_trace =
       Effect.trace(pre_exit_state, Effect.Trace.ExitSet,
         indexes: states_to_exit,
         configuration: machine_state.configuration
       )

+    post_sweep_state = machine_state
+
     done_trace =
-      Effect.trace(machine_state, Effect.Trace.Done,
+      Effect.trace(post_sweep_state, Effect.Trace.Done,
         configuration: configuration_at_exit,
         donedata: donedata
       )
```

This is distinct from `0012_configuration_read_post_departure.diff`, which
tests the post-mutation **field** half of the amendment. This one tests the
post-mutation **stamp** - a case the amendment permits ("the step counters it
carries are the ones that stood at that boundary"; the run has ended, so the
counters at the end *are* the boundary's) and that no existing row probes.

An optional strengthening, permitted but not required: also reword the ADR-0012
comment to name `post_sweep_state`. Prefer the minimal form above; a comment
edit adds a second signal and muddies what the row measures.

#### 3. Manifest rows

**File**: `test/fixtures/adr_judge/manifest.exs`
**Changes**: Two rows appended next to the existing ADR-0012 subtle rows, in the
five-key schema, using the `<>` string-concatenation style the neighbouring rows
use.

```elixir
%{
  key: "adr-0012-debuggability",
  file: "0012_exit_sweep_stamp_swapped_beside_done.diff",
  expect: :violation,
  tier: :subtle,
  note:
    "the exit sweep's `Trace.ExitSet` counters are stamped from the post-sweep " <>
      "state - the `pre_exit_state` binding is deleted and the six-line ADR-0012 " <>
      "comment naming the rule is left standing. The hunk is cut wide " <>
      "(--unified=14) so the `Trace.Done` call eight lines below is visible in " <>
      "the same chunk, stamped post-sweep and correctly so: the row asks the " <>
      "judge to indict one trace call and acquit the other from the same bytes, " <>
      "which no other fixture does. This is the second `Trace.ExitSet` stamp " <>
      "site; `enter_states/2` is a third and is deliberately unfixtured, because " <>
      "the corpus is indexed by rule and tier rather than by production site and " <>
      "this row earns its place on the two-trace discrimination, not on the path " <>
      "string. UNMEASURED as of st-6f7h Phase 1; no gate path runs this row - " <>
      "first measured in " <>
      "docs/plans/260819-st-6f7h-interpreter-exitset-trace-coverage.md Phase 2"
},
%{
  key: "adr-0012-debuggability",
  file: "0012_done_trace_stamped_post_sweep.diff",
  expect: :clean,
  tier: :subtle,
  note:
    "the `Trace.Done` payload is stamped from an explicitly named post-sweep " <>
      "binding, which is correct: the boundary this trace names is the end of " <>
      "the run, so the counters that stood at it are the post-sweep ones. The " <>
      "`Trace.ExitSet` stamp above it is untouched and visible in the same hunk. " <>
      "The adversarial partner to the row above, and the corpus's only probe of " <>
      "a legitimately post-mutation STAMP - " <>
      "0012_configuration_read_post_departure.diff probes a legitimately " <>
      "post-mutation FIELD. A judge that learned 'stamp pre-mutation' as an " <>
      "unconditional rule scores a false positive here. UNMEASURED as of " <>
      "st-6f7h Phase 1; first measured in " <>
      "docs/plans/260819-st-6f7h-interpreter-exitset-trace-coverage.md Phase 2"
},
```

#### 4. Fixture inventory prose

**File**: `docs/testing.md`
**Changes**: One count sentence, at `docs/testing.md:94`: "A `:subtle` tier
(twelve fixtures, six per-registry-entry pairs)" becomes **fourteen fixtures,
seven pairs**. Append one clause naming what the new pair isolates - that the
ADR-0012 subtle tier now separates a wrongly post-mutation stamp from a
**rightly** post-mutation stamp, in a hunk carrying both trace calls.

Leave every recorded score cell alone. Phase 2, not this phase, adds the new
labeled row. There is no combined corpus total stated anywhere in the file, so
do not go hunting for an "eighteen" or a "twenty" to change.

#### 5. Pinning the corpus-equivalent unit

**File**: `docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md`
**Changes**: One sentence appended to Decision 3, immediately after "one
corpus-equivalent is one pass over all 18 fixtures", to the effect that the unit
is **pinned at 18 fixture-runs as a unit of account and does not float with the
corpus's size** - re-anchoring it would silently re-denominate every figure
already recorded against the ceiling. Note in the same sentence that the corpus
is 20 rows at st-xsb1 and 22 after st-6f7h, and that st-xsb1's 1.0 CE was
computed on the pinned unit.

Appending a clarifying note into st-2ts's document is precedented: st-xsb1 wrote
its scorecard into that file's Phase 5 subsection. Do not edit Decision 3's
existing allocation table.

#### 6. Site C, recorded as a non-target

No new file. The record lives in two places already listed: this plan's
**Decision 3** below, and the sentence in change 3's violation-row note naming
`enter_states/2` as deliberately unfixtured with the reason. That is deliberate
- a note inside the corpus outlives a plan document, and the plan carries the
argument.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] `mix gate.verify` confirms the run was a full, unscoped gate
- [x] `mix test test/mix/statifier/adr_judge_corpus_shape_test.exs` passes, now
      all 22 rows - specifically the file-exists, real-key, known-tier,
      both-verdicts-per-`{key, tier}`, own-scope-only, and no-`@tag :skip`
      checks
- [x] `mix test` reports zero `adr_judge_corpus` tests executed, so the addition
      put nothing paid on the ordinary suite
- [x] Each new fixture is a single contiguous hunk containing both trace calls:
      for each file,
      `grep -c '^@@' <file>` is `1`, and `grep -c 'Effect.Trace.ExitSet' <file>`
      and `grep -c 'Effect.Trace.Done' <file>` are each at least `1`
- [x] Both new fixtures apply cleanly at HEAD:
      `git apply --check test/fixtures/adr_judge/0012_exit_sweep_stamp_swapped_beside_done.diff`
      and the same for `0012_done_trace_stamped_post_sweep.diff` exit 0
- [x] `git diff --stat` shows no path under `lib/`
- [x] `git diff --stat` shows no guarded path (`.quality.exs`, `.credo.exs`,
      `coveralls.json`, `.sobelow-conf`, `.doctor.exs`, `mix.exs`,
      `test/passing_tests.json`), so `mix gate.check` needs no ledger entry
- [x] Use `mix quality --profile loop` between edits while iterating

#### Manual Verification:
- [ ] The violation half's hunk, read as the judge would read it with no other
      context, contains everything needed to indict the `ExitSet` stamp and
      acquit the `Done` stamp - and a reader who knows only ADR-0012's text
      reaches that verdict
- [ ] The clean half is genuinely meaning-preserving: `post_sweep_state` is a
      pure alias for the post-reduce `machine_state`, so the emitted `Done`
      payload is byte-identical
- [ ] The clean half varies something no existing clean row varies, and a reader
      can say in one sentence what (a post-mutation **stamp**, where
      `0012_configuration_read_post_departure.diff` varies a post-mutation
      **field**)
- [ ] Neither fixture touches site A or site C, so each presents exactly one
      site and the row is scored on one signal
- [ ] No existing row's prose or `.diff` bytes changed: the branch's diff of
      `manifest.exs` and `test/fixtures/adr_judge/` is a pure insertion
- [ ] The `docs/testing.md` clause and the Decision 3 sentence read as
      annotations, not as edits to recorded measurements

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run full `mix quality` as the phase gate. In interactive execution,
pause here for the human to confirm the manual items before Phase 2. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically and the Manual items are deferred to the end. **A `--loop` pass
stops at the end of Phase 1** - see Phase 2.

---

## Phase 2: Recorded measurement (HUMAN-GATED - real spend)

### Overview

Measure the two new rows, record the result in st-2ts's scorecard, and mirror
the summary into `docs/testing.md`.

> **This phase MUST NOT be executed unattended.** Every run below makes real
> `claude` CLI calls and costs real money. No agent may start it, and no agent
> may continue it past the budget stated below. All of its success criteria are
> **manual**; it has no Automated Verification list by design, so no `--loop`
> pass and no gate can advance through it.

### Changes Required:

#### 1. The runs (a human's, by hand)

**Budget: 6 fixture-runs = 0.33 corpus-equivalents.** Against Decision 3's
ceiling of 8, with 5.2 already spent, this puts cumulative spend at **5.53 of
8**, leaving 2.47. The scope is the **two new rows only**, three seeds,
`claude-sonnet-5` only:

```
STATIFIER_ADR_JUDGE_MODEL=claude-sonnet-5 \
  mix test --only fixture:<name> --seed <101|202|303> --trace
```

once per fixture per seed, for:

| Fixture | Expect |
|---|---|
| `0012_exit_sweep_stamp_swapped_beside_done.diff` | violation (new) |
| `0012_done_trace_stamped_post_sweep.diff` | clean (new) |

Do **not** use `--only tier:subtle` (14 fixtures x 3 seeds = 2.33 CE), do
**not** use `--include adr_judge_corpus` (the whole corpus), and do **not** add
a second model (a `haiku` column doubles this phase to 0.67 CE).

The four existing ADR-0012 subtle rows are **not** re-measured: no ADR text and
no prompt changed, so st-xsb1's 2026-08-18 figures still stand for them and
re-buying them would be 1.0 CE for a number already on the record.

Record per run: per-fixture verdict, per-fixture wall time, model id, seed.
Compute the majority of three per fixture; count any non-unanimous fixture as a
flap and never fold the flap count into the score, per st-2ts Decision 2.

**The stop rule, restated and binding here:** if the budget above is reached
before the measurement is complete, **stop and report the partial scorecard.**
Do not run the remaining fixtures, do not add a model, do not raise the ceiling.
Raising it is a human's call and st-2ts says so at `:279-282`.

#### 2. The scorecard entry

**File**: `docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md`
**Changes**: A dated sub-entry appended inside the existing
`#### Phase 5 measurement (recorded)` subsection, in that subsection's two
shapes: a per-fixture verdict matrix (one row per fixture, a
`sonnet 101/202/303` column, cells `ok` / `FN` / `FP`) and a summary row.
Labeled a **first measurement of two new rows**, not a re-measurement, so no
reader mistakes it for a replacement of anything above it. Spend stated in
corpus-equivalents against the ceiling of 8, cumulative with st-2ts's 4.2 and
st-xsb1's 1.0.

#### 3. The mirror

**File**: `docs/testing.md`
**Changes**: The recorded-scores table gains a labeled row for the two new rows
on one model, with a sentence saying it supersedes nothing and that the earlier
rows were measured over wider tiers.

#### 4. If either row misses

**Files**: `test/fixtures/adr_judge/manifest.exs`, and this plan's findings
section
**Changes**: **Record it and stop.** Update the row's `:note` with the date and
the seeds, write the finding into the findings section below, and report to a
human. Do **not** re-word the fixture and re-measure, and do **not** amend
ADR-0012; either is a second measurement pass at another 0.33 CE minimum and
neither is budgeted here.

The clean half is the row most likely to miss, and a false positive there is the
**most informative single outcome this plan can buy**: it would mean the judge
has internalized "stamp pre-mutation" unconditionally, which is precisely the
over-generalization the amendment's second paragraph exists to bound and which
every prior measurement's 0/3 false-positive column was too easy to detect. A
false positive here is a finding worth having, not a fixture defect.

### Success Criteria:

#### Automated Verification:

None. This phase has no automated criteria **by design** - every criterion below
requires a human, and giving it an automated one would let a `--loop` pass
advance through a phase that spends money.

The one command that may be run to confirm this phase changed nothing it should
not: `mix quality` still passes and `git diff --stat` shows only
`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md`, `docs/testing.md`, and
this plan - **plus `test/fixtures/adr_judge/manifest.exs` if and only if change
4's branch was taken.** That fourth path is an expected outcome, not a symptom.

#### Manual Verification:
- [x] A human, not an agent, decided to start this phase and authorized the
      spend. If an agent runs the six commands under that authorization, the
      deviation is written into the scorecard entry rather than ticked away -
      st-xsb1 recorded exactly this deviation and the precedent is to state it.
      **Deviation, recorded rather than ticked away**: the human explicitly
      said to go ahead and run the six commands; an agent ran them
- [ ] Every recorded cell traces to one
      `mix test --only fixture:<name> --seed <n>` invocation whose raw ExUnit
      output was read directly; no cell inferred from another. **Not fully
      satisfied**: the violation row's seed-101 cell has a sound verdict (a
      miss, exit status 2) but no captured assertion text - the agent's first
      invocation was run without redirecting output and the terminal output
      was truncated before it could be read. That cell is recorded as an
      uncaptured miss, not inferred from seeds 202/303, per the plan's own
      instruction not to infer a cell from another cell
- [x] The spend is recorded in corpus-equivalents against Decision 3's ceiling
      of 8, cumulative - 0.33 spent, cumulative 5.53 of 8
- [x] The budget was not exceeded: 6 of 6 runs, no fixture re-run, no second
      model, no tier-wide selector
- [x] The entry is unambiguously labeled a first measurement of two new rows,
      and every existing table is left standing
- [x] `docs/testing.md`'s mirrored row carries the same label
- [x] If either row misses, the finding is written down and **no further paid
      run was made**

**Implementation Note**: There is no `--loop` execution of this phase. An agent
reaching it stops, reports that Phase 1 is complete, and states plainly that
Phase 2 is a human's to run.

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
compile time (`test/mix/statifier/adr_judge_corpus_test.exs:29-59`), so Phase
1's two rows produce two new generated tests with no test-file edit, each
inheriting the existing `# sabotage: n/a` line and its stated reason. The repo's
sabotage rule therefore has no new `lib/`-asserting assertion to attach to; this
is recorded rather than omitted, per `docs/testing.md`.

The real coverage of Phase 1 is the free shape test, which already asserts the
six invariants a new row must satisfy. Its own sabotage lines are unchanged.

Edge cases the shape test decides for us, and that Phase 1 must not trip:

- A `.diff` whose paths fall outside `lib/statifier/` produces no scoped chunks
  and fails the own-scope check. `lib/statifier/interpreter.ex` is inside it.
- A `.diff` that also touched `.claude/wurk/` would fail the differing-scope
  check. Neither fixture goes near it.
- A tier other than `:blatant`/`:subtle` fails outright.
- A fixture containing the literal `@tag :skip` fails. Neither does.

### Manual Testing Steps:

1. After Phase 1: read both new diffs against `lib/statifier/interpreter.ex` at
   HEAD, confirm each `git apply --check`s clean, and confirm each is one hunk
   showing both trace calls.
2. After Phase 1: read the violation half as the judge sees it - ADR-0012's text
   plus that one hunk, nothing else - and answer whether the amendment alone
   decides it. Then do the same for the clean half. This is the cheapest
   available predictor of Phase 2's result.
3. After Phase 1: run `mix quality --profile merge` and confirm the `ADR judge`
   stage reports the `:no_scoped_changes` skip, since no phase touches
   `lib/statifier/`.
4. Phase 2 is manual in its entirety; its steps are the runs listed there.

## Decisions Taken Without a Human

No human was available while this plan was written. Each decision below is taken
provisionally so the plan is executable, with the grounds, the assumption, and
the redirect cost stated. Every one is a maintainer's to overturn.

**Decision 1: the bead's either/or resolves to (a), a fixture pair - but a
`Trace.Done` pair, not a transplant.**
*Grounds*: the research set out both bodies of evidence and the case against a
*transplant* is strong - the judge sees only hunk bytes, the corpus is indexed by
`{key, tier}` rather than by site, the isolated stamp-swap signal is already
measured caught 3/3, and the swap is value-inert at all three sites - but every
one of those arguments is an argument against a **narrow-context transplant**,
not against a fixture at site B as such. The redesigned pair is distinct under
both readings of what the corpus is for: under "the corpus measures whether the
judge understands the rule", the two-trace discrimination and the untested
post-mutation-**stamp** axis are both new understanding to measure; under "the
corpus measures whether a regression would be caught at each binding site", it
covers site B by construction. A design that is right under both readings does
not need the reading to be settled first, which is what makes this decidable
without the maintainer.
*Assumption*: that the acceptance criterion's "anchored on the exit-sweep
ExitSet trace" is satisfied by a fixture whose violation is the exit-sweep
ExitSet stamp swap, even though its distinguishing content is the neighbouring
`Trace.Done` call. It is: the violation half is exactly that swap.
*Redirect cost*: if a maintainer prefers branch (b), Phase 1 is dropped and this
section becomes the recorded decision - the argument is already written. If a
maintainer prefers the literal transplant, only change 1's `--unified` width and
the manifest notes change; Phase 2's budget is unaffected.

**Decision 2: the pair joins `:subtle`.**
*Grounds*: the corpus's own definition - shape preserved, meaning broken - and
the shape test admits only two tiers. *Consequence, stated rather than hidden*:
`:subtle` is the measured tier, which is what makes Phase 2 cost anything at
all.

**Decision 3: site C (`enter_states/2`) gets no fixture, and no follow-up bead.**
*Grounds*: this plan's pair is justified by the two-trace discrimination signal,
not by a per-site coverage standard. Site C has no adversarial partner in its
function - it emits one trace call - so a site-C fixture could only ever be the
transplant Decision 1 rejects, at a third of a CE for a path string. Filing a
follow-up bead would imply the per-site standard this plan declines to adopt,
and would leave a permanently-open bead arguing for work nobody intends to do.
*Assumption*: that the bead's "worth checking in the same pass" is discharged by
checking it, confirming the pattern, and recording why it is not fixtured -
which the research did and the manifest note now carries.
*Redirect cost*: if a maintainer does adopt a per-site standard, a site-C pair
is a transplant of site A's fixtures to `enter_states/2` at 0.33 CE for
measurement, and the ceiling has room for it. Nothing in Phase 1 or 2 has to
change first.
*Recorded as a finding either way*: site C is governed by the amendment, carries
an identically worded comment, and is exercised by nothing. That is true whether
or not it is fixtured, and it is now written into the corpus rather than into a
plan only.
*Reviewed 2026-08-19 (st-6f7h Direction stage, escalated from `/wurk:verify`)*:
**upheld, with amended grounds.** The verify pass falsified this decision's
"transplant buys only a path string" premise - the site-B violation row's
changed lines are byte-identical to
`0012_trace_stamp_swapped_comment_kept.diff`, caught 3/3 at site A and missed
3/3 at site B, so a re-situated transplant did surface a real blind spot. The
conclusion survives on the grounds that remain: the miss is not attributable to
the production site (width, the second trace call, and the site stay
unseparated, and the site is the hypothesis with the least mechanical support
in what the judge is shown); site C emits one trace call and cannot reproduce
the composition that did the finding, so a site-C pair tests only that
least-supported hypothesis at 0.33 CE where a 0.17 CE narrow re-cut of site
B's own edit at `--unified=3` separates site from context directly; and
per-site coverage is not the corpus's unit and does not terminate. No
follow-up bead; the named trigger for filing one is that re-cut being bought
by a human and missing. Full reasoning:
`docs/research/260819-st-6f7h-decision-3-site-c-review.md`.

**Decision 4: the corpus-equivalent unit stays pinned at 18 fixture-runs.**
*Grounds*: a unit of account that floats with the thing it measures makes every
recorded figure incomparable. st-xsb1 computed its 1.0 CE on the pinned unit
while the corpus stood at 18-then-20, and st-2ts's forward projections (6.2,
8.2) only parse on the pinned reading. Re-anchoring to 22 would silently
re-denominate 5.2 to about 4.3 and manufacture headroom nobody voted for.
*Assumption*: that Decision 3's "one pass over all 18 fixtures" was a
denomination, not a description that was expected to track the corpus.
*Redirect cost*: one sentence in Phase 1 change 5, reversible with one revert.

**Decision 5: the diff context width is `--unified=14`.**
*Grounds*: verified empirically in a scratch copy against the real file -
`--unified=3` and `--unified=10` both split the violation edit into two hunks
with `Trace.Done` only partly visible, and 14 is the smallest **tested** width
producing one contiguous hunk carrying the comment, the deleted binding, the
swapped stamp, and the whole `Trace.Done` call. Widths 11-13 were not tried, so
14 is sufficient rather than proven minimal; the phase's one-hunk grep criterion
is what actually holds the requirement. Nothing in the harness validates
hunk width and fixtures need not apply, so a wider context is a permitted
authoring choice; it is simply one no existing fixture has needed.
*Assumption*: that a wider hunk does not itself change the judge's behavior in
a way that confounds the measurement. This is untested at this repository and is
the one methodological soft spot in the plan - it is listed under Deferred
Manual Verification, and the honest reading of a surprising Phase 2 result is
that width is a candidate explanation alongside content.
*Redirect cost*: re-cutting both fixtures at another width, and, if Phase 2 has
already run, a re-measurement at 0.33 CE.

**Decision 6: no ADR-0012 amendment, and no re-measurement of existing rows.**
*Grounds*: the amendment already states the rule generally and st-xsb1 verified
it decides site A's pair without leaning on an inline comment; adding a fixture
changes no text the judge reads, so no recorded verdict is invalidated.
*Assumption*: that a rule already stated generally does not need re-stating to
reach a second site. If Phase 2 shows otherwise, that is the finding, recorded
under Phase 2 change 4 rather than acted on.

### Findings recorded but not acted on

- **The bead's acceptance criterion cannot be fully satisfied by an unattended
  agent.** "If fixtures land, they are measured" requires Phase 2, which is
  human-gated real spend. An agent completing Phase 1 has done everything it may
  do; the bead is not closable on Phase 1 alone, and closing it would also
  require the branch to be merged.
- **The clean half's expected verdict is genuinely uncertain**, more so than any
  row st-xsb1 landed. That is the point of it, and Phase 2 change 4 is written
  so a miss is recorded rather than engineered away.
- **The blatant ADR-0012 rows remain the standing residual** from st-xsb1's
  amendment, unmeasured since. This plan does not close that and does not widen
  the risk, since it changes no ADR text.
- **st-2ts's `@default_model` recommendation still stands unacted.** Phase 2
  measures on sonnet partly because of that. If a maintainer moves the default,
  Phase 2's model should move with it.

### Phase 2 finding: the measurement inverted the plan's own prediction

**Measured 2026-08-19**, `claude-sonnet-5`, seeds 101/202/303, per Phase 2's
budget of six fixture-runs (0.33 CE; cumulative 5.53 of 8). Full matrix,
provenance, and interpretation are recorded in
`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md`'s Phase 5 subsection
("First measurement of two new rows, 2026-08-19 (st-6f7h)"), mirrored in
`docs/testing.md`. Summarized here because this plan's own text made a
prediction the result contradicts.

**Result.**

| Fixture | Expect | sonnet 101/202/303 | Majority |
|---|---|---|---|
| `0012_exit_sweep_stamp_swapped_beside_done.diff` | violation | uncaptured (miss, exit 2), FN, FN | **MISS, unanimous** |
| `0012_done_trace_stamped_post_sweep.diff` | clean | ok, ok, ok | **ok, unanimous** |

**Two deviations, written down rather than ticked away:**

1. **An agent, not a human, ran the six commands.** The human authorized the
   spend explicitly ("go ahead and run the six commands"); the agent executed
   them. This is the same deviation shape st-xsb1 recorded, and is recorded
   here per this plan's own manual criterion rather than silently ticked.
2. **One cell has no captured assertion text.** The violation row's seed-101
   run exited 2 (an ExUnit failure - a sound miss verdict), but the agent's
   first invocation was run without redirecting output and the terminal
   output was truncated before the assertion text could be read. Per this
   plan's instruction not to infer a cell from another, that cell is recorded
   plainly as an **uncaptured miss** - not inferred as FALSE NEGATIVE or
   WRONG-ADR from the other two seeds. The row's majority verdict does not
   depend on this cell: seeds 202 and 303 alone already form a majority of
   false negatives.

**The finding, read plainly.** This plan predicted the clean row was the
likelier miss - that a judge which had internalized "stamp pre-mutation" as
an unconditional rule would fire a false positive on the conspicuously
post-sweep `Trace.Done` stamp. The measurement went the other way: the clean
row was acquitted unanimously, and the violation row - the swapped
`Trace.ExitSet` stamp sitting beside the untouched, correctly post-sweep
`Trace.Done` call in the same hunk - was missed unanimously. On this wide
two-trace hunk, the judge did not indict the swapped stamp at all.

**Diagnostic: a failure to propose, not a refute-pass over-rejection.** The
violation row's runs took roughly 6.0s of sync time; the clean row's took
13-32s. The judge's propose step returned no candidate at all on the
violation row - no candidate means no refute call, hence the short runtime.
On the clean row the judge proposed candidates and then refuted them away.
So this miss is not the judge seeing a real violation and being talked out of
it by refute; it never proposed one.

**What the measurement cannot separate.** `0012_trace_stamp_swapped_comment_kept.diff`,
the comment-kept `Trace.ExitSet` stamp swap at site A (`exit_states/2`), was
previously measured caught unanimously (st-xsb1). The new violation row
differs from it in at least three ways simultaneously: the wider
`--unified=14` context (no prior fixture used more than 3), the presence of a
second, legitimately post-sweep trace call in the same hunk, and the
different production site. Any one of the three could explain the miss where
the other row was caught. The budget spent here (six fixture-runs) cannot
isolate which explanation is correct, and separating them - by re-wording a
fixture and re-measuring - is explicitly out of budget for this phase and is
a human's call, not this plan's to make. This is an open question, recorded
rather than resolved.

## Deferred Manual Verification

Everything below needs a human. None of it may be added to `mix quality`, to CI,
or to any phase's Automated Verification list, and no phase's advancement may be
gated on it.

**An automated pass must stop at the end of Phase 1.** Phase 2 carries no
automated criteria, so a tool that reads "all automated criteria satisfied" as
"phase complete" will read Phase 2 as complete on arrival. It is not.

### Paid corpus runs (Phase 2)

- [x] Three `claude-sonnet-5` runs at seeds 101/202/303 over each of the two new
      fixtures, via `--only fixture:<name>` - 6 fixture-runs = 0.33 CE,
      cumulative 5.53 of 8
- [~] Per-fixture verdicts and wall times recorded per run. **Partially
      satisfied**: one cell (violation, seed 101) has a sound verdict but no
      captured assertion text or wall time - the terminal output was truncated
      before it could be read. Recorded as an uncaptured miss rather than
      inferred; see the Phase 2 finding above
- [x] Majority-of-three computed per fixture and the flap column filled in, per
      st-2ts Decision 2
- [x] The matrix and summary row added to st-2ts's
      `#### Phase 5 measurement (recorded)` subsection, labeled a first
      measurement of two new rows
- [x] The summary mirrored into `docs/testing.md` with the same label
- [x] Spend recorded in corpus-equivalents against the ceiling of 8, cumulative

### Judgment items a command cannot settle

- [x] **Whether `--unified=14` itself confounds the measurement.** No existing
      fixture uses a width above 3, so a surprising Phase 2 verdict has two
      candidate explanations - the fixture's content and its unusual width - and
      this plan cannot separate them within its budget. If the pair behaves
      unexpectedly, record width as a live hypothesis rather than concluding
      about content. **Fired**: Phase 2's violation row missed unanimously,
      the inverse of the plan's prediction. Width remains one of at least
      three live, unseparated hypotheses alongside hunk content (the second
      trace call) and production site (site B vs. the previously-caught site
      A fixture) - see the Phase 2 finding above. Separating them is a
      re-measurement pass, out of this phase's budget, and remains a human's
      call. **Narrowed 2026-08-19 (`/wurk:verify`), at no spend**: this row's
      changed lines are byte-identical to
      `0012_trace_stamp_swapped_comment_kept.diff`, which is caught 3/3. The
      edit is therefore exonerated as the cause, leaving exactly three live
      hypotheses - hunk width (60 lines vs 22), the second trace call in the
      hunk, and the production site. A maintainer chose on 2026-08-19 to record
      this narrowing and spend nothing further, so width vs. the other two
      remains unseparated by choice, not by budget exhaustion (2.47 CE remain)
- [x] **Whether the violation half reads as one violation or two.** A judge may
      propose a finding against the `Trace.Done` stamp as well. Under the
      harness a violation row passes on any surviving finding, so this would not
      show as a failure - but a finding aimed at the wrong call is a false
      positive hiding inside a true positive, and only reading the proposed
      findings' text catches it. Read them; do not read only the verdicts.
      **Settled 2026-08-19 (`/wurk:verify`)**: moot for this measurement. The
      propose step returned **no candidate at all** on every seed, so there was
      no finding of either kind - nothing could hide inside a true positive
      because there was no true positive. The question stays live for any
      future run in which this row is caught.
- [x] **Whether Decision 3 (no site-C fixture) survives maintainer review.** It
      is the decision most likely to be overturned, and the redirect is cheap
      and additive. **Reviewed 2026-08-19 (Direction stage, no human
      available): upheld with amended grounds** - conclusion stands (no site-C
      fixture, no follow-up bead), the falsified "transplant is uninformative"
      premise is retired, and the named reopening trigger is a 0.17 CE
      `--unified=3` re-cut of site B's own edit missing at three seeds. See
      `docs/research/260819-st-6f7h-decision-3-site-c-review.md`; still a
      maintainer's to overturn, like every provisional decision above

### Explicitly not budgeted

- A `haiku` column for either new row (doubles the phase to 0.67 CE).
- Re-measuring the four existing ADR-0012 subtle rows (1.0 CE for numbers
  already on the record).
- A full fourteen-fixture subtle-tier measurement (2.33 CE on one model).
- A site-C pair (0.33 CE plus authoring).

Any of these is a ceiling decision, and Decision 3 of st-2ts says a ceiling
decision is a human's call.


### Phase 1

- [x] The violation half's hunk, read as the judge would read it with no other
      context, contains everything needed to indict the `ExitSet` stamp and
      acquit the `Done` stamp - and a reader who knows only ADR-0012's text
      reaches that verdict
- [x] The clean half is genuinely meaning-preserving: `post_sweep_state` is a
      pure alias for the post-reduce `machine_state`, so the emitted `Done`
      payload is byte-identical
- [x] The clean half varies something no existing clean row varies, and a reader
      can say in one sentence what (a post-mutation **stamp**, where
      `0012_configuration_read_post_departure.diff` varies a post-mutation
      **field**)
- [x] Neither fixture touches site A or site C, so each presents exactly one
      site and the row is scored on one signal
- [x] No existing row's prose or `.diff` bytes changed: the branch's diff of
      `manifest.exs` and `test/fixtures/adr_judge/` is a pure insertion
- [x] The `docs/testing.md` clause and the Decision 3 sentence read as
      annotations, not as edits to recorded measurements

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run full `mix quality` as the phase gate. In interactive execution,
pause here for the human to confirm the manual items before Phase 2. In looped
(`--loop`) execution, this phase's Automated Verification gates advancement
automatically and the Manual items are deferred to the end. **A `--loop` pass
stops at the end of Phase 1** - see Phase 2.

---
## References

- Source document:
  `docs/research/260819-st-6f7h-interpreter-exitset-trace-coverage.md`
- Related ADRs: `docs/adr/0012-debuggability-designed-into-the-core.md` (the
  judged record and its st-xsb1 amendment at `:83-98` - not amended by this
  plan), `docs/adr/0011-*` (guarded gate config - no phase touches a guarded
  path), `docs/adr/0002-*` (Appendix D literalness - no phase touches the
  interpreter)
- Prior plans: `docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md`
  (the shape this plan follows, the site-A pair, the stale-base finding),
  `docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md` (Decisions 1-3, the
  Phase 5 scorecard, the spend ceiling),
  `docs/plans/260808-st-6f7-adr-judge-refute-grounding.md` (the hand-written
  diff convention),
  `docs/plans/260818-st-ntf5-microstep-configuration-on-trace-effects.md`
- Anchor site: `lib/statifier/interpreter.ex:1741-1799` -
  `pre_exit_state` at `:1750`, the `ExitSet` stamp at `:1775-1779`, the
  `Trace.Done` stamp at `:1781-1784`
- Sibling sites, deliberately untouched:
  `lib/statifier/interpreter/exit_entry.ex:134-167` (site A) and `:706-733`
  (site C)
- Harness: `test/support/adr_judge_corpus.ex:28-62`,
  `test/mix/statifier/adr_judge_corpus_shape_test.exs:13-82`,
  `lib/mix/statifier/adr_judge.ex:173-211`
- Beads issue: `st-6f7h`
