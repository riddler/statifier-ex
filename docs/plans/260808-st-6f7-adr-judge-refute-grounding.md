# ADR Judge Refute Grounding Implementation Plan

## Overview

The ADR judge's refute pass overturns correct findings by crediting
exculpatory mechanisms it has no way to check. This plan first builds the
thing that can tell whether any fix works - a fixture corpus of known-violating
and known-clean diffs per registry entry, run against the real `claude` CLI and
scored on false negatives *and* false positives, gated behind a tag excluded by
default. It then reworks `refute_prompt/1` so a refuting argument has to be
grounded in the material actually shown, measures the result on the corpus, and
only then decides whether the mechanical grounds rule and a model raise are
warranted. Beads issue: st-6f7.

## Current State Analysis

`lib/mix/statifier/adr_judge.ex` runs two model calls per candidate: `propose`
builds a prompt from the ADR text plus that ADR's in-scope diff hunks
(`adr_judge.ex:451-480`), and `refute` builds a prompt from the ADR text plus a
one-line candidate claim (`adr_judge.ex:482-511`). The refute prompt is the
bug, in three compounding ways:

- **No tool access, by design.** `call_claude_cli/1` passes `--tools ""` and
  `--strict-mcp-config` (`adr_judge.ex:611-630`), and both prompts say "do not
  attempt to read, grep, or list any file". Correct for reproducibility;
  fatal in combination with the next two items.
- **An unconditional instruction to construct a defence.** "Argue against it
  being a real violation if a good-faith argument exists. Only conclude it
  survives if you cannot construct that argument" (`adr_judge.ex:494-496`).
  With no tools, a defence of the form "this is fine if some unseen mechanism
  compensates" is *always* constructible, so the pass approaches an
  unconditional veto.
- **A tie-break that compounds it.** "If you are genuinely uncertain, respond
  `{"violation": false}` - ties go to 'not a violation'"
  (`adr_judge.ex:508-509`). Uncertainty about material the refute pass was
  never shown reads as a tie.

The refute pass also **never sees the diff**. `judged_identity/1`
(`adr_judge.ex:439-441`) carries only `key`, `label`, and `adr_text` onto each
candidate, so "the change does not show X" is an assumption the refute pass
cannot check even in principle. The live st-laz verification (2026-08-07)
produced exactly that failure: a deleted enforced `:location` field on
`Statifier.Document.Content` was proposed correctly with constraint 3 named,
then overturned on a hypothesised "side table, index, or other data structure
keyed by content ID" that does not exist.

`parse_refute/1` (`adr_judge.ex:532-537`) reads anything other than an explicit
`{"violation": true}` as "not a violation" - the fail-closed default for parse
failures, which is separate from the judgment-level tie rule above and stays.

Testing today is entirely stubbed: every test in
`test/mix/statifier/adr_judge_test.exs` (748 lines) injects `opts[:caller]`, and
the `:test` build's `@default_caller` is `refuse_real_call/1`, which raises
(`adr_judge.ex:176-184`, st-c8c). That is the right default and this plan does
not weaken it - but it also means **nothing in the repository can currently tell
whether a prompt change helped**, which is how the stage reached a near-no-op
without anyone noticing.

### Key Discoveries

- **`call_claude_cli/1` is public and exists in `:test` builds.** A corpus test
  can opt into real calls by passing `caller: &AdrJudge.call_claude_cli/1`
  explicitly, with no production change and no weakening of the `:test` default
  (`adr_judge.ex:610-630`). The opt-in is visible at the call site, which is
  exactly what st-c8c asks for.
- **The tag-exclusion pattern is one line.** `test/test_helper.exs` is
  `ExUnit.start(exclude: [:scion, :scxml_w3])`; generated corpus files carry
  `@moduletag :scion` (`test/scion_tests/**`). The judge corpus follows the
  same shape with `:adr_judge_corpus`.
- **`Mix.Statifier.GateGuard` scans added lines under `test/` for `@tag :skip`**
  (`gate_guard.ex:197-204`). Fixture diffs live under `test/`, so a fixture
  whose body contains that literal string would fire the guard. Fixtures must
  not contain it.
- **`.quality.exs` is guarded at file granularity** (`gate_guard.ex:36`), so
  this plan does not touch it - the corpus is a hand-run, not a stage.
- **The registry's three entries are the corpus's rows**: ADR-0012
  (`lib/statifier/`), ADR-0014 (`lib/statifier/`), ADR-0015 constraint 4
  (`.claude/skills/**/SKILL.md`) - `adr_judge.ex:135-170`.
- **Observed cost, from the bead**: ~59s per propose call, ~55s for a
  propose+refute pair, 176.1s for a three-entry run on
  `claude-haiku-4-5-20251001`. That number is what the ADR-0011 cost model is
  judged against.

## Desired End State

1. `mix test --only adr_judge_corpus` runs a fixture corpus against the real
   `claude` CLI and reports, per fixture, whether the judge got it right - a
   violating fixture with no surviving finding is a named false negative, a
   clean fixture with a finding is a named false positive. The corpus never
   runs in `mix test`, `mix quality`, or `mix test.regression`.
2. A cheap, caller-free test in the ordinary suite keeps the corpus honest:
   every manifest entry names a fixture file that exists, every registry entry
   has at least one violating and one clean fixture, and every fixture's diff
   is in the scope its manifest row claims.
3. `refute_prompt/1` shows the refute pass the same diff hunks the propose pass
   saw, names the unverifiable-hypothesis failure mode explicitly, and requires
   a refuting argument to be grounded in the ADR text, the claim, or those
   hunks. The tie rule survives, narrowed to ambiguity *within the material
   shown*.
4. The corpus's before/after scores are recorded in the repository, along with
   the measured gate-time delta for haiku versus a raised model, so the
   `@default_model` decision is made against numbers rather than intuition.
5. The long-open DMV item inherited from the st2-meo plan - "a live-verified
   surviving finding remains unproven" - is answered by a recorded corpus run,
   not by a one-shot anecdote.

Verify with: a bare `mix quality` green (corpus excluded, shape test running),
then a hand-run `mix test --only adr_judge_corpus` whose scorecard is pasted
into the record.

## What We're NOT Doing

- **Not giving the refute pass tools.** `--tools ""` and `--strict-mcp-config`
  stay. A judge that can read the repository on its own is a different design
  with a different reproducibility story; the fix here is to show it more of
  the material, not to let it go find material.
- **Not touching `.quality.exs`.** The corpus is a hand-run, not a stage.
  Registering it would need an ADR-0011 ledger entry, which is a human's call,
  and a stage that makes ~10 real CLI calls does not belong in any profile.
- **Not weakening `@default_caller`.** The `:test` default stays
  `refuse_real_call/1`; the corpus opts in explicitly at its call site.
- **Not adding registry entries or scopes.** The judged-ADR registry is
  st-laz's product and stays as-is.
- **Not changing `parse_propose/1`, `extract_json/1`, or the task wrapper.**
- **Not writing a changelog fragment.** `changelog.d/README.md` excludes
  quality-gate and agent-tooling changes; nobody calling the public API can
  tell the difference.
- **Not building a bulk scoring harness or a report generator.** ExUnit's own
  per-test pass/fail *is* the false-negative/false-positive score, provided each
  failure message names which of the two it is.

## Implementation Approach

Corpus first, prompt second, mechanics third, model fourth - deliberately, and
in that order. The bead is explicit that the corpus is the real deliverable:
"a prompt change with no way to tell whether it helped is how the stage got
here." Each later phase is therefore gated on a measurement the earlier phase
made possible, and Phase 3 has a stated skip condition rather than being
assumed necessary.

The prompt rework (Phase 2) bundles all three prompt-level candidates from the
bead's notes - hunks, named failure mode, narrowed tie rule - into one change,
because they are one idea seen from three angles and measuring them separately
would cost three full corpus runs (~20 minutes each) to separate effects that
compound anyway. The *mechanical* half (Phase 3) is separated, because it
changes which direction the stage fails in and therefore deserves its own
measurement.

## Phase 1: Fixture Corpus and Real-CLI Harness

### Overview

Build the scoreboard. Hand-written unified diffs per registry entry, a manifest
binding each to its expected verdict, a tagged test module that runs them
against the real CLI, and a cheap in-suite test that keeps the corpus from
rotting. Ends with a recorded baseline run against the *current* prompts, which
is the number every later phase is compared to.

### Changes Required:

#### 1. Fixture corpus

**Files**: `test/fixtures/adr_judge/*.diff`, `test/fixtures/adr_judge/manifest.exs`

Eight fixtures, at least one violating and one clean per registry entry:

| Fixture | Key | Expect | Shape |
|---|---|---|---|
| `0012_dropped_location.diff` | adr-0012 | `:violation` | Deletes the enforced `:location` field from `Statifier.Document.Content` - the bead's live repro |
| `0012_dropped_trace.diff` | adr-0012 | `:violation` | Removes a trace effect at a phase boundary in the interpreter |
| `0012_rename_keeps_location.diff` | adr-0012 | `:clean` | Renames a field and threads `:location` through unchanged |
| `0012_pure_docs_change.diff` | adr-0012 | `:clean` | Moduledoc-only edit inside `lib/statifier/` |
| `0014_span_table_dropped.diff` | adr-0014 | `:violation` | Compiled-expression value loses its span table |
| `0014_span_preserving_refactor.diff` | adr-0014 | `:clean` | Extracts a helper, spans preserved on both sides |
| `0015_delegated_judgment.diff` | adr-0015 | `:violation` | A `SKILL.md` step that stated a policy now says "run `script.rb` and follow what it says" |
| `0015_mechanics_only.diff` | adr-0015 | `:clean` | A `SKILL.md` step names a script for mechanics while restating the policy in prose |

Diffs are hand-written in `git diff --unified=0 --src-prefix=a/ --dst-prefix=b/`
shape against real repository paths. They do not need to apply - they need to
parse through `AdrJudge.scoped_chunks/2` and land in the scope their row claims.

**Fixture content constraint**: no fixture may contain the literal `@tag :skip`.
`GateGuard` scans added lines under `test/` for it (`gate_guard.ex:197-204`) and
would fire on a fixture body.

The manifest is a plain `.exs` term:

```elixir
[
  %{
    key: "adr-0012-debuggability",
    file: "0012_dropped_location.diff",
    expect: :violation,
    note: "st-6f7 live repro: enforced :location dropped from Document.Content"
  },
  # ...
]
```

#### 2. Real-CLI corpus module

**File**: `test/mix/statifier/adr_judge_corpus_test.exs`
**Changes**: One generated test per manifest row, under `@moduletag :adr_judge_corpus`

```elixir
defmodule Mix.Statifier.AdrJudgeCorpusTest do
  use ExUnit.Case, async: false

  # Real `claude` CLI calls: ~2 minutes per fixture. Excluded by default in
  # test_helper.exs for the same reason :scion and :scxml_w3 are - and for
  # st-c8c's reason on top of that, since this is the one module in the suite
  # that reaches the real caller on purpose.
  @moduletag :adr_judge_corpus
  @moduletag timeout: :infinity

  alias Mix.Statifier.AdrJudge

  for entry <- Mix.Statifier.AdrJudgeCorpus.manifest() do
    @entry entry
    test "#{entry.file} (#{entry.expect})" do
      findings = AdrJudge.analyze(source_for(@entry), caller: &AdrJudge.call_claude_cli/1)

      case @entry.expect do
        :violation ->
          assert findings != [],
                 "FALSE NEGATIVE: #{@entry.file} is a known #{@entry.key} violation " <>
                   "(#{@entry.note}) and produced no surviving finding"

          assert Enum.any?(findings, &(&1.check == @entry.key)),
                 "WRONG ADR: #{@entry.file} survived under #{inspect(Enum.map(findings, & &1.check))}"

        :clean ->
          assert findings == [],
                 "FALSE POSITIVE: #{@entry.file} is known-clean for #{@entry.key} " <>
                   "and produced #{inspect(findings)}"
      end
    end
  end
end
```

The caller is passed explicitly. `@default_caller` and `refuse_real_call/1` are
untouched, so a *forgotten* caller still raises everywhere else in the suite.

#### 3. Shared corpus loader

**File**: `test/support/adr_judge_corpus.ex`
**Changes**: Manifest loading, fixture reading, and `source()` construction,
shared by the corpus module and the shape test.

```elixir
def manifest, do: @manifest_path |> Code.eval_file() |> elem(0)

def source_for(entry) do
  registry = Enum.find(AdrJudge.judged(), &(&1.key == entry.key))
  diff = File.read!(Path.join(@fixture_dir, entry.file))

  %{
    diff: diff,
    adrs: [
      %{
        key: registry.key,
        label: registry.label,
        focus: registry.focus,
        adr_text: File.read!(registry.adr_path),
        chunks: AdrJudge.scoped_chunks(diff, registry.scope)
      }
    ]
  }
end
```

`test/support/` is already on the `:test` elixirc path (`mix.exs:36`) and is
excluded from coverage (`docs/testing.md`), so this adds no coverage pressure.

#### 4. Shape test (runs in the ordinary suite)

**File**: `test/mix/statifier/adr_judge_corpus_shape_test.exs`
**Changes**: Caller-free assertions that the corpus is well-formed

- Every manifest row's `file` exists under `test/fixtures/adr_judge/`.
- Every manifest row's `key` is a real registry key.
- Every registry entry has at least one `:violation` and one `:clean` row.
- Every fixture's diff produces a non-empty `scoped_chunks/2` result for its
  row's scope, and an empty one for at least one other scope where the scopes
  differ.
- No fixture contains the literal `@tag :skip`.

```
# sabotage: n/a - asserts manifest/fixture consistency, no lib/ behavior
```

...except the `scoped_chunks/2` assertions, which do exercise `lib/`:

```
# sabotage: have in_scope?/2 ignore scope.prefix -> red (the 0015 fixture
#           would read as in ADR-0012's lib/statifier/ scope too)
```

#### 5. Tag exclusion

**File**: `test/test_helper.exs`
**Changes**: `ExUnit.start(exclude: [:scion, :scxml_w3, :adr_judge_corpus])`

#### 6. Documentation

**File**: `docs/testing.md`
**Changes**: A short subsection under "The three suites" naming the corpus as a
fourth, hand-run suite: what it is, why it is excluded (real CLI calls, real
spend, ~15-20 minutes), how to run it, and how to read a failure as a false
negative versus a false positive.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] The corpus does not run in the ordinary suite: `mix test` reports no
      `adr_judge_corpus` tests executed
- [x] The corpus does not run in the ratchet: `mix test.regression` likewise
- [x] The shape test runs and passes in the ordinary suite
- [x] `mix test --only adr_judge_corpus --dry-run`-equivalent: the module
      compiles and generates one test per manifest row

#### Manual Verification:
- [ ] `mix test --only adr_judge_corpus` runs end to end against the real CLI
- [ ] Baseline recorded: per-fixture verdict, wall time, and model id, pasted
      into the plan's record section (or `docs/plans/` follow-up note)
- [ ] The baseline reproduces the bead's bug - `0012_dropped_location.diff`
      fails as a false negative. If it does *not*, stop and report: the
      premise of Phase 2 is unconfirmed and the fixture or the failure mode
      needs re-examination before any prompt change
- [ ] The clean fixtures pass at baseline, establishing that today's false-positive
      rate is the number to not regress

**Implementation Note**: Use `mix quality --profile loop` between edits; run the
full `mix quality` as the phase gate. The corpus run is manual and costs real
money - run it once, deliberately, and record the output.

#### Baseline (measured)

Run: `mix test --only adr_judge_corpus --seed 0 --trace`, 2026-08-08, against
the *current* (unmodified) prompts. Model `claude-haiku-4-5-20251001` - today's
`@default_model`, with `STATIFIER_ADR_JUDGE_MODEL` confirmed unset. Total wall
time **357.9 s** (~6 minutes) for 8 fixtures; 4 failures.

| Fixture | Expect | Verdict | Classification | Wall |
|---|---|---|---|---|
| `0012_dropped_location.diff` | violation | FAIL | **false negative** | 54.4 s |
| `0012_dropped_trace.diff` | violation | FAIL | **false negative** | 40.8 s |
| `0012_rename_keeps_location.diff` | clean | PASS | correct | 25.5 s |
| `0012_pure_docs_change.diff` | clean | PASS | correct | 11.2 s |
| `0014_span_table_dropped.diff` | violation | FAIL | **false negative** | 70.6 s |
| `0014_span_preserving_refactor.diff` | clean | PASS | correct | 14.5 s |
| `0015_delegated_judgment.diff` | violation | FAIL | **false negative** | 78.1 s |
| `0015_mechanics_only.diff` | clean | PASS | correct | 62.1 s |

Score: **4 false negatives out of 4 violating fixtures (100%), 0 false
positives out of 4 clean fixtures (0%)**. No wrong-ADR attributions - no
violating fixture produced a surviving finding under any key at all.

Two things this settles, both of which Phase 2 is built on:

- **The bead's bug reproduces.** `0012_dropped_location.diff` - the st-laz live
  repro, an enforced `:location` dropped from `Statifier.Document.Content` -
  fails as a false negative, exactly as the bead describes. Phase 2's premise is
  confirmed against a fixture rather than an anecdote.
- **The false-positive rate today is zero**, and that is the number Phase 2 and
  Phase 3 must not regress. Every clean fixture passed, so any new finding on a
  clean fixture after a prompt change is a real regression and not noise in a
  pre-existing count.

Read together, the two columns say something sharper than "the refute pass is
too lenient": at baseline the stage is not a weak check, it is very nearly a
*no-op in the violating direction*. Every violating fixture across all three
registry entries was suppressed - the failure is not specific to ADR-0012 or to
the one hunk shape the bead happened to hit, so a fix aimed only at the
side-table hypothesis would be aimed too narrowly.

**Confirmatory rerun** (same day, same unmodified prompts, `--seed 675107`):
329.9 s, 3 of 4 violating fixtures false-negatived (`0012_dropped_location.diff`,
`0012_dropped_trace.diff`, `0014_span_table_dropped.diff`) and 0 false
positives; `0015_delegated_judgment.diff` survived correctly on this run where
it had false-negatived on the first. The live-CLI judge is not perfectly
deterministic run to run, so a single fixture's pass on one run is not proof a
prompt change fixed it - the bead's own fixture
(`0012_dropped_location.diff`) false-negatived on both runs, and that is the
number Phase 2 is judged against. Phase 2/3/4 comparisons should read a single
clean fixture failure as noise-worthy only if it recurs.

The corpus is also not too easy to be a fair test (Open Question 6): each of the
four violating fixtures is a deletion or an omission that the deterministic
guards would catch instantly, and the judge suppressed all four. If anything the
fixtures are on the blatant end, which makes a 0/4 detection rate the strongest
possible form of the finding. Harder cases can wait until the stage detects the
easy ones.

## Phase 2: Ground the Refute Pass in the Material Shown

### Overview

Rework `refute_prompt/1` so the refuting argument must be grounded in what the
pass was actually shown, and show it more: the same diff hunks the propose pass
saw. Prompt-level only - `parse_refute/1` is unchanged in this phase.

### Changes Required:

#### 1. Carry the hunks onto each candidate

**File**: `lib/mix/statifier/adr_judge.ex`
**Changes**: `judged_identity/1` gains the rendered hunks; `candidate()` gains a
`hunks` field

```elixir
@type candidate :: %{
        file: String.t(),
        line: pos_integer() | nil,
        claim: String.t(),
        key: String.t(),
        label: String.t(),
        adr_text: String.t(),
        hunks: String.t()
      }

defp judged_identity(judged) do
  %{
    key: judged.key,
    label: judged.label,
    adr_text: judged.adr_text,
    hunks: render_hunks(judged.chunks)
  }
end
```

`render_hunks/1` is extracted from `propose_prompt/1`'s existing `Enum.map_join`
so both prompts render the same text from one definition site rather than two
that can drift.

#### 2. Rework the refute prompt

**File**: `lib/mix/statifier/adr_judge.ex`
**Changes**: `refute_prompt/1` body

The three substantive edits, each traceable to the bead:

- **Show the hunks**, so "the change does not show X" is checkable rather than
  assumed.
- **Name the failure mode.** Replace "Argue against it being a real violation if
  a good-faith argument exists. Only conclude it survives if you cannot
  construct that argument" with a grounding rule that says plainly which
  argument shape does not count:

  > Your refutation must be grounded in the material below - the ADR text, the
  > claim, or the diff hunks. An argument that depends on a mechanism not
  > visible in that material does not overturn the claim. "The change does not
  > show X, but X might exist elsewhere in the codebase - a side table, an
  > index, a helper, a caller that compensates" is exactly the reasoning to
  > exclude: you have no way to check it, so it is a hypothesis, not a
  > refutation. If the only defence you can construct is of that shape, the
  > claim survives.

- **Narrow the tie rule** rather than deleting it. Ambiguity *within the shown
  material* still breaks toward not-a-violation; doubt sourced from material
  not shown does not count as ambiguity at all:

  > If the material shown leaves the question genuinely ambiguous, respond
  > `{"violation": false}` - ties within the shown material go to "not a
  > violation". Uncertainty about material you were not shown is not a tie.

- Ask for a `grounds` field alongside the verdict (quote or reference to the
  shown material). **Phase 2 does not read it** - `parse_refute/1` still keys
  only on `{"violation": true}`. It exists so Phase 2's corpus run produces the
  evidence Phase 3's decision needs, and so a human reading a transcript can
  see whether a verdict was grounded.

Keep the prompt-injection paragraph, the no-tools paragraph, and the
JSON-only instruction verbatim.

#### 3. Tests

**File**: `test/mix/statifier/adr_judge_test.exs`
**Changes**: New tests, spy-caller style, matching the file's existing shape

- The refute prompt carries the candidate's own diff hunks
  (`# sabotage: drop :hunks from judged_identity/1 -> red`)
- The refute prompt names the unverifiable-hypothesis exclusion
  (`# sabotage: restore the old "argue against it" wording -> red`)
- A candidate proposed under one ADR gets that ADR's hunks, not another's, when
  two registry entries share a scope
  (`# sabotage: render hunks from the first source.adrs entry -> red`)
- Existing behavior unchanged: `{"violation": true}` survives,
  `{"violation": false}` overturns, unparseable overturns

#### 4. Moduledoc

**File**: `lib/mix/statifier/adr_judge.ex`
**Changes**: Update the moduledoc's description of the refute pass to state the
grounding rule and why the pass now sees the diff. Match the file's existing
house style (it uses em dashes; keep them there).

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] New refute-prompt tests pass and each carries a sabotage line
- [x] Every existing `adr_judge_test.exs` test still passes unchanged

#### Manual Verification:
- [ ] `mix test --only adr_judge_corpus` re-run, same model as the baseline
- [ ] Scorecard compared to baseline and recorded: false negatives before/after,
      false positives before/after, wall time
- [ ] `0012_dropped_location.diff` now produces a surviving finding - this is
      the bead's acceptance condition and the answer to the DMV item
- [ ] Clean fixtures still produce zero findings; any new false positive is
      reported to the user rather than absorbed, since a false positive here
      blocks a commit

**Implementation Note**: In interactive execution, pause here for the corpus
comparison before proceeding - Phase 3's entire justification is whichever
false negatives survive this phase.

#### Phase 2 corpus re-run (measured)

Run: `mix test --only adr_judge_corpus --seed 0 --trace`, 2026-08-08, against
the reworked `refute_prompt/1` (hunks shown, unverifiable-hypothesis exclusion
named, tie rule narrowed to the shown material, `grounds` requested but not
yet read). Model `claude-haiku-4-5-20251001` - unchanged from the baseline,
`STATIFIER_ADR_JUDGE_MODEL` confirmed unset. Total wall time **272.4 s**
(~4.5 minutes) for 8 fixtures; **0 failures**.

| Fixture | Expect | Verdict | Classification | Wall |
|---|---|---|---|---|
| `0012_dropped_location.diff` | violation | PASS | correct (surviving finding) | 41.9 s |
| `0012_dropped_trace.diff` | violation | PASS | correct (surviving finding) | 29.6 s |
| `0012_rename_keeps_location.diff` | clean | PASS | correct | 35.2 s |
| `0012_pure_docs_change.diff` | clean | PASS | correct | 10.0 s |
| `0014_span_table_dropped.diff` | violation | PASS | correct (surviving finding) | 32.6 s |
| `0014_span_preserving_refactor.diff` | clean | PASS | correct | 25.0 s |
| `0015_delegated_judgment.diff` | violation | PASS | correct (surviving finding) | 49.2 s |
| `0015_mechanics_only.diff` | clean | PASS | correct | 48.2 s |

Score: **0 false negatives out of 4 violating fixtures (0%), 0 false positives
out of 4 clean fixtures (0%)** - every violating fixture now produces a
surviving finding under its own registry key, and every clean fixture still
produces none.

Comparison to the Phase 1 baseline (357.9 s, 4/4 violating fixtures false
negatived, 0/4 false positives):

- **False negatives: 4 -> 0.** All four violating fixtures across all three
  registry entries, including `0012_dropped_location.diff` - the bead's own
  live repro (an enforced `:location` dropped from
  `Statifier.Document.Content`) - now produce a surviving finding under the
  correct ADR key. **This is the answer to the bead's acceptance condition and
  the long-open DMV item ("a live-verified surviving finding remains
  unproven"): it is no longer unproven.**
- **False positives: 0 -> 0, no regression.** Every clean fixture still
  produces zero findings; the grounding rule and the narrowed tie rule did not
  tip the stage into over-suppression's opposite failure - flagging clean
  changes.
- **Wall time: 357.9 s -> 272.4 s**, faster despite the refute prompt now
  carrying the full diff hunks (more input tokens per refute call). The extra
  input did not measurably slow the round trip at this scale; the run-to-run
  variance already noted at baseline (357.9 s vs. 329.9 s on the confirmatory
  rerun) is larger than this apparent speedup, so the direction of the time
  change should not be read as a property of the prompt rework by itself.

The prompt rework alone (no mechanical change to `parse_refute/1`) closed
every false negative in the corpus with no false-positive regression. Per
Phase 3's stated skip condition ("skip this phase entirely if Phase 2's corpus
run shows zero false negatives and no false-positive regression"), **Phase 3
is not needed** on this measurement - the mechanical `grounds`-required rule
stays unbuilt unless a later run resurfaces a false negative the prompt alone
does not catch.

---

## Phase 3: Reject Ungrounded Refutations Mechanically (Conditional)

### Overview

**Skip this phase entirely if Phase 2's corpus run shows zero false negatives
and no false-positive regression.** It exists for the case where the prompt
alone does not hold: make an ungrounded refutation mechanically incapable of
vetoing a candidate, by requiring the `grounds` field to be present and
non-empty for a `false` verdict to count.

### Changes Required:

#### 1. `parse_refute/1`

**File**: `lib/mix/statifier/adr_judge.ex`
**Changes**: Three outcomes instead of two

```elixir
# An explicit survival survives. An overturn counts only when the model shows
# its work: a `false` verdict with no grounds is a refutation the pass could
# not ground in the material it was shown, which is the failure mode st-6f7
# exists to close - it does not veto. An unparseable response still reads as
# "not a violation": there we learned nothing at all, and failing toward not
# blocking a commit is the right direction for garbage.
defp parse_refute(text) do
  case text |> extract_json() |> JSON.decode() do
    {:ok, %{"violation" => true}} -> true
    {:ok, %{"violation" => false, "grounds" => g}} when is_binary(g) -> String.trim(g) == ""
    {:ok, %{"violation" => false}} -> true
    _other -> false
  end
end
```

Note the asymmetry this creates and the reason for it: a *well-formed but
ungrounded* verdict promotes the candidate (the refute pass tried and failed to
ground its defence), while an *unparseable* response still suppresses it (the
refute pass produced nothing to judge). This is a deliberate distinction, and it
is the one part of this plan that changes which direction the stage fails in.

#### 2. Prompt

**File**: `lib/mix/statifier/adr_judge.ex`
**Changes**: Make `grounds` load-bearing in `refute_prompt/1`'s response
instruction - state that a `false` verdict without non-empty `grounds` is read
as "not overturned".

#### 3. Tests

**File**: `test/mix/statifier/adr_judge_test.exs`
**Changes**:

- `{"violation": false, "grounds": "the ADR's constraint 3 names only ..."}`
  overturns (`# sabotage: ignore the grounds field -> red`)
- `{"violation": false}` with no grounds does *not* overturn
  (`# sabotage: treat a bare false as an overturn -> red`)
- `{"violation": false, "grounds": "  "}` does not overturn
  (`# sabotage: drop the String.trim/1 -> red`)
- Unparseable still overturns (unchanged, pinned against regression)

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes: `mix quality`
- [ ] New `parse_refute/1` tests pass with sabotage lines
- [ ] The unparseable-overturns test is unchanged and still green

#### Manual Verification:
- [ ] Corpus re-run and scored against Phase 2's numbers
- [ ] False-positive count did not rise. If it did, report the numbers and stop
      - trading the reported bug for commit-blocking false positives is a
      human's call, not the implementer's
- [ ] The skip condition was evaluated explicitly and the decision recorded,
      including "skipped because Phase 2 was sufficient"

---

## Phase 4: Model Evaluation and Record

### Overview

Measure the model axis, decide `@default_model` against the ADR-0011 cost model,
and write the outcome into the repository so the next reader does not re-derive
it. This phase changes at most one line of code and mostly produces evidence.

### Changes Required:

#### 1. Measurement

No code change. Run the corpus twice more with `STATIFIER_ADR_JUDGE_MODEL` set,
and time a real three-entry `mix adr.judge` run for each:

- `claude-haiku-4-5-20251001` (today's default) - already measured in Phase 2/3
- `claude-sonnet-5` (correction: `claude-sonnet-4-6`, named in the original
  Open Question 4, is not a current model id)

Record for each: per-fixture verdict, corpus score, per-call wall time, and the
three-entry `mix adr.judge` wall time (the bead's 176.1s haiku figure is the
comparison point).

#### 2. Decision and, if taken, the raise

**File**: `lib/mix/statifier/adr_judge.ex`
**Changes**: `@default_model`, only if the decision rule below is met

Decision rule, stated in advance so the measurement is not read backwards:

- Raise only if the corpus score strictly improves (fewer false negatives, no
  more false positives) **and** the three-entry `mix adr.judge` run stays under
  6 minutes - roughly 2x the observed haiku figure, which is the outer bound
  worth paying on a `:merge`-profile-only, opt-in path.
- If the score is unchanged and the prompt fix alone closed the bug, keep haiku
  and record the sonnet numbers as the evidence for that choice.
- If the score improves but the time bound is blown, report both numbers and
  stop - trading gate time against judge quality on a path a human opted into
  is a human's call.

`STATIFIER_ADR_JUDGE_MODEL` remains the escape hatch either way, so nobody is
locked into the default.

#### 3. Record

**Files**: `lib/mix/statifier/adr_judge.ex` (moduledoc),
`docs/testing.md`, `docs/plans/260807-st-laz-adr-judge-multi-adr.md`

- Moduledoc: state that the refute pass sees the propose pass's hunks and why,
  and that the model choice is measured rather than assumed, naming the corpus
  as the measurement.
- `docs/testing.md`: the corpus subsection gains the recorded baseline/after
  scores so a reader knows what "passing" looked like when it was last run.
- st-laz plan: mark the DMV item "a live-verified surviving finding remains
  unproven" as answered, citing the corpus fixture that proves it.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes: `mix quality`
- [x] If `@default_model` changed, the existing suite still passes (no test
      asserts the model id today; if one is added, it reads the attribute
      rather than re-typing the string)

#### Manual Verification:
- [ ] Both model runs completed and their numbers recorded
- [ ] The decision rule was applied and the outcome written down, including
      "kept haiku because X"
- [ ] The three-entry `mix adr.judge` wall time under the chosen model is
      recorded next to the bead's 176.1s baseline
- [ ] A reader of the moduledoc can tell how to re-run the corpus and what the
      last recorded score was

#### Phase 4 measurement (recorded)

**Corpus run**, `mix test --only adr_judge_corpus --seed 0 --trace`,
2026-08-08, `STATIFIER_ADR_JUDGE_MODEL=claude-sonnet-5`, same reworked
`refute_prompt/1` as the Phase 2 re-run (unchanged in Phase 4 - this phase
touches no prompt code). Total wall time **91.4 s** for 8 fixtures; **0
failures**.

| Fixture | Expect | Verdict | Classification | Wall |
|---|---|---|---|---|
| `0012_dropped_location.diff` | violation | PASS | correct (surviving finding) | 13.6 s |
| `0012_dropped_trace.diff` | violation | PASS | correct (surviving finding) | 12.1 s |
| `0012_rename_keeps_location.diff` | clean | PASS | correct | 14.6 s |
| `0012_pure_docs_change.diff` | clean | PASS | correct | 5.6 s |
| `0014_span_table_dropped.diff` | violation | PASS | correct (surviving finding) | 12.1 s |
| `0014_span_preserving_refactor.diff` | clean | PASS | correct | 5.4 s |
| `0015_delegated_judgment.diff` | violation | PASS | correct (surviving finding) | 12.2 s |
| `0015_mechanics_only.diff` | clean | PASS | correct | 15.1 s |

Score: **0 false negatives out of 4 violating fixtures (0%), 0 false
positives out of 4 clean fixtures (0%)** on `claude-sonnet-5` - identical to
Phase 2's haiku score (0/4, 0/4). Sonnet's per-call latency in this run was
markedly lower than haiku's (91.4 s total versus haiku's 272.4 s for the same
8 fixtures), but that is not what the decision rule below turns on.

**Three-entry `mix adr.judge` timing**, both against the same real,
uncommitted scratch diff (a comment-only addition to
`lib/statifier/document/content.ex`, landing in both the ADR-0012 and
ADR-0014 `lib/statifier/` scope, plus a comment-only addition to
`.claude/skills/commit/SKILL.md`, landing in the ADR-0015 scope - three
registry entries judged in one invocation, matching the bead's "three-entry"
shape). Reverted immediately after each measurement; neither appears in the
final diff.

| Model | Wall time | vs. bead's 176.1s baseline |
|---|---|---|
| `claude-haiku-4-5-20251001` (`STATIFIER_ADR_JUDGE_MODEL` unset) | 54.4 s | faster |
| `claude-sonnet-5` | 19.6 s | faster |

Both land well inside the 360s (6-minute) bound Open Question 3 sets, and
both are considerably faster than the bead's original 176.1s figure - the
scratch diff here is a same-shape but comment-only edit rather than the
bead's real violation-shaped diff, and a "no violation" propose verdict
appears to resolve faster than one that has to reason through a genuine
finding, so these two numbers are not read as contradicting the bead's
figure, only as bounding this measurement's own run.

**Decision**: **keep `claude-haiku-4-5-20251001` as `@default_model`.** The
decision rule requires the corpus score to *strictly improve* (fewer false
negatives than haiku's 0/4) before a raise is considered, and sonnet's score
is unchanged at 0/4 false negatives, 0/4 false positives - there was no
headroom left for sonnet to improve on, since Phase 2's prompt fix alone
already reached a perfect score on haiku. This is exactly the plan's stated
expected outcome ("If the score is unchanged and the prompt fix alone closed
the bug, keep haiku and record the sonnet numbers as the evidence for that
choice"). No code changes in this phase; `STATIFIER_ADR_JUDGE_MODEL` remains
available for anyone who wants to opt into sonnet anyway.

---

## Testing Strategy

### Unit Tests

In `test/mix/statifier/adr_judge_test.exs`, stubbed-caller style, pattern
matching over multiple asserts, each with a sabotage line:

- Hunk threading: the refute prompt contains the candidate's own hunks; two
  registry entries sharing a scope each get their own
- Prompt content: the grounding rule and the named failure mode are present; the
  no-tools and injection paragraphs survive
- Tie narrowing: the prompt states that uncertainty about unshown material is
  not a tie
- (Phase 3) `parse_refute/1`'s three outcomes

### Corpus Tests

`test/mix/statifier/adr_judge_corpus_test.exs`, tag `:adr_judge_corpus`,
excluded by default. One test per fixture; the failure message classifies the
failure as a false negative, a false positive, or a wrong-ADR attribution. Not
sabotage-tested - it asserts model behavior, not `lib/` behavior, and states
that exemption:

```
# sabotage: n/a - scores real model output against known fixtures; the
#           implementation under test is the prompt, not a pure function
```

The shape test in the ordinary suite *is* sabotage-tested where it touches
`scoped_chunks/2`.

### Conformance Tests

None. This change touches no interpreter behavior and no SCION/W3C test moves.

### Manual Testing Steps

1. `mix test` - confirm no `adr_judge_corpus` tests ran.
2. `mix test --only adr_judge_corpus` - full corpus, real CLI, ~15-20 minutes.
   Record the scorecard.
3. `STATIFIER_ADR_JUDGE_MODEL=claude-sonnet-5 mix test --only adr_judge_corpus`
   - same, on the raised model.
4. Apply the `Statifier.Document.Content` sabotage by hand, run
   `mix quality --profile merge`, confirm a surviving finding reaches the gate
   as a real failure, then revert. This is the end-to-end proof that the corpus
   result transfers to the actual stage.

## Performance Considerations

The corpus is the cost. Eight fixtures x (one propose call + one refute call
per proposed candidate) at ~55-60s per pair is roughly 15-20 minutes and a
real, if small, bill. That is why it is hand-run and tag-excluded rather than a
stage, and why the plan runs it a bounded number of times (baseline, post-Phase
2, optionally post-Phase 3, plus one sonnet sweep) rather than in a loop.

Gate-time impact of the shipped change is bounded by the model decision in Phase
4 and by one extra input: the refute prompt now carries the diff hunks, so its
input token count rises to roughly the propose prompt's. On a stage that is
already latency-bound on the model round trip, this is expected to be noise
against the 176.1s figure, but it is part of what Phase 4 measures rather than
something to assert here.

## Open Questions

No human is available during planning, so each of these has a stated assumption
the implementation proceeds on. Each is a place a human may want to overrule.

1. **Should a well-formed but ungrounded `false` verdict promote the candidate?**
   *Assumed: not yet.* Phase 2 ships the prompt change only; Phase 3 adds the
   mechanical rule only if measurement shows the prompt alone is insufficient.
   The rule inverts the stage's failure direction for one specific response
   shape, and inverting it on speculation would be the same mistake in the other
   direction.
2. **Should the tie rule survive at all?** *Assumed: yes, narrowed.* The bead's
   description says to keep it for genuine ambiguity within the shown material;
   the notes ask whether the two rules compound. Narrowing removes the
   compounding without removing the safety valve. If the corpus shows persistent
   false negatives traceable to ties, deleting the rule is the next lever - a
   human's call, since it raises commit-blocking risk.
3. **What is the gate-time budget for a raised model?** *Assumed: under 6
   minutes for a three-entry `mix adr.judge` run,* roughly 2x the observed
   176.1s. The bead says the observed cost "is the thing the ADR-0011 cost model
   is judged against" but does not name a bound. If the measurement lands near
   the boundary, the number should be a human's.
4. **Which sonnet?** *Correction (recorded during implementation, no human
   available to ask): `claude-sonnet-4-6` is not a current model id.* The
   current model ids are `claude-opus-5`, `claude-sonnet-5`,
   `claude-haiku-4-5-20251001`, and `claude-fable-5`. Phase 4 uses
   `claude-sonnet-5` as the sonnet-tier candidate. Note the existing
   `@default_model` uses a dated id (`claude-haiku-4-5-20251001`); new entries
   should use the undated alias unless the pin is deliberate.
5. **Does the new default-excluded tag want a `docs/quality-gate-changes.md`
   entry?** *Assumed no.* `mix gate.check` does not flag `test_helper.exs`, and
   the tag adds a suite rather than narrowing an existing one - nothing that ran
   before stops running. But "adding a test-suite exclusion" is close enough to
   the spirit of the guarded-scope rule that a maintainer may want it on the
   record, and per CLAUDE.md that entry is a human's to write.
6. **Fixture count and hand-authored realism.** *Assumed eight fixtures, hand-written.*
   Real diffs cut from git history would be more faithful but pin the corpus to
   specific commits and drift as the repository grows. If the hand-written
   diffs turn out to be too clean to be a fair test (every violating fixture
   caught trivially, every clean one obviously clean), the corpus needs harder
   cases before its score means anything - that judgment happens at the Phase 1
   baseline.

## References

- Beads issue: `st-6f7`
- Module under change: `lib/mix/statifier/adr_judge.ex` (`refute_prompt/1`
  482-511, `judged_identity/1` 439-441, `parse_refute/1` 532-537,
  `@default_model` 173, `@default_caller` 176-184, `call_claude_cli/1` 610-630)
- Existing tests: `test/mix/statifier/adr_judge_test.exs`
- Task wrapper: `lib/mix/tasks/adr.judge.ex`
- Related ADRs: `docs/adr/0011-quality-gate-config-not-agent-editable.md`
  (cost model, guarded config), `docs/adr/0012-debuggability-designed-into-the-core.md`,
  `docs/adr/0014-expression-spans-in-cond-diagnostics.md`,
  `docs/adr/0015-skill-mechanics-in-scripts.md` (constraint 4, Enforcement)
- Prior plan: `docs/plans/260807-st-laz-adr-judge-multi-adr.md` (registry, DMV item)
- Tag-exclusion precedent: `test/test_helper.exs`, `docs/testing.md`
- Guard interaction: `lib/mix/statifier/gate_guard.ex:197-204` (`@tag :skip` scan
  over added lines under `test/`)
