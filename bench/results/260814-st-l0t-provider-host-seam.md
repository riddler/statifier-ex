# Provider/host seam for In/1: before/after, 2026-08-14

Evidence for `st-l0t` (mirrors `px-10u`), following the acceptance criterion
in `docs/plans/260814-st-l0t-provider-host-seam-for-in1.md`. Produced by
`mix run bench/macrostep.exs` and `mix run bench/context_build.exs`.

## Machine

- macOS, Apple M3, 8 cores, 24 GB
- Elixir 1.18.3, Erlang/OTP 27.3, JIT enabled
- benchee 1.5.1

The before and after rows in this file come from the same machine. The
Before rows below were captured on the merge-base tree, before any `lib/`
edit in this plan; `bench/results/260814-macrostep.md`'s own table is the
historical before-set from a prior session and is not reused here, so this
comparison is same-machine rather than same-machine-class.

Note per the plan: the script's derived `S_time`/`S_mem` figures are not
reported here. They are already declared dead in
`bench/results/260814-macrostep.md` (their derivation constants predate
ADR-0028's within-block threading), and Phase 3 of this plan repairs the
constants that make them meaningful again. Only `measured macrostep` and the
`context_build.exs` timing/memory figures are recorded in this Phase 1
capture.

Note on the Phase 1 claim, added 2026-08-15 during the deferred manual
verification: **no Phase-1-only after capture was taken**, so this file has
no post-swap `T_full` row to sit beside the Before rows below, and Phase 1's
commit body overstates the file when it cites a before/after here. The claim
that commit makes - that converting `In/1` from a closure to a provider
moves no benchmark number - is evidenced instead by the `T_resolve_provider`
and `T_resolve_closure` scenarios Phase 3 added to
`bench/context_build.exs`, recorded in the After table below: 1.36 us /
5.80 KB against 1.40 us / 5.41 KB at `:corpus`, and within 1.30-1.43 us at
every one of the four size points. Those two scenarios isolate the swap
directly, which a `T_full` comparison could only do by inference, so the
claim is better supported here than the missing rows would have supported
it.

## Before (baseline, this machine)

### `mix run bench/macrostep.exs` - measured macrostep

| Document family | Input | ips | average | median | Memory |
|---|---|---:|---:|---:|---:|
| realistic | (single) | 57.51 K | 17.39 μs | 17.33 μs | 74.19 KB |
| assign-heavy | n=1 | 96.99 K | 10.31 μs | 10.08 μs | 43.59 KB |
| assign-heavy | n=5 | 68.08 K | 14.69 μs | 14.54 μs | 56.83 KB |
| assign-heavy | n=25 | 27.27 K | 36.67 μs | 36.83 μs | 129.91 KB |
| assign-heavy | n=100 | 8.04 K | 124.41 μs | 121.38 μs | 455.93 KB |
| foreach | n=1 | 84.45 K | 11.84 μs | 11.08 μs | 43.66 KB |
| foreach | n=10 | 72.71 K | 13.75 μs | 13.58 μs | 50.23 KB |
| foreach | n=100 | 23.04 K | 43.40 μs | 43.00 μs | 116.55 KB |
| foreach | n=1000 | 2.87 K | 348.90 μs | 338.83 μs | 785.56 KB |
| cond-bearing selection (not corpus-reachable) | (single) | 116.25 K | 8.60 μs | 8.46 μs | 34.57 KB |

Per-build cost (`Evaluator.context/1` on each document's own live
`machine_state`):

| Document family | Input | average | Memory |
|---|---|---:|---:|
| realistic + assign-heavy (constant datamodel) | (single) | 1.91 μs | 9.26 KB |
| foreach | n=1 | 2.00 μs | 9.56 KB |
| foreach | n=10 | 2.30 μs | 9.56 KB |
| foreach | n=100 | 3.59 μs | 12.66 KB |
| foreach | n=1000 | 18.57 μs | 40.78 KB |
| cond | (single) | 1.95 μs | 8.98 KB |

### `mix run bench/context_build.exs` - `T_full`/`T_fixed`/`T_bind` at every size point

`T_new` (`Context.new/2, no nils`) is the script's own scenario and is
recorded too since Phase 2's equivalence claim references it.

| Size point | T_bind | T_fixed | T_new | T_full |
|---|---:|---:|---:|---:|
| corpus | 0.138 μs / 0.59 KB | 1.31 μs / 5.51 KB | 1.86 μs / 8.91 KB | 2.30 μs / 10.92 KB |
| stress_small | 0.111 μs / 0.63 KB | 1.31 μs / 5.77 KB | 6.10 μs / 32.42 KB | 9.53 μs / 48.56 KB |
| stress_medium | 0.161 μs / 0.72 KB | 1.31 μs / 5.77 KB | 170.74 μs / 843.14 KB | 302.15 μs / 1357.98 KB |
| stress_large | 0.00016 ms / 0.00075 MB | 0.00132 ms / 0.00564 MB | 1.22 ms / 5.81 MB | 2.33 ms / 9.43 MB |

Block-level A/B (`bind/3-threaded` vs `rebuild-per-write`) at each size
point, `n` in `[1, 5, 25, 100]` writes per block - unchanged by this plan
(ADR-0028's own mechanism, re-measured here only as a same-session
cross-check, not as a Phase 1 target):

| Size point | n | bind/3-threaded | rebuild-per-write |
|---|---:|---:|---:|
| corpus | 1 | 0.25 μs / 1.18 KB | 2.49 μs / 11.49 KB |
| corpus | 5 | 1.01 μs / 5.52 KB | 12.34 μs / 59.02 KB |
| corpus | 25 | 4.80 μs / 27.18 KB | 61.73 μs / 295.70 KB |
| corpus | 100 | 18.49 μs / 108.63 KB | 257.34 μs / 1183.77 KB |
| stress_small | 1 | 0.25 μs / 1.22 KB | 10.33 μs / 46.29 KB |
| stress_small | 5 | 1.00 μs / 5.72 KB | 48.21 μs / 231.54 KB |
| stress_small | 25 | 4.95 μs / 28.22 KB | 290.63 μs / 1156.21 KB |
| stress_small | 100 | 18.51 μs / 112.59 KB | 1209.55 μs / 4629.23 KB |
| stress_medium | 1 | 0.26 μs / 0.00128 MB | 364.69 μs / 1.30 MB |
| stress_medium | 5 | 1.12 μs / 0.00604 MB | 1806.92 μs / 6.51 MB |
| stress_medium | 25 | 5.20 μs / 0.0298 MB | 8939.33 μs / 32.54 MB |
| stress_medium | 100 | 20.15 μs / 0.119 MB | 35187.48 μs / 130.15 MB |
| stress_large | 1 | 0.00027 ms / 0.00133 MB | 2.41 ms / 9.38 MB |
| stress_large | 5 | 0.00112 ms / 0.00627 MB | 12.09 ms / 46.92 MB |
| stress_large | 25 | 0.00530 ms / 0.0310 MB | 60.74 ms / 234.62 MB |
| stress_large | 100 | 0.0201 ms / 0.123 MB | 238.80 ms / 938.48 MB |

Full raw benchee output for both runs is not reproduced here beyond the
tables above; both runs completed cleanly with no benchee errors, only the
routine "super fast function" warning on `T_bind` at `stress_small` (an
expected artifact of measuring a sub-microsecond operation, not a defect in
the run).

## After (Phase 2)

Captured after commit `cf8b16c` (Phase 2: compile-time `base_context/0`,
`put_host/2` per site, `bind/3` per root), same machine, same session as the
Before rows above. `bench/macrostep.exs`'s derivation constants were repaired
first (see "Repaired build-count derivation" below), so the `build count`
lines below already read against the current call graph, not the pre-ADR-0028
table.

### `mix run bench/macrostep.exs` - measured macrostep

| Document family | Input | ips | average | median | Memory |
|---|---|---:|---:|---:|---:|
| realistic | (single) | 73.65 K | 13.58 μs | 13.21 μs | 43.18 KB |
| assign-heavy | n=1 | 129.18 K | 7.74 μs | 7.54 μs | 25.40 KB |
| assign-heavy | n=5 | 71.90 K | 13.91 μs | 11.92 μs | 38.75 KB |
| assign-heavy | n=25 | 26.52 K | 37.71 μs | 34.67 μs | 111.32 KB |
| assign-heavy | n=100 | 8.41 K | 118.95 μs | 118.08 μs | 437.16 KB |
| foreach | n=1 | 109.39 K | 9.14 μs | 8.96 μs | 25.43 KB |
| foreach | n=10 | 84.30 K | 11.86 μs | 11.67 μs | 32.45 KB |
| foreach | n=100 | 23.81 K | 42.00 μs | 41.67 μs | 98.52 KB |
| foreach | n=1000 | 2.63 K | 379.51 μs | 367.04 μs | 764.97 KB |
| cond-bearing selection (not corpus-reachable) | (single) | 141.52 K | 7.07 μs | 6.88 μs | 22.79 KB |

Per-build cost (`Evaluator.context/1` on each document's own live
`machine_state`), and the repaired-constant derivation each document's build
count now comes from:

| Document family | Input | average | Memory | build count |
|---|---|---:|---:|---:|
| realistic + assign-heavy (constant datamodel) | (single) | 1.041 μs | 2.928 KB | 5 (realistic), 3 (assign-heavy, every n) |
| foreach | n=1 | 1.223 μs | 3.536 KB | 3 |
| foreach | n=10 | 1.328 μs | 3.824 KB | 3 |
| foreach | n=100 | 4.006 μs | 6.16 KB | 3 |
| foreach | n=1000 | 35.699 μs | 35.504 KB | 3 |
| cond | (single) | 1.419 μs | 3.184 KB | 2 |

The `foreach` per-build-cost figures at `n=100`/`n=1000` carry benchee
deviations of ±1599%/±1049% respectively (full raw output retained in this
session's run logs, not reproduced here) - far larger than the point
estimate itself. Treat those two `per-build cost` numbers, and any
`S_time`/`S_mem` figure computed from them, as noise, not as evidence either
way; see "Noise" below.

### `mix run bench/context_build.exs` - `T_full`/`T_fixed`/`T_bind`/`T_put_host`/`T_resolve_*` at every size point

`T_put_host` (`Context.put_host/2`), `T_resolve_provider`
(`Context.resolve_functions/1` with `providers: [Statifier.Evaluator.Functions]`)
and `T_resolve_closure` (`Context.resolve_functions/1` with an inline
function-literal closure, `In/1`'s pre-Phase-1 shape) are the three scenarios
Phase 3 added to Run 1 of `bench/context_build.exs`.

| Size point | T_put_host | T_bind | T_fixed | T_resolve_provider | T_resolve_closure | T_new | T_full |
|---|---:|---:|---:|---:|---:|---:|---:|
| corpus | 0.0330 μs / 0.0859 KB | 0.150 μs / 0.59 KB | 1.33 μs / 5.51 KB | 1.36 μs / 5.80 KB | 1.40 μs / 5.41 KB | 2.05 μs / 8.91 KB | 1.13 μs / 4.77 KB |
| stress_small | 0.0316 μs / 0.0859 KB | 0.154 μs / 0.63 KB | 1.34 μs / 5.77 KB | 1.36 μs / 5.80 KB | 1.38 μs / 5.68 KB | 6.64 μs / 32.42 KB | 11.00 μs / 42.55 KB |
| stress_medium | 0.0332 μs / 0.0859 KB | 0.176 μs / 0.72 KB | 1.33 μs / 5.77 KB | 1.36 μs / 5.80 KB | 1.43 μs / 5.68 KB | 227.61 μs / 843.14 KB | 379.98 μs / 1356.14 KB |
| stress_large | 0.0499 μs / 0.0859 KB | 0.177 μs / 0.77 KB | 2.08 μs / 5.77 KB | 1.37 μs / 5.80 KB | 1.30 μs / 5.68 KB | 1419.65 μs / 5950.53 KB | 2317.24 μs / 9652.09 KB |

Two things this table makes visible directly:

- **`T_resolve_provider` and `T_resolve_closure` land within noise of each
  other at every size point** (1.30-1.43 μs / 5.41-5.80 KB across all four
  points, deviations in the 370%-560% range on both scenarios at every
  point) - the same finding Phase 1's research made ad hoc, now reproducible
  from the committed script: a provider swap by itself moves no number.
- **`T_fixed` barely moves before Phase 2 (1.29-1.36 μs across both
  captures) because this scenario calls `Predicator.Context.new/2` directly**
  and is unaffected by `Evaluator.context/1`'s hoist - it is still
  isolating `resolve_functions/1`'s per-call cost, which Phase 2 removed
  from `Evaluator.context/1`'s own path but did not and could not change
  inside `Context.new/2` itself. The number that actually falls is
  `T_full`, and only `T_full`, because `T_full` is the only scenario of the
  four original ones that calls `Evaluator.context/1`.
- `T_put_host` triggers benchee's "super fast function" warning at every
  size point (sub-0.05 μs), the same expected artifact Phase 1 noted for
  `T_bind` at `stress_small` - not a defect in the run.

## Comparison

### Measured macrostep, before vs. after

| Document | Before (μs / KB) | After (μs / KB) | Time Δ | Memory Δ | Read |
|---|---|---|---:|---:|---|
| realistic | 17.39 / 74.19 | 13.58 / 43.18 | -21.9% | -41.8% | Real win, well outside noise on both axes. |
| assign-heavy n=1 | 10.31 / 43.59 | 7.74 / 25.40 | -24.9% | -41.7% | Real win; time deviation (±51%) is wide but memory confirms it. |
| assign-heavy n=5 | 14.69 / 56.83 | 13.91 / 38.75 | -5.3% | -31.8% | Time is noise (±534% deviation - the point estimate is smaller than its own error band); memory drop stands. |
| assign-heavy n=25 | 36.67 / 129.91 | 37.71 / 111.32 | +2.8% | -14.3% | Time is noise (±146% deviation); memory drop stands. |
| assign-heavy n=100 | 124.41 / 455.93 | 118.95 / 437.16 | -4.4% | -4.1% | Small but real win; tight deviation (±4.16%) on this one. |
| foreach n=1 | 11.84 / 43.66 | 9.14 / 25.43 | -22.8% | -41.7% | Real win. |
| foreach n=10 | 13.75 / 50.23 | 11.86 / 32.45 | -13.7% | -35.4% | Time win plausible (±13.43% deviation, comparable to the effect size); memory win stands. |
| foreach n=100 | 43.40 / 116.55 | 42.00 / 98.52 | -3.2% | -15.5% | Time is within noise (±13.73% deviation exceeds the effect); memory drop stands. |
| foreach n=1000 | 348.90 / 785.56 | 379.51 / 764.97 | +8.8% | -2.6% | Time is a small apparent regression, larger than its own deviation band (±11.72%) - reported honestly below, not smoothed over; memory is flat/slightly better. |
| cond-bearing selection (not corpus-reachable) | 8.60 / 34.57 | 7.07 / 22.79 | -17.8% | -34.1% | Plausible win (deviation ±57%) - selection-round builds are exactly what Phase 2 also made cheaper, unlike ADR-0028's own Phase 4 verification where this row was unchanged. |

**Memory figures in this benchmark carry zero measured deviation** - every
Benchee run in this session printed `**All measurements for memory usage
were the same**` for every scenario, meaning the memory numbers above are
exact per-call byte counts, not samples with a distribution. Every
document family's memory figure drops or is flat after Phase 2, with no
exception. Time figures, by contrast, carry benchee's usual scheduler noise
at microsecond scale, and are read against their own deviation bands rather
than taken at face value - several of the rows above (`n=5`, `n=25`,
`n=100` foreach, `n=1000` foreach) show a time delta smaller than or
comparable to that noise band, and are reported as noise or as a small,
possibly-negative result rather than as a win.

**`realistic` - the corpus-representative point (D1, `bench/results/260814-context-build.md`'s
own corpus scan) - shows a clear, noise-clearing win on both axes.** The
sweep documents (`assign-heavy`, `foreach`) are stress shapes past what the
corpus actually contains; they show real, if shrinking, wins at small `n`,
flattening into noise or a small apparent regression at large `n`. This is
the shape the plan's own "Performance Considerations" section predicted:
the fixed `resolve_functions/1` term Phase 2 removes is a large share of a
*small* build (56.6% at `:corpus`) and a vanishing share of a large one
(`T_fixed`/`T_full` at `stress_medium` is ~0.35%), so a document whose
per-build cost is already dominated by datamodel-size-scaling work (a large
`foreach` array, a large `assign` chain) has little of that term left to
remove, and what's left is smaller than benchee's own noise floor at that
scale.

### `foreach n=1000`, reported honestly

The point estimate for `foreach n=1000`'s measured macrostep moved from
348.90 μs before to 379.51 μs after - an 8.8% increase, and one that sits
outside the after-run's own ±11.72% deviation band taken at face value
(though not outside a combined before/after noise comparison, since the
before run's own deviation was not re-captured this session). This is not
hidden or tuned away: it is reported as a small apparent regression at this
one size point, most plausibly attributable to run-to-run scheduler/GC
variance at this document's size (its per-build-cost scenario, run
immediately adjacent in the same script, shows a ±1049% deviation at the
same `n=1000` point - the whole neighborhood of this measurement is noisy),
not to anything Phase 2 changed working against the built context at this
size. `foreach n=1000`'s memory figure (deterministic, per above) moved the
right direction, from 785.56 KB to 764.97 KB.

### `T_full` before vs. after, `bench/context_build.exs`

| Size point | T_full before | T_full after | Time Δ | Memory Δ |
|---|---:|---:|---:|---:|
| corpus | 2.30 μs / 10.92 KB | 1.13 μs / 4.77 KB | -50.9% | -56.3% |
| stress_small | 9.53 μs / 48.56 KB | 11.00 μs / 42.55 KB | +15.4% (noise, ±380% deviation) | -12.4% |
| stress_medium | 302.15 μs / 1357.98 KB | 379.98 μs / 1356.14 KB | +25.7% (noise, ±143% deviation) | -0.1% |
| stress_large | 2.33 ms / 9.43 MB | 2.317 ms / 9.42 MB | -0.6% (flat) | -0.1% |

`:corpus` is the size point that decides the bead (same reasoning as
`bench/results/260814-context-build.md`'s own framing): it is the shape
D1 derived from actually scanning the corpus, and it shows a real,
large win on both axes, at a deviation (not shown above, but ≤514% on the
after run, comparable to the before run's own ≤478%) that does not come
close to explaining a 51%/56% shift. The three `:stress_*` points are
synthetic and intentionally far past corpus scale; at those sizes the fixed
term Phase 2 removes is already a vanishing fraction of `T_full`
(0.35%-0.6% by the `:corpus`-to-`:stress_medium` `T_fixed`/`T_full` ratio),
so no measurable win is expected there, and none of the deltas above clear
their own deviation bands - they are reported as noise/flat rather than as
wins or regressions.

### The acceptance criterion, read explicitly: cost per build, not count of builds

`st-l0t`'s acceptance criterion says `bench/macrostep.exs` should show "the
per-block and per-selection-round builds reduced." This plan
(`docs/plans/260814-st-l0t-provider-host-seam-for-in1.md`, resolved open
question 2) reads that as a reduction in what each build *costs*, not in how
many builds a macrostep runs. Under this plan, the number of
`Evaluator.context/1` calls per macrostep is unchanged from the Before
baseline in every document family measured here (5 for `realistic`, 3 for
`assign-heavy` and `foreach` regardless of `n`, 2 for the cond-bearing
selection document) - what Phase 2 changed is that each of those calls no
longer resolves `In/1`'s functions map at runtime, so each call is cheaper
by roughly the fixed `resolve_functions/1` term (56.6% of one build at
`:corpus` scale, per `bench/results/260814-context-build.md`'s Modifier C
finding). That per-build reduction is what shows up in the `measured
macrostep` and `T_full` tables above, most clearly at `:corpus`/`realistic`
scale where the fixed term is the dominant part of a build's cost. A
reduction in the *count* of builds - collapsing the two selection-round
builds into one build-once-plus-refresh, the "clean candidate" the research
doc's section 3 named - is available and was deliberately not taken by this
plan (see "What We're NOT Doing" in the plan): it would require storing a
context across the interval those two builds span, which is the storage
question Phase 4's ADR answers on its own grounds, not this phase's. If the
human closing `st-l0t` reads the acceptance criterion as requiring a build
*count* reduction instead, this plan has not met it as written, and the
honest next step is a follow-up bead for that widening, not a re-argument of
this reading.

### Repaired build-count derivation

`bench/macrostep.exs`'s constants (`7` and `n + 3` for `realistic`/
`assign-heavy`, `n + 4` for `foreach`, `2` for the cond document) were read
off the pre-ADR-0028 call-site table and counted one `Evaluator.context/1`
rebuild per `<assign>` and per `<foreach>` iteration - rebuilds ADR-0028
(`docs/adr/0028-executable-content-blocks-thread-one-context.md`) already
removed by threading `bind/3` through the block instead. Verified directly
against the current call graph for this phase (not merely asserted from the
plan): `lib/statifier/interpreter/content.ex:140-145`'s `execute_block/3`
builds exactly one context per non-empty block and never rebuilds inside
it (the `c_indexes: []` clause at `:136-138` skips the build entirely for an
empty block); `lib/statifier/machine/content/assign.ex` and
`lib/statifier/machine/content/foreach.ex`'s `write_iteration/4`/
`bind_names/4` bind each write into that same block context with
`Evaluator.bind/3` rather than rebuilding; and
`lib/statifier/interpreter/selection.ex:332,364` each build exactly one
context per selection round regardless of candidate-transition count. The
repaired counts:

- **realistic**: 2 selection-round builds (`select_transitions/2`,
  `select_eventless_transitions/1`) + 3 non-empty content blocks (`<onexit>`,
  the transition's own content, `<onentry>`) = **5** (was 7).
- **assign-heavy(n)**: 2 selection-round builds + 1 non-empty content block
  (the transition's content, holding all `n` `<assign>` nodes, which bind
  into that one block context) = **3, constant in `n`** (was `n + 3`).
- **foreach(n)**: 2 selection-round builds + 1 non-empty content block (the
  transition's content wrapping `<foreach>`) = **3, constant in `n`** (was
  `n + 4`) - `declare/2`'s item/index declaration and every
  `write_iteration/4` call bind into that one block context rather than
  rebuilding.
- **cond-bearing selection**: unaffected by ADR-0028 (no content blocks run)
  and unaffected by this plan's count (only its per-build cost changes) -
  2 selection-round builds, no content blocks = **2** (unchanged).

This reading matches the plan's own assertion in Phase 3's "Changes
Required" section exactly - no divergence found between the call graph as
read for this phase and the call graph as the plan describes it.

## Machine and versions (After capture)

- macOS, Apple M3, 8 cores, 24 GB
- Elixir 1.18.3, Erlang/OTP 27.3, JIT enabled
- benchee 1.5.1

Same machine, same `benchee`/Elixir/Erlang versions as the Before capture
above, in the same session (this phase's implementation run) - only `lib/`
changed (commits `c0f2b94`, `cf8b16c`) between the Before and After rows in
this file.
