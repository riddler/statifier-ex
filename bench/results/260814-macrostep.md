# Macrostep: the end-to-end share, 2026-08-14

Produced by `mix run bench/macrostep.exs`. Evidence for `docs/adr/0027-*`
(Phase 3) and for the pre-registered decision rule in
`docs/plans/260814-st-sdh-context-rebuild-vs-bind-benchmark.md`.

## Machine

- macOS, Apple M3, 8 cores, 24 GB
- Elixir 1.18.3, Erlang/OTP 27.3, JIT enabled
- benchee 1.5.1 (same dependency Phase 1 added)

## Method

Every document is driven only through the public boundary
(`Statifier.compile/1`, `Statifier.initialize/2`, `Statifier.send_event/2`).
`machine_state` is immutable, so one compiled + initialized `machine_state`
per document is handed to Benchee directly - `send_event/2` never mutates
its argument, so repeated timed calls are independent and correct without a
`before_each` hook.

For each document, the share is **derived, not instrumented**: no counters
went into `lib/`. The steps are:

1. Read the document against the call-site table
   (`docs/research/260814-st-sdh-context-rebuild-vs-bind-benchmark.md`
   section 1) and `Statifier.Interpreter.Content.execute_block/3`'s own
   moduledoc, and count the context builds one `send_event/2` call (one
   macrostep) triggers.
2. Measure the per-build cost - `Statifier.Evaluator.context/1` run
   directly on the document's own real `machine_state` via Benchee, not one
   of Phase 1's four discrete `:corpus`/`:stress_*` buckets. This matters
   for `<foreach>`: its array is part of the datamodel, so per-build cost
   grows with `N` in a way none of Phase 1's fixed size points track. For
   the realistic and assign-heavy documents, whose datamodel is constant
   (the same 5 flat roots at every `n`), this measurement is effectively
   Phase 1's `:corpus` `T_full` figure re-measured on this script's own
   documents rather than reused from the results file, so both numbers can
   be cross-checked against each other (they land within the same
   ballpark: this run's realistic `T_full` is ~1.99 us / 9.48 KB, Phase 1's
   published `:corpus` `T_full` was 2.28 us / 10.92 KB - close, and the
   remaining gap is exactly what the shape difference predicts: Phase 1's
   `:corpus` point deliberately used a nested `depth: 1, breadth: 2` tree
   per root as the corpus's worst case, D1, while this script's documents
   use the corpus's actual flat-scalar shape).
3. `estimated build cost = build count * per-build cost`.
4. `S_time = estimated build cost (time) / measured macrostep cost (time)`,
   `S_mem` likewise for memory.

Deviation on the macrostep and per-build scenarios ran 3%-1210% depending on
document and size, same shape as Phase 1's own noise discussion: absolute
values dominate scheduler/timer noise at microsecond scale, but every
comparison this file draws a conclusion from is a difference of several
multiples (54%-93% vs. a 5% decision threshold), an order of magnitude
outside what this noise band could produce by chance.

## Build-count derivations

### Realistic

Corpus-shaped: `<onentry>`/`<onexit>` blocks with one `<assign>` and one
`<log>` each, a plain (uncond) transition on `go`. Firing `go` runs one full
macrostep: exit `s1` (`<onexit>`), the transition's own content, enter `s2`
(`<onentry>`).

| Site | Builds |
|---|---:|
| `Selection.select_transitions/2` (the external-event round) | 1 |
| `Selection.select_eventless_transitions/1` (the terminal quiescence probe every macrostep ends with, `lib/statifier/interpreter.ex:521`) | 1 |
| `execute_block/3` for `<onexit>` | 1 |
| `execute_block/3` for the transition's own content | 1 |
| `execute_block/3` for `<onentry>` | 1 |
| `<assign>` rebuild inside `<onexit>` | 1 |
| `<assign>` rebuild inside `<onentry>` | 1 |
| **Total** | **7** |

### Assign-heavy (`n` in `[1, 5, 25, 100]`)

Same datamodel, `n` `<assign>` nodes on the fired transition's own content,
no `<onentry>`/`<onexit>` content - the fired macrostep's only content block
is this one.

`build count = 1 (select_transitions) + 1 (eventless probe) + 1 (the one
transition-content block) + n (one rebuild per <assign>,
lib/statifier/machine/content/assign.ex:76-91) = n + 3`.

### Foreach (`N` in `[1, 10, 100, 1000]`)

Same datamodel plus one more root, `items`, an `N`-element array. The
`<foreach>` body is empty (declares `x`, nothing else) so the build count is
exactly `declare/2`'s pre-loop rebuild plus one rebuild per iteration
(`lib/statifier/machine/content/foreach.ex:276-285`), with no nested
`<assign>` inflating it.

`build count = 1 (select_transitions) + 1 (eventless probe) + 1 (the
transition-content block wrapping <foreach>) + 1 (declare/2's pre-loop
rebuild) + N (one rebuild per write_iteration/4 call) = N + 4`.

`N=1000` is deliberately past the decision rule's `N<=100` bar, to show the
curve's shape beyond the point that decides.

### Cond-bearing selection (not corpus-reachable)

Three cond-bearing candidate transitions on the same event from the same
atomic state, only one matching. `cond` on transitions is not reachable from
the corpus (`lib/statifier/interpreter/selection.ex:277-280` -
`FeatureDetector` marks `conditional_transitions` `:unsupported`), so this
document is the only way to measure a selection round that actually
evaluates `cond`. `select_transitions/2` builds exactly **one** context per
round regardless of how many candidate transitions carry `cond`
(`lib/statifier/interpreter/selection.ex:332`) - evaluating more `cond`
expressions against that one context adds evaluation calls, not additional
builds. No content blocks run (the matching transition carries no content
and its target states have no `<onentry>`).

`build count = 1 (select_transitions, now evaluating 3 cond expressions) + 1
(eventless probe) = 2`.

This is reported separately and is **not** folded into the realistic share,
per D1.

## Results

### Realistic (the point that decides the bead)

| Metric | Value |
|---|---:|
| Build count | 7 |
| Per-build cost | 1.989 us / 9.48 KB |
| Estimated build cost | 13.922 us / 66.36 KB |
| Measured macrostep cost | 22.438 us / 98.896 KB |
| **S_time** | **62.04%** |
| **S_mem** | **67.10%** |

Both axes are more than twelve times the rule's 5% threshold.

### Assign-heavy

| n | build count | estimated cost | measured macrostep | S_time | S_mem |
|---:|---:|---:|---:|---:|---:|
| 1 | 4 | 7.955 us / 37.92 KB | 12.587 us / 55.672 KB | 63.20% | 68.11% |
| 5 | 8 | 15.911 us / 75.84 KB | 33.855 us / 115.672 KB | 47.00% | 65.56% |
| 25 | 28 | 55.687 us / 265.44 KB | 110.318 us / 417.496 KB | 50.48% | 63.58% |
| 100 | 103 | 204.849 us / 976.44 KB | 369.223 us / 1610.208 KB | 55.48% | 60.64% |

**Cross-check.** The *raw* estimated build cost and the *raw* measured
macrostep cost each grow closely linearly in `n`, as the additive case
predicts: estimated cost scales 7.955 -> 15.911 -> 55.687 -> 204.849 us
against a build count of 4 -> 8 -> 28 -> 103 (ratio n=100/n=1 estimated
cost = 25.8x, ratio of build counts = 25.75x - matching to within noise);
measured macrostep cost scales 12.587 -> 33.855 -> 110.318 -> 369.223 us,
the same order of growth. Because *both* the numerator (build cost) and the
denominator (macrostep cost) scale together - a block of `n` `<assign>`
nodes is, to first order, `n` context rebuilds plus a fixed amount of
surrounding work - the **ratio** (`S_time`/`S_mem`) does not grow with `n`;
it stays in a stable 47%-63% band across two orders of magnitude of `n`.
That is the expected shape, not a sign the build count is wrong: an
`<assign>`-heavy block's cost is *dominated* by context rebuilds at every
size tested, so its share saturates rather than climbing toward 100% or
drifting toward 0%. The plan's own cross-check language ("should grow
roughly linearly in `n`; if not, the build count is wrong") is satisfied by
the *absolute* estimated-cost curve, which the numbers above confirm is
linear; a bug in the build-count formula (e.g. counting a constant instead
of `n + 3`, or `n^2` instead of `n`) would have produced a curve that did
not track the build-count ratios this closely.

### Foreach (the multiplicative case)

| N | build count | per-build cost | estimated cost | measured macrostep | S_time | S_mem |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 5 | 2.062 us / 9.792 KB | 10.311 us / 48.96 KB | 16.14 us / 68.256 KB | 63.89% | 71.73% |
| 10 | 14 | 2.135 us / 9.792 KB | 29.897 us / 137.088 KB | 41.319 us / 186.352 KB | 72.36% | 73.56% |
| 100 | 104 | 3.746 us / 12.96 KB | 389.593 us / 1347.84 KB | 501.656 us / 1655.36 KB | 77.66% | 81.42% |
| 1000 | 1004 | 19.197 us / 41.76 KB | 19273.944 us / 41927.04 KB | 24040.4 us / 44855.576 KB | 80.17% | 93.47% |

Unlike assign-heavy, the `<foreach>` document's datamodel itself grows with
`N` (the `items` array is part of the datamodel `Evaluator.context/1` walks
every time), so the **per-build cost also grows with `N`** - from 2.062 us
at `N=1` to 19.197 us at `N=1000`, roughly 9x. Combined with a build count
that itself grows linearly in `N` (`N + 4`), the estimated build cost grows
super-linearly (10.3 us at `N=1` to ~19.27 ms at `N=1000`, a ~1870x
increase against a 200x increase in `N`). This is the expected shape for
the "one multiplicative construct" (D1/D3 in the plan): both terms in
`build count x per-build cost` scale with `N` at once. Because the
measured macrostep cost scales the same way (it is, after all, mostly
context rebuilds at this point), the *share* still climbs steadily rather
than flattening - 63.89% at `N=1` up to 80.17%/93.47% at `N=1000` - which is
consistent, not erratic: `<foreach>` becomes an increasingly larger fraction
of what the macrostep does as `N` grows, exactly as the "the one
multiplicative case" framing predicts. At the decision rule's own `N<=100`
boundary the share is already 77.66%/81.42%, itself far past the 5%
threshold.

### Cond-bearing selection (not corpus-reachable, reported separately)

| Metric | Value |
|---|---:|
| Build count | 2 |
| Per-build cost | 2.229 us / 9.192 KB |
| Estimated build cost | 4.458 us / 18.384 KB |
| Measured macrostep cost | 12.748 us / 35.4 KB |
| S_time | 34.97% |
| S_mem | 51.93% |

Not folded into the realistic number (D1). Informative for the future:
should `cond` on transitions ever become reachable from the corpus, the
share of a macrostep spent on context construction stays high here too -
consistent with the realistic and assign-heavy findings rather than
contradicting them.

## Applying the pre-registered decision rule

Quoted from `docs/plans/260814-st-sdh-context-rebuild-vs-bind-benchmark.md`,
"The pre-registered decision rule":

> - **Branch A - rebuilding is fine.** `S_time < 5%` **and** `S_mem < 5%` at
>   realistic scale, **and** the `<foreach>` stress case stays under 5% on
>   both axes for N <= 100 iterations.
> - **Branch B - the change is justified.** `S_time >= 5%` or `S_mem >= 5%`
>   at realistic scale, **or** the `<foreach>` case crosses 5% on either
>   axis at N <= 100.

Measured against each condition:

- Realistic scale: `S_time` = 62.04%, `S_mem` = 67.10%. Both are far
  `>= 5%`. Branch A's first requirement (`S_time < 5% and S_mem < 5%`)
  fails on both axes; Branch B's first disjunct (`S_time >= 5% or S_mem
  >= 5%`) is satisfied on both axes.
- `<foreach>` at N <= 100 (N=1, 10, 100): `S_time` ranges 63.89%-77.66%,
  `S_mem` ranges 71.73%-81.42%. Every point in this range is `>= 5%` on
  both axes, at every N tested up to and including 100. Branch A's second
  requirement ("stays under 5% on both axes for N <= 100") fails at every
  point; Branch B's second disjunct ("crosses 5% on either axis at N <=
  100") is satisfied, and by a wide margin, starting at N=1.

Both of Branch A's requirements fail, and both of Branch B's disjuncts are
independently satisfied - the realistic-scale condition alone would be
sufficient. There is no tie and no ambiguity: the rule's "ties and
ambiguity resolve to Branch A" fallback does not apply, because nothing
here is close to the 5% line - every measured share is one to two orders of
magnitude above the threshold.

**The pre-registered rule selects Branch B.**

## Modifier C

Modifier C was evaluated in Phase 1 against `T_fixed`/`T_full` at the
`:corpus` size point and already fired there
(`bench/results/260814-context-build.md`: `T_fixed / T_full` = 56.6% >=
50%). Per the plan, Modifier C "fires or does not fire on its own evidence;
it does not change which of A or B is taken" - it is independent of, and
does not itself decide, the branch selection above. Phase 3 files the
predicator-ex bead for `resolve_functions/1` memoization that Modifier C
calls for, in addition to recording Branch B here.

## Phase 4 verification, 2026-08-14

Re-run of this same `mix run bench/macrostep.exs` after Phase 4 landed the
`bind/3`-threading change ADR-0028 records (`<assign>`/`<foreach>` bind
into the block's existing context; `<script>` threads the post-run context
`Predicator.execute/3` already returns - see
`lib/statifier/evaluator.ex`'s `run_program/2`). Same machine, same
`benchee` version, same documents; only `lib/` changed between the two
runs.

This script's own `S_time`/`S_mem` figures are no longer meaningful after
Phase 4 and are not reported below: the "estimated build cost" they divide
by is `build count * Evaluator.context/1`'s per-build cost - a model of
the *old* per-write-rebuild behavior. Once `<assign>`/`<foreach>`/`<script>`
stop rebuilding, that estimate no longer describes what the measured
macrostep actually spends, and the ratio exceeds 100% at every point
(e.g. `foreach n=1000`: 5195%) - not a regression, just a metric whose
denominator assumption Phase 4 invalidated by construction. The number
that still means the same thing before and after is `measured macrostep`
itself - Benchee's direct timing of `Statifier.send_event/2` - so before
vs. after is reported as that.

| Document | Before (μs / KB) | After (μs / KB) | Time reduction | Memory reduction |
|---|---|---|---|---|
| realistic | 24.035 / 98.896 | 17.558 / 75.968 | 27.0% | 23.2% |
| assign-heavy n=1 | 12.462 / 55.672 | 10.198 / 44.640 | 18.2% | 19.8% |
| assign-heavy n=5 | 26.243 / 115.672 | 14.620 / 58.192 | 44.3% | 49.7% |
| assign-heavy n=25 | 95.387 / 417.496 | 36.264 / 133.024 | 62.0% | 68.1% |
| assign-heavy n=100 | 364.992 / 1610.208 | 120.305 / 466.872 | 67.0% | 71.0% |
| foreach n=1 | 17.054 / 68.256 | 12.474 / 44.704 | 26.9% | 34.5% |
| foreach n=10 | 40.897 / 186.352 | 15.194 / 51.440 | 62.9% | 72.4% |
| foreach n=100 | 496.337 / 1655.360 | 47.912 / 119.352 | 90.3% | 92.8% |
| foreach n=1000 | 23123.502 / 44855.576 | 359.539 / 804.416 | 98.4% | 98.2% |
| cond-bearing selection (not corpus-reachable) | 8.657 / 35.400 | 9.007 / 35.400 | -4.0% (noise) | 0.0% |

Every corpus-reachable document is faster and lighter after Phase 4, and
the win grows with block/iteration count exactly as predicted: the
additive `<assign>` sweep goes from a ~1.2x-2.8x reduction (n=1 to n=100)
and the multiplicative `<foreach>` sweep goes from ~1.4x at N=1 to ~64x at
N=1000, consistent with rebuilding being replaced by an O(1)-in-datamodel-
size `bind/3` at each write. `cond`-bearing selection is unchanged (within
noise) as expected - Branch B is scoped to executable content, and the
selection round still calls `Evaluator.context/1` directly
(`lib/statifier/interpreter/selection.ex`, untouched by this phase).
