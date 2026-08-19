---
date: 2026-08-19T08:41:34-0600
researcher: Claude
git_commit: a2948a424d67a236e9d07a7394eee356cdf5ba72
branch: st-6f7h-exitset-trace-coverage
repository: statifier-ex
beads_issue: st-6f7h
topic: "Covering the interpreter.ex exit-sweep ExitSet trace stamp site in the ADR judge corpus"
tags: [research, codebase, adr-judge-corpus, observability]
status: complete
last_updated: 2026-08-19
last_updated_by: Claude
---

# Research: covering the interpreter.ex exit-sweep ExitSet trace stamp site

**Date**: 2026-08-19T08:41:34-0600
**Git Commit**: a2948a424d67a236e9d07a7394eee356cdf5ba72
**Branch**: st-6f7h-exitset-trace-coverage
**Bead**: st-6f7h

## Research Question

st-6f7h records that ADR-0012's st-xsb1 amendment governs more than one
production site, and that only one of them is exercised by the ADR judge
corpus. It asks for either a fixture pair anchored on the uncovered site, or a
recorded decision that one site's coverage is sufficient for the rule.

Document, as the codebase exists today:

1. The exact production code at both ExitSet stamp sites and at the
   `enter_states/2` EntrySet site, and how the third site's comment differs.
2. What ADR-0012's st-xsb1 amendment says verbatim, and whether it is a
   general rule or a per-site rule.
3. How the `adr_judge` fixture harness works: fixture authoring, manifest row
   shape, tag selection, and what one "corpus-equivalent run" means.
4. The recorded measurement history and the running spend tally, so the plan
   can state remaining headroom precisely.
5. Whether a fixture anchored at the `interpreter.ex` site would be a
   genuinely distinct signal from the two existing ADR-0012 trace-stamp
   violation fixtures, or a near-duplicate - with the evidence for both
   readings gathered rather than one picked.

## Summary

There are **three** production sites that follow the amendment's split, not
two. `exit_states/2` and `exit_interpreter/1` both emit `Trace.ExitSet`;
`enter_states/2` emits `Trace.EntrySet` under a comment that is
word-for-word the same modulo `exit`/`entry` and the binding name. Only
`exit_states/2` is anchored by any corpus fixture. The bead's framing of "two
sites" undercounts by one, and the undercount matters to the crux: if the
argument for a second fixture is "each governed site needs its own row", it
argues for a third fixture too.

ADR-0012's amendment is **stated as a general rule about trace effects**, with
`exit_states/2` named only in the "worked example" position. Nothing in the ADR
text, the registry `focus` string, or the shape test's coverage invariant is
per-call-site: the shape test requires one violating and one clean fixture per
`{registry key, tier}` pair, never per production site.

The judge never sees the repository. It gets the ADR file verbatim, a one-line
`focus` string, and the diff hunks, under an explicit "they are everything you
get" instruction. So the question of whether an `interpreter.ex` fixture is a
distinct signal reduces to a question about **the bytes inside the hunk**, not
about the site's semantics. At default context width the hunk would be nearly
byte-identical to the existing `exit_entry.ex` violation fixture. At a widened
context width it would carry material no existing fixture carries - most
importantly a second trace call, `Trace.Done`, that is legitimately stamped
against the post-sweep state in the same function. That inversion is the
strongest available distinctness argument, and it is an argument for a
*differently designed* fixture rather than for a transplant of the existing one.

Spend: the ceiling is 8 corpus-equivalents and **5.2 are spent, leaving 2.8** -
the bead's note reads 5.2 as the remainder, which is a misreading of the ledger.
A new pair measured the way st-xsb1 measured its pair (2 fixtures x 3 seeds x 1
model = 6 fixture-runs) is **0.33 corpus-equivalents**, comfortably inside 2.8.
Authoring iteration is charged from the same pot at roughly one fixture-run per
try. Nothing about a new pair obliges a re-measurement of existing rows, because
no ADR text change is implied.

## Detailed Findings

### 1. The three production stamp sites

#### Site A: `exit_states/2`, the worked example (covered)

[`lib/statifier/interpreter/exit_entry.ex:134-167`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L134-L167). The binding is at
[`lib/statifier/interpreter/exit_entry.ex:150`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L150), under a six-line comment at
[`lib/statifier/interpreter/exit_entry.ex:144-149`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L144-L149), and the stamp is at
[`lib/statifier/interpreter/exit_entry.ex:161`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L161):

```elixir
    # ADR-0012: the counters this payload stamps must be the ones that stood
    # at the exit-set phase boundary, so the trace is stamped against
    # `pre_exit_state`; only `configuration` is read from the post-departure
    # state, because "the configuration after this exit set was applied"
    # does not exist until the reduce below has run. Effect-list
    # position is unchanged: the list is concatenated at the end either way.
    pre_exit_state = machine_state
```

```elixir
    trace_effects =
      Effect.trace(pre_exit_state, Effect.Trace.ExitSet,
        indexes: states_to_exit,
        configuration: machine_state.configuration
      )
```

The moduledoc restates the rule at
[`lib/statifier/interpreter/exit_entry.ex:120-131`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L120-L131) and names
`test/fixtures/adr_judge/0012_trace_prestate_captured.diff` as the sanctioned
shape.

#### Site B: `exit_interpreter/1`, the exit sweep (uncovered)

[`lib/statifier/interpreter.ex:1741-1799`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1741-L1799). The binding is at
[`lib/statifier/interpreter.ex:1750`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1750), under a comment at
[`lib/statifier/interpreter.ex:1744-1749`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1744-L1749), and the stamp is at
[`lib/statifier/interpreter.ex:1775`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1775):

```elixir
    # ADR-0012: the counters this payload stamps must be the ones that stood
    # at the exit-set phase boundary, so the trace is stamped against
    # `pre_exit_state`; only `configuration` is read from the post-sweep
    # state, because "the configuration after this exit set was applied"
    # does not exist until the reduce below has run. Effect-list
    # position is unchanged: the list is concatenated at the end either way.
    pre_exit_state = machine_state
```

The comment differs from site A's in **one word**: `post-departure` becomes
`post-sweep`. Everything else, including the binding name, is identical.

Three things at this site have no counterpart at site A:

- `configuration_at_exit` is captured at [`lib/statifier/interpreter.ex:1742`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1742),
  before the sweep, and feeds `Trace.Done` and `Effect.Done`.
- A second trace, `Effect.trace(machine_state, Effect.Trace.Done, ...)` at
  [`lib/statifier/interpreter.ex:1781-1784`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1781-L1784), is deliberately stamped against
  the **post-sweep** state while carrying `configuration: configuration_at_exit`,
  a **pre-sweep** value. Its pre/post split is the exact mirror image of the
  `ExitSet` payload's.
- The `ExitSet` payload's `configuration` field is provably always
  `MapSet.new()` here. The `Trace.ExitSet` moduledoc says so at
  [`lib/statifier/effect/trace/exit_set.ex:23-29`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/effect/trace/exit_set.ex#L23-L29), and the `exit_interpreter/1`
  moduledoc repeats it at [`lib/statifier/interpreter.ex:1691-1698`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1691-L1698), adding that
  it is "read rather than hardcoded so it cannot drift from the walk".

#### Site C: `enter_states/2`, the EntrySet mirror (uncovered, and not in the bead's count)

[`lib/statifier/interpreter/exit_entry.ex:706-733`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L706-L733). Binding at
[`lib/statifier/interpreter/exit_entry.ex:716`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L716), comment at
[`lib/statifier/interpreter/exit_entry.ex:710-715`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L710-L715), stamp at
[`lib/statifier/interpreter/exit_entry.ex:727`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L727). The comment is site A's with
`exit-set` -> `entry-set`, `pre_exit_state` -> `pre_entry_state`, and
`post-departure` -> `post-entry`. The moduledoc at
[`lib/statifier/interpreter/exit_entry.ex:691-701`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L691-L701) states the rule "(ADR-0012,
mirroring `exit_states/2`)".

The bead names site C as "worth checking in the same pass". It is confirmed:
site C carries the identical pattern, is governed by the same amendment, and is
covered by no fixture either. Any argument that site B's non-coverage is a gap
applies unchanged to site C.

#### What a stamp swap would actually change at each site

`Effect.trace/3` ([`lib/statifier/effect.ex:172-182`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/effect.ex#L172-L182)) stamps only
`macrostep`/`microstep`/`round`, via each payload's `new/2`
([`lib/statifier/effect/trace/exit_set.ex:53-59`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/effect/trace/exit_set.ex#L53-L59)). None of the three reduces
mutates those three counters - they are set by the microstep and macrostep
drivers, not by `depart/2`, `arrive/3`, or `run_onexit_blocks/2`. So at **all
three sites** a stamp swap is value-inert today: the emitted payload is
byte-identical either way.

That is not a finding against the rule. It is what the amendment is about: the
binding exists so the payload cannot silently acquire the wrong counters if a
future edit does move a counter inside one of those reduces. It does mean no
`test/` assertion can catch a stamp swap at any of the three sites - which is
why the ADR judge corpus is the only instrument in play, and why "coverage" in
this bead means judge-corpus coverage, not test coverage.

### 2. What the amendment says, and how general it is

[`docs/adr/0012-debuggability-designed-into-the-core.md:83-98`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/adr/0012-debuggability-designed-into-the-core.md#L83-L98), verbatim:

> **Amendment (st-xsb1):** item 4 commits trace effects to carrying "the step
> and the identity of what raised them" but does not say which state those
> counters are read from. A trace effect names a phase boundary, and the step
> counters it carries are the ones that stood at that boundary - stamped
> against the state as it was when the boundary was crossed, not against
> whatever the state became afterwards.
>
> The converse is equally part of the rule: a payload field whose meaning is
> defined only by the mutation - "the configuration after this exit set was
> applied" - is correctly read from the post-mutation state. Reading such a
> field after the mutation is not a violation of this item; stamping the
> counters after it is. A trace effect can therefore mix a pre-mutation
> stamp with a post-mutation field in the same payload without breaking item
> 4, so long as each is read from the state its own meaning depends on.
> `exit_states/2` ([`lib/statifier/interpreter/exit_entry.ex:134-167`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L134-L167)) is a
> worked example of exactly this split.

**It is a general rule.** The subject of every normative sentence is "a trace
effect", never a named function. `exit_states/2` appears once, in the trailing
"worked example" position, after the rule is stated in full. The ADR's own
scope claim at
[`docs/adr/0012-debuggability-designed-into-the-core.md:101-102`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/adr/0012-debuggability-designed-into-the-core.md#L101-L102) is that the
amendment "constrains no code that was not already constrained by item 4", and
item 4 (`:46-48`) is about trace effects generally.

The st-xsb1 plan made the example's dispensability an explicit acceptance
criterion - [`docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md:390-393`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md#L390-L393):
"the amendment must be readable without it - a rubric that only works when the
code under review still carries the explaining comment is the exact failure this
bead exists to fix" - and recorded the verification at `:825-829`: "it does, and
the rule is complete before any code is cited". The same plan records at
`:833-835` that the code citation is **inert to the judge**, which runs with
`--tools ""` and cannot open a file: "this is a fix for human readers".

The status line announces it in general terms too
([`docs/adr/0012-debuggability-designed-into-the-core.md:5-7`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/adr/0012-debuggability-designed-into-the-core.md#L5-L7)): "amended
2026-08-18 (st-xsb1: item 4's step counters are stamped against the state at
the phase boundary, not against whatever the state became afterwards)".

Two other pieces of judging guidance exist, and neither is per-site:

- The Consequences checklist,
  [`docs/adr/0012-debuggability-designed-into-the-core.md:117-119`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/adr/0012-debuggability-designed-into-the-core.md#L117-L119).
- The registry `focus` string, [`lib/mix/statifier/adr_judge.ex:179-181`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/mix/statifier/adr_judge.ex#L179-L181): "a
  microstep-resumability regression, a dropped trace effect at a phase
  boundary, a lost source location, or an uncounted or unstamped step".

### 3. How the adr_judge harness works

**What the judge sees.** `Mix.Statifier.AdrJudgeCorpus.source_for/1`
([`test/support/adr_judge_corpus.ex:46-62`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/support/adr_judge_corpus.ex#L46-L62)) builds a one-ADR source from a
manifest row: the registry entry's `label`, `focus`, the **entire ADR file**
read with `File.read!/1`, and `AdrJudge.scoped_chunks(diff, registry.scope)`.
`render_hunks/1` ([`lib/mix/statifier/adr_judge.ex:509-511`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/mix/statifier/adr_judge.ex#L509-L511)) renders each chunk
as `### <path>\n<chunk>`, so the judge does see `lib/statifier/interpreter.ex`
as a path string. The propose prompt
([`lib/mix/statifier/adr_judge.ex:516-540`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/mix/statifier/adr_judge.ex#L516-L540)) then says:

> You have no tool access in this session: do not attempt to read, grep, or
> list any file. Judge only from the ADR text and diff hunks given below -
> they are everything you get.

This is the single most consequential harness fact for question 5: the judge
cannot see the enclosing function, the moduledoc, or the sibling site. Only the
hunk's own context lines carry site identity.

**Calls per fixture.** `analyze/2` ([`lib/mix/statifier/adr_judge.ex:242-249`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/mix/statifier/adr_judge.ex#L242-L249))
is one propose call per ADR entry, plus one refute call per surviving proposed
candidate. So a clean fixture that proposes nothing costs one CLI call; a
violation fixture with one candidate costs two.
[`test/mix/statifier/adr_judge_corpus_test.exs:6-12`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/mix/statifier/adr_judge_corpus_test.exs#L6-L12) records "~11-78s per
fixture"; [`docs/testing.md:44-45`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/testing.md#L44-L45) records "~15-20 minutes for the full corpus
(roughly two model round trips per fixture)".

**Manifest rows.** `test/fixtures/adr_judge/manifest.exs` is a bare Elixir list
literal, `Code.eval_file/1`-ed by
`Mix.Statifier.AdrJudgeCorpus.manifest/0` ([`test/support/adr_judge_corpus.ex:37`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/support/adr_judge_corpus.ex#L37)).
It holds **20 rows today** (18 at st-2ts time, plus st-xsb1's pair). Each row is
`%{key:, file:, expect:, tier:, note:}`, documented at
[`test/support/adr_judge_corpus.ex:28-35`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/support/adr_judge_corpus.ex#L28-L35). `:note` is unvalidated prose that
appears in failure messages
([`test/mix/statifier/adr_judge_corpus_test.exs:41-42`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/mix/statifier/adr_judge_corpus_test.exs#L41-L42)).

**Validation** lives entirely in the free companion
`test/mix/statifier/adr_judge_corpus_shape_test.exs`: the file exists
(`:13-18`), the key is a real registry key (`:21-27`), the tier is
`:blatant | :subtle` (`:30-36`), the diff lands in its own scope and not a
differing one (`:53-72`), no fixture contains the literal `@tag :skip`
(`:75-82`), and - the one that bears directly on this bead - the pairing
invariant at [`test/mix/statifier/adr_judge_corpus_shape_test.exs:39-49`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/mix/statifier/adr_judge_corpus_shape_test.exs#L39-L49):

```elixir
    by_key_and_tier = Enum.group_by(@manifest, &{&1.key, &1.tier})

    for {{key, tier}, rows} <- by_key_and_tier do
      assert Enum.any?(rows, &(&1.expect == :violation)),
             "#{key} has no :violation fixture in the #{tier} tier"

      assert Enum.any?(rows, &(&1.expect == :clean)),
             "#{key} has no :clean fixture in the #{tier} tier"
    end
```

The unit of required coverage is `{registry key, tier}`. There is no notion of
a production site anywhere in the harness.

**Tag selection.** The paid module is tagged `:adr_judge_corpus`
([`test/mix/statifier/adr_judge_corpus_test.exs:13`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/mix/statifier/adr_judge_corpus_test.exs#L13)) and excluded in
[`test/test_helper.exs:9`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/test_helper.exs#L9). Each generated test carries `@tag tier: entry.tier`
and `@tag fixture: entry.file`
(`test/mix/statifier/adr_judge_corpus_test.exs:30-31, 46-47`). ExUnit's
`--only` beats the exclusion, so `mix test --only tier:subtle` and
`mix test --only fixture:<name>` are the spend controls. `--seed` is plain
ExUnit seed used only as a run label for repeat sampling; nothing passes a seed
to the model. The model is chosen by `STATIFIER_ADR_JUDGE_MODEL`, defaulting to
`claude-sonnet-5` ([`lib/mix/statifier/adr_judge.ex:213-215`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/mix/statifier/adr_judge.ex#L213-L215)).

**Fixture authoring.** Fixtures are hand-written unified diffs that **need not
apply**. [`docs/plans/260808-st-6f7-adr-judge-refute-grounding.md:178-184`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260808-st-6f7-adr-judge-refute-grounding.md#L178-L184):

> Diffs are hand-written in `git diff --unified=0 --src-prefix=a/
> --dst-prefix=b/` shape against real repository paths. They do not need to
> apply - they need to parse through `AdrJudge.scoped_chunks/2` and land in the
> scope their row claims.

The parser only needs `diff --git` separators and a `+++ b/<path>` or
`--- a/<path>` line (`lib/mix/statifier/adr_judge.ex:453, 466-474`). The four
ADR-0012 exit-set fixtures were re-anchored against real source with
`--unified=3` and carry `index` lines
([`docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md:124-126`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md#L124-L126)). **No
code checks the base revision**; there is no `git apply` anywhere in `lib/` or
`test/`. It was checked once by hand as a plan acceptance criterion
([`docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md:755-767`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md#L755-L767)).

Confirmed at this HEAD: `lib/statifier/interpreter/exit_entry.ex` is blob
`93d2fa4`, matching the two st-xsb1 fixtures; the two older fixtures carry
`b594e64`, the two-revision-stale base the bead's note says not to re-cut.
`lib/statifier/interpreter.ex` is blob `f98c27d`, which no fixture references.

**Gate wiring.** `.quality.exs:33` disables the `adr_judge` stage by default and
`:40-42` re-enables it in the `merge` profile. That stage runs `mix adr.judge`
over the branch diff; it never runs the corpus. No gate path runs any corpus
row, which the manifest's own note on
`0012_trace_stamp_swapped_comment_kept.diff` already records.

### 4. The spend ledger

**The unit**, defined once at
[`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:263-264`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md#L263-L264): "The whole bead
is budgeted at **eight full-corpus-equivalent runs**, where one
corpus-equivalent is one pass over all 18 fixtures." So 1.0 CE = 18
fixture-runs, and one fixture-run is one `--only fixture:<file>` invocation at
one seed on one model. The measurement unit it composes with (`:241-247`): three
runs at three distinct seeds, verdict by majority, non-unanimous counted as a
flap and never folded into the score.

Note the unit is anchored at "18 fixtures" as a **number**, not as "the corpus,
whatever size it is". The corpus is 20 rows today and a new pair makes 22; the
CE unit does not move with it, and nothing in the documents suggests it should.

**Recorded expenditures:**

| # | Expenditure | CE | What it bought |
|---|---|---|---|
| 1 | st-2ts Phase 5, 2026-08-18 | 4.2 | 76 fixture-runs: 60 subtle (3 seeds x 10 fixtures x 2 models) + 16 blatant (8 fixtures x 2 models). Wall ~63 min. [`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:1015-1019`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md#L1015-L1019) |
| 2 | st-xsb1 Phase 3, 2026-08-18 | 1.0 | 18 fixture-runs: 6 ADR-0012 subtle rows x 3 seeds x `claude-sonnet-5`, drawn from the 1.2 reserve. Wall 6.4 min. [`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:1088-1091`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md#L1088-L1091) |
| | **Cumulative** | **5.2 of 8** | **Remaining: 2.8** |

**The bead's note misstates this.** It says the ceiling "stands at 5.2 after
st-xsb1 consumed 1.0", which reads 5.2 as headroom. Every source states it as
cumulative spend: "Cumulative against Decision 3's ceiling of 8: **5.2**"
([`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:1090`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md#L1090)). Remaining
headroom is **2.8**, not 5.2. The forward-looking figures in the st-xsb1 plan
only parse on the cumulative reading
([`docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md:743-745`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md#L743-L745): a haiku
column would be "cumulative spend at 6.2 of 8").

**Raising the ceiling is a human's call**, stated three times.
[`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:279-282`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md#L279-L282):

> **If the ceiling is reached before Phase 5's measurement is complete, stop and
> report the partial scorecard.** Continuing to spend past a stated ceiling
> because the numbers are almost in is the decision this line exists to prevent,
> and raising the ceiling is a human's call.

Restated at `:1306-1309` and at
[`docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md:476-479`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md#L476-L479) and
`:652-654`.

**What a new pair would cost.** Following st-xsb1's precedent exactly - the new
rows only, three seeds, `claude-sonnet-5` only:

- 2 fixtures x 3 seeds x 1 model = 6 fixture-runs = **0.33 CE**.
- Authoring iteration, at roughly one fixture-run per try
  ([`docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md:268`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md#L268) budgeted 2.0 CE
  for ~36 authoring runs across three phases). A generous ten tries is 0.56 CE.
- Total worst case around **0.9 CE**, against 2.8 remaining.

A new pair does **not** oblige re-measuring existing rows: st-xsb1's 1.0 CE was
bought because amending the ADR text invalidated prior ADR-0012 numbers
([`docs/testing.md:112-114`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/testing.md#L112-L114)). Adding a fixture changes no ADR text and no prompt,
so every recorded per-fixture verdict still stands.

If instead a fixture also landed at site C (`enter_states/2`), the pair count
doubles to 0.67 CE plus authoring - still inside 2.8, but it is a second
decision, not a rider on the first.

**Recorded measurement history for the ADR-0012 subtle rows**
([`docs/testing.md:104-119`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/testing.md#L104-L119)): the third scorecard row, "ADR-0012 subtle only, 6
rows (partial, st-xsb1)", `claude-sonnet-5`, 1/3 false negatives, 0/3 false
positives, 0/6 flaps, 21.5s mean. It "supersedes nothing". It moved two
violation rows from false negative to caught, including
`0012_trace_stamp_swapped_comment_kept.diff`, the row st-ntf5 had hand-measured
as a false negative against the unamended rubric.
`0012_location_precision_one_caller.diff` remains missed.

### 5. The crux: distinct signal, or near-duplicate?

The two existing violation fixtures are the comparison set.

`test/fixtures/adr_judge/0012_trace_after_departure.diff` deletes both the
six-line comment and the `pre_exit_state` binding, and stamps from
`machine_state`. Its manifest note records that a variant keeping the comment
was a false negative, "so some of this row's signal is the deleted comment
naming the rule rather than the stamp swap alone".

`test/fixtures/adr_judge/0012_trace_stamp_swapped_comment_kept.diff` is that
variant, isolated: it deletes only the binding line, leaves the comment
standing, and swaps the stamp. Its note: "the only signal is the stamp swap
itself... The gap this row isolates is closed; it now guards against the
amendment being dropped."

#### Evidence that an interpreter.ex fixture would be a near-duplicate

1. **The judge sees only hunk bytes.** With the harness's authoring convention
   (`--unified=3`), a site-B violation fixture would consist of: a `diff --git`
   header naming `lib/statifier/interpreter.ex`, and a hunk showing the same
   six-line comment (one word different), the same deleted
   `pre_exit_state = machine_state` line, and the same
   `Effect.trace(machine_state, Effect.Trace.ExitSet, indexes: ..., configuration:
   machine_state.configuration)` call. Everything the amendment asks the judge to
   reason about is textually the same. The inference chain - "the payload names a
   phase boundary; the stamp now reads a state from after the boundary" - is
   identical, word for word.

2. **The rule is general and the corpus indexes rules, not sites.** The
   amendment's subject is "a trace effect"
   ([`docs/adr/0012-debuggability-designed-into-the-core.md:85`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/adr/0012-debuggability-designed-into-the-core.md#L85)); the shape test's
   coverage unit is `{key, tier}`
   ([`test/mix/statifier/adr_judge_corpus_shape_test.exs:39-49`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/mix/statifier/adr_judge_corpus_shape_test.exs#L39-L49)); the registry
   `focus` is a rule description
   ([`lib/mix/statifier/adr_judge.ex:179-181`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/mix/statifier/adr_judge.ex#L179-L181)). Nothing in the harness models a
   production site, so "site B is uncovered" is a statement about the codebase,
   not about a hole the corpus's own invariants recognize.

3. **The measurement already answered the question the row would ask.** The
   isolated stamp-swap signal was measured at three seeds and caught on all
   three ([`docs/testing.md:104-119`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/testing.md#L104-L119)). A second instance of the same edit at a
   different path measures the judge's sensitivity to file identity, which no
   ADR clause makes relevant.

4. **The value-inertness is symmetric.** At all three sites the swap emits an
   identical payload today, because no counter moves inside any of the three
   reduces. There is no semantic axis on which site B's swap is a worse or
   different violation than site A's.

5. **Site C exists.** If per-site coverage is the standard, the corpus needs a
   third pair for `enter_states/2` and the argument does not terminate at two.
   The corpus has never been sized per site.

6. **Cost is not free even where it fits.** 0.33 CE minimum plus authoring, out
   of 2.8 remaining, spent on a row whose distinguishing feature is a path
   string.

#### Evidence that an interpreter.ex fixture would be a distinct signal

1. **Site B contains an adversarial partner the corpus cannot currently
   express.** `Effect.trace(machine_state, Effect.Trace.Done, configuration:
   configuration_at_exit, ...)` at [`lib/statifier/interpreter.ex:1781-1784`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1781-L1784) is
   stamped post-mutation with a pre-mutation field - the exact inverse of the
   `ExitSet` payload eight lines above it. A hunk wide enough to show both puts
   a judge in front of two trace calls in one function with opposite pre/post
   splits, and asks it to indict one and not the other. No existing fixture
   contains two trace calls at all. This is a genuinely new discrimination task,
   and it targets the false-positive risk the amendment's second paragraph
   exists to bound: "Reading such a field after the mutation is not a violation
   of this item; stamping the counters after it is."

2. **The false-positive axis is under-tested.** Every recorded ADR-0012 subtle
   run has 0 false positives on 2-3 clean rows, so the clean side of the rule is
   effectively unmeasured against anything hard. `Trace.Done`'s stamp is a
   legitimate post-mutation stamp - the run ended, so the counters at the end are
   the right ones - and a judge that internalized "stamp pre-mutation" as an
   unconditional rule flags it. `0012_configuration_read_post_departure.diff`
   tests the post-mutation *field* half; nothing tests a legitimately
   post-mutation *stamp*.

3. **The `MapSet.new()` degeneracy is only at site B.** The moduledoc
   ([`lib/statifier/effect/trace/exit_set.ex:23-29`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/effect/trace/exit_set.ex#L23-L29)) records that
   `configuration` there is always empty and is read anyway so it "cannot drift
   from the walk". A clean fixture that hardcodes `MapSet.new()` instead of
   reading, or a violating one that does, is a rule-adjacent edit with no
   analogue at site A.

4. **The amendment's own "worked example" wording invites the question.** Naming
   one site as an example is what makes a reader ask whether the rule reaches
   the others. A corpus row at a second site is the mechanical demonstration
   that it does, and st-2ts's tier was added precisely to buy discrimination the
   blatant tier could not
   ([`docs/testing.md:121-124`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/testing.md#L121-L124)).

5. **The bead's own framing.** "a regression that swapped the stamp at
   `interpreter.ex:1775` would be caught by no corpus row" is literally true of
   the corpus as an instrument, whatever the rule's generality.

#### What separates the two readings

The readings differ on one question: **is the corpus an instrument for
measuring whether the judge understands a rule, or an instrument for measuring
whether the judge would catch a regression at each place the rule binds?** The
harness's `{key, tier}` invariant, the ADR's general wording, and the judge's
blindness to everything outside the hunk all point to the first. The bead's
phrasing points to the second.

Under the first reading, a transplanted site-B fixture is a near-duplicate and
the recorded decision is that one site's coverage is sufficient - with site C's
existence as the argument that per-site coverage does not terminate.

Under the second reading, the fixture worth cutting is **not** a transplant. It
is a pair built around `Trace.Done` - a violation that swaps the `ExitSet` stamp
in a hunk wide enough to show `Trace.Done` stamped correctly beside it, and a
clean partner that touches `Trace.Done`'s legitimate post-sweep stamp without
breaking it. That pair is distinct on both readings, because its signal is the
two-trace discrimination rather than the file path.

## Code References

- [`lib/statifier/interpreter/exit_entry.ex:120-131`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L120-L131) - `exit_states/2` moduledoc step 6, naming the sanctioned fixture
- [`lib/statifier/interpreter/exit_entry.ex:144-149`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L144-L149) - site A's six-line ADR-0012 comment
- [`lib/statifier/interpreter/exit_entry.ex:150`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L150) - site A's `pre_exit_state` binding
- [`lib/statifier/interpreter/exit_entry.ex:161-165`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L161-L165) - site A's `Trace.ExitSet` stamp
- [`lib/statifier/interpreter/exit_entry.ex:691-701`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L691-L701) - `enter_states/2` moduledoc step 4
- [`lib/statifier/interpreter/exit_entry.ex:710-715`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L710-L715) - site C's comment
- [`lib/statifier/interpreter/exit_entry.ex:716`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L716) - site C's `pre_entry_state` binding
- [`lib/statifier/interpreter/exit_entry.ex:727-731`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter/exit_entry.ex#L727-L731) - site C's `Trace.EntrySet` stamp
- [`lib/statifier/interpreter.ex:1686-1698`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1686-L1698) - `exit_interpreter/1` moduledoc step 2, the always-empty `configuration` rationale
- [`lib/statifier/interpreter.ex:1742`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1742) - `configuration_at_exit` capture
- [`lib/statifier/interpreter.ex:1744-1749`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1744-L1749) - site B's comment
- [`lib/statifier/interpreter.ex:1750`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1750) - site B's `pre_exit_state` binding
- [`lib/statifier/interpreter.ex:1775-1779`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1775-L1779) - site B's `Trace.ExitSet` stamp
- [`lib/statifier/interpreter.ex:1781-1784`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1781-L1784) - `Trace.Done`, the inverted pre/post pairing
- [`lib/statifier/effect.ex:172-182`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/effect.ex#L172-L182) - `Effect.trace/3`, what a stamp actually stamps
- [`lib/statifier/effect/trace/exit_set.ex:8-31`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/effect/trace/exit_set.ex#L8-L31) - the payload moduledoc naming both emitting sites
- [`lib/statifier/effect/trace/exit_set.ex:53-59`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/effect/trace/exit_set.ex#L53-L59) - `new/2`, counters from the passed state
- [`lib/mix/statifier/adr_judge.ex:173-211`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/mix/statifier/adr_judge.ex#L173-L211) - the judged-ADR registry
- [`lib/mix/statifier/adr_judge.ex:179-181`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/mix/statifier/adr_judge.ex#L179-L181) - ADR-0012's `focus` string
- [`lib/mix/statifier/adr_judge.ex:242-249`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/mix/statifier/adr_judge.ex#L242-L249) - `analyze/2`, one propose plus one refute per candidate
- [`lib/mix/statifier/adr_judge.ex:445-475`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/mix/statifier/adr_judge.ex#L445-L475) - `scoped_chunks/2` and the diff parser
- [`lib/mix/statifier/adr_judge.ex:509-540`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/mix/statifier/adr_judge.ex#L509-L540) - `render_hunks/1` and the propose prompt
- [`test/support/adr_judge_corpus.ex:28-62`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/support/adr_judge_corpus.ex#L28-L62) - manifest schema doc and `source_for/1`
- `test/fixtures/adr_judge/manifest.exs` - 20 rows; the four ADR-0012 trace rows carry the measurement history in their notes
- [`test/mix/statifier/adr_judge_corpus_test.exs:29-59`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/mix/statifier/adr_judge_corpus_test.exs#L29-L59) - tier/fixture tag generation
- [`test/mix/statifier/adr_judge_corpus_shape_test.exs:39-49`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/mix/statifier/adr_judge_corpus_shape_test.exs#L39-L49) - the `{key, tier}` pairing invariant
- [`test/test_helper.exs:9`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/test/test_helper.exs#L9) - `:adr_judge_corpus` exclusion
- `.quality.exs:33, 40-42` - stage disabled by default, enabled in `merge`
- [`docs/adr/0012-debuggability-designed-into-the-core.md:83-98`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/adr/0012-debuggability-designed-into-the-core.md#L83-L98) - the st-xsb1 amendment
- [`docs/testing.md:28-137`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/testing.md#L28-L137) - the fourth-suite description and every recorded scorecard

## Architecture Documentation

- **ADR-0012** (debuggability designed into the core) is the rule under test.
  Item 2 binds a trace row to the phase boundaries Appendix D names, which is
  why `exit_interpreter/1` emits `Trace.ExitSet` at all
  ([`lib/statifier/interpreter.ex:1686-1691`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/lib/statifier/interpreter.ex#L1686-L1691)); item 4 plus the st-xsb1
  amendment is the stamping rule.
- **ADR-0011** makes the "never go green by weakening the check" rule
  mechanical, which is the family the ADR judge belongs to.
- **ADR-0017 point 6** governs the manifest-policy fixtures in the corpus's
  0015 family and is the reason a manifest key that reclassifies what blocks
  needs prose.
- **ADR-0005** (interned integer indexes) is why `Trace.ExitSet.indexes` and
  `configuration` are index sets rather than id strings.
- The corpus is a **fourth suite in kind**, not just in tag
  ([`docs/testing.md:28-36`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/testing.md#L28-L36)): it is the only place in the repository that
  deliberately reaches a real model, and the only instrument that can detect a
  stamp swap at any of the three sites, since none of them changes an
  observable value today.

## Historical Context

- `docs/plans/260808-st-6f7-adr-judge-refute-grounding.md` established the
  hand-written-diff authoring convention and the original eight blatant
  fixtures.
- `docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md` added the subtle tier,
  the `tier:`/`fixture:` spend controls, the three-seed majority measurement
  policy (Decision 2), and the eight-corpus-equivalent ceiling (Decision 3).
  Phase 5 spent 4.2 CE.
- st-ntf5 hand-measured the comment-kept stamp swap as a false negative, which
  is the observation that produced st-xsb1.
- `docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md` amended ADR-0012,
  landed the two newest ADR-0012 rows, and spent 1.0 CE re-measuring the six
  ADR-0012 subtle rows on `claude-sonnet-5`. Its "Provisional Decisions and
  Findings for a Maintainer" section is the shape to follow when this bead
  answers its own open questions without a human: state the provisional answer,
  the grounds, the assumption, and the redirect cost.
- The st-xsb1 plan also recorded that two of the four exit-set fixtures carry a
  two-revision-stale base blob, verified benign
  ([`docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md:755-767`](https://github.com/riddler/statifier-ex/blob/a2948a424d67a236e9d07a7394eee356cdf5ba72/docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md#L755-L767)). This
  bead's note forbids re-cutting them.

## Related Research

- `docs/research/260818-st-xsb1-adr-0012-pre-mutation-fixture.md`
- `docs/research/260818-st-2ts-adr-judge-harder-fixtures.md`
- `docs/plans/260818-st-xsb1-adr-0012-pre-mutation-fixture.md`
- `docs/plans/260818-st-2ts-adr-judge-harder-fixtures.md`
- `docs/plans/260808-st-6f7-adr-judge-refute-grounding.md`

## Open Questions

No human was available while this document was written. Each question below is
recorded rather than answered, with the assumption this document proceeds under
stated alongside it.

1. **Is the corpus indexed by rule or by production site?** This is the crux and
   it is a maintainer's call. The harness answers "by rule" mechanically
   (`{key, tier}`); the bead's phrasing assumes "by site". *Assumption taken
   here*: neither reading is picked, and both bodies of evidence are set out in
   section 5 for the plan to choose from.

   **Settled (2026-08-19):** by rule and tier, per the plan's Decision 3 - the
   harness enforces `{key, tier}` and ADR-0012's amendment is written generally,
   with `exit_states/2` named only as a worked example. Recorded as the working
   answer, **not as a closed question**: whether it survives maintainer review
   is still open on the plan's deferred list, and overturning it would oblige a
   site-C pair.

2. **If a pair lands, is it a transplant or a `Trace.Done` pair?** A transplant
   is the cheaper and more literal reading of the acceptance criterion; a
   `Trace.Done` pair is the only design distinct under both readings but is a
   harder fixture to word and its clean half tests a rule half the corpus has
   never probed. *Assumption*: the plan should treat these as two options with
   different evidence, not one.

   **Settled (2026-08-19):** the `Trace.Done` pair - but the dichotomy was
   false, and that only became visible after measurement. The pair's violation
   half is byte-identical in its changed lines to
   `0012_trace_stamp_swapped_comment_kept.diff`, so it *is* the transplant; the
   novelty lives in the clean half and the wide two-trace hunk. That accident
   turned out to be the most useful property of the fixture: identical bytes
   caught 3/3 at site A and missed 3/3 at site B exonerate the edit and isolate
   the cause to context.

3. **Does site C (`enter_states/2`) join this bead?** The bead says to check it;
   it is confirmed governed and uncovered. Whether that is a finding to record,
   a second pair to cut, or a follow-up bead is unanswered. *Assumption*: it is
   at minimum a finding this bead must record, since a per-site coverage
   argument that stops at two sites is incomplete.

   **Settled (2026-08-19):** recorded as a finding, no fixture and no follow-up
   bead, per the plan's Decision 3 - a site-C row could only be the transplant
   the design rejected. Durably recorded in the violation row's manifest note,
   not only in the plan. Still subject to maintainer review on the plan's
   deferred list.

4. **Should the corpus-equivalent unit be re-anchored?** 1.0 CE is defined as
   "one pass over all 18 fixtures" and the corpus is 20 rows, heading for 22.
   Re-anchoring the unit would silently change every recorded figure.
   *Assumption*: the unit stays pinned at 18 fixture-runs and this document
   computes against that, matching how st-xsb1 computed its 1.0.

   **Settled (2026-08-19):** pinned at 18 fixture-runs, and now stated in
   st-2ts's Decision 3 itself rather than left as a convention. Re-anchoring to
   22 would re-denominate 5.2 to roughly 4.3 and manufacture headroom nobody
   voted for.

5. **Does the bead's note need correcting on the record?** It states 5.2 as
   remaining headroom where every source states it as cumulative spend of 8, so
   real headroom is 2.8. *Assumption*: this document records the correction; a
   `bd update` to the note is the orchestrating session's call, not this
   research stage's.

   **Settled (2026-08-19):** corrected on the bead by a dated `bd note` during
   the research stage. Headroom was 2.8 before this bead's Phase 2 and is 2.47
   after it.

6. **What context width should a site-B fixture use?** The older convention is
   `--unified=0` and the re-anchored ADR-0012 fixtures use `--unified=3`. A
   `Trace.Done` pair needs roughly `--unified=10` for both trace calls to be
   visible, which no existing fixture uses. *Assumption*: widening context is a
   permitted authoring choice, since nothing validates hunk width and the
   fixtures need not apply - but it is untested at this repository and worth a
   plan phase's explicit check.

   **Settled (2026-08-19):** `--unified=14`, chosen empirically (widths 3 and 10
   split the violation edit into two hunks with `Trace.Done` partly hidden; 14
   yields one hunk carrying both trace calls). Sufficient, not minimal - 11-13
   were never tried. **This choice is now a live suspect** rather than a settled
   detail: it is one of the three surviving explanations for the row's unanimous
   miss, and the only one this bead introduced.
